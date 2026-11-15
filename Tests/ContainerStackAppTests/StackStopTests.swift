import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

struct StackStopTests {
    @Test("Stack Stop controls do not remove containers")
    func stopControlsKeepContainers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "Sources/ContainerStackApp/StacksView.swift"), encoding: .utf8)

        #expect(
            source.contains(
                "InspectorAction(title: \"Stop\") {\n                        Task { await model.stopStack(stack) }"))
        #expect(source.components(separatedBy: "Task { await model.stopStack(stack) }").count == 3)
    }
}

extension StackStopTests {
    @Test("Group Stop keeps stopped containers and the discovered stack")
    @MainActor
    func groupStopKeepsDiscoveredStack() async throws {
        let stopped = """
            [{"Id":"web","State":"exited","Labels":{
              "com.docker.compose.project":"demo",
              "com.docker.compose.project.config_files":"/tmp/demo/compose.yaml",
              "com.docker.compose.project.working_dir":"/tmp/demo"}}]
            """
        let transport = GatedDockerTransport(answers: ["/containers/web/stop": "{}", "/containers/json": stopped])
        let model = RuntimeViewModel(client: DockerAPIClient(transport: transport))
        model.applyState(socketResponds: true)
        let running = try JSONDecoder().decode(
            [DockerContainerSummary].self, from: Data(stopped.replacingOccurrences(of: "exited", with: "running").utf8))

        await model.stop(group: ContainerGroup(project: "demo", containers: running))

        #expect(model.resourceMessage == "Stopped demo.")
        #expect(model.busyResource == nil)
        #expect(model.containers.map(\.id) == ["web"])
        #expect(model.allStacks.map(\.name) == ["demo"])
    }
}
