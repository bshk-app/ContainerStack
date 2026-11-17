import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@MainActor struct SharedRuntimeIdlePickerTests {
    @Test func anIdlePickerWithOneGroupShowsThatGroupsValue() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = SharedRuntimeSettings(home: home)
        let json =
            #"{"version":1,"groups":[{"name":"mcp-catalog","kind":"exec","idleMinutes":30,"enabled":false}],"rules":[]}"#
        try RuntimeGroupsFile.write(RuntimeGroupsFile.decode(Data(json.utf8)), to: settings.fileURL, expecting: nil)
        settings.reload()
        #expect(settings.idleMinutes == 30)
        settings.setIdleMinutes(5)
        #expect(settings.idleMinutes == 5)
    }
}
