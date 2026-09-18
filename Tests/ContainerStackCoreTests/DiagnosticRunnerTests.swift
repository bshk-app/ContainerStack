import Foundation
import Testing

@testable import ContainerStackCore

/// Fixed so `ranAt` is assertable: a report must never stamp itself from `Date()`.
let diagnosticClockDate = Date(timeIntervalSince1970: 1_700_000_000)

/// The socket the fixtures describe, and the bridge that counts as ours on them.
let diagnosticSocketPath = "/tmp/containerstack-doctor-tests.sock"
let diagnosticBridgePath = "/Applications/ContainerStack.app/Contents/Helpers/socktainer"

func makeRunner(
    probe: any SystemProbe,
    transport: StubDockerTransport = StubDockerTransport(byPath: [:]),
    socketPath: String = diagnosticSocketPath,
    bridgePath: String = diagnosticBridgePath,
    now: Date = diagnosticClockDate
) -> DiagnosticRunner {
    DiagnosticRunner(
        client: DockerAPIClient(transport: transport),
        probe: probe,
        socketPath: socketPath,
        bridgePath: bridgePath,
        now: { now }
    )
}

/// Probe results default to empty output rather than to nothing: an unconfigured
/// `RecordingSystemProbe` method records an issue, which no caller here wants.
func makeRunner(
    runtimeStatus: ProbeResult = .output(""),
    routingTable: ProbeResult = .output(""),
    socketHolder: ProbeResult = .output(""),
    processTable: ProbeResult = .output(""),
    transport: StubDockerTransport = StubDockerTransport(byPath: [:]),
    socketPath: String = diagnosticSocketPath,
    bridgePath: String = diagnosticBridgePath,
    now: Date = diagnosticClockDate
) -> DiagnosticRunner {
    makeRunner(
        probe: RecordingSystemProbe(
            runtimeStatus: runtimeStatus,
            routingTable: routingTable,
            socketHolder: socketHolder,
            processTable: processTable
        ),
        transport: transport,
        socketPath: socketPath,
        bridgePath: bridgePath,
        now: now
    )
}

/// A socket that answers. Without it `resolve` never reaches the branches this
/// suite is about: both `foreignBridge` and `missingAppRoot` require a live socket.
func respondingSocket() -> StubDockerTransport {
    StubDockerTransport(byPath: ["/_ping": .success(jsonResponse("OK"))])
}

@Suite("A run answers every requested check and nothing else")
struct DiagnosticRunnerTests {
    @Test("one check per requested id, in a fixed order")
    func everyRequestedCheckAppearsExactlyOnce() async {
        let report = await makeRunner().run(checks: [.appRoot, .routes])
        #expect(Set(report.checks.map(\.id)) == [.appRoot, .routes])
        #expect(report.checks.count == 2)
        #expect(report.checks.map(\.id) == [.appRoot, .routes])
    }

    // Spelled out rather than derived from `allCases`: reordering `CheckID` away from
    // F-004 precedence must fail here, not pass against a moving target.
    @Test("the emitted order is the declared order, pinned literally")
    func theReportEmitsChecksInTheDeclaredOrder() async {
        let report = await makeRunner().run(checks: Set(CheckID.allCases))
        #expect(
            report.checks.map(\.id) == [
                .foreignBridge, .appRoot, .socket, .versions, .routes, .dockerContext,
                .memoryCommitment,
            ]
        )
    }

    // The producer owns what `DiagnosticCheck` cannot: a check that was not run
    // names no repair.
    @Test("a skipped check carries no remedy")
    func theSkeletonSkipsEveryCheckWithoutNamingARemedy() async {
        let report = await makeRunner().run(checks: Set(CheckID.allCases))
        #expect(report.checks.count == CheckID.allCases.count)
        #expect(report.checks.allSatisfy { $0.verdict == .skipped })
        #expect(report.checks.allSatisfy { $0.remedy == nil })
        #expect(report.checks.allSatisfy { !$0.summary.isEmpty })
    }

    @Test("the stamp is the injected clock's, not the wall clock's")
    func theReportIsStampedByTheInjectedClock() async {
        let report = await makeRunner(now: diagnosticClockDate).run(checks: [.socket])
        #expect(report.ranAt == diagnosticClockDate)
    }

    @Test("an empty request is an empty report, not an error")
    func anEmptyCheckSetStillProducesAStampedReport() async {
        let report = await makeRunner().run(checks: [])
        #expect(report.checks.isEmpty)
        #expect(report.ranAt == diagnosticClockDate)
    }
}

/// `RuntimeState.resolve` is the only place that ranks one failure above another,
/// so these fixtures assert the projection of its answer, never a second ordering.
@Suite("Precedence is whatever RuntimeState.resolve decided")
struct DiagnosticRunnerPrecedenceTests {
    private let missingRoot = "/tmp/containerstack-doctor-tests/root-that-is-gone"

    private var statusWithMissingRoot: String {
        """
        FIELD              VALUE
        status             running
        appRoot            \(missingRoot)
        installRoot        /usr/local/
        """
    }

    private let foreignLsofOutput = "p4242\ncsocktainer\nn/tmp/containerstack-doctor-tests.sock"
    private let ourLsofOutput = "p777\ncsocktainer\nn/tmp/containerstack-doctor-tests.sock"
    private let processTable = """
            1 /sbin/launchd
          777 \(diagnosticBridgePath) --socket /tmp/containerstack-doctor-tests.sock
        """

    private func wedgedByAForeignBridge(checks: Set<CheckID>) async -> DiagnosticReport {
        await makeRunner(
            runtimeStatus: .output(statusWithMissingRoot),
            socketHolder: .output(foreignLsofOutput),
            processTable: .output(processTable),
            transport: respondingSocket()
        ).run(checks: checks)
    }

    @Test("a foreign bridge outranks a missing app root")
    func aForeignBridgeOutranksAMissingAppRoot() async {
        let report = await wedgedByAForeignBridge(checks: CheckID.uiSet)
        #expect(report.check(.foreignBridge)?.verdict == .failure)
        #expect(report.check(.appRoot)?.verdict == .skipped)
        #expect(report.check(.socket)?.verdict == .skipped)
        #expect(report.check(.appRoot)?.summary.contains(diagnosticSocketPath) == true)
    }

    // F-005 in both sets: the CLI measures bridge ownership too, and a local restart
    // is the wrong remedy against a socket someone else serves.
    @Test("no local-restart remedy is offered under a foreign bridge, in either set")
    func aForeignBridgeNeverOffersALocalRestart() async {
        for checks in [CheckID.uiSet, CheckID.cliSet] {
            let report = await wedgedByAForeignBridge(checks: checks)
            #expect(report.check(.foreignBridge)?.verdict == .failure)
            #expect(report.check(.appRoot)?.verdict == .skipped)
            #expect(report.checks.allSatisfy { $0.remedy != .restartRuntime })
            #expect(report.checks.contains { $0.verdict == .failure })
        }
    }

    @Test("a missing app root alone is the failure, and the checks below it are skipped")
    func aMissingAppRootAloneFailsTheAppRootCheck() async {
        let report = await makeRunner(
            runtimeStatus: .output(statusWithMissingRoot),
            socketHolder: .output(ourLsofOutput),
            processTable: .output(processTable),
            transport: respondingSocket()
        ).run(checks: CheckID.uiSet)
        #expect(report.check(.appRoot)?.verdict == .failure)
        #expect(report.check(.appRoot)?.remedy == .restartRuntime)
        #expect(report.check(.foreignBridge)?.verdict == .skipped)
        #expect(report.check(.socket)?.verdict == .skipped)
        #expect(report.check(.socket)?.summary.contains(missingRoot) == true)
    }

    // F-003 forbids drift: these are the bytes `cstack doctor` prints today
    // (`CStackCommands.swift:25-27`), copied rather than improved.
    @Test("the app-root failure reproduces today's CLI wording verbatim")
    func aMissingAppRootCarriesTheCLIsOwnWording() async {
        let report = await makeRunner(
            runtimeStatus: .output(statusWithMissingRoot),
            socketHolder: .output(ourLsofOutput),
            processTable: .output(processTable),
            transport: respondingSocket()
        ).run(checks: CheckID.cliSet)
        let appRoot = report.check(.appRoot)
        #expect(appRoot?.verdict == .failure)
        #expect(
            appRoot?.summary
                == "Runtime storage: MISSING — storing into \(missingRoot), which no longer exists."
        )
        #expect(
            appRoot?.detail
                == """
                Images, volumes and containers kept there cannot be found.
                The restart moves it back to the default location. Run: cstack runtime restart
                """
        )
        #expect(appRoot?.remedy == .restartRuntime)
    }

    // The assertion that the ordering is not copied: the expected state is computed by
    // `resolve` itself, so a change there moves this fixture rather than contradicting it.
    @Test("the failing check is the one resolve names, for the same signals")
    func theProjectedFailureIsWhateverResolveNames() async {
        let state = RuntimeState.resolve(
            socketResponds: true,
            helperRunning: true,
            isStarting: false,
            failure: nil,
            missingAppRoot: missingRoot,
            foreignBridge: diagnosticSocketPath
        )
        #expect(state == .foreignBridge(socketPath: diagnosticSocketPath))
        let report = await wedgedByAForeignBridge(checks: CheckID.uiSet)
        #expect(report.checks.filter { $0.verdict == .failure }.map(\.id) == [.foreignBridge])
        #expect(report.check(.foreignBridge)?.summary == state.title)
        #expect(report.check(.foreignBridge)?.detail == state.detail)
    }

    // F-010: a runtime that is not there is grey with a reason, not red.
    @Test("a socket that does not answer skips every check with a reason")
    func anUnreachableSocketSkipsEveryCheck() async {
        let report = await makeRunner(
            runtimeStatus: .output(statusWithMissingRoot),
            socketHolder: .output(foreignLsofOutput),
            processTable: .output(processTable)
        ).run(checks: CheckID.uiSet)
        #expect(report.checks.allSatisfy { $0.verdict == .skipped })
        #expect(report.checks.allSatisfy { !$0.summary.isEmpty })
        #expect(report.checks.allSatisfy { $0.remedy == nil })
    }

    // F-010 also splits stopped from wedged: a socket that times out must be `.indeterminate`,
    // never `.skipped`. `resolve` has no wedged case yet, so today's answer is pinned as wrong.
    @Test("a wedged socket is still grey, which F-010 forbids")
    func aWedgedSocketIsNotYetToldApartFromAStoppedOne() async {
        let report = await makeRunner(
            transport: StubDockerTransport(byPath: ["/_ping": .failure(UnixSocketError.timedOut)])
        ).run(checks: CheckID.uiSet)
        #expect(report.checks.allSatisfy { $0.verdict == .skipped })
        withKnownIssue("a wedged socket reads as a stopped one until resolve can tell them apart") {
            #expect(report.checks.contains { $0.verdict == .indeterminate })
        }
    }
}
