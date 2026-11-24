import ContainerStackCore
import Testing

@testable import ContainerStackApp

struct KubernetesStateTests {
    @Test(arguments: ClusterTestScenario.all)
    func stateOrderAndActions(scenario: ClusterTestScenario) {
        let state = ClusterRowState.resolve(
            operation: scenario.operation, missing: scenario.missing, startFailure: scenario.failure,
            runtimeState: scenario.runtime, runningNodes: scenario.running, totalNodes: 2,
            apiReady: scenario.ready)
        #expect(state == scenario.expected)
        #expect(state.actions == scenario.actions)
    }
}

struct ClusterTestScenario: Sendable {
    var operation: ClusterOperation?
    var missing: [String] = []
    var failure: String?
    var runtime: KubernetesCluster.State = .running
    var running = 2
    var ready = true
    var expected: ClusterRowState
    var actions: [ClusterAction]

    static let all: [Self] = [
        Self(
            operation: .creating, missing: ["worker"], failure: "failed", ready: false,
            expected: .operating(.creating), actions: []),
        Self(
            operation: .starting, missing: ["worker"], failure: "failed", expected: .operating(.starting), actions: []),
        Self(
            operation: .stopping, missing: ["worker"], failure: "failed", expected: .operating(.stopping), actions: []),
        Self(
            operation: .deleting, missing: ["worker"], failure: "failed", expected: .operating(.deleting), actions: []),
        Self(
            missing: ["worker"], failure: "failed", runtime: .degraded, running: 1,
            expected: .missing(["worker"]), actions: [.delete]),
        Self(failure: "failed", expected: .startFailed("failed"), actions: [.restart, .stop, .delete]),
        Self(ready: false, expected: .apiNotReady, actions: [.restart, .delete]),
        Self(expected: .running, actions: [.stop, .delete]),
        Self(
            runtime: .degraded, running: 1, ready: false, expected: .degraded(1, 2), actions: [.start, .stop, .delete]),
        Self(runtime: .stopped, running: 0, ready: false, expected: .stopped, actions: [.start, .delete]),
    ]
}
