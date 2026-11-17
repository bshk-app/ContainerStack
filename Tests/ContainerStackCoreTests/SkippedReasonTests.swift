import Foundation
import Testing

@testable import ContainerStackCore

struct SkippedReasonTests {
    @Test func skippedReasons() throws {
        let reasons = [
            "no-stdin": "The run does not keep stdin open.",
            "no-autoremove": "The run does not remove itself when it ends.",
            "tty": "The run has a TTY.",
            "mount": "The run or its image has a mount or a volume.",
            "port": "The run publishes a port.",
            "network": "The run sets a network.",
            "limits": "The run sets resource limits.",
            "unknown-group": "The group is unknown.",
            "disabled-group": "The group is disabled.",
            "option:Privileged": "The run sets Privileged.",
        ]
        for (reason, text) in reasons {
            let parsed = try #require(SkippedReason("g:" + reason))
            #expect(parsed.group == "g")
            #expect(parsed.explanation == text)
        }
        #expect(SkippedReason("g:future")?.explanation == "future")
        #expect(SkippedReason("broken") == nil)
    }
}
