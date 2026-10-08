import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

/// A refresh reads five lists in turn. Each used to capture its own epoch, so a refresh superseded
/// while it listed images discarded the images and still published every list read after them
/// (#102).
@Suite("A superseded refresh publishes nothing")
@MainActor
struct RefreshEpochTests {
    @Test("no list read after the supersede is published")
    func noListAfterSupersede() async throws {
        let transport = GatedDockerTransport(
            answers: [
                "/images/json": "[]",
                "/containers/json": #"[{"Id":"web","State":"running"}]"#,
                "/volumes": #"{"Volumes":[{"Name":"data","Driver":"local"}]}"#,
                "/networks": #"[{"Id":"n1","Name":"bridge"}]"#,
            ],
            holding: ["/images/json"]
        )
        let model = try makeModel(transport)

        await refreshSupersededWhileListingImages(model, transport)

        #expect(model.containers.isEmpty)
        #expect(model.discoveredProjects.isEmpty)
        #expect(model.volumes.isEmpty)
        #expect(model.networks.isEmpty)
    }

    @Test("no error from a list read after the supersede is published")
    func noErrorAfterSupersede() async throws {
        let transport = GatedDockerTransport(answers: ["/images/json": "[]"], holding: ["/images/json"])
        let model = try makeModel(transport)

        await refreshSupersededWhileListingImages(model, transport)

        #expect(model.containersErrorMessage == nil)
        #expect(model.volumesErrorMessage == nil)
        #expect(model.networksErrorMessage == nil)
    }

    /// The probe's steady-state read is a refresh too: its lists go out under the epoch it began
    /// with, or a runtime declared dead during its ping gets its containers back.
    @Test("a probe whose epoch moved during its ping publishes no containers")
    func probeAfterSupersedePublishesNothing() async throws {
        let transport = GatedDockerTransport(answers: ["/containers/json": #"[{"Id":"web","State":"running"}]"#])
        let model = try makeModel(transport)
        model.applyState(socketResponds: true)
        model.steps.ping = {
            model.clearInventoryForStop()
            return true
        }

        await model.probeRuntime()

        #expect(model.containers.isEmpty)
    }

    private func refreshSupersededWhileListingImages(
        _ model: RuntimeViewModel, _ transport: GatedDockerTransport
    ) async {
        let healthy = try? RuntimeHealthSnapshot(
            pingOK: true,
            version: JSONDecoder().decode(DockerVersion.self, from: Data("{}".utf8)),
            info: JSONDecoder().decode(DockerInfo.self, from: Data("{}".utf8))
        )
        let refresh = Task { await model.refresh(health: { try #require(healthy) }) }
        await transport.waitUntilRequested("/images/json")

        model.clearInventoryForStop()
        await transport.release("/images/json")
        await refresh.value
    }

    private func makeModel(_ transport: GatedDockerTransport) throws -> RuntimeViewModel {
        let model = RuntimeViewModel(
            socketPath: "/tmp/containerstack-epoch-\(UUID().uuidString).sock",
            startsRuntime: false,
            client: DockerAPIClient(transport: transport, retryPolicy: DockerRetryPolicy(maxAttempts: 1, delay: .zero))
        )
        model.steps = FakeRuntime().steps()
        return model
    }
}
