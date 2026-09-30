import ContainerStackCore
import Foundation
import Observation

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
    /// The run in flight. Read by tests, which await it instead of sleeping.
    @ObservationIgnored private(set) var inFlight: Task<Void, Never>?

    /// Bumped each time the section is left. A run publishes only into the generation it was
    /// started or adopted in; it decides whether a result is shown, never which of two runs wins,
    /// because there are never two.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inFlightGeneration = 0
    @ObservationIgnored private var cadence = DiagnosticCadence(interval: DoctorViewModel.automaticInterval)
    private let run: @Sendable () async -> DiagnosticReport
    private let now: () -> ContinuousClock.Instant

    init(
        run: @escaping @Sendable () async -> DiagnosticReport,
        now: @escaping () -> ContinuousClock.Instant = { .now }
    ) {
        self.run = run
        self.now = now
    }

    convenience init(runner: DiagnosticRunner) {
        self.init(run: { await runner.run(checks: CheckID.uiSet) })
    }

    /// The automatic run: throttled, and joined rather than repeated while one is going.
    func appeared() {
        if inFlight != nil {
            inFlightGeneration = generation
            return
        }
        guard cadence.shouldRun(now: now()) else { return }
        start()
    }

    /// "Check again": bypasses the cadence but not single-flight, and restarts the window so the
    /// next open does not repeat the run it just asked for.
    func checkAgain() {
        guard inFlight == nil else { return }
        cadence.recordRun(now: now())
        start()
    }

    func disappeared() {
        generation &+= 1
    }

    private func start() {
        isRunning = true
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
        guard inFlightGeneration == generation else { return }
        self.report = report
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
        self.init(runner: runner)
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
