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
}
