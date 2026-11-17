import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@MainActor struct SharedLifecycleActionTests {
    private func summary(_ id: String, labels: [String: String], state: String = "running") throws
        -> DockerContainerSummary
    {
        try JSONDecoder().decode(
            DockerContainerSummary.self,
            from: JSONSerialization.data(withJSONObject: [
                "Id": id, "State": state, "Labels": labels,
            ]))
    }

    @Test func onlyRunningSharedResourcesCanBeStopped() throws {
        for state in ["created", "exited", "running"] {
            for key in ["containerstack.shared.group", "containerstack.session.group"] {
                let container = try summary("shared", labels: [key: "mcp"], state: state)
                #expect(container.allowsLifecycleAction == (state == "running"))
            }
            let dedicated = try summary("dedicated", labels: [:], state: state)
            #expect(dedicated.allowsLifecycleAction)
        }
    }

}
