import ContainerStackCore
import Foundation
import Synchronization

@testable import ContainerStackApp

/// A Docker client configuration that lives in memory. Test models get one by default, so no test
/// reaches the user's contexts, the ownership record or the takeover preference (#102).
final class InMemoryDockerContext: Sendable {
    struct State: Equatable {
        var active: String?
        /// Socket paths by context name.
        var endpoints: [String: String]
        /// Every socket path `install` pointed our context at, in order.
        var installs: [String] = []
    }

    private let state: Mutex<State>

    init(active: String? = "default", endpoints: [String: String] = ["default": "/var/run/docker.sock"]) {
        state = Mutex(State(active: active, endpoints: endpoints))
    }

    var snapshot: State {
        state.withLock { $0 }
    }

    var store: DockerContextStore {
        DockerContextStore(
            read: { [self] includeInstalledContext in
                state.withLock {
                    DockerContextReading(
                        active: $0.active,
                        installed: includeInstalledContext ? $0.endpoints[DockerContext.name] != nil : nil,
                        defaultSocket: DockerSocketStatus(target: "/var/run/docker.sock", isReachable: false)
                    )
                }
            },
            install: { [self] socketPath in
                state.withLock {
                    $0.endpoints[DockerContext.name] = socketPath
                    $0.active = DockerContext.name
                    $0.installs.append(socketPath)
                }
            },
            uninstall: { [self] in
                state.withLock {
                    if $0.active == DockerContext.name { $0.active = "default" }
                    return $0.endpoints.removeValue(forKey: DockerContext.name) != nil
                }
            },
            recordedSocketPath: { [self] name in state.withLock { $0.endpoints[name] } },
            repairRecord: { [self] socketPath in state.withLock { $0.endpoints[DockerContext.name] = socketPath } }
        )
    }
}

extension DockerContextTakeoverPreference {
    /// Never written anywhere: the choice lives as long as the preference does.
    static func inMemory(_ stored: Bool? = nil) -> DockerContextTakeoverPreference {
        DockerContextTakeoverPreference(stored: stored, save: { _ in })
    }
}

extension RuntimeViewModel {
    /// The model every test builds unless it passes a store itself: an in-memory Docker
    /// configuration, an in-memory takeover preference, and a socket nothing serves. A test that
    /// means to reach the user's configuration has to say `.live`.
    convenience init(
        socketPath: String = "/tmp/containerstack-test-\(UUID().uuidString).sock",
        startsRuntime: Bool = false,
        client: DockerAPIClient? = nil,
        dockerContext: InMemoryDockerContext = InMemoryDockerContext(),
        dockerContextTakeoverPreference: DockerContextTakeoverPreference = .inMemory()
    ) {
        self.init(
            socketPath: socketPath,
            startsRuntime: startsRuntime,
            dockerContextStore: dockerContext.store,
            dockerContextTakeoverPreference: dockerContextTakeoverPreference,
            client: client
        )
    }
}
