import Foundation
import Synchronization
import Testing

@testable import ContainerStackCore

/// Every `docker` command the check was handed, through the runner `recordedSocketPath(for:using:)`
/// already takes, so a test can prove the check read the record and wrote nothing.
private final class RecordedContextCommands: Sendable {
    private let listing: Result<String, DockerCLIError>
    private let commands = Mutex<[[String]]>([])

    init(listing: Result<String, DockerCLIError>) { self.listing = listing }

    var all: [[String]] { commands.withLock { $0 } }

    var recordedSocketPath: @Sendable (String) throws -> String? {
        { try DockerCLI.recordedSocketPath(for: $0, using: self.run) }
    }

    private func run(_ arguments: [String]) throws -> String {
        commands.withLock { $0.append(arguments) }
        return try listing.get()
    }
}

/// The dispatch queue each listing ran on, which is how a test tells a thread of Swift's
/// cooperative pool from any other: libdispatch labels those `com.apple.root.<qos>.cooperative`.
private final class ListingQueues: Sendable {
    private let labels = Mutex<[String]>([])

    var all: [String] { labels.withLock { $0 } }

    func record() { labels.withLock { $0.append(String(cString: __dispatch_queue_get_label(nil))) } }
}

/// Decision 8: Doctor judges the record with the pure pieces the repair is built from and never
/// writes it, because a diagnostic that repairs while reporting is not a diagnostic.
@Suite("The docker-context check reads the record and never repairs it")
struct DiagnosticRunnerDockerContextTests {
    private let retiredSocketPath = "/tmp/containerstack-doctor-tests/retired.sock"
    private let foreignLsofOutput = "p4242\ncsocktainer\nn\(diagnosticSocketPath)"

    private func listing(recording path: String) -> Result<String, DockerCLIError> {
        .success("default\tunix:///var/run/docker.sock\n\(DockerContext.name)\tunix://\(path)")
    }

    private func report(
        _ commands: RecordedContextCommands,
        setting: DiagnosticRunner.DockerContextSetting? = managedDockerContext,
        socketHolder: ProbeResult = .output(ourBridgeLsofOutput),
        transport: StubDockerTransport = respondingRuntime()
    ) async -> DiagnosticReport {
        await makeRunner(
            socketHolder: socketHolder,
            transport: transport,
            dockerContextSetting: setting,
            recordedSocketPath: commands.recordedSocketPath
        ).run(checks: CheckID.uiSet)
    }

    @Test("a record naming another socket is amber, with the repair the app already has")
    func aStaleRecordIsAWarningWithTheRepair() async {
        let commands = RecordedContextCommands(listing: listing(recording: retiredSocketPath))
        let check = await report(commands).check(.dockerContext)
        #expect(check?.verdict == .warning)
        #expect(check?.remedy == .repairDockerContext)
        #expect(check?.summary == "Docker context: containerstack points at a retired socket")
        #expect(
            check?.detail
                == "It records /tmp/containerstack-doctor-tests/retired.sock, not /tmp/containerstack-doctor-tests.sock."
                + " The repair rewrites the record without switching to it."
        )
    }

    @Test("a record naming the current socket is healthy and offers nothing")
    func aCurrentRecordIsHealthy() async {
        let commands = RecordedContextCommands(listing: listing(recording: diagnosticSocketPath))
        let check = await report(commands).check(.dockerContext)
        #expect(check?.verdict == .ok)
        #expect(check?.remedy == nil)
        #expect(check?.summary == "Docker context: no stale record to repair")
    }

    // F-009: a listing that never arrived is not a record that matched. The reason is the error's
    // own wording, never Foundation's bridge text (T-016b).
    @Test("a listing that could not run is amber, never healthy, and says why")
    func anUnreadableRecordIsIndeterminate() async {
        let commands = RecordedContextCommands(
            listing: .failure(.failed(command: "context ls", status: 1, output: "config.json: permission denied"))
        )
        let check = await report(commands).check(.dockerContext)
        #expect(check?.verdict == .indeterminate)
        #expect(check?.remedy == nil)
        #expect(check?.summary == "Docker context: UNKNOWN — the context record could not be checked.")
        #expect(check?.detail == "docker context ls exited with status 1: config.json: permission denied")
    }

    // The stale fixture is the one where a repairing check would act, so it is the one that proves
    // this check does not: one listing, NFR-001's fifth spawn, and nothing after it.
    @Test("the check lists the contexts once and runs no command that would repair them")
    func theCheckOnlyReadsTheRecord() async {
        let commands = RecordedContextCommands(listing: listing(recording: retiredSocketPath))
        _ = await report(commands)
        #expect(commands.all == [["context", "ls", "--format", "{{.Name}}\t{{.DockerEndpoint}}"]])
        #expect(!commands.all.contains { $0.contains("use") || $0.contains("update") })
    }

    @Test("without the app's context setting the check is amber and lists nothing")
    func anUnknownSettingIsIndeterminateWithoutASpawn() async {
        let commands = RecordedContextCommands(listing: listing(recording: retiredSocketPath))
        let check = await report(commands, setting: nil).check(.dockerContext)
        #expect(check?.verdict == .indeterminate)
        #expect(check?.remedy == nil)
        #expect(check?.detail == "The app did not say whether ContainerStack manages the Docker context.")
        #expect(commands.all.isEmpty)
    }

    // F-005: the repair would point Docker at a socket another bridge serves, so the check is grey
    // beneath it, as every check below a foreign bridge is.
    @Test("a stale record under a foreign bridge is grey and offers no repair")
    func aForeignBridgeOutranksAStaleRecord() async {
        let commands = RecordedContextCommands(listing: listing(recording: retiredSocketPath))
        let report = await report(commands, socketHolder: .output(foreignLsofOutput), transport: respondingSocket())
        #expect(report.check(.foreignBridge)?.verdict == .failure)
        #expect(report.check(.dockerContext)?.verdict == .skipped)
        #expect(report.checks.allSatisfy { $0.remedy != .repairDockerContext })
    }

    // F-010: a stopped runtime is grey with a reason, whatever the record says.
    @Test("a stale record on a stopped runtime is grey and offers no repair")
    func aStoppedRuntimeLeavesTheCheckGrey() async {
        let commands = RecordedContextCommands(listing: listing(recording: retiredSocketPath))
        let report = await report(commands, transport: StubDockerTransport(byPath: [:]))
        #expect(report.check(.dockerContext)?.verdict == .skipped)
        #expect(report.check(.dockerContext)?.summary.isEmpty == false)
        #expect(report.checks.allSatisfy { $0.remedy == nil })
    }

    // F-009: the rule declines when the record is missing as well as when it matches, and only the
    // second is an answer. A listing without our endpoint was not compared, so it is not `.ok`.
    @Test("a listing that names no unix socket for our context is amber, never healthy")
    func aMissingRecordIsIndeterminate() async {
        let listings = [
            "default\tunix:///var/run/docker.sock",
            "default\tunix:///var/run/docker.sock\n\(DockerContext.name)\ttcp://192.168.1.5:2375",
        ]
        for listing in listings {
            let check = await report(RecordedContextCommands(listing: .success(listing))).check(.dockerContext)
            #expect(check?.verdict == .indeterminate, "\(listing)")
            #expect(check?.remedy == nil)
            #expect(
                check?.detail
                    == "docker context ls named no unix socket for containerstack, so its record could not be compared."
            )
        }
    }

    @Test("an installation the app has not read is amber only while the record could need repair")
    func anUnreadInstallationIsIndeterminate() async {
        let setting = DiagnosticRunner.DockerContextSetting(
            takeoverEnabled: true,
            installed: nil,
            activeContext: DockerContext.fallbackName
        )
        let retired = RecordedContextCommands(listing: listing(recording: retiredSocketPath))
        let stale = await report(retired, setting: setting).check(.dockerContext)
        #expect(stale?.verdict == .indeterminate)
        #expect(stale?.detail == "The app has not yet read whether the containerstack context is installed.")

        let current = RecordedContextCommands(listing: listing(recording: diagnosticSocketPath))
        #expect(await report(current, setting: setting).check(.dockerContext)?.verdict == .ok)
    }

    // The bound on the two tests above: an unknown is amber only where it could change the answer,
    // and nothing the record says changes it for a context the app does not manage.
    @Test("a context the app does not manage is healthy, whatever is unknown about it")
    func anUnmanagedContextIsHealthy() async {
        let setting = DiagnosticRunner.DockerContextSetting(
            takeoverEnabled: false,
            installed: nil,
            activeContext: DockerContext.fallbackName
        )
        let commands = RecordedContextCommands(listing: .success("default\tunix:///var/run/docker.sock"))
        let check = await report(commands, setting: setting).check(.dockerContext)
        #expect(check?.verdict == .ok)
        #expect(check?.remedy == nil)
    }

    // NFR-002: `ProcessRunner.run` holds its thread until the child exits. Held on the cooperative
    // pool, it can take the thread the budget's timer needs, and the run then outlasts its deadline.
    @Test("the listing never blocks a thread of the cooperative pool")
    func theListingRunsOffTheCooperativePool() async {
        let queues = ListingQueues()
        _ = await makeRunner(
            transport: respondingRuntime(),
            recordedSocketPath: { _ in
                queues.record()
                return diagnosticSocketPath
            }
        ).run(checks: CheckID.uiSet)
        #expect(queues.all.count == 1)
        #expect(queues.all.allSatisfy { !$0.hasSuffix(".cooperative") }, "\(queues.all)")
    }
    // NFR-002: the listing blocks on a spawn nothing cancels, so one that never returns is cut off
    // by the run's budget like any other probe, and carries the time it burned.
    @Test("a listing that never returns is amber once the budget expires")
    func aHungListingIsCutOffByTheBudget() async {
        let release = DispatchSemaphore(value: 0)
        let report = await makeRunner(
            transport: respondingRuntime(),
            recordedSocketPath: { _ in
                release.wait()
                return diagnosticSocketPath
            },
            budget: .milliseconds(200)
        ).run(checks: CheckID.uiSet)
        release.signal()
        let check = report.check(.dockerContext)
        #expect(check?.verdict == .indeterminate)
        #expect(check?.detail == DiagnosticRunner.budgetExpired)
        #expect(check?.duration != .zero)
    }

    /// `count` running containers publishing on one network with a subnet: from one upward the
    /// routes check needs `netstat`, so the run spends every spawn NFR-001 allows.
    private func publishing(_ count: Int) -> StubDockerTransport {
        let containers = (1..<count + 1).map { index in
            #"{"Id":"c\#(index)","Names":["/web\#(index)"],"State":"running","#
                + #""Ports":[{"PrivatePort":80,"PublicPort":\#(8000 + index),"Type":"tcp"}],"#
                + #""NetworkSettings":{"Networks":{"compose_default":{}}}}"#
        }
        return StubDockerTransport(byPath: [
            "/_ping": .success(jsonResponse("OK")),
            "/version": .success(jsonResponse(#"{"Version":"1.7.0","ApiVersion":"1.43"}"#)),
            "/info": .success(jsonResponse(#"{"Containers":\#(count),"Images":1}"#)),
            "/containers/json": .success(jsonResponse("[\(containers.joined(separator: ","))]")),
            "/networks": .success(
                jsonResponse(
                    #"[{"Id":"n1","Name":"compose_default","Driver":"bridge","#
                        + #""IPAM":{"Config":[{"Subnet":"192.168.64.0/24"}]}}]"#
                )
            ),
        ])
    }

    /// Both seams a run spawns through: the four `SystemProbe` commands, and the listing decision 8
    /// sends through `DockerCLI` instead, which a probe fake alone would never see.
    private func spawns(
        of checks: Set<CheckID>,
        publishing count: Int
    ) async -> (probe: [ProbeCall], listings: Int, paths: [String]) {
        let probe = RecordingSystemProbe(
            runtimeStatus: .output(""),
            routingTable: .output("Internet:\ndefault  192.168.1.1  UGScg  en0\n192.168.64  link#18  UC  bridge100"),
            socketHolder: .output(ourBridgeLsofOutput),
            processTable: .output(ourBridgeProcessTable)
        )
        let commands = RecordedContextCommands(listing: listing(recording: diagnosticSocketPath))
        let transport = publishing(count)
        _ = await makeRunner(
            probe: probe,
            transport: transport,
            recordedSocketPath: commands.recordedSocketPath
        ).run(checks: checks)
        return (await probe.calls.sorted { $0.rawValue < $1.rawValue }, commands.all.count, await transport.paths)
    }

    // NFR-001's acceptance, counted across both seams: the listing is the UI set's fifth spawn and
    // never the CLI's. Only `netstat` depends on the machine, and only on whether anything publishes.
    @Test("spawns stay within four for the CLI set and five for the UI set, however many containers run")
    func spawnTotalsAreBoundedByTheCheckSet() async {
        let everyProbe: [ProbeCall] = [.processTable, .routingTable, .runtimeStatus, .socketHolder]
        for count in [0, 1, 20] {
            let probes = count == 0 ? everyProbe.filter { $0 != .routingTable } : everyProbe
            let ui = await spawns(of: CheckID.uiSet, publishing: count)
            let cli = await spawns(of: CheckID.cliSet, publishing: count)
            #expect(ui.probe == probes, "UI set, \(count) publishing")
            #expect(ui.listings == 1, "UI set, \(count) publishing")
            #expect(ui.probe.count + ui.listings == (count == 0 ? 4 : 5), "UI set, \(count) publishing")
            #expect(ui.paths == ["/_ping", "/version", "/info", "/containers/json", "/networks"], "\(count)")
            #expect(cli.probe == probes, "CLI set, \(count) publishing")
            #expect(cli.listings == 0, "CLI set, \(count) publishing")
            #expect(cli.probe.count + cli.listings == (count == 0 ? 3 : 4), "CLI set, \(count) publishing")
        }
    }
}
