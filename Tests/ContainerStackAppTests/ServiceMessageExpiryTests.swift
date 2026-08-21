import XCTest

@testable import ContainerStackApp

@MainActor
final class ServiceMessageExpiryTests: XCTestCase {
    func testFreshMessageSurvivesExpiryCheck() {
        let model = RuntimeViewModel(startsRuntime: false)
        model.serviceMessage = "Runtime LaunchAgent registered."
        model.expireServiceMessage(now: Date())
        XCTAssertEqual(model.serviceMessage, "Runtime LaunchAgent registered.")
    }

    func testStaleMessageClearsSoFooterCanShowEngineStatus() {
        let model = RuntimeViewModel(startsRuntime: false)
        model.serviceMessage = "Runtime LaunchAgent registered."
        let later = Date().addingTimeInterval(RuntimeViewModel.serviceMessageLifetime + 0.1)
        model.expireServiceMessage(now: later)
        XCTAssertNil(model.serviceMessage)
    }

    func testNewMessageResetsExpiry() {
        let model = RuntimeViewModel(startsRuntime: false)
        model.serviceMessage = "old"
        let firstExpiry = model.serviceMessageExpiresAt
        model.serviceMessage = "Docker context configured, but it is not active."
        XCTAssertEqual(model.serviceMessage, "Docker context configured, but it is not active.")
        XCTAssertNotEqual(model.serviceMessageExpiresAt, firstExpiry)
        model.expireServiceMessage(now: Date())
        XCTAssertEqual(model.serviceMessage, "Docker context configured, but it is not active.")
    }
}
