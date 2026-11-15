import Testing

@testable import ContainerStackApp
@testable import ContainerStackCore

@MainActor
struct ContainerActionMessageTests {
    @Test(arguments: [("stop", "Stopped"), ("start", "Started"), ("restart", "Restarted"), ("remove", "Removed")])
    func completionNamesTheAction(action: String, completion: String) async {
        let path = action == "remove" ? "/containers/demo" : "/containers/demo/\(action)"
        let transport = GatedDockerTransport(answers: [path: "", "/containers/json": "[]"])
        let model = RuntimeViewModel(client: DockerAPIClient(transport: transport))
        model.applyState(socketResponds: true)
        let container = DockerContainerSummary(
            id: "demo", names: ["/demo"], image: "alpine", imageID: nil,
            command: nil, created: nil, state: action == "start" ? "exited" : "running",
            status: nil, labels: nil, ports: nil, networkSettings: nil
        )

        switch action {
        case "stop", "start": await model.toggle(container: container)
        case "restart": await model.restart(container: container)
        default: await model.remove(container: container)
        }

        #expect(model.containerMessage == "\(completion) demo.")
        #expect(await transport.wasRequested(path))
        #expect(await transport.wasRequested("/containers/json"))
        #expect(model.busyContainerIDs.isEmpty)
    }
}
