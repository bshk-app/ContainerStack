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
        let base = Date(timeIntervalSince1970: 1_000_000)
        model.clock = { base }
        model.serviceMessage = "old"
        let firstExpiry = model.serviceMessageExpiresAt
        model.clock = { base.addingTimeInterval(1) }
        model.serviceMessage = "Docker context configured, but it is not active."
        XCTAssertEqual(model.serviceMessage, "Docker context configured, but it is not active.")
        XCTAssertNotEqual(model.serviceMessageExpiresAt, firstExpiry)
        model.expireServiceMessage(now: base.addingTimeInterval(5.5))
        XCTAssertEqual(model.serviceMessage, "Docker context configured, but it is not active.")
    }
}
