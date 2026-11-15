import AppKit
import XCTest

@testable import ContainerStackApp

@MainActor
final class InspectorConstraintCollapseTests: XCTestCase {
    func testTheInspectorItemCollapsesWithConstraints() async throws {
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let inspector = NSViewController()
        inspector.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let contentItem = NSSplitViewItem(viewController: content)
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        let controller = NSSplitViewController()
        controller.addSplitViewItem(contentItem)
        controller.addSplitViewItem(inspectorItem)
        let window = NSWindow(contentViewController: controller)
        XCTAssertNotEqual(inspectorItem.collapseBehavior, .useConstraints)

        content.view.addSubview(InspectorConstraintCollapse.Anchor())
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(inspectorItem.collapseBehavior, .useConstraints)
        XCTAssertNotEqual(contentItem.collapseBehavior, .useConstraints)
        window.close()
    }
}
