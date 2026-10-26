import ContainerStackCore
import XCTest

@testable import ContainerStackApp

final class StackStartProminenceTests: XCTestCase {
    func testStartIsNotProminentWhenEveryServiceRuns() {
        XCTAssertFalse(StackInspector.isStartProminent([service("web", running: true), service("db", running: true)]))
    }

    func testStartIsProminentWhenAServiceIsStopped() {
        XCTAssertTrue(StackInspector.isStartProminent([service("web", running: true), service("db", running: false)]))
    }

    func testStartIsProminentBeforeTheStatusIsKnown() {
        XCTAssertTrue(StackInspector.isStartProminent([]))
    }

    private func service(_ name: String, running: Bool) -> ComposeServiceStatus {
        ComposeServiceStatus(
            name: name,
            state: running ? "running" : "exited",
            health: nil,
            publishedPorts: [],
            isRunning: running
        )
    }
}
