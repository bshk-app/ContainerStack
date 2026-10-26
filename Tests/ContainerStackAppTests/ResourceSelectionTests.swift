import XCTest

@testable import ContainerStackApp

final class ResourceSelectionTests: XCTestCase {
    /// The row's Logs button shows the logs in the inspector, so a hidden inspector must open.
    func testShowingContainerLogsOpensAHiddenInspector() {
        var selection = ResourceSelection(isInspectorShown: false)

        selection.showContainerLogs()

        XCTAssertEqual(selection.containerTab, .logs)
        XCTAssertTrue(selection.isInspectorShown)
    }
}
