import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

/// What a test must never change: the user's active Docker context, the endpoint of the context
/// the app installs, the record of which context it took over from, and the takeover preference.
/// Read through the same code the app uses; on a machine without `docker` the first two are nil.
struct UserDockerConfiguration: Equatable {
    let activeContext: String?
    let ourEndpoint: String?
    let ownershipRecord: Data?
    let takeoverPreference: Bool?

    static func read() -> UserDockerConfiguration {
        UserDockerConfiguration(
            activeContext: DockerCLI.activeContext(),
            ourEndpoint: try? DockerCLI.recordedSocketPath(for: DockerContext.name),
            ownershipRecord: try? Data(contentsOf: DockerContextOwnershipStore.defaultURL),
            takeoverPreference: UserDefaults.standard.object(forKey: DockerContextTakeoverPreference.defaultKey)
                as? Bool
        )
    }
}

@Suite("Tests leave the user's Docker configuration alone")
@MainActor
struct DockerContextIsolationTests {
    /// The path that rewrote the user's context on #102: Stop's closing probe finds the socket
    /// answering, the transition adopts the Docker context, and the model installed it, through the
    /// real `DockerCLI`, pointing at the test's socket.
    @Test("the lifecycle path adopts the context in the test's own store, and the user's is unchanged")
    func lifecyclePathAdoptsOnlyTheIsolatedContext() async {
        let before = UserDockerConfiguration.read()
        let context = InMemoryDockerContext(
            active: DockerContext.name, endpoints: [DockerContext.name: "/tmp/containerstack-elsewhere.sock"])
        let model = RuntimeViewModel(
            client: DockerAPIClient(
                transport: GatedDockerTransport(answers: [:]), retryPolicy: DockerRetryPolicy(maxAttempts: 1)),
            dockerContext: context
        )
        let runtime = FakeRuntime()
        runtime.socketAnswers = true
        model.steps = runtime.steps()

        #expect(await settled(Task { await model.stopRuntime() }) != nil)

        #expect(context.snapshot.installs == [model.socketPath])
        #expect(model.dockerContextTakeoverPreference.isEnabled)
        #expect(UserDockerConfiguration.read() == before)
    }
}
