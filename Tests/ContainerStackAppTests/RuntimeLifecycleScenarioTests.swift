import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

/// Start, Stop and Restart run whole here, on substituted steps: nothing reaches the machine's
/// runtime or bridge (#102).
@Suite("Runtime lifecycle scenarios")
@MainActor
struct RuntimeLifecycleScenarioTests {
    @Test("Stop runs every stop step on the substituted steps and reports the bridge stopped")
    func stopRunsWhole() async {
        let model = makeModel()
        let log = StepLog()
        model.steps = .inert(recording: log)

        await model.stopRuntime()

        #expect(
            log.steps
                == RuntimeRestartPlan.stopSteps(
                    configuration: model.runtimeConfiguration(), replacingSibling: false))
        #expect(model.runtimeMessage == "Docker bridge stopped.")
        #expect(model.runtimeFailure == nil)
        #expect(!model.isRestarting)
    }

    private func makeModel() -> RuntimeViewModel {
        RuntimeViewModel(
            socketPath: "/tmp/containerstack-scenario-\(UUID().uuidString).sock",
            startsRuntime: false
        )
    }
}

@MainActor
final class StepLog {
    var steps: [RuntimeControlStep] = []
}

extension RuntimeSteps {
    /// Touches nothing on the machine: every CLI step succeeds and the socket never answers.
    @MainActor
    static func inert(recording log: StepLog) -> RuntimeSteps {
        RuntimeSteps(
            control: { log.steps.append($0) },
            ping: { false },
            versionComplaint: { _ in nil },
            systemStatus: { _ in "" },
            endHelper: { process, _ in process.terminate() }
        )
    }
}
