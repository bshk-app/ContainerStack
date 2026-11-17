import Foundation
import Testing

@testable import ContainerStackCore

struct SharedContainerGroupTests {
    private func container(_ id: String, _ labels: [String: String] = [:]) throws -> DockerContainerSummary {
        try JSONDecoder().decode(
            DockerContainerSummary.self,
            from: JSONSerialization.data(withJSONObject: [
                "Id": id, "Names": ["/" + id], "State": "running", "Labels": labels,
            ]))
    }

    @Test func groupsAndActions() throws {
        let shared = try container("parent", ["containerstack.shared.group": "mcp"])
        let other = try container("other", ["containerstack.shared.group": "mcp"])
        let session = try container(
            "s1", ["containerstack.session.group": "mcp", "containerstack.session.container": "parent"])
        let session2 = try container(
            "s2", ["containerstack.session.group": "mcp", "containerstack.session.container": "parent"])
        let orphan = try container(
            "s3",
            [
                "containerstack.session.group": "mcp", "containerstack.session.container": "gone",
                "com.docker.compose.project": "ignored",
            ])
        let compose = try container("web", ["com.docker.compose.project": "web"])
        let standalone = try container("alone")
        let groups = ContainerGroup.grouped([standalone, session, other, shared, orphan, compose, session2])
        #expect(groups.map(\.id) == ["compose:web", "shared:other", "shared:parent", "__standalone"])
        #expect(groups[2].containers == [session, session2])
        #expect(groups[3].containers == [standalone, orphan])
        #expect(groups[2].headerActions == [.stop])
        #expect(groups[2].stopConfirmation == "Stop mcp? This ends 2 sessions.")
        #expect(session.rowActions == [.stop, .logs])
        #expect(session.inspectorActions == [.stop])
        #expect(shared.inspectorActions == [.stop])
        #expect(Set(groups.map(\.id)).count == groups.count)
    }
}
