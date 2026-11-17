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

extension SharedRuntimeRestartTests {
    @Test func restartMessagesDescribeOnlyThePendingChanges() {
        let shared = "Shared runtimes start after a Docker bridge restart."
        let resources = "Saved. New Docker API containers and builds use these values after a Docker bridge restart."
        #expect(
            SystemSettingsView.restartMessages(resourcesAwaitRestart: false, sharedRuntimesAwaitRestart: true) == [
                shared
            ])
        #expect(
            SystemSettingsView.restartMessages(resourcesAwaitRestart: true, sharedRuntimesAwaitRestart: false) == [
                resources
            ])
        #expect(
            SystemSettingsView.restartMessages(resourcesAwaitRestart: true, sharedRuntimesAwaitRestart: true) == [
                shared, resources,
            ])
        #expect(
            SystemSettingsView.restartMessages(resourcesAwaitRestart: false, sharedRuntimesAwaitRestart: false).isEmpty)
    }
}
