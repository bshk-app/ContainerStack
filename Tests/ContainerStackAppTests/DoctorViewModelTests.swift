import ContainerStackCore
import DiagnosticTestSupport
import Foundation
import Testing

@testable import ContainerStackApp

/// A run is the unit the section pays for: every request either starts one or rides the one in
/// flight. The gate stands in for a runtime that is slow to answer, so a run can be held open while
/// the test requests others, and nothing here waits by sleeping.
@MainActor
@Suite("Doctor runs one report at a time, at most every 30s unless asked")
struct DoctorViewModelTests {
    /// A manual clock: the cadence reads it, and only the test moves it.
    private final class Clock {
        var now = ContinuousClock.now
    }

    nonisolated private static func report(_ second: Int) -> DiagnosticReport {
        DiagnosticReport(checks: [], ranAt: Date(timeIntervalSince1970: TimeInterval(second)))
    }

    /// Each run passes the gate once and returns a report stamped with its own ordinal, so which
    /// run published is readable from `ranAt` and how many ran from the probe's call count.
    private func gatedModel(probe: GatedSystemProbe, clock: Clock) -> DoctorViewModel {
        DoctorViewModel(
            run: {
                _ = await probe.runtimeStatus()
                return Self.report(await probe.callCount)
            },
            now: { clock.now }
        )
    }

    // F-007 (a) and (b): requests made while run A is parked neither reach the probe nor replace A.
    @Test("a request while a run is in flight joins it rather than starting another")
    func requestsCoalesceOntoTheRunInFlight() async throws {
        let probe = GatedSystemProbe(result: .output(""))
        let model = gatedModel(probe: probe, clock: Clock())

        model.appeared()
        await probe.waitUntilCalled()
        let runA = try #require(model.inFlight)
        model.checkAgain()
        model.appeared()

        #expect(model.inFlight == runA)
        #expect(model.isRunning)
        await probe.open()
        await runA.value
        #expect(await probe.callCount == 1)
        #expect(model.report == Self.report(1))
        #expect(!model.isRunning)
        #expect(model.inFlight == nil)
    }

    @Test("leaving the section discards the result of the run in flight")
    func leavingDiscardsTheResult() async throws {
        let probe = GatedSystemProbe(result: .output(""))
        let model = gatedModel(probe: probe, clock: Clock())

        model.appeared()
        await probe.waitUntilCalled()
        let runA = try #require(model.inFlight)
        model.disappeared()
        #expect(model.isRunning, "the probes are uncancellable, so the run is still going")

        await probe.open()
        await runA.value
        #expect(model.report == nil)
        #expect(!model.isRunning)
    }

    // F-011 counts runs, not shown reports: a run on a wedged runtime can take the whole budget,
    // which is exactly when a return visit must not buy another one. The section says "Check
    // again" instead of spending five uncancellable spawns on its own.
    @Test("a discarded run still holds the window, so returning costs nothing")
    func aDiscardedRunStillHoldsTheWindow() async throws {
        let probe = GatedSystemProbe(result: .output(""))
        let clock = Clock()
        let model = gatedModel(probe: probe, clock: clock)

        model.appeared()
        await probe.waitUntilCalled()
        let runA = try #require(model.inFlight)
        model.disappeared()
        await probe.open()
        await runA.value
        clock.now += .seconds(21)
        model.appeared()

        #expect(model.inFlight == nil)
        #expect(await probe.callCount == 1)
        #expect(model.report == nil)
    }

    // Returning inside the window does not start a second run: the section rides A, and A is now
    // the report this visit asked for.
    @Test("returning while the run is still going adopts it, and it publishes")
    func returningAdoptsTheRunInFlight() async throws {
        let probe = GatedSystemProbe(result: .output(""))
        let model = gatedModel(probe: probe, clock: Clock())

        model.appeared()
        await probe.waitUntilCalled()
        let runA = try #require(model.inFlight)
        model.disappeared()
        model.appeared()
        #expect(model.inFlight == runA)

        await probe.open()
        await runA.value
        #expect(await probe.callCount == 1)
        #expect(model.report == Self.report(1))
    }

    @Test("a run requested after the previous one finished does execute")
    func aLaterRunExecutes() async throws {
        let probe = GatedSystemProbe(result: .output(""))
        await probe.open()
        let model = gatedModel(probe: probe, clock: Clock())

        model.appeared()
        await model.inFlight?.value
        model.checkAgain()
        await model.inFlight?.value

        #expect(await probe.callCount == 2)
        #expect(model.report == Self.report(2))
    }

    // F-011: section switching is unbounded, so opening is throttled and the button is not.
    @Test("two opens inside 30s cost one run; the explicit button costs a second")
    func opensAreThrottledButTheButtonIsNot() async {
        let probe = GatedSystemProbe(result: .output(""))
        await probe.open()
        let clock = Clock()
        let model = gatedModel(probe: probe, clock: clock)

        model.appeared()
        await model.inFlight?.value
        model.disappeared()
        clock.now += .seconds(29)
        model.appeared()
        #expect(model.inFlight == nil)
        #expect(await probe.callCount == 1)
        #expect(model.report == Self.report(1), "inside the window the cached report stays up")

        model.checkAgain()
        await model.inFlight?.value
        #expect(await probe.callCount == 2)
    }

    @Test("an open after the window runs again")
    func anOpenAfterTheWindowRuns() async {
        let probe = GatedSystemProbe(result: .output(""))
        await probe.open()
        let clock = Clock()
        let model = gatedModel(probe: probe, clock: clock)

        model.appeared()
        await model.inFlight?.value
        model.disappeared()
        clock.now += DoctorViewModel.automaticInterval
        model.appeared()
        await model.inFlight?.value

        #expect(await probe.callCount == 2)
        #expect(model.report == Self.report(2))
    }

    // The button restarts the window, so an open right after it does not repeat the run.
    @Test("an open straight after the button does not run again")
    func theButtonRestartsTheWindow() async {
        let probe = GatedSystemProbe(result: .output(""))
        await probe.open()
        let clock = Clock()
        let model = gatedModel(probe: probe, clock: clock)

        model.appeared()
        await model.inFlight?.value
        clock.now += .seconds(29)
        model.checkAgain()
        await model.inFlight?.value
        model.disappeared()
        clock.now += .seconds(29)
        model.appeared()

        #expect(model.inFlight == nil)
        #expect(await probe.callCount == 2)
    }
}

@MainActor
@Suite("Doctor runs the UI check set with the app's own context state")
struct DoctorViewModelWiringTests {
    @Test("a runner-backed model reports exactly the UI set")
    func theRunnerIsAskedForTheUISet() async {
        let probe = RecordingSystemProbe(
            runtimeStatus: .output(""),
            routingTable: .output(""),
            socketHolder: .output(""),
            processTable: .output("")
        )
        let runner = DiagnosticRunner(
            client: DockerAPIClient(
                socketPath: "/nonexistent/containerstack-doctor.sock",
                retryPolicy: DockerRetryPolicy(maxAttempts: 1)
            ),
            probe: probe,
            socketPath: "/nonexistent/containerstack-doctor.sock",
            bridgePath: "/nonexistent/socktainer",
            recordedSocketPath: { _ in nil },
            log: { _ in }
        )
        let model = DoctorViewModel(runner: runner)

        model.appeared()
        await model.inFlight?.value

        #expect(model.report?.checks.map(\.id) == CheckID.allCases.filter(CheckID.uiSet.contains))
    }

    // T-018: without these the context row is amber on every run; the runner cannot spawn for
    // them itself without exceeding NFR-001.
    @Test("the context check is judged against what the app already knows")
    func theContextSettingIsTheAppsState() {
        let runtime = RuntimeViewModel(socketPath: "/tmp/containerstack-doctor.sock", startsRuntime: false)
        runtime.activeDockerContext = "colima"
        runtime.isDockerContextInstalled = true

        let setting = DoctorViewModel.contextSetting(of: runtime)

        #expect(
            setting
                == DiagnosticRunner.DockerContextSetting(
                    takeoverEnabled: runtime.takesOverDockerContext,
                    installed: true,
                    activeContext: "colima"
                )
        )
    }
}
