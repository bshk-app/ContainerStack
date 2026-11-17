import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@MainActor struct SharedRuntimeRestartTests {
    @Test func aFailedRestartKeepsTheRestartNoticeUntilTheBridgeReturns() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = SharedRuntimeSettings(home: home)
        settings.setEnabled(true, group: "mcp-catalog")
        #expect(!settings.awaitsBridgeRestart)
        settings.bridgeStatus = .notRunning
        #expect(settings.awaitsBridgeRestart)
        settings.beginBridgeRestart()
        settings.bridgeStatus = nil
        settings.reload()
        #expect(settings.awaitsBridgeRestart)
        settings.bridgeStatus = .on
        #expect(!settings.awaitsBridgeRestart)
        settings.bridgeStatus = nil
        #expect(!settings.awaitsBridgeRestart)
    }
}
