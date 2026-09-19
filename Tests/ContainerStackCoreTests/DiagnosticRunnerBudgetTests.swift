import Foundation
import Testing

@testable import ContainerStackCore

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
