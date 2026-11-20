import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@Suite("Inventory polling")
@MainActor
struct InventoryPollingTests {
    @Test("Steady ticks do not list images and volumes on every tick")
    func keepsSteadyPollCheap() async {
        let transport = InventoryTransport()
        let model = await makeModel(transport)

        let start = ContinuousClock.now
        for tick in 0..<20 {
            await model.probeRuntime(now: start + .seconds(tick * 3))
        }

        let paths = await transport.paths
        #expect(paths.filter { $0 == "/containers/json" }.count == 20)
        #expect(paths.filter { $0 == "/networks" }.count == 20)
        #expect(paths.filter { $0 == "/images/json" }.count == 1)
        #expect(paths.filter { $0 == "/volumes" }.count == 1)
    }

    @Test("A healthy poll follows external image and volume changes with bulk reads")
    func followsExternalChanges() async {
        let transport = InventoryTransport()
        let model = await makeModel(transport)

        let start = ContinuousClock.now
        await model.probeRuntime(now: start)

        #expect(model.images.map(\.id) == ["pulled", "built"])
        #expect(model.volumes.map(\.name) == ["external"])
        #expect(model.images.count == 2)
        #expect(model.volumes.count == 1)

        await transport.removeExternalResources()
        await model.probeRuntime(now: start + .seconds(60))

        #expect(model.images.isEmpty)
        #expect(model.volumes.isEmpty)
        #expect(
            await transport.paths == [
                "/containers/json", "/networks", "/images/json", "/volumes",
                "/containers/json", "/networks", "/images/json", "/volumes",
            ])
    }

    @Test("Full refresh is immediate and the next poll does not repeat it")
    func fullRefreshResetsCadence() async throws {
        let transport = InventoryTransport()
        let model = await makeModel(transport)
        let data = Data("{}".utf8)
        let health = try RuntimeHealthSnapshot(
            pingOK: true,
            version: JSONDecoder().decode(DockerVersion.self, from: data),
            info: JSONDecoder().decode(DockerInfo.self, from: data)
        )

        await model.refresh(health: { health })
        #expect(model.images.count == 2)
        #expect(model.volumes.count == 1)

        await transport.removeExternalResources()
        await model.refresh(health: { health })
        #expect(model.images.isEmpty)
        #expect(model.volumes.isEmpty)

        await model.probeRuntime()

        let paths = await transport.paths
        #expect(paths.filter { $0 == "/images/json" }.count == 2)
        #expect(paths.filter { $0 == "/volumes" }.count == 2)
    }

    private func makeModel(_ transport: InventoryTransport) async -> RuntimeViewModel {
        let model = RuntimeViewModel(client: DockerAPIClient(transport: transport))
        model.steps = FakeRuntime().steps()
        model.steps.ping = { true }
        model.applyState(socketResponds: true)
        _ = await model.appRootAdvisory.fresh { nil }
        _ = await model.bridgeOwnerAdvisory.fresh { nil }
        return model
    }
}

private actor InventoryTransport: DockerAPITransport {
    private var hasResources = true
    private(set) var paths: [String] = []

    func removeExternalResources() { hasResources = false }

    func send(request: Data) async throws -> Data {
        let target = String(decoding: request, as: UTF8.self).split(separator: " ")[1]
        let path = String(target.prefix { $0 != "?" })
        paths.append(path)
        let body: String
        switch path {
        case "/images/json" where hasResources:
            body = #"[{"Id":"pulled","RepoTags":["alpine:3.20"]},{"Id":"built","RepoTags":["local:latest"]}]"#
        case "/volumes":
            body = hasResources ? #"{"Volumes":[{"Name":"external","Driver":"local"}]}"# : #"{"Volumes":[]}"#
        default:
            body = "[]"
        }
        return Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    }
}
