import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@MainActor struct SharedRuntimeSettingsTests {
    @Test func editsAndBridgeStates() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = SharedRuntimeSettings(home: home)
        #expect(settings.document == .defaults)
        #expect(!FileManager.default.fileExists(atPath: settings.fileURL.path))
        #expect(!settings.awaitsBridgeRestart)
        settings.setEnabled(true, group: "mcp-catalog")
        #expect(settings.document?.group(named: "mcp-catalog")?.enabled == true)
        for status in [nil, .on, .notRunning, .starting, .off(cause: "bad")] as [SharedRuntimesStatus?] {
            settings.bridgeStatus = status
            #expect(settings.awaitsBridgeRestart == (status == .notRunning))
        }
        settings.setEnabled(false, group: "mcp-catalog")
        for status in [nil, .on, .notRunning, .starting, .off(cause: "bad")] as [SharedRuntimesStatus?] {
            settings.bridgeStatus = status
            #expect(!settings.awaitsBridgeRestart)
        }
        settings.setIdleMinutes(30)
        #expect(settings.idleMinutes == 30)
        try RuntimeGroupsFile.edit(at: settings.fileURL) { $0.groups[0].idleMinutes = 5 }
        settings.reload()
        #expect(settings.idleMinutes == nil)
        settings.setEnabled(true, group: "stdio-sessions")
        #expect(settings.document?.groups[0].idleMinutes == 5)
        try Data("bad".utf8).write(to: settings.fileURL)
        settings.setEnabled(false, group: "stdio-sessions")
        #expect(settings.document == nil)
        #expect(try String(contentsOf: settings.fileURL, encoding: .utf8) == "bad")
        settings.resetToDefaults()
        #expect(settings.document == .defaults)
    }
}

extension SharedRuntimeSettingsTests {
    @Test func aSettingChangeKeepsHandEditedRulesAndGroups() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = SharedRuntimeSettings(home: home)
        let json = """
            {"version":1,"groups":[
              {"name":"custom","kind":"pod","idleMinutes":60,"enabled":true},
              {"name":"stdio-sessions","kind":"exec","idleMinutes":5,"enabled":false},
              {"name":"mcp-catalog","kind":"exec","idleMinutes":30,"enabled":false}],
            "rules":[{"group":"custom","image":"custom/*"},
              {"group":"stdio-sessions","stdioSession":true},{"group":"mcp-catalog","image":"mcp/*"}]}
            """
        let original = try RuntimeGroupsFile.decode(Data(json.utf8))
        try RuntimeGroupsFile.write(original, to: settings.fileURL, expecting: nil)
        settings.setEnabled(true, group: "mcp-catalog")
        let edited = try #require(settings.document)
        #expect(edited.rules == original.rules)
        #expect(edited.groups.map(\.name) == original.groups.map(\.name))
        #expect(edited.groups[0] == original.groups[0])
        #expect(edited.groups[1] == original.groups[1])
        #expect(edited.groups[2].enabled)
        settings.setIdleMinutes(10)
        #expect(settings.document?.groups[0].idleMinutes == 60)
        #expect(settings.idleMinutes == 10)
    }
}
