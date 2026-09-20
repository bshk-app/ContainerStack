import Foundation
import Testing

@testable import ContainerStackCore

/// Fixed so `ranAt` is assertable: a report must never stamp itself from `Date()`.
let diagnosticClockDate = Date(timeIntervalSince1970: 1_700_000_000)

/// The socket the fixtures describe, and the bridge that counts as ours on them.
let diagnosticSocketPath = "/tmp/containerstack-doctor-tests.sock"
let diagnosticBridgePath = "/Applications/ContainerStack.app/Contents/Helpers/socktainer"

/// A machine whose socket is held by the bridge this build ships. The default every
/// fixture takes, because a holder nobody can see is unknown ownership, not ours.
let ourBridgeLsofOutput = "p777\ncsocktainer\nn\(diagnosticSocketPath)"
let ourBridgeProcessTable = """
        1 /sbin/launchd
      777 \(diagnosticBridgePath) --socket \(diagnosticSocketPath)
    """

func makeRunner(
    probe: any SystemProbe,
    transport: StubDockerTransport = StubDockerTransport(byPath: [:]),
    socketPath: String = diagnosticSocketPath,
    bridgePath: String = diagnosticBridgePath,
    hostMemoryBytes: Int64? = nil,
    now: Date = diagnosticClockDate,
    ticks: @escaping @Sendable () -> Duration = MonotonicTicks.sinceStart,
    log: @escaping @Sendable (String) -> Void = { _ in },
    budget: Duration = DiagnosticRunner.defaultBudget
) -> DiagnosticRunner {
    DiagnosticRunner(
        client: DockerAPIClient(transport: transport),
        probe: probe,
        socketPath: socketPath,
        bridgePath: bridgePath,
        hostMemoryBytes: { hostMemoryBytes },
        now: { now },
        ticks: ticks,
        log: log,
        budget: budget
    )
}

/// Probe results default to empty output rather than to nothing: an unconfigured
/// `RecordingSystemProbe` method records an issue, which no caller here wants.
func makeRunner(
    runtimeStatus: ProbeResult = .output(""),
    routingTable: ProbeResult = .output(""),
    socketHolder: ProbeResult = .output(ourBridgeLsofOutput),
    processTable: ProbeResult = .output(ourBridgeProcessTable),
    transport: StubDockerTransport = StubDockerTransport(byPath: [:]),
    socketPath: String = diagnosticSocketPath,
    bridgePath: String = diagnosticBridgePath,
    hostMemoryBytes: Int64? = nil,
    now: Date = diagnosticClockDate,
    ticks: @escaping @Sendable () -> Duration = MonotonicTicks.sinceStart,
    log: @escaping @Sendable (String) -> Void = { _ in },
    budget: Duration = DiagnosticRunner.defaultBudget
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
        hostMemoryBytes: hostMemoryBytes,
        now: now,
        ticks: ticks,
        log: log,
        budget: budget
    )
}

/// A socket that answers. Without it `resolve` never reaches the branches this
/// suite is about: both `foreignBridge` and `missingAppRoot` require a live socket.
func respondingSocket() -> StubDockerTransport {
    StubDockerTransport(byPath: ["/_ping": .success(jsonResponse("OK"))])
}

/// A runtime that answers every call the socket and versions checks make. `respondingSocket`
/// answers only the ping, which leaves the versions check unmeasurable.
func respondingRuntime() -> StubDockerTransport {
    StubDockerTransport(byPath: [
        "/_ping": .success(jsonResponse("OK")),
        "/version": .success(jsonResponse(#"{"Version":"1.7.0","ApiVersion":"1.43"}"#)),
        "/info": .success(jsonResponse(#"{"Containers":3,"Images":11}"#)),
    ])
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

    // F-010 splits stopped from wedged, and the split is made here rather than in `resolve`:
    // both are `.offline`, and only the transport knows which of them happened.
    @Test("a wedged socket is amber, never the grey of a stopped one")
    func aWedgedSocketIsToldApartFromAStoppedOne() async {
        let report = await makeRunner(
            transport: StubDockerTransport(byPath: ["/_ping": .failure(UnixSocketError.timedOut)])
        ).run(checks: CheckID.uiSet)
        #expect(report.check(.socket)?.verdict == .indeterminate)
        #expect(report.check(.versions)?.verdict == .indeterminate)
        #expect(report.checks.contains { $0.verdict == .indeterminate })
        #expect(report.checks.allSatisfy { $0.verdict != .skipped } == false)
        #expect(report.check(.appRoot)?.verdict == .skipped)
        #expect(report.checks.allSatisfy { $0.remedy == nil })
        #expect(report.checks.allSatisfy { !$0.summary.isEmpty })
    }

    // A launchd-started bridge answering something other than `OK`: `ping` returns false without
    // throwing, so only `helperRunning` decides, and this caller launched nothing (#44).
    @Test("a wedged bridge this caller did not launch never reports a start in progress")
    func aBridgeThisCallerDidNotLaunchIsNeverAStartInProgress() async {
        let report = await makeRunner(
            socketHolder: .output(ourLsofOutput),
            processTable: .output(processTable),
            transport: StubDockerTransport(byPath: ["/_ping": .success(jsonResponse("wedged"))])
        ).run(checks: CheckID.uiSet)
        #expect(report.checks.allSatisfy { $0.verdict != .ok })
        #expect(report.checks.allSatisfy { $0.summary != RuntimeState.starting.detail })
        #expect(report.check(.socket)?.summary == RuntimeState.genericFailure)
        #expect(report.check(.appRoot)?.summary == RuntimeState.genericFailure)
    }
}

/// F-009. The chain this suite pins shut: `CommandShell.output` returns `""` for a command
/// that never ran, and `RuntimeStatusParser.missingAppRoot("")` is nil — "no missing root".
@Suite("A probe that could not run never reads as a healthy app root")
struct DiagnosticRunnerProbeFailureTests {
    private let ourLsofOutput = "p777\ncsocktainer\nn/tmp/containerstack-doctor-tests.sock"
    private let foreignLsofOutput = "p4242\ncsocktainer\nn/tmp/containerstack-doctor-tests.sock"
    private let processTable = """
            1 /sbin/launchd
          777 \(diagnosticBridgePath) --socket /tmp/containerstack-doctor-tests.sock
        """
    private let spawnFailure = ProbeResult.failed(reason: "/usr/local/bin/container could not be run: ENOENT")

    private func report(
        runtimeStatus: ProbeResult,
        socketHolder: String,
        transport: StubDockerTransport,
        checks: Set<CheckID>
    ) async -> DiagnosticReport {
        await makeRunner(
            runtimeStatus: runtimeStatus,
            socketHolder: .output(socketHolder),
            processTable: .output(processTable),
            transport: transport
        ).run(checks: checks)
    }

    @Test("the app-root check is amber, not grey and never green")
    func aFailedStatusProbeLeavesTheAppRootCheckIndeterminate() async {
        let report = await report(
            runtimeStatus: spawnFailure,
            socketHolder: ourLsofOutput,
            transport: respondingSocket(),
            checks: CheckID.uiSet
        )
        #expect(report.check(.appRoot)?.verdict == .indeterminate)
        #expect(report.check(.appRoot)?.verdict != .skipped)
        #expect(report.check(.appRoot)?.verdict != .ok)
        #expect(report.check(.appRoot)?.remedy == nil)
    }

    // F-009 asks for a matrix rather than one fixture: a narrow assertion passes while a
    // neighbouring check answers `.ok` off the same dead probe.
    @Test("no check in either set reads as passing while the status probe is dead")
    func aFailedStatusProbeLeavesNoCheckLookingPassed() async {
        for checks in [CheckID.uiSet, CheckID.cliSet] {
            let report = await report(
                runtimeStatus: spawnFailure,
                socketHolder: ourLsofOutput,
                transport: respondingSocket(),
                checks: checks
            )
            // Exact rather than `allSatisfy`: F-009 governs the checks that depend on the dead
            // probe, and the socket and the bridge each answered from a probe of their own.
            #expect(report.checks.filter { $0.verdict == .ok }.map(\.id) == [.foreignBridge, .socket])
            #expect(report.check(.versions)?.verdict == .indeterminate)
            #expect(report.check(.appRoot)?.verdict == .indeterminate)
            #expect(report.checks.allSatisfy { !$0.summary.isEmpty })
        }
    }

    @Test("the reason the probe gave is what the report says")
    func theProbeFailureReasonReachesTheReport() async {
        let report = await report(
            runtimeStatus: .failed(reason: "/usr/local/bin/container exited with status 127"),
            socketHolder: ourLsofOutput,
            transport: respondingSocket(),
            checks: CheckID.uiSet
        )
        #expect(report.check(.appRoot)?.detail?.contains("exited with status 127") == true)
    }

    // Empty output is a measurement: the parser looked and found no missing root. A failed
    // probe is not, and the two must not project onto the same verdict.
    @Test("a status that parsed clean stays grey, which is what makes amber mean something")
    func aMeasuredStatusIsToldApartFromAnUnmeasurableOne() async {
        let measured = await report(
            runtimeStatus: .output(""),
            socketHolder: ourLsofOutput,
            transport: respondingSocket(),
            checks: CheckID.uiSet
        )
        #expect(measured.check(.appRoot)?.verdict == .skipped)
        #expect(measured.check(.appRoot)?.verdict != .indeterminate)
    }

    // T-008: `RuntimeState.resolve` ranks failures and a measurement failure is not one of
    // its inputs, so a foreign bridge still decides and the app root stays grey beneath it.
    @Test("a foreign bridge still outranks an app root that could not be measured")
    func aForeignBridgeStillOutranksAnUnmeasurableAppRoot() async {
        let report = await report(
            runtimeStatus: spawnFailure,
            socketHolder: foreignLsofOutput,
            transport: respondingSocket(),
            checks: CheckID.uiSet
        )
        #expect(report.check(.foreignBridge)?.verdict == .failure)
        #expect(report.check(.appRoot)?.verdict == .skipped)
        #expect(report.check(.appRoot)?.summary.contains(diagnosticSocketPath) == true)
        #expect(report.checks.allSatisfy { $0.verdict != .ok })
    }

    // F-010: a stopped runtime is grey with a reason. Nothing was owed about the app root
    // of a runtime that is not running, so the dead probe does not turn that amber.
    @Test("a stopped runtime stays grey even when the status probe also failed")
    func aStoppedRuntimeIsNotRepaintedByAFailedProbe() async {
        let report = await report(
            runtimeStatus: spawnFailure,
            socketHolder: ourLsofOutput,
            transport: StubDockerTransport(byPath: [:]),
            checks: CheckID.uiSet
        )
        #expect(report.checks.allSatisfy { $0.verdict == .skipped })
        #expect(report.check(.appRoot)?.summary.isEmpty == false)
    }
}

/// NFR-002: `health()` is three retried calls and `.timedOut` is retryable on the general
/// path, so a wedged socket costs ~46s there — more than twice the whole run's 20s budget.
@Suite("The socket and versions checks report a hang instead of outlasting it")
struct DiagnosticRunnerSocketTests {
    private let refused = UnixSocketError.systemCallFailed(ECONNREFUSED)

    @Test("a socket that hangs is asked once, and nothing is asked after it")
    func aWedgedSocketIsAskedOnceNotThreeTimes() async {
        let transport = StubDockerTransport(byPath: ["/_ping": .failure(UnixSocketError.timedOut)])
        _ = await makeRunner(transport: transport).run(checks: CheckID.uiSet)
        #expect(await transport.paths.filter { $0 == "/_ping" }.count == 1)
        #expect(await transport.paths == ["/_ping"])
    }

    // The other side of the split: a refused connection costs a syscall to re-ask, so it is
    // retried, and it stays the grey of a runtime that is genuinely not there.
    @Test("a refused socket is retried and still reads as a stopped runtime")
    func aRefusedSocketIsRetriedAndStaysGrey() async {
        let transport = StubDockerTransport(byPath: ["/_ping": .failure(refused)])
        let report = await makeRunner(transport: transport).run(checks: CheckID.uiSet)
        #expect(await transport.paths == ["/_ping", "/_ping", "/_ping"])
        #expect(report.checks.allSatisfy { $0.verdict == .skipped })
        #expect(report.check(.socket)?.verdict != .indeterminate)
    }

    // F-003: the bytes `cstack doctor` prints today (`CStackCommands.swift:32-36`), copied
    // rather than reworded, because T-016 renders these back out.
    @Test("a healthy socket and its versions carry the CLI's own wording")
    func aHealthyRuntimeCarriesTheCLIsOwnWording() async {
        let report = await makeRunner(transport: respondingRuntime()).run(checks: CheckID.cliSet)
        #expect(report.check(.socket)?.verdict == .ok)
        #expect(report.check(.socket)?.summary == "Docker socket: healthy")
        #expect(report.check(.versions)?.verdict == .ok)
        #expect(report.check(.versions)?.summary == "API version: 1.43")
        #expect(
            report.check(.versions)?.detail
                == """
                Engine: 1.7.0
                Containers: 3
                Images: 11
                """
        )
        #expect(report.check(.versions)?.remedy == nil)
    }

    @Test("a field the daemon did not report is the CLI's `unknown`, not an empty line")
    func anUnreportedVersionFieldReadsAsUnknown() async {
        let report = await makeRunner(
            transport: StubDockerTransport(byPath: [
                "/_ping": .success(jsonResponse("OK")),
                "/version": .success(jsonResponse("{}")),
                "/info": .success(jsonResponse("{}")),
            ])
        ).run(checks: CheckID.cliSet)
        #expect(report.check(.versions)?.summary == "API version: unknown")
        #expect(report.check(.versions)?.detail?.contains("Containers: unknown") == true)
    }

    @Test("a versions call that hangs is amber, asked once, on a socket that answered")
    func aWedgedVersionsCallIsAmberAndAskedOnce() async {
        let transport = StubDockerTransport(byPath: [
            "/_ping": .success(jsonResponse("OK")),
            "/version": .failure(UnixSocketError.timedOut),
        ])
        let report = await makeRunner(transport: transport).run(checks: CheckID.uiSet)
        #expect(await transport.paths.filter { $0 == "/version" }.count == 1)
        #expect(report.check(.socket)?.verdict == .ok)
        #expect(report.check(.versions)?.verdict == .indeterminate)
        #expect(report.check(.versions)?.verdict != .ok)
    }

    // NFR-001: every check reads its own endpoint once, and the ping is not paid twice.
    @Test("a healthy run asks each endpoint exactly once, in order")
    func aHealthyRunAsksEachEndpointOnce() async {
        let transport = StubDockerTransport(byPath: [
            "/_ping": .success(jsonResponse("OK")),
            "/version": .success(jsonResponse(#"{"Version":"1.7.0","ApiVersion":"1.43"}"#)),
            "/info": .success(jsonResponse(#"{"Containers":3,"Images":11}"#)),
            "/containers/json": .success(jsonResponse("[]")),
            "/networks": .success(jsonResponse("[]")),
        ])
        _ = await makeRunner(transport: transport).run(checks: CheckID.uiSet)
        #expect(await transport.paths == ["/_ping", "/version", "/info", "/containers/json", "/networks"])
    }
}
