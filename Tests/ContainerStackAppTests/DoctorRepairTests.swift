import ContainerStackCore
import DiagnosticTestSupport
import Foundation
import Testing

@testable import ContainerStackApp

/// F-008: the section offers only the repairs the app already has, runs at most one at a time, and
/// never leaves a verdict on screen that the repair has made stale. The gates stand in for a
/// restart that takes a while, so each state can be asserted while it lasts, without sleeping.
@MainActor
@Suite("Doctor runs the app's own repairs, one at a time (F-008)")
struct DoctorRepairTests {
    /// What the app would answer; the test flips it to play a restart started from the sidebar.
    private final class AppState {
        var canRestartRuntime = true
        var isRuntimeRestarting = false
        var restartSucceeds = true
        var contextRepairSucceeds = true
    }

    private let runs = GatedSystemProbe(result: .output(""))
    private let repairGate = GatedSystemProbe(result: .output(""))
    private let app = AppState()

    nonisolated private static func report(_ ordinal: Int) -> DiagnosticReport {
        DiagnosticReport(checks: [], ranAt: Date(timeIntervalSince1970: TimeInterval(ordinal)))
    }

    /// Runs pass `runs` (opened by each test that wants them to finish); both repairs pass
    /// `repairGate`, so its call count is the number of repair operations performed.
    private func model(
        run: (@Sendable () async -> DiagnosticReport)? = nil
    ) -> DoctorViewModel {
        let runs = runs
        let repairGate = repairGate
        let app = app
        return DoctorViewModel(
            run: run ?? {
                _ = await runs.runtimeStatus()
                return Self.report(await runs.callCount)
            },
            repairs: DoctorRepairs(
                restartRuntime: {
                    _ = await repairGate.runtimeStatus()
                    return app.restartSucceeds
                },
                repairDockerContext: {
                    _ = await repairGate.routingTable()
                    return app.contextRepairSucceeds
                },
                canRestartRuntime: { app.canRestartRuntime },
                isRuntimeRestarting: { app.isRuntimeRestarting }
            )
        )
    }

    @Test("only an in-process remedy gets a button; advice stays text")
    func buttonPerRemedy() {
        #expect(DoctorAction(.restartRuntime) == .restartRuntime)
        #expect(DoctorAction(.repairDockerContext) == .repairDockerContext)
        #expect(DoctorAction(.manual("Recreate the runtime's storage directory.")) == nil)
        #expect(DoctorAction(nil) == nil)
    }

    @Test("a second tap while a repair runs performs nothing")
    func twoTapsPerformOneOperation() async {
        await runs.open()
        let doctor = model()

        let first = Task { await doctor.perform(.restartRuntime) }
        await repairGate.waitUntilCalled()
        #expect(!doctor.canPerform(.restartRuntime))
        #expect(!doctor.canPerform(.repairDockerContext))
        // Tasks, not inline awaits: a regression then reaches the gate and fails the count below,
        // instead of parking the test on a gate that only opens after it.
        let taps = [
            Task { await doctor.perform(.restartRuntime) },
            Task { await doctor.perform(.repairDockerContext) },
        ]
        await repairGate.open()
        await first.value
        for tap in taps { await tap.value }

        #expect(await repairGate.callCount == 1)
    }

    @Test("while a repair runs the report is gone and no automatic run starts")
    func aRepairReplacesTheReport() async {
        await runs.open()
        let doctor = model()
        doctor.appeared()
        await doctor.inFlight?.value
        #expect(doctor.report == Self.report(1))

        let repair = Task { await doctor.perform(.repairDockerContext) }
        await repairGate.waitUntilCalled()
        #expect(doctor.report == nil, "its verdicts predate the repair")
        #expect(doctor.repairInProgress == .repairDockerContext)
        #expect(doctor.statusLine == DoctorAction.repairDockerContext.progressTitle)
        doctor.disappeared()
        doctor.appeared()
        doctor.checkAgain()
        #expect(doctor.inFlight == nil)
        #expect(await runs.callCount == 1)

        await repairGate.open()
        await repair.value
        await doctor.inFlight?.value
        #expect(doctor.repairInProgress == nil)
        #expect(await runs.callCount == 2, "the section re-runs on completion, inside the window too")
        #expect(doctor.report == Self.report(2))
    }

    @Test("a repair that did not succeed says so, and the next repair clears it")
    func aFailedRepairIsReported() async {
        await runs.open()
        await repairGate.open()
        app.contextRepairSucceeds = false
        let doctor = model()

        await doctor.perform(.repairDockerContext)
        await doctor.inFlight?.value
        #expect(doctor.repairFailure == DoctorAction.repairDockerContext.failureMessage)

        await doctor.perform(.restartRuntime)
        await doctor.inFlight?.value
        #expect(doctor.repairFailure == nil)
    }

    @Test("restart follows the app's own permission; the context repair does not need it")
    func restartIsBoundToCanRestartRuntime() async {
        await runs.open()
        await repairGate.open()
        app.canRestartRuntime = false
        let doctor = model()

        #expect(!doctor.canPerform(.restartRuntime))
        #expect(doctor.canPerform(.repairDockerContext))
        await doctor.perform(.restartRuntime)
        #expect(await repairGate.callCount == 0)
    }

    @Test("nothing is repaired while a report is being run")
    func noRepairDuringARun() async {
        let doctor = model()
        doctor.appeared()
        await runs.waitUntilCalled()

        #expect(!doctor.canPerform(.restartRuntime))
        #expect(!doctor.canPerform(.repairDockerContext))
        await runs.open()
        await doctor.inFlight?.value
        #expect(doctor.canPerform(.restartRuntime))
    }

    // The sidebar's Restart makes every row just as stale as the section's own button does.
    @Test("a restart started elsewhere shows as in progress and holds the automatic run")
    func anOutsideRestartHoldsTheRun() async {
        await runs.open()
        app.isRuntimeRestarting = true
        let doctor = model()

        doctor.appeared()
        doctor.checkAgain()
        #expect(doctor.repairInProgress == .restartRuntime)
        #expect(doctor.inFlight == nil)
        #expect(!doctor.canPerform(.repairDockerContext))

        app.isRuntimeRestarting = false
        doctor.appeared()
        await doctor.inFlight?.value
        #expect(await runs.callCount == 1, "the held open did not use up the window")
    }

    // Decision 9: the section forwards the app's restart state as it changes. A report measured
    // before a sidebar restart must not come back after it; the run that replaces it is due at
    // once, whatever the window says, and without the section being reopened.
    @Test("a sidebar restart drops the report and re-runs it when the restart ends")
    func anOutsideRestartReRunsWhenItEnds() async {
        await runs.open()
        let doctor = model()
        doctor.appeared()
        await doctor.inFlight?.value
        #expect(doctor.report == Self.report(1))

        app.isRuntimeRestarting = true
        #expect(doctor.repairInProgress == .restartRuntime)
        doctor.runtimeRestartChanged(isRestarting: true)
        #expect(doctor.report == nil)
        #expect(doctor.inFlight == nil)

        app.isRuntimeRestarting = false
        doctor.runtimeRestartChanged(isRestarting: false)
        await doctor.inFlight?.value
        #expect(await runs.callCount == 2)
        #expect(doctor.report == Self.report(2))
    }

    // A run going when the restart begins measured the system before it. Whether it ends during
    // the restart or after, its result is not shown, and one fresh run follows it; the two never
    // overlap (F-007).
    @Test("a run that outlives a sidebar restart is not shown, and a fresh one follows it")
    func aRunOutlivingTheRestartIsReplaced() async throws {
        // The fresh run waits at a gate of its own. Through the shared one, already open, it could
        // finish and publish before the check below that the stale result was dropped.
        let fresh = GatedSystemProbe(result: .output(""))
        let runs = runs
        let doctor = model(run: {
            let ordinal = await runs.callCount + fresh.callCount + 1
            _ = await (ordinal == 1 ? runs : fresh).runtimeStatus()
            return Self.report(ordinal)
        })
        doctor.appeared()
        await runs.waitUntilCalled()
        let stale = try #require(doctor.inFlight)

        app.isRuntimeRestarting = true
        doctor.runtimeRestartChanged(isRestarting: true)
        app.isRuntimeRestarting = false
        doctor.runtimeRestartChanged(isRestarting: false)
        #expect(doctor.inFlight == stale, "never two runs at once")

        await runs.open()
        await stale.value
        #expect(doctor.report == nil, "measured before the restart")
        await fresh.open()
        await doctor.inFlight?.value
        #expect(await runs.callCount == 1)
        #expect(await fresh.callCount == 1)
        #expect(doctor.report == Self.report(2))
    }

    // §7: nothing runs with nobody looking. A section left before the stale run ends owes its
    // replacement to the next visit, which pays it at once, window or not: the report it would
    // otherwise show was dropped by the restart.
    @Test("a stale run ending unseen starts nothing, and the next visit runs at once")
    func aStaleRunEndingUnseenIsReplacedOnReturn() async throws {
        let doctor = model()
        doctor.appeared()
        await runs.waitUntilCalled()
        let stale = try #require(doctor.inFlight)

        app.isRuntimeRestarting = true
        doctor.runtimeRestartChanged(isRestarting: true)
        app.isRuntimeRestarting = false
        doctor.runtimeRestartChanged(isRestarting: false)
        doctor.disappeared()
        await runs.open()
        await stale.value
        #expect(doctor.inFlight == nil)
        #expect(await runs.callCount == 1)
        #expect(doctor.report == nil)

        doctor.appeared()
        await doctor.inFlight?.value
        #expect(await runs.callCount == 2, "inside the window, and still owed")
        #expect(doctor.report == Self.report(2))
    }

    // The dashboard forwards both edges of a restart whether or not the section is open, so a
    // restart that happened entirely while it was hidden is known on return; nothing runs
    // meanwhile (§7), and the return pays the run at once, inside the window.
    @Test("a restart that happens while the section is hidden runs nothing then, and re-runs on return")
    func aRestartWhileHiddenIsReRunOnReturn() async {
        await runs.open()
        let doctor = model()
        doctor.appeared()
        await doctor.inFlight?.value

        doctor.disappeared()
        app.isRuntimeRestarting = true
        doctor.runtimeRestartChanged(isRestarting: true)
        app.isRuntimeRestarting = false
        doctor.runtimeRestartChanged(isRestarting: false)
        #expect(doctor.inFlight == nil)
        #expect(await runs.callCount == 1)

        doctor.appeared()
        await doctor.inFlight?.value
        #expect(await runs.callCount == 2)
        #expect(doctor.report == Self.report(2))
        doctor.disappeared()
        doctor.appeared()
        #expect(doctor.inFlight == nil, "paid once, then the window applies again")
    }

    // §7 again: a repair that settles after the section was left starts nothing then; the run
    // it owes is the next visit's, at once.
    @Test("a repair that settles after the section was left re-runs on return, not before")
    func aRepairSettlingUnseenReRunsOnReturn() async {
        await runs.open()
        let doctor = model()
        doctor.appeared()
        await doctor.inFlight?.value

        let repair = Task { await doctor.perform(.repairDockerContext) }
        await repairGate.waitUntilCalled()
        doctor.disappeared()
        await repairGate.open()
        await repair.value
        #expect(doctor.inFlight == nil)
        #expect(await runs.callCount == 1)

        doctor.appeared()
        await doctor.inFlight?.value
        #expect(await runs.callCount == 2, "inside the window, and still owed")
        #expect(doctor.report == Self.report(2))
    }
    // The repair's own re-run can be blocked by a restart the hidden section never hears about;
    // the repair still dropped the report, so the next visit owes it a run.
    @Test("a repair whose re-run was blocked while hidden is re-run on return")
    func aBlockedRepairReRunIsPaidOnReturn() async {
        await runs.open()
        let doctor = model()
        doctor.appeared()
        await doctor.inFlight?.value

        let repair = Task { await doctor.perform(.repairDockerContext) }
        await repairGate.waitUntilCalled()
        doctor.disappeared()
        app.isRuntimeRestarting = true
        await repairGate.open()
        await repair.value
        #expect(doctor.inFlight == nil)
        app.isRuntimeRestarting = false
        doctor.appeared()
        await doctor.inFlight?.value

        #expect(await runs.callCount == 2, "inside the window, and still owed")
        #expect(doctor.report == Self.report(2))
    }
    @Test("a run that ends during the restart is not shown either")
    func aRunEndingDuringTheRestartIsDiscarded() async throws {
        let doctor = model()
        doctor.appeared()
        await runs.waitUntilCalled()
        let stale = try #require(doctor.inFlight)

        app.isRuntimeRestarting = true
        doctor.runtimeRestartChanged(isRestarting: true)
        await runs.open()
        await stale.value
        #expect(doctor.report == nil)
        #expect(doctor.inFlight == nil, "nothing runs while the restart does")

        app.isRuntimeRestarting = false
        doctor.runtimeRestartChanged(isRestarting: false)
        await doctor.inFlight?.value
        #expect(await runs.callCount == 2)
        #expect(doctor.report == Self.report(2))
    }

    // The section's own restart flips the app's flag too, and SwiftUI may deliver either change
    // before `perform` resumes. `perform` owns that report and its re-run; the forwarded changes
    // must add nothing, or its end would start a run on top of the one `perform` starts.
    @Test("the section's own restart is left to perform: one run after it, not two")
    func anOwnRestartIsLeftToPerform() async {
        await runs.open()
        let doctor = model()
        doctor.appeared()
        await doctor.inFlight?.value

        let restart = Task { await doctor.perform(.restartRuntime) }
        await repairGate.waitUntilCalled()
        app.isRuntimeRestarting = true
        doctor.runtimeRestartChanged(isRestarting: true)
        app.isRuntimeRestarting = false
        doctor.runtimeRestartChanged(isRestarting: false)
        #expect(doctor.inFlight == nil)
        await repairGate.open()
        await restart.value
        await doctor.inFlight?.value

        #expect(await runs.callCount == 2)
        #expect(doctor.report == Self.report(2))
    }

    // A sidebar restart that begins during the section's context repair blocks the repair's own
    // re-run; the restart's end is what owes it.
    @Test("a sidebar restart during the section's context repair still ends in one fresh run")
    func aRestartDuringAContextRepairStillReRuns() async {
        await runs.open()
        let doctor = model()
        doctor.appeared()
        await doctor.inFlight?.value

        let repair = Task { await doctor.perform(.repairDockerContext) }
        await repairGate.waitUntilCalled()
        app.isRuntimeRestarting = true
        doctor.runtimeRestartChanged(isRestarting: true)
        await repairGate.open()
        await repair.value
        #expect(doctor.inFlight == nil, "nothing runs while the restart does")
        #expect(doctor.repairInProgress == .restartRuntime)

        app.isRuntimeRestarting = false
        doctor.runtimeRestartChanged(isRestarting: false)
        await doctor.inFlight?.value
        #expect(await runs.callCount == 2)
        #expect(doctor.report == Self.report(2))
    }
}

@MainActor
@Suite("The production Doctor repairs through the app")
struct DoctorRepairWiringTests {
    @Test("restart availability and progress come from the app's own restart state")
    func restartStateIsTheApps() {
        let runtime = RuntimeViewModel(socketPath: "/tmp/containerstack-doctor.sock", startsRuntime: false)
        let doctor = DoctorViewModel(runtime: runtime)
        #expect(doctor.canPerform(.restartRuntime) == runtime.canRestartRuntime)

        runtime.isRestarting = true

        #expect(!doctor.canPerform(.restartRuntime))
        #expect(doctor.repairInProgress == .restartRuntime)
    }

    /// The real app's restart flag, with a report run that only counts itself.
    private func watchedModel(
        of runtime: RuntimeViewModel,
        runs: GatedSystemProbe
    ) -> DoctorViewModel {
        DoctorViewModel(
            run: {
                _ = await runs.runtimeStatus()
                let ordinal = await runs.callCount
                return DiagnosticReport(checks: [], ranAt: Date(timeIntervalSince1970: TimeInterval(ordinal)))
            },
            repairs: DoctorRepairs(runtime: runtime)
        )
    }

    @Test("a restart seen at both ends drops the report, then re-runs it")
    func theModelWatchesTheAppsRestartFlag() async {
        let runtime = RuntimeViewModel(socketPath: "/tmp/containerstack-doctor.sock", startsRuntime: false)
        let runs = GatedSystemProbe(result: .output(""))
        await runs.open()
        let doctor = watchedModel(of: runtime, runs: runs)
        doctor.appeared()
        await doctor.inFlight?.value

        runtime.isRestarting = true
        await doctor.restartLook?.value
        #expect(doctor.report == nil)
        #expect(doctor.inFlight == nil)

        runtime.isRestarting = false
        await doctor.restartLook?.value
        await doctor.inFlight?.value
        #expect(await runs.callCount == 2)
        #expect(doctor.report?.ranAt == Date(timeIntervalSince1970: 2))
    }

    // A restart that fails at its first step can flip the flag and back before anything
    // renders, so a view's `onChange` would see no change at all. The model still does.
    @Test("a restart that begins and ends before anyone looks still counts")
    func aRestartBetweenTwoLooksStillCounts() async {
        let runtime = RuntimeViewModel(socketPath: "/tmp/containerstack-doctor.sock", startsRuntime: false)
        let runs = GatedSystemProbe(result: .output(""))
        await runs.open()
        let doctor = watchedModel(of: runtime, runs: runs)
        doctor.appeared()
        await doctor.inFlight?.value

        runtime.isRestarting = true
        runtime.isRestarting = false
        await doctor.restartLook?.value
        await doctor.inFlight?.value

        #expect(await runs.callCount == 2)
        #expect(doctor.report?.ranAt == Date(timeIntervalSince1970: 2))
    }

    /// Plays the app's restart as it really runs: the flag rises before the work and falls in a
    /// `defer` before `restartRuntime()` returns, so the model's look at the falling edge is
    /// still pending when `perform` resumes.
    @Observable
    final class ObservedRestart {
        var isRestarting = false
    }

    // Its own restart's edges must not be counted as an outside one: that would leave a run owed
    // after `perform`'s re-run, and the next open inside the window would pay it (F-011).
    @Test("the section's own restart, seen as it really happens, leaves nothing owed")
    func anOwnRestartLeavesNothingOwed() async {
        let restart = ObservedRestart()
        let work = GatedSystemProbe(result: .output(""))
        let runs = GatedSystemProbe(result: .output(""))
        await runs.open()
        let doctor = DoctorViewModel(
            run: {
                _ = await runs.runtimeStatus()
                let ordinal = await runs.callCount
                return DiagnosticReport(checks: [], ranAt: Date(timeIntervalSince1970: TimeInterval(ordinal)))
            },
            repairs: DoctorRepairs(
                restartRuntime: {
                    restart.isRestarting = true
                    defer { restart.isRestarting = false }
                    _ = await work.runtimeStatus()
                    return true
                },
                repairDockerContext: { false },
                canRestartRuntime: { !restart.isRestarting },
                isRuntimeRestarting: { restart.isRestarting }
            )
        )
        doctor.appeared()
        await doctor.inFlight?.value

        let repair = Task { await doctor.perform(.restartRuntime) }
        await work.waitUntilCalled()
        await doctor.restartLook?.value
        await work.open()
        await repair.value
        await doctor.restartLook?.value
        await doctor.inFlight?.value
        #expect(await runs.callCount == 2)
        #expect(doctor.report?.ranAt == Date(timeIntervalSince1970: 2))

        doctor.disappeared()
        doctor.appeared()
        #expect(doctor.inFlight == nil, "nothing was left owed")
        #expect(await runs.callCount == 2)
    }
}
