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

    /// The transport's own words, not the Doctor's: `UnixSocketError` carries no message,
    /// so what a failed call reports is whatever Foundation bridges it to.
    private let transportFailure = UnixSocketError.timedOut.localizedDescription

    private var statusWithMissingRoot: String {
        """
        FIELD              VALUE
        status             running
        appRoot            \(missingRoot)
        installRoot        /usr/local/
        """
    }

    private let publishingContainers = """
        [{"Id":"c1","Names":["/web"],"State":"running",
          "Ports":[{"PrivatePort":80,"PublicPort":8080,"Type":"tcp"}],
          "NetworkSettings":{"Networks":{"compose_default":{}}}}]
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

    // Derived from `CStackCommands.swift:32-36` and `:56`, `:120`. The bridge line is F-003's
    // one behavioural addition; `:38` has no projection behind it and is absent (reported).
    @Test("a healthy runtime renders the CLI's block in the CLI's order")
    func aHealthyRuntimeRendersTodaysLines() async {
        let text = await rendered(
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
                Container routes: no running container publishes ports
                Container memory limits: 4.0 GB in explicit container limits vs 16.0 GB host memory
                """
        )
    }

    // Derived from `CStackCommands.swift:25-27`. `:24` prints the socket line first and has no
    // projection behind it in this state, so it is absent (reported).
    @Test("a missing app root renders the three lines the CLI prints for it")
    func aMissingAppRootRendersTodaysLines() async {
        let text = await rendered(
            runtimeStatus: .output(statusWithMissingRoot),
            transport: respondingSocket()
        )
        #expect(
            text == """
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
                Another Docker bridge holds \(diagnosticSocketPath), so starting and stopping containers can hang. \
                Stop it, then start the runtime again.
                Stop the other Docker bridge holding \(diagnosticSocketPath), then start the runtime again.
                """
        )
        #expect(!text.contains("Docker socket:"))
        #expect(!text.contains("Runtime storage:"))
    }

    // F-003 §2.1, row 1. Today's CLI aborts here, so only the table's line is owed; the reason
    // the probe gave follows it, which the table does not enumerate (reported).
    @Test("a status probe nobody could read renders the unknown-storage line")
    func anUnreadableStatusProbeRendersTheUnknownLine() async {
        let text = await rendered(
            runtimeStatus: .failed(reason: probeFailure),
            transport: quietRuntime()
        )
        #expect(
            text == """
                Docker bridge: ours
                Runtime storage: UNKNOWN — the runtime status could not be read.
                \(probeFailure)
                Docker socket: healthy
                API version: 1.43
                Engine: 1.7.0
                Containers: 0
                Images: 0
                Container routes: no running containers to check
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
                \(transportFailure)
                API version: UNKNOWN — the Docker API did not answer.
                \(transportFailure)
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
                \(transportFailure)
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
                \(transportFailure)
                Container memory limits: UNKNOWN — the Docker API did not answer.
                \(transportFailure)
                """
        )
    }

    // F-003 §2.1, row 7, and the one row today's projection cannot render: the memory check is
    // `.skipped` in this state, and a skipped check is what the foreign-bridge row renders as silence.
    @Test("a runtime with nothing running renders no memory line at all")
    func nothingRunningRendersNoMemoryLine() async {
        let text = await rendered(transport: quietRuntime(), hostMemoryBytes: hostBytes)
        #expect(text.contains("Container routes: no running containers to check"))
        #expect(!text.contains("Container memory limits"))
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
