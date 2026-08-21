import Foundation
import Testing
@testable import ContainerStackCore

struct ContainerGroupTests {
    @Test
    func groupsComposeProjectsBeforeStandaloneContainers() throws {
        let containers = [
            try summary(id: "a", project: nil),
            try summary(id: "b", project: "web"),
            try summary(id: "c", project: "api"),
            try summary(id: "d", project: "web")
        ]

        let groups = ContainerGroup.grouped(containers)

        #expect(groups.map(\.title) == ["api", "web", "Standalone"])
        #expect(groups[1].containers.map(\.id) == ["b", "d"])
        #expect(groups[2].project == nil)
    }

    @Test
    func returnsNoGroupsForEmptyInput() {
        #expect(ContainerGroup.grouped([]).isEmpty)
    }

    private func summary(id: String, project: String?) throws -> DockerContainerSummary {
        let labels = project.map { "{\"com.docker.compose.project\":\"\($0)\"}" } ?? "null"
        let json = """
        {"Id":"\(id)","Names":["/\(id)"],"State":"running","Labels":\(labels)}
        """
        return try JSONDecoder().decode(DockerContainerSummary.self, from: Data(json.utf8))
    }
}
