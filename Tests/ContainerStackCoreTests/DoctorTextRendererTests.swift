import DiagnosticTestSupport
import Foundation
import Testing

@testable import ContainerStackCore

/// F-003's goldens. `doctor` prints and there is no CLI test target, so every expectation
/// here is derived by hand from `CStackCommands.swift` and cites the lines it came from.
@Suite("Doctor text reproduces the CLI's own lines")
struct DoctorTextRendererTests {
    private let hostBytes: Int64 = 16_000_000_000
    private let missingRoot = "/tmp/containerstack-doctor-tests/root-that-is-gone"
    private let probeFailure = "/usr/local/bin/container could not be run: ENOENT"
    private let foreignLsofOutput = "p4242\ncsocktainer\nn\(diagnosticSocketPath)"
    private var statusWithMissingRoot: String { statusWith(root: missingRoot) }

    private func statusWith(root: String) -> String {
        """
        FIELD              VALUE
        status             running
        appRoot            \(root)
        installRoot        /usr/local/
        """
    }

    /// `.intact` is only reached for a root that is there, so the golden for the line the CLI
    /// prints at `:38` needs a directory that exists.
    private func makeIntactRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "doctor-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private let publishingContainers = """
        [{"Id":"c1","Names":["/web"],"State":"running",
          "Ports":[{"PrivatePort":80,"PublicPort":8080,"Type":"tcp"}],
          "NetworkSettings":{"Networks":{"compose_default":{}}}}]
        """
    /// One network the routing table can answer for and one the runtime listed no record for, which
    /// is what makes `uncheckablePublishingNetworks` non-empty next to a reachable verdict.
    private let publishingOnTwoNetworks = """
        [{"Id":"c1","Names":["/web"],"State":"running",
          "Ports":[{"PrivatePort":80,"PublicPort":8080,"Type":"tcp"}],
          "NetworkSettings":{"Networks":{"compose_default":{},"legacy_default":{}}}}]
        """
    private let networksWithSubnet = """
        [{"Id":"n1","Name":"compose_default","Driver":"bridge",
          "IPAM":{"Config":[{"Subnet":"192.168.64.0/24"}]}}]
        """
    private let tableWithoutTheBridge = """
        Internet:
        Destination        Gateway            Flags        Netif
        default            192.168.1.1        UGScg          en0
        """
    private let routedTable = """
        Internet:
        Destination        Gateway            Flags        Netif
        default            192.168.1.1        UGScg          en0
        192.168.64         link#18            UC       bridge100
        """

    private func inspectResponse(id: String, memory: Int64) -> Data {
        jsonResponse(
            #"{"Id":"\#(id)","Name":"/\#(id)","State":{"Running":true},"HostConfig":{"Memory":\#(memory)}}"#
        )
    }

    private func runtime(
        containers: Result<Data, any Error>,
        networks: Result<Data, any Error>,
        info: String = #"{"Containers":0,"Images":0}"#,
        inspects: [String: Result<Data, any Error>] = [:]
    ) -> StubDockerTransport {
        var byPath: [String: Result<Data, any Error>] = [
            "/_ping": .success(jsonResponse("OK")),
            "/version": .success(jsonResponse(#"{"Version":"1.7.0","ApiVersion":"1.43"}"#)),
            "/info": .success(jsonResponse(info)),
            "/containers/json": containers,
            "/networks": networks,
        ]
        for (id, result) in inspects {
            byPath["/containers/\(id)/json"] = result
        }
        return StubDockerTransport(byPath: byPath)
    }

    /// An idle runtime that answers every call, which is the base every case varies from.
    private func quietRuntime() -> StubDockerTransport {
        runtime(containers: .success(jsonResponse("[]")), networks: .success(jsonResponse("[]")))
    }

    private func rendered(
        runtimeStatus: ProbeResult = .output(""),
        routingTable: ProbeResult = .output(""),
        socketHolder: ProbeResult = .output(ourBridgeLsofOutput),
        transport: StubDockerTransport,
        hostMemoryBytes: Int64? = nil
    ) async -> String {
        let report = await makeRunner(
            runtimeStatus: runtimeStatus,
            routingTable: routingTable,
            socketHolder: socketHolder,
            transport: transport,
            hostMemoryBytes: hostMemoryBytes
        ).run(checks: CheckID.cliSet)
        return DoctorTextRenderer.render(report)
    }

    // A refused socket is deliberately `.skipped` in the report (F-010), but a CLI
    // invocation must still say why it printed no other checks.
    @Test("a stopped runtime still tells the CLI user the socket is not responding")
    func aStoppedRuntimeNeverRendersAsSilence() async {
        let text = await rendered(transport: StubDockerTransport(byPath: [:]))
        #expect(text == "Docker socket: not responding")
    }

    @Test("a measured missing root does not turn a stopped runtime into a detachable one")
    func aStoppedRuntimeWithAMissingRootReportsOnlyTheSocket() async {
        let text = await rendered(
            runtimeStatus: .output(statusWithMissingRoot),
            transport: StubDockerTransport(byPath: [:])
        )
        #expect(text == "Docker socket: not responding")
    }

    // Derived from `CStackCommands.swift:32-36`, `:38` and `:56`, `:120`, in the order the CLI
    // prints them: storage follows the version block rather than leading the report.
    @Test("a healthy runtime renders the CLI's block in the CLI's order")
    func aHealthyRuntimeRendersTodaysLines() async throws {
        let root = try makeIntactRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = await rendered(
            runtimeStatus: .output(statusWith(root: root.path)),
            transport: runtime(
                containers: .success(jsonResponse(#"[{"Id":"c0","Names":["/c0"],"State":"running"}]"#)),
                networks: .success(jsonResponse("[]")),
                info: #"{"Containers":1,"Images":0}"#,
                inspects: ["c0": .success(inspectResponse(id: "c0", memory: 4_000_000_000))]
            ),
            hostMemoryBytes: hostBytes
        )
        #expect(
            text == """
                Docker bridge: ours
                Docker socket: healthy
                API version: 1.43
                Engine: 1.7.0
                Containers: 1
                Images: 0
                Runtime storage: \(root.path)
                Container routes: no running container publishes ports
                Container memory limits: 4.0 GB in explicit container limits vs 16.0 GB host memory
                """
        )
    }

    // Derived from `CStackCommands.swift:24-27`: the socket line leads, because `resolve` reaches
    // this state only with the socket answering.
    @Test("a missing app root renders the four lines the CLI prints for it")
    func aMissingAppRootRendersTodaysLines() async {
        let text = await rendered(
            runtimeStatus: .output(statusWithMissingRoot),
            transport: respondingSocket()
        )
        #expect(
            text == """
                Docker socket: healthy
                Runtime storage: MISSING — storing into \(missingRoot), which no longer exists.
                Images, volumes and containers kept there cannot be found.
                The restart moves it back to the default location. Run: cstack runtime restart
                """
        )
    }

    // Derived from `CStackCommands.swift:32-36`, `:69`, `:74-75`, `:120`. `.restartRuntime` is
    // not text, so the advice arrives only through `detail`, exactly as the CLI printed it.
    @Test("an unroutable network renders the CLI's route failure verbatim")
    func anUnroutableNetworkRendersTodaysLines() async {
        let text = await rendered(
            routingTable: .output(tableWithoutTheBridge),
            transport: runtime(
                containers: .success(jsonResponse(publishingContainers)),
                networks: .success(jsonResponse(networksWithSubnet)),
                info: #"{"Containers":1,"Images":1}"#,
                inspects: ["c1": .success(inspectResponse(id: "c1", memory: 4_000_000_000))]
            ),
            hostMemoryBytes: hostBytes
        )
        #expect(
            text == """
                Docker bridge: ours
                Docker socket: healthy
                API version: 1.43
                Engine: 1.7.0
                Containers: 1
                Images: 1
                Container routes: NO ROUTE to compose_default (192.168.64.0/24)
                Published ports accept connections and then hang.
                Restarting the containers does not fix it. Run: cstack runtime restart
                Container memory limits: 4.0 GB in explicit container limits vs 16.0 GB host memory
                """
        )
    }

    // F-003 §2.1, row 5. New to the CLI, so nothing is derived from `CStackCommands.swift`; the
    // checks the bridge makes meaningless are skipped and render nothing.
    @Test("a foreign bridge renders its ownership lines and silences the rest")
    func aForeignBridgeRendersOwnershipAndNothingElse() async {
        let text = await rendered(
            runtimeStatus: .output(statusWithMissingRoot),
            socketHolder: .output(foreignLsofOutput),
            transport: respondingSocket()
        )
        #expect(
            text == """
                Another Docker bridge is in use
                Process 4242 holds \(diagnosticSocketPath), so starting and stopping containers can hang. \
                Stop process 4242, then start the runtime again.
                """
        )
        #expect(!text.contains("Docker socket:"))
        #expect(!text.contains("Runtime storage:"))
    }

    // F-003 §2.1, rows 1 and 7. Today's CLI aborts here, so only the table's lines are owed; the
    // reason the probe gave follows the first, which the table does not enumerate (reported).
    @Test("a status probe nobody could read renders the unknown-storage line")
    func anUnreadableStatusProbeRendersTheUnknownLine() async {
        let text = await rendered(
            runtimeStatus: .failed(reason: probeFailure),
            transport: quietRuntime()
        )
        #expect(
            text == """
                Docker bridge: ours
                Docker socket: healthy
                API version: 1.43
                Engine: 1.7.0
                Containers: 0
                Images: 0
                Runtime storage: UNKNOWN — the runtime status could not be read.
                \(probeFailure)
                Container routes: no running containers to check
                Container memory limits: no running containers to check
                """
        )
    }

    // F-003 §2.1, rows 2 and 3: one wedged socket produces both lines, and every check below
    // it is grey rather than amber, so nothing else renders.
    @Test("a socket that timed out renders the socket and version unknowns")
    func aWedgedSocketRendersBothUnknownLines() async {
        let text = await rendered(
            transport: StubDockerTransport(byPath: ["/_ping": .failure(UnixSocketError.timedOut)])
        )
        #expect(
            text == """
                Docker socket: UNKNOWN — the socket did not answer before the timeout.
                The connection to the Docker socket timed out.
                API version: UNKNOWN — the Docker API did not answer.
                The connection to the Docker socket timed out.
                """
        )
    }

    // F-003 §2.1, row 4.
    @Test("a network listing that failed renders the unknown-routes line")
    func aFailedNetworkListingRendersTheUnknownLine() async {
        let text = await rendered(
            transport: runtime(
                containers: .success(jsonResponse("[]")),
                networks: .failure(UnixSocketError.timedOut)
            )
        )
        #expect(
            text == """
                Docker bridge: ours
                Docker socket: healthy
                API version: 1.43
                Engine: 1.7.0
                Containers: 0
                Images: 0
                Container routes: UNKNOWN — the Docker API did not answer.
                The connection to the Docker socket timed out.
                Container memory limits: no running containers to check
                """
        )
    }

    // T-016c: a response the parser rejects reaches the same line, and the words have to be ours.
    @Test("a network listing that could not be parsed renders our words for the parse failure")
    func anUnparseableNetworkListingRendersTheParseFailure() async {
        let text = await rendered(
            transport: runtime(
                containers: .success(jsonResponse("[]")),
                networks: .success(Data("not an HTTP response at all".utf8))
            )
        )
        #expect(
            text == """
                Docker bridge: ours
                Docker socket: healthy
                API version: 1.43
                Engine: 1.7.0
                Containers: 0
                Images: 0
                Container routes: UNKNOWN — the Docker API did not answer.
                The Docker API sent a response whose headers never ended.
                Container memory limits: no running containers to check
                """
        )
    }

    // F-003 §2.1, row 6.
    @Test("a socket whose holder nobody could see renders the unknown-bridge line")
    func anUnseenBridgeHolderRendersTheUnknownLine() async {
        let text = await rendered(socketHolder: .output(""), transport: quietRuntime())
        #expect(
            text == """
                Docker bridge: UNKNOWN — the process holding the socket could not be identified.
                The socket answers, but lsof named no process holding it, so its owner is not visible from here.
                Docker socket: healthy
                API version: 1.43
                Engine: 1.7.0
                Containers: 0
                Images: 0
                Container routes: no running containers to check
                Container memory limits: no running containers to check
                """
        )
    }

    // F-003 §2.1, row 8. The same failed listing answers both checks, so each renders its own
    // unknown line rather than one standing in for the other.
    @Test("a container listing that failed renders the unknown-memory line")
    func aFailedContainerListingRendersTheUnknownLine() async {
        let text = await rendered(
            transport: runtime(
                containers: .failure(UnixSocketError.timedOut),
                networks: .success(jsonResponse("[]"))
            )
        )
        #expect(
            text == """
                Docker bridge: ours
                Docker socket: healthy
                API version: 1.43
                Engine: 1.7.0
                Containers: 0
                Images: 0
                Container routes: UNKNOWN — the Docker API did not answer.
                The connection to the Docker socket timed out.
                Container memory limits: UNKNOWN — the Docker API did not answer.
                The connection to the Docker socket timed out.
                """
        )
    }

    // F-003 §2.1, row 7: the CLI returns before the memory report here, and the table sanctions
    // the line that says so, which a `.skipped` verdict would render as silence.
    @Test("a runtime with nothing running renders the memory line the table sanctions")
    func nothingRunningRendersTheMemoryLine() async {
        let text = await rendered(transport: quietRuntime(), hostMemoryBytes: hostBytes)
        #expect(text.contains("Container routes: no running containers to check"))
        #expect(text.contains("Container memory limits: no running containers to check"))
    }

    // Derived from `CStackCommands.swift:67` and `:81`, which the CLI prints one after the other:
    // a network nobody can judge does not withdraw the verdict on the networks that were judged.
    @Test("a reachable network and an unjudgeable one both render")
    func reachableNetworksSurviveAnUnjudgeableSibling() async {
        let text = await rendered(
            routingTable: .output(routedTable),
            transport: runtime(
                containers: .success(jsonResponse(publishingOnTwoNetworks)),
                networks: .success(jsonResponse(networksWithSubnet)),
                info: #"{"Containers":1,"Images":1}"#,
                inspects: ["c1": .success(inspectResponse(id: "c1", memory: 4_000_000_000))]
            ),
            hostMemoryBytes: hostBytes
        )
        #expect(
            text == """
                Docker bridge: ours
                Docker socket: healthy
                API version: 1.43
                Engine: 1.7.0
                Containers: 1
                Images: 1
                Container routes: reachable (compose_default (192.168.64.0/24))
                Container routes: cannot check legacy_default — no subnet reported
                Container memory limits: 4.0 GB in explicit container limits vs 16.0 GB host memory
                """
        )
    }

    // F-004 precedence and reading order are two lists that happen to overlap. Pinned here and in
    // `DiagnosticRunnerTests.theReportEmitsChecksInTheDeclaredOrder`, so moving one cannot move the other.
    @Test("the CLI print order is its own list, pinned literally")
    func thePrintOrderIsPinnedApartFromPrecedence() {
        #expect(
            DoctorTextRenderer.printOrder == [
                .foreignBridge, .socket, .versions, .appRoot, .routes, .dockerContext,
                .memoryCommitment,
            ]
        )
        #expect(DoctorTextRenderer.printOrder != CheckID.allCases)
        // Total over `CheckID`: a new check has to be given a place to print rather than vanishing.
        #expect(Set(DoctorTextRenderer.printOrder) == Set(CheckID.allCases))
        #expect(DoctorTextRenderer.printOrder.count == CheckID.allCases.count)
    }

    @Test("a precedence-ordered report renders in print order")
    func theRendererReordersAPrecedenceOrderedReport() {
        let report = DiagnosticReport(
            checks: [
                DiagnosticCheck(
                    id: .appRoot,
                    verdict: .ok,
                    summary: "Runtime storage: /tmp/root",
                    detail: nil,
                    remedy: nil,
                    duration: .zero
                ),
                DiagnosticCheck(
                    id: .socket,
                    verdict: .ok,
                    summary: "Docker socket: healthy",
                    detail: nil,
                    remedy: nil,
                    duration: .zero
                ),
            ],
            ranAt: diagnosticClockDate
        )
        #expect(
            DoctorTextRenderer.render(report) == """
                Docker socket: healthy
                Runtime storage: /tmp/root
                """
        )
    }

    // The hazard: the advice is both a `detail` line and the remedy, and here a trailing line
    // follows it, so matching the tail alone would print it twice.
    @Test("advice carried by both detail and remedy is rendered once")
    func duplicatedAdviceIsRenderedOnce() async {
        let text = await rendered(
            transport: runtime(
                containers: .success(
                    jsonResponse(#"[{"Id":"c0","State":"running"},{"Id":"c1","State":"running"}]"#)
                ),
                networks: .success(jsonResponse("[]")),
                info: #"{"Containers":2,"Images":0}"#,
                inspects: [
                    "c0": .success(inspectResponse(id: "c0", memory: 14_000_000_000)),
                    "c1": .failure(UnixSocketError.timedOut),
                ]
            ),
            hostMemoryBytes: hostBytes
        )
        let advice = "Stop a container or recreate it with a smaller --memory."
        #expect(text.components(separatedBy: advice).count - 1 == 1)
        #expect(
            text == """
                Docker bridge: ours
                Docker socket: healthy
                API version: 1.43
                Engine: 1.7.0
                Containers: 2
                Images: 0
                Container routes: no running container publishes ports
                Container memory limits: HIGH — 14.0 GB in explicit container limits vs 16.0 GB host memory
                Guests do not reserve every byte immediately, but host use can grow toward these limits.
                \(advice)
                1 running container(s) could not be inspected, so the total is incomplete.
                """
        )
    }

    // A `.manual` remedy nothing in `detail` already says is advice the CLI would otherwise lose.
    @Test("a manual remedy absent from detail is rendered")
    func manualAdviceMissingFromDetailIsRendered() {
        let check = DiagnosticCheck(
            id: .foreignBridge,
            verdict: .failure,
            summary: "Docker bridge: foreign",
            detail: "Someone else holds it.",
            remedy: .manual("Stop the other bridge."),
            duration: .zero
        )
        let report = DiagnosticReport(checks: [check], ranAt: diagnosticClockDate)
        #expect(
            DoctorTextRenderer.render(report) == """
                Docker bridge: foreign
                Someone else holds it.
                Stop the other bridge.
                """
        )
    }

    // NFR-005: `duration` is the log line's, not the CLI's.
    @Test("a check's duration never reaches the rendered text")
    func theDurationIsNeverRendered() {
        let check = DiagnosticCheck(
            id: .socket,
            verdict: .ok,
            summary: "Docker socket: healthy",
            detail: nil,
            remedy: nil,
            duration: .seconds(7)
        )
        let report = DiagnosticReport(checks: [check], ranAt: diagnosticClockDate)
        #expect(DoctorTextRenderer.render(report) == "Docker socket: healthy")
    }

    @Test("the report's stamp never reaches the rendered text")
    func theStampIsNeverRendered() async {
        let text = await rendered(transport: quietRuntime())
        #expect(!text.contains("2023"))
        #expect(!text.contains(diagnosticClockDate.description))
    }

    // F-012: the CLI is `print(render(report))`, and `print` supplies the final newline.
    @Test("the text carries no trailing newline and an empty report is empty text")
    func theTextEndsWithoutATrailingNewline() async {
        let text = await rendered(transport: quietRuntime())
        #expect(!text.hasSuffix("\n"))
        #expect(DoctorTextRenderer.render(DiagnosticReport(checks: [], ranAt: diagnosticClockDate)).isEmpty)
    }
}
