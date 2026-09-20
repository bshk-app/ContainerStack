import Foundation
import Synchronization
import Testing

@testable import ContainerStackCore

/// One fixed step per read, so a measured span is a count of reads rather than elapsed real
/// time: a duration is assertable without any test waiting for one.
private final class SteppingTicks: Sendable {
    private let step: Duration
    private let reads = Mutex(0)

    init(step: Duration) { self.step = step }

    func callAsFunction() -> Duration {
        reads.withLock { count in
            count += 1
            return step * count
        }
    }
}

/// What the runner logged, in order, so NFR-005's line is assertable without a log stream.
private final class RecordedLines: Sendable {
    private let lines = Mutex<[String]>([])

    var all: [String] { lines.withLock { $0 } }

    func record(_ line: String) { lines.withLock { $0.append(line) } }
}

/// A clock only a Docker call moves and `ticks` merely reads, so the two probe branches
/// reading it concurrently cannot perturb the spans the sequential API branch measures.
private final class BilledClock: Sendable {
    private let elapsed = Mutex(Duration.zero)

    var now: Duration { elapsed.withLock { $0 } }

    func bill(_ cost: Duration) { elapsed.withLock { $0 += cost } }
}

/// Answers by path and bills each path its own cost, so a check's span is a sum no other
/// check's calls can add up to.
private actor BillingTransport: DockerAPITransport {
    private let byPath: [String: (body: Data, cost: Duration)]
    private let clock: BilledClock

    init(byPath: [String: (body: Data, cost: Duration)], clock: BilledClock) {
        self.byPath = byPath
        self.clock = clock
    }

    func send(request: Data) throws -> Data {
        let fields = String(decoding: request, as: UTF8.self).split(separator: " ")
        guard fields.count > 1, let keyed = byPath[String(fields[1])] else {
            throw StubDockerTransport.Exhausted()
        }
        clock.bill(keyed.cost)
        return keyed.body
    }
}
/// A runtime that answers every request the UI set makes, so the API branch finishes
/// while the probes are still parked and the two are told apart.
private func idleRuntime() -> StubDockerTransport {
    StubDockerTransport(byPath: [
        "/_ping": .success(jsonResponse("OK")),
        "/version": .success(jsonResponse(#"{"Version":"1.7.0","ApiVersion":"1.43"}"#)),
        "/info": .success(jsonResponse(#"{"Containers":0,"Images":0}"#)),
        "/containers/json": .success(jsonResponse("[]")),
        "/networks": .success(jsonResponse("[]")),
    ])
}

/// A container publishing a port on a network with a subnet, so the routes check reaches
/// `netstat` and a third probe can be in flight at once.
private func publishingRuntime() -> StubDockerTransport {
    StubDockerTransport(byPath: [
        "/_ping": .success(jsonResponse("OK")),
        "/version": .success(jsonResponse(#"{"Version":"1.7.0","ApiVersion":"1.43"}"#)),
        "/info": .success(jsonResponse(#"{"Containers":1,"Images":1}"#)),
        "/containers/json": .success(
            jsonResponse(
                """
                [{"Id":"c1","Names":["/web"],"State":"running",
                  "Ports":[{"PrivatePort":80,"PublicPort":8080,"Type":"tcp"}],
                  "NetworkSettings":{"Networks":{"compose_default":{}}}}]
                """
            )
        ),
        "/networks": .success(
            jsonResponse(
                """
                [{"Id":"n1","Name":"compose_default","Driver":"bridge",
                  "IPAM":{"Config":[{"Subnet":"192.168.64.0/24"}]}}]
                """
            )
        ),
    ])
}

/// Opens the gate after `after`, so a run that waits for a probe that never returns
/// fails on its assertions instead of parking the suite forever.
private func rescue(_ probe: GatedSystemProbe, after: Duration = .seconds(3)) -> Task<Void, Never> {
    Task {
        try? await Task.sleep(for: after)
        guard !Task.isCancelled else { return }
        await probe.open()
    }
}

/// NFR-002: four probes at `ProcessRunner.diagnosticTimeout` are 40s in sequence, which is
/// twice the whole run's budget. A diagnostic reports a hang rather than joining it.
@Suite("A run is bounded as a whole, and what did not finish says so")
struct DiagnosticRunnerBudgetTests {
    @Test("every probe the run needs is in flight before any of them answers")
    func probesEnterConcurrentlyRatherThanOneAfterAnother() async {
        let probe = GatedSystemProbe(result: .output(""))
        let runner = makeRunner(probe: probe, transport: publishingRuntime())
        let rescuer = rescue(probe)
        let run = Task { await runner.run(checks: CheckID.uiSet) }

        await probe.waitUntilCalled(count: 3)
        // The whole proof: three spawns entered and none has returned, which a run that
        // awaits one probe before starting the next can never reach.
        #expect(await probe.completedCallCount == 0)
        #expect(await probe.callCount == 3)

        rescuer.cancel()
        await probe.open()
        _ = await run.value
    }

    @Test("the budget publishes a report while the probes are still parked")
    func theBudgetPublishesWhileTheProbesAreStillParked() async {
        let probe = GatedSystemProbe(result: .failed(reason: "parked"))
        let runner = makeRunner(probe: probe, transport: idleRuntime(), budget: .milliseconds(200))
        let rescuer = rescue(probe)

        let report = await runner.run(checks: CheckID.uiSet)

        #expect(await probe.completedCallCount == 0)
        #expect(report.ranAt == diagnosticClockDate)
        rescuer.cancel()
        await probe.open()
    }

    @Test("a check the budget cut off is amber, never grey and never healthy")
    func anUnfinishedCheckIsIndeterminate() async {
        let probe = GatedSystemProbe(result: .failed(reason: "parked"))
        let runner = makeRunner(probe: probe, transport: idleRuntime(), budget: .milliseconds(200))
        let rescuer = rescue(probe)

        let report = await runner.run(checks: CheckID.uiSet)

        // Guards the reason this passes: the budget ended the run, not a probe answering.
        #expect(await probe.completedCallCount == 0)
        for id in [CheckID.appRoot, .foreignBridge] {
            #expect(report.check(id)?.verdict == .indeterminate)
            #expect(report.check(id)?.verdict != .skipped)
            #expect(report.check(id)?.verdict != .ok)
        }
        #expect(report.verdict == .indeterminate)
        rescuer.cancel()
        await probe.open()
    }

    @Test("a check that answered before the budget expired keeps its own measurement")
    func aFinishedCheckKeepsItsMeasurement() async {
        let probe = GatedSystemProbe(result: .failed(reason: "parked"))
        let runner = makeRunner(probe: probe, transport: idleRuntime(), budget: .milliseconds(200))
        let rescuer = rescue(probe)

        let report = await runner.run(checks: CheckID.uiSet)

        #expect(await probe.completedCallCount == 0)
        #expect(report.check(.socket)?.verdict == .ok)
        #expect(report.check(.socket)?.summary == "Docker socket: healthy")
        #expect(report.check(.versions)?.verdict == .ok)
        #expect(report.check(.versions)?.summary == "API version: 1.43")
        #expect(report.check(.routes)?.verdict == .ok)
        rescuer.cancel()
        await probe.open()
    }

    @Test("a probe answering after the budget cannot change the report it missed")
    func aLateProbeCannotChangeTheReport() async {
        let probe = GatedSystemProbe(result: .output(""))
        let runner = makeRunner(probe: probe, transport: idleRuntime(), budget: .milliseconds(200))
        let rescuer = rescue(probe)

        let report = await runner.run(checks: CheckID.uiSet)
        rescuer.cancel()
        await probe.open()
        await probe.waitUntilCompleted(count: 3)

        #expect(await probe.completedCallCount == 3)
        #expect(report.check(.appRoot)?.verdict == .indeterminate)
        #expect(report.check(.foreignBridge)?.verdict == .indeterminate)
        #expect(report.checks.count == CheckID.uiSet.count)
    }

    @Test("the budget the spec fixes is the one a caller gets without asking")
    func theDefaultBudgetIsTheTwentySecondsTheSpecFixes() {
        #expect(DiagnosticRunner.defaultBudget == .seconds(20))
    }

    /// The gathering and the budget signal the same gate, and a continuation resumed twice
    /// traps rather than fails, so every way the two can land is raced here instead.
    @Test("the gate resumes its one waiter once, whichever way the race lands")
    func theGateResumesItsWaiterOnceHoweverTheRaceLands() async {
        for step in 0..<120 {
            // Straddles the gathering: the low budgets signal before anyone waits, the high
            // ones after it, and the ones in between tie with it.
            let runner = makeRunner(transport: idleRuntime(), budget: .microseconds(step * 5))
            let report = await runner.run(checks: CheckID.uiSet)
            #expect(report.checks.count == CheckID.uiSet.count)
        }
    }
}

/// NFR-005: three amber checks and no timings cannot say whether one probe hung for the
/// whole budget or three were merely slow, which is the question an incident asks first.
@Suite("A check's duration names the probe that consumed the budget")
struct DiagnosticRunnerDurationTests {
    private let budget = Duration.milliseconds(200)

    @Test("a check the budget cut off carries the time it burned, never zero")
    func anUnfinishedCheckCarriesTheTimeItBurned() async {
        let probe = GatedSystemProbe(result: .failed(reason: "parked"))
        let runner = makeRunner(probe: probe, transport: idleRuntime(), budget: budget)
        let rescuer = rescue(probe)

        let report = await runner.run(checks: CheckID.uiSet)

        // Guards the reason this passes: the budget ended the run, not a probe answering.
        #expect(await probe.completedCallCount == 0)
        for id in [CheckID.appRoot, .foreignBridge] {
            #expect(report.check(id)?.duration != .zero)
            #expect(report.check(id)?.duration ?? .zero >= budget)
        }
        rescuer.cancel()
        await probe.open()
    }

    @Test("a check that answered is cheaper than the budget the abandoned ones burned")
    func aFinishedCheckCostsLessThanTheBudget() async {
        let probe = GatedSystemProbe(result: .failed(reason: "parked"))
        let runner = makeRunner(probe: probe, transport: idleRuntime(), budget: budget)
        let rescuer = rescue(probe)

        let report = await runner.run(checks: CheckID.uiSet)

        #expect(await probe.completedCallCount == 0)
        #expect(report.check(.socket)?.duration ?? budget < budget)
        #expect(report.check(.appRoot)?.duration ?? .zero >= budget)
        rescuer.cancel()
        await probe.open()
    }

    @Test("a duration is read from the injected clock, never from the wall clock")
    func aDurationComesFromTheInjectedClock() async {
        // An hour a read, against a run that takes microseconds: no elapsed real time can
        // produce these numbers, and no test waits for them.
        let ticks = SteppingTicks(step: .seconds(3600))
        let runner = makeRunner(transport: idleRuntime(), ticks: { ticks() })

        let report = await runner.run(checks: CheckID.uiSet)

        for id in [CheckID.socket, .versions, .appRoot, .foreignBridge, .routes] {
            #expect(report.check(id)?.duration ?? .zero >= .seconds(3600), "\(id)")
        }
        // The one check nothing measures: grey, and zero by construction rather than by clock.
        #expect(report.check(.dockerContext)?.duration == .zero)
    }

    @Test("a run with an unmeasured check logs one line naming every one of them")
    func anIndeterminateRunLogsOneLineNamingTheChecks() async {
        let lines = RecordedLines()
        let runner = makeRunner(
            transport: StubDockerTransport(results: [.failure(UnixSocketError.timedOut)]),
            log: { lines.record($0) }
        )

        let report = await runner.run(checks: CheckID.uiSet)

        let unmeasured = report.checks.filter { $0.verdict == .indeterminate }.map(\.id)
        #expect(unmeasured == [.socket, .versions])
        #expect(lines.all.count == 1)
        #expect(lines.all.first?.contains("socket") == true)
        #expect(lines.all.first?.contains("versions") == true)
    }

    @Test("a run that measured everything logs nothing")
    func aFullyMeasuredRunLogsNothing() async {
        let lines = RecordedLines()
        let runner = makeRunner(transport: idleRuntime(), log: { lines.record($0) })

        let report = await runner.run(checks: CheckID.uiSet)

        #expect(report.checks.allSatisfy { $0.verdict != .indeterminate })
        #expect(lines.all.isEmpty)
    }

    /// A uniform step proves a duration was measured but not whose it is: every span is the
    /// same number, so two checks trading spans reads exactly like two checks keeping them.
    @Test("a check's duration is the span it earned, never another check's")
    func eachDurationIsPairedWithTheCheckThatEarnedIt() async {
        let clock = BilledClock()
        let runner = DiagnosticRunner(
            client: DockerAPIClient(
                transport: BillingTransport(
                    byPath: [
                        "/_ping": (jsonResponse("OK"), .seconds(1)),
                        "/version": (jsonResponse(#"{"Version":"1.7.0","ApiVersion":"1.43"}"#), .seconds(2)),
                        "/info": (jsonResponse(#"{"Containers":0,"Images":0}"#), .seconds(4)),
                        "/containers/json": (jsonResponse("[]"), .seconds(8)),
                        "/networks": (jsonResponse("[]"), .seconds(16)),
                    ],
                    clock: clock
                )
            ),
            probe: RecordingSystemProbe(
                runtimeStatus: .output(""),
                routingTable: .output(""),
                socketHolder: .output(ourBridgeLsofOutput),
                processTable: .output(ourBridgeProcessTable)
            ),
            socketPath: diagnosticSocketPath,
            bridgePath: diagnosticBridgePath,
            hostMemoryBytes: { nil },
            now: { diagnosticClockDate },
            ticks: { clock.now },
            log: { _ in }
        )

        let report = await runner.run(checks: CheckID.uiSet)

        // Distinct sums of powers of two: a check wearing another's span carries a number its
        // own calls could not have billed, so a swap fails here rather than passing unnoticed.
        #expect(report.check(.socket)?.duration == .seconds(1))
        #expect(report.check(.versions)?.duration == .seconds(6))
        #expect(report.check(.routes)?.duration == .seconds(24))
    }
}
