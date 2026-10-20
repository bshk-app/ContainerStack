import ContainerStackCore
import Foundation
import Observation
import Synchronization

/// Owns the Doctor section's report and the one run that may be producing it (F-007).
///
/// A run cannot be stopped once started: its probes block in `ProcessRunner.run`, which
/// `Task.cancel()` does not reach. So every request either starts the only run or joins the one in
/// flight, and leaving the section decides only whether that run's result is shown.
@MainActor
@Observable
final class DoctorViewModel {
    /// F-011: how long opening the section shows the cached report instead of running again.
    static let automaticInterval: Duration = .seconds(30)

    private(set) var report: DiagnosticReport?
    private(set) var isRunning = false
    /// The repair this section started, until it settles (F-008).
    private(set) var repairing: DoctorAction?
    /// Why the last repair this section started did not succeed; the next repair clears it.
    private(set) var repairFailure: String?
    /// The run in flight. Read by tests, which await it instead of sleeping.
    @ObservationIgnored private(set) var inFlight: Task<Void, Never>?

    /// Bumped each time the section is left. A run publishes only into the generation it was
    /// started or adopted in; it decides whether a result is shown, never which of two runs wins,
    /// because there are never two.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inFlightGeneration = 0
    /// The run in flight began before a restart it did not see, so its result describes a system
    /// that no longer exists: it is not shown, and a fresh run follows it.
    @ObservationIgnored private var inFlightPredatesRestart = false
    /// A repair or restart dropped the report and no run has replaced it yet. Paid by the next run
    /// that starts, or by the next visit if the section was hidden when it fell due.
    @ObservationIgnored private var owesRun = false
    /// Whether the section is on screen. Only an open section starts a run on its own account
    /// (§7); a left one leaves what it owes to its next visit.
    @ObservationIgnored private var isShown = false
    /// The app's restart flag as of the last look, so a restart that began and ended between two
    /// looks still counts as one.
    @ObservationIgnored private var sawRestarting = false
    @ObservationIgnored private var cadence = DiagnosticCadence(interval: DoctorViewModel.automaticInterval)
    private let run: @Sendable () async -> DiagnosticReport
    private let repairs: DoctorRepairs
    private let now: () -> ContinuousClock.Instant
    /// The look scheduled by the latest change of the restart flag. Read by tests, which await it.
    nonisolated private let pendingLook = Mutex<Task<Void, Never>?>(nil)

    init(
        run: @escaping @Sendable () async -> DiagnosticReport,
        repairs: DoctorRepairs = .unavailable,
        now: @escaping () -> ContinuousClock.Instant = { .now }
    ) {
        self.run = run
        self.repairs = repairs
        self.now = now
        watchRestarts()
    }

    convenience init(runner: DiagnosticRunner, repairs: DoctorRepairs = .unavailable) {
        self.init(run: { await runner.run(checks: CheckID.uiSet) }, repairs: repairs)
    }

    /// OQ-6, decided at T-022: while a repair runs the section shows that, not the report. A
    /// restart started from the sidebar counts too, since it leaves every row just as stale.
    var repairInProgress: DoctorAction? {
        repairing ?? (repairs.isRuntimeRestarting() ? .restartRuntime : nil)
    }

    var restartLook: Task<Void, Never>? {
        pendingLook.withLock { $0 }
    }

    /// A restart this section did not start, e.g. from the sidebar, makes the report as stale as
    /// its own would: the report is dropped when the restart begins and run again, window or not,
    /// when it ends if the section is open, or on its next visit if not. A run already going is
    /// not joined but outlived: its result predates the restart, and the fresh run starts only
    /// once it is done, never beside it. The section's own restart reaches here too, but only
    /// while `repairing` holds every run back (`perform` waits for the look); `perform`'s own
    /// re-run then pays what it left owed.
    func runtimeRestartChanged(isRestarting: Bool) {
        report = nil
        owesRun = true
        if isRestarting {
            if inFlight != nil {
                inFlightPredatesRestart = true
            }
        } else if isShown, inFlight == nil {
            checkAgain()
        }
    }

    /// The automatic run: throttled, joined rather than repeated while one is going, and held
    /// while a repair runs, without using up the window, since its result would be stale at once.
    /// A run owed since a repair or restart is paid at once, window or not.
    func appeared() {
        isShown = true
        if inFlight != nil {
            inFlightGeneration = generation
            return
        }
        guard repairInProgress == nil else { return }
        if owesRun {
            checkAgain()
            return
        }
        guard cadence.shouldRun(now: now()) else { return }
        start()
    }

    /// "Check again": bypasses the cadence but not single-flight, and restarts the window so the
    /// next open does not repeat the run it just asked for.
    func checkAgain() {
        guard inFlight == nil, repairInProgress == nil else { return }
        cadence.recordRun(now: now())
        start()
    }

    func disappeared() {
        isShown = false
        generation &+= 1
    }

    /// Not while a report is being run: its verdicts would describe the system before the repair.
    func canPerform(_ action: DoctorAction) -> Bool {
        guard repairInProgress == nil, !isRunning else { return false }
        switch action {
        case .restartRuntime: return repairs.canRestartRuntime()
        case .repairDockerContext: return true
        }
    }

    /// Runs one of the app's existing repairs (Doctor implements none), then the report again, at
    /// once if the section is open and on its next visit if not: the old verdicts predate the
    /// repair, so they leave the screen when it starts.
    func perform(_ action: DoctorAction) async {
        guard canPerform(action) else { return }
        repairing = action
        repairFailure = nil
        report = nil
        owesRun = true
        let repaired =
            switch action {
            case .restartRuntime: await repairs.restartRuntime()
            case .repairDockerContext: await repairs.repairDockerContext()
            }
        // The app lowers its restart flag before returning, so the model's look at that edge is
        // still pending: let it happen while `repairing` still marks the restart as this
        // section's, or it would read as an outside restart and leave a run owed.
        await restartLook?.value
        repairing = nil
        if !repaired {
            repairFailure = action.failureMessage
        }
        // Left mid-repair: the re-run is owed to the next visit rather than run unseen (§7).
        if isShown {
            checkAgain()
        }
    }

    /// Observation reports the first change after each look synchronously, as it is made, even if
    /// the flag flips back before anything renders. A view's `onChange` compares rendered values,
    /// so a restart that fails at its first step could pass it unseen; this cannot miss it, and it
    /// hears the flag whether or not the section is open.
    private func watchRestarts() {
        sawRestarting = withObservationTracking {
            repairs.isRuntimeRestarting()
        } onChange: { [weak self] in
            let look: Task<Void, Never> = Task { @MainActor [weak self] in self?.lookAtRestartFlag() }
            self?.pendingLook.withLock { $0 = look }
        }
    }

    private func lookAtRestartFlag() {
        let before = sawRestarting
        watchRestarts()
        switch (before, sawRestarting) {
        case (false, true):
            runtimeRestartChanged(isRestarting: true)
        case (true, false):
            runtimeRestartChanged(isRestarting: false)
        case (false, false):
            // Began and ended between two looks.
            runtimeRestartChanged(isRestarting: true)
            runtimeRestartChanged(isRestarting: false)
        case (true, true):
            // Ended and began again between two looks.
            runtimeRestartChanged(isRestarting: false)
            runtimeRestartChanged(isRestarting: true)
        }
    }

    private func start() {
        isRunning = true
        owesRun = false
        inFlightGeneration = generation
        let run = run
        inFlight = Task { [weak self] in
            let report = await run()
            self?.finish(with: report)
        }
    }

    private func finish(with report: DiagnosticReport) {
        inFlight = nil
        isRunning = false
        if inFlightPredatesRestart {
            inFlightPredatesRestart = false
            // Still restarting: the restart's end runs it. Already over: nothing else will, so run
            // now, but only for a section still open; a left one waits for its next visit (§7).
            if isShown {
                checkAgain()
            }
            return
        }
        guard inFlightGeneration == generation else { return }
        self.report = report
    }
}

/// A remedy the section can run in-process (F-008). `.manual` advice is text, never a button.
enum DoctorAction: Equatable, Sendable {
    case restartRuntime
    case repairDockerContext

    init?(_ remedy: Remedy?) {
        switch remedy {
        case .restartRuntime: self = .restartRuntime
        case .repairDockerContext: self = .repairDockerContext
        case .manual, nil: return nil
        }
    }

    var title: String {
        switch self {
        case .restartRuntime: "Restart Runtime"
        case .repairDockerContext: "Repair Context"
        }
    }

    var progressTitle: String {
        switch self {
        case .restartRuntime: "Restarting the runtime…"
        case .repairDockerContext: "Repairing the Docker context…"
        }
    }

    var failureMessage: String {
        switch self {
        case .restartRuntime:
            "The runtime did not restart. The runtime panel in the sidebar says why."
        case .repairDockerContext:
            "The Docker context record was not repaired. The report below shows what it points at now."
        }
    }
}

/// The app's existing repairs and the state that gates them, injected so the section's rules are
/// testable without restarting anything.
struct DoctorRepairs {
    var restartRuntime: @MainActor () async -> Bool
    var repairDockerContext: @MainActor () async -> Bool
    /// `RuntimeViewModel.canRestartRuntime`: false while restarting or starting.
    var canRestartRuntime: @MainActor () -> Bool
    /// True while the runtime restarts or stops, whoever started it. Read inside observation
    /// tracking, so an observable source makes the model notice every change.
    var isRuntimeRestarting: @MainActor () -> Bool

    /// For a model with nothing to repair through: every remedy is unavailable.
    static var unavailable: DoctorRepairs {
        DoctorRepairs(
            restartRuntime: { false },
            repairDockerContext: { false },
            canRestartRuntime: { false },
            isRuntimeRestarting: { false }
        )
    }
}

extension DoctorRepairs {
    /// The app's own: its restart, its context-record repair, and its restart state.
    init(runtime: RuntimeViewModel) {
        self.init(
            restartRuntime: { [weak runtime] in await runtime?.restartRuntime(replacingSibling: true) ?? false },
            repairDockerContext: { [weak runtime] in await runtime?.repairDockerContextRecord() ?? false },
            canRestartRuntime: { [weak runtime] in runtime?.canRestartRuntime ?? false },
            isRuntimeRestarting: { [weak runtime] in runtime?.isRestarting ?? false }
        )
    }
}

extension DoctorViewModel {
    /// The production model: the UI check set, run against the socket and helper the app manages.
    convenience init(runtime: RuntimeViewModel) {
        let configuration = runtime.runtimeConfiguration()
        let runner = DiagnosticRunner(
            client: runtime.client,
            probe: ShellSystemProbe(containerPath: configuration.containerPath),
            socketPath: configuration.socketPath,
            bridgePath: configuration.socktainerPath,
            dockerContextSetting: { [weak runtime] in
                guard let runtime else { return nil }
                return await DoctorViewModel.contextSetting(of: runtime)
            }
        )
        self.init(runner: runner, repairs: DoctorRepairs(runtime: runtime))
    }

    /// T-018: the context check's inputs the runner cannot measure without a sixth spawn. The app
    /// already tracks them, so the section judges the record against the same state the app acts on.
    static func contextSetting(of runtime: RuntimeViewModel) -> DiagnosticRunner.DockerContextSetting {
        DiagnosticRunner.DockerContextSetting(
            takeoverEnabled: runtime.takesOverDockerContext,
            installed: runtime.isDockerContextInstalled,
            activeContext: runtime.activeDockerContext
        )
    }
}
