import XCTest

@testable import ContainerStackApp

final class ImageCreatedLabelTests: XCTestCase {
    /// `/images/json` reports `Created: 0` for Apple's vminit images; the epoch rendered as
    /// "56 years ago", which is a fabricated fact.
    func testEpochZeroIsUnknownNotNineteenSeventy() {
        XCTAssertEqual(ImageCreatedLabel.text(for: 0), "—")
    }

    func testMissingIsUnknown() {
        XCTAssertEqual(ImageCreatedLabel.text(for: nil), "—")
    }

    func testNegativeIsUnknown() {
        XCTAssertEqual(ImageCreatedLabel.text(for: -1), "—")
    }

    func testRealTimestampStillFormats() {
        let label = ImageCreatedLabel.text(for: 1_786_988_463)
        XCTAssertNotEqual(label, "—")
        XCTAssertFalse(label.contains("1970"))
    }
}
