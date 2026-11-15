import SwiftUI
import XCTest

@testable import ContainerStackApp

@MainActor
final class InspectorPresentationTests: XCTestCase {
    func testLateCollapseKeepsTheInspectorChoiceAfterReturning() {
        var navigation = DashboardNavigation()
        var resources = ResourceSelection()
        let binding = DashboardView.inspectorPresented(
            navigation: Binding(get: { navigation }, set: { navigation = $0 }),
            resources: Binding(get: { resources }, set: { resources = $0 })
        )
        XCTAssertTrue(binding.wrappedValue)

        navigation.selection = .overview
        XCTAssertFalse(binding.wrappedValue)
        navigation.selection = .containers
        binding.wrappedValue = false

        XCTAssertTrue(resources.isInspectorShown)
        XCTAssertTrue(binding.wrappedValue)
    }

    func testHideChoiceSurvivesSectionChangesAndPresentationCallbacks() {
        var navigation = DashboardNavigation()
        var resources = ResourceSelection()
        let binding = DashboardView.inspectorPresented(
            navigation: Binding(get: { navigation }, set: { navigation = $0 }),
            resources: Binding(get: { resources }, set: { resources = $0 })
        )
        resources.isInspectorShown.toggle()
        navigation.selection = .overview
        navigation.selection = .containers
        binding.wrappedValue = false

        XCTAssertFalse(resources.isInspectorShown)
        XCTAssertFalse(binding.wrappedValue)
    }
}
