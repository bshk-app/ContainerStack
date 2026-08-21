import XCTest

@testable import ContainerStackApp
@testable import ContainerStackCore

@MainActor
final class InlineLogsTests: XCTestCase {
    func testInlineLogsDoesNotWriteSheetState() async {
        let model = RuntimeViewModel(
            socketPath: "/tmp/containerstack-no-such.sock",
            startsRuntime: false
        )
        model.logs = "sheet-should-stay-nil"
        model.logs = nil
        model.containerMessage = "keep"

        let output = await model.inlineLogs(
            for: DockerContainerSummary(
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
        )

        XCTAssertFalse(output.isEmpty)
        XCTAssertNil(model.logs)
        XCTAssertEqual(model.containerMessage, "keep")
    }
}
