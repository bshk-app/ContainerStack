import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@MainActor struct SharedHeaderReviewTests {
    private func summary(_ id: String, labels: [String: String], state: String = "running") throws
        -> DockerContainerSummary
    {
        try JSONDecoder().decode(
            DockerContainerSummary.self,
            from: JSONSerialization.data(withJSONObject: [
                "Id": id, "State": state, "Labels": labels,
            ]))
    }

    @Test func sharedHeaderUsesAllSessionsForItsStopConfirmation() throws {
        let parent = try summary("parent", labels: ["containerstack.shared.group": "mcp"])
        let labels = ["containerstack.session.group": "mcp", "containerstack.session.container": "parent"]
        let first = try summary("first", labels: labels)
        let second = try summary("second", labels: labels)
        let model = RuntimeViewModel(socketPath: "/unused-test.sock")
        model.containers = [parent, first, second]
        let filtered = ContainerGroup(kind: .shared(container: parent), containers: [first])
        let header = ContainerGroupHeader(group: filtered, model: model, isCollapsed: false, toggle: {})
        #expect(header.actionGroup.headerActions == [.stop])
        #expect(header.actionGroup.stopConfirmation == "Stop mcp? This ends 2 sessions.")
    }

}
