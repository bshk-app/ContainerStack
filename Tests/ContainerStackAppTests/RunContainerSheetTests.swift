import XCTest

@testable import ContainerStackApp

final class RunContainerSheetTests: XCTestCase {
    /// The image list refreshes while the sheet is open. When the refresh drops the chosen image,
    /// the picker shows nothing, and Run must not submit the name it no longer shows.
    func testRunNeedsAnImageTheListStillOffers() {
        XCTAssertFalse(RunContainerSheet.canRun("alpine:3.20", from: ["nginx:latest"]))
    }

    func testRunAcceptsAListedImage() {
        XCTAssertTrue(RunContainerSheet.canRun("alpine:3.20", from: ["nginx:latest", "alpine:3.20"]))
    }
}
