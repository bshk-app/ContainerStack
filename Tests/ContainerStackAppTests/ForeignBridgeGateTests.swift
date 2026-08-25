import XCTest

@testable import ContainerStackApp
@testable import ContainerStackCore

/// A bridge that is not ours answers every read and hangs every lifecycle call,
/// so the two have to be gated apart: the container list and its logs are exactly
/// what someone needs while that is true.
@MainActor
final class ForeignBridgeGateTests: XCTestCase {
    private func model() -> RuntimeViewModel {
        let model = RuntimeViewModel(
            socketPath: "/tmp/containerstack-no-such-\(UUID().uuidString).sock",
            startsRuntime: false
        )
        model.applyState(socketResponds: true, foreignBridge: "/tmp/foreign.sock")
        return model
    }

    private var container: DockerContainerSummary {
        DockerContainerSummary(
            id: "abc123",
            names: ["/demo"],
            image: "alpine:3.20",
            imageID: nil,
            command: nil,
            created: nil,
            state: "running",
            status: "Up 1h",
            labels: nil,
            ports: nil,
            networkSettings: nil
        )
    }

    func testReadsStayAvailableWhileMutationsDoNot() {
        let model = model()

        XCTAssertTrue(model.isHealthy)
        XCTAssertFalse(model.canMutate)
    }

    /// Reverting the read gate makes this fail: the guard drops the call and the
    /// seeded message survives untouched.
    func testLogsAreStillAttempted() async {
        let model = model()
        model.containerMessage = "untouched"

        await model.showLogs(for: container)

        XCTAssertNotEqual(model.containerMessage, "untouched")
    }

    func testLifecycleActionIsRefused() async {
        let model = model()
        model.containerMessage = "untouched"

        await model.toggle(container: container)

        XCTAssertEqual(model.containerMessage, "untouched")
    }
}
