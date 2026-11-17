import Foundation
import Testing

@testable import ContainerStackCore

struct SkippedReasonTests {
    @Test func skippedReasons() throws {
        for reason in [
            "no-stdin", "no-autoremove", "tty", "mount", "port", "network", "limits", "unknown-group", "disabled-group",
        ] {
            let parsed = try #require(SkippedReason("g:" + reason))
            #expect(parsed.group == "g")
            #expect(parsed.explanation != reason)
        }
        #expect(SkippedReason("g:future")?.explanation == "future")
        #expect(SkippedReason("broken") == nil)
    }
}
