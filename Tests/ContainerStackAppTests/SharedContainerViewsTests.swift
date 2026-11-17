import ContainerStackCore
import Foundation
import SwiftUI
import Testing

@testable import ContainerStackApp

@MainActor struct SharedContainerViewsTests {
    private func summary(_ id: String, _ labels: [String: String]) throws -> DockerContainerSummary {
        try JSONDecoder().decode(
            DockerContainerSummary.self,
            from: JSONSerialization.data(withJSONObject: [
                "Id": id, "Names": ["/" + id], "State": "running", "Labels": labels,
            ]))
    }

    @Test func searchKeepsTheParentAndInspectorExplainsSessions() throws {
        let parent = try summary("parent", ["containerstack.shared.group": "mcp"])
        let session = try summary(
            "session", ["containerstack.session.group": "mcp", "containerstack.session.container": "parent"])
        let groups = ContainerGroup.grouped([parent, session])
        #expect(ResourceSearch.containerGroups(groups, query: "parent") == groups)
        #expect(ResourceSearch.containerGroups(groups, query: "session") == groups)
        #expect(ResourceSearch.containerGroups(groups, query: "absent").isEmpty)
        let model = RuntimeViewModel(socketPath: "/test-unused.sock")
        model.containers = [parent, session]
        let inspector = ContainerInspector(container: session, model: model, tab: .constant(.info))
        let rows = inspector.infoRows(session)
        #expect(rows.contains { $0.key == "Shared container" && $0.value == "parent" })
        #expect(rows.contains { $0.key == "Group" && $0.value == "mcp" })
        #expect(inspector.infoRows(parent).contains { $0.key == "Sessions" && $0.value == "1" })
    }
}

extension SharedContainerViewsTests {
    @Test func unsupportedActionsReturnBeforeTheAPI() async throws {
        let transport = GatedDockerTransport(answers: [:])
        let model = RuntimeViewModel(client: DockerAPIClient(transport: transport))
        model.applyState(socketResponds: true)
        #expect(model.canMutate)
        let shared = try summary("parent", ["containerstack.shared.group": "mcp"])
        let session = try summary("session", ["containerstack.session.group": "mcp"])
        await model.start(group: ContainerGroup(kind: .shared(container: shared), containers: [session]))
        await model.remove(group: ContainerGroup(kind: .shared(container: shared), containers: [session]))
        await model.restart(container: session)
        await model.remove(container: session)
        #expect(model.resourceMessage == nil)
        #expect(model.containerMessage == nil)
    }
}
