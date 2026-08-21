import XCTest

@testable import ContainerStackApp

final class StackActionAvailabilityTests: XCTestCase {
    func testOfflineStackCanStillBeEdited() {
        let availability = StackActionAvailability(isHealthy: false, isBusy: false)

        XCTAssertFalse(availability.canControl)
        XCTAssertTrue(availability.canEdit)
    }

    func testBusyStackDisablesControlAndEditing() {
        let availability = StackActionAvailability(isHealthy: true, isBusy: true)

        XCTAssertFalse(availability.canControl)
        XCTAssertFalse(availability.canEdit)
    }
}
