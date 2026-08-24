import XCTest

@testable import ContainerStackApp
@testable import ContainerStackCore

@MainActor
final class ContainerBusyStateTests: XCTestCase {
    private func summary(id: String, name: String) -> DockerContainerSummary {
        DockerContainerSummary(
            id: id,
            names: ["/\(name)"],
            image: "alpine:3.20",
            imageID: nil,
            command: nil,
            created: nil,
            state: "running",
            status: "Up 1 minute",
            labels: nil,
            ports: nil,
            networkSettings: nil
        )
    }

    /// The reported bug: stopping one container disabled every other container's
    /// controls, because the model tracked "something is busy" rather than which.
    func testOneBusyContainerLeavesTheOthersActionable() {
        let model = RuntimeViewModel(socketPath: "/dev/null", startsRuntime: false)
        let stopping = summary(id: "aaa", name: "demo-webserver-1")
        let idle = summary(id: "bbb", name: "doyourai-apps-postgres-1")

        model.busyContainerIDs.insert(stopping.id)

        XCTAssertTrue(model.isBusy(stopping))
        XCTAssertFalse(model.isBusy(idle))
    }

    func testFinishingOneActionLeavesAnotherBusy() {
        let model = RuntimeViewModel(socketPath: "/dev/null", startsRuntime: false)
        let first = summary(id: "aaa", name: "first")
        let second = summary(id: "bbb", name: "second")

        model.busyContainerIDs.insert(first.id)
        model.busyContainerIDs.insert(second.id)
        model.busyContainerIDs.remove(first.id)

        XCTAssertFalse(model.isBusy(first))
        XCTAssertTrue(model.isBusy(second))
    }
}
