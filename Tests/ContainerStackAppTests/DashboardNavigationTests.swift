import XCTest

@testable import ContainerStackApp

final class DashboardNavigationTests: XCTestCase {
    /// A recent container on Overview opens Containers. A query typed in another section filtered
    /// that list to "No matching containers", and the inspector for the opened container was hidden.
    func testOpeningASectionClearsTheQuery() {
        var navigation = DashboardNavigation(selection: .overview, searchText: "zzz")

        navigation.open(.containers)

        XCTAssertEqual(navigation, DashboardNavigation(selection: .containers, searchText: ""))
    }

    /// If a section switch kept the open stack, the next visit to Stacks opened the editor by itself.
    func testSwitchingSectionClosesTheStackEditor() {
        var navigation = DashboardNavigation(selection: .stacks, openedStackID: UUID())

        navigation.selection = .containers

        XCTAssertNil(navigation.openedStackID)
    }

    func testSelectingStacksAgainKeepsTheStackEditor() {
        let stackID = UUID()
        var navigation = DashboardNavigation(selection: .stacks, openedStackID: stackID)

        navigation.selection = .stacks

        XCTAssertEqual(navigation.openedStackID, stackID)
    }

    func testOnlyListSectionsHaveAnInspector() {
        XCTAssertEqual(
            DashboardDestination.allCases.filter(\.hasInspector),
            [.containers, .images, .volumes, .networks, .stacks]
        )
    }

    /// Beside the inspector, the stack editor had about 426 pt at the minimum window width.
    func testTheStackEditorHidesTheInspectorUntilItCloses() {
        var navigation = DashboardNavigation(selection: .stacks)
        XCTAssertTrue(navigation.allowsInspector)

        navigation.openedStackID = UUID()
        XCTAssertFalse(navigation.allowsInspector)

        navigation.openedStackID = nil
        XCTAssertTrue(navigation.allowsInspector)
    }
}
