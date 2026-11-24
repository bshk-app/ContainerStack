import ContainerStackCore
import Foundation
import Yams

enum ClusterKubeconfigError: Error, Equatable, CustomStringConvertible {
    case collision(String)
    case unreadable

    var description: String {
        switch self {
        case .collision(let name):
            "~/.kube/config already has a cluster, context or user named \(name). "
                + "container would replace it. Remove it first or use the ContainerStack kubeconfig."
        case .unreadable:
            "Could not read ~/.kube/config. Check the file before adding a context."
        }
    }
}

struct ClusterKubeconfig {
    let commands: ClusterCommands

    static func copyLines(name: String) -> [String] {
        [
            "kubectl --kubeconfig ~/.containerstack/kubeconfig --context \(name) get nodes",
            "export KUBECONFIG=~/.containerstack/kubeconfig",
        ]
    }

    func checkAdd(name: String) throws {
        try commands.prepareKubeconfig()
        guard let user = try readUser() else { return }
        if user.names.contains(name) { throw ClusterKubeconfigError.collision(name) }
    }

    func add(name: String) async throws {
        try checkAdd(name: name)
        try await commands.writeConfig(name: name, into: .userDefault)
    }

    func writeManaged(name: String) async throws {
        try await commands.writeConfig(name: name)
    }

    func managedContexts() -> Set<String> {
        let config = try? Self.read(commands.managedKubeconfig)
        return Set(config?.contexts?.map(\.name) ?? [])
    }

    func cleanupCommands(name: String, endpoint: URL?) -> [String] {
        guard let endpoint, let user = try? readUser(),
            let context = user.contexts?.first(where: { $0.name == name }),
            let cluster = user.clusters?.first(where: { $0.name == context.context.cluster }),
            URL(string: cluster.cluster.server) == endpoint
        else { return [] }
        return ["context", "cluster", "user"].map {
            "kubectl --kubeconfig \"$HOME/.kube/config\" config delete-\($0) \(name)"
        }
    }

    private func readUser() throws -> KubeconfigIndex? {
        do {
            return try Self.read(commands.userKubeconfig)
        } catch {
            throw ClusterKubeconfigError.unreadable
        }
    }

    private static func read(_ path: URL) throws -> KubeconfigIndex? {
        do {
            let text = try String(contentsOf: path, encoding: .utf8)
            return try YAMLDecoder().decode(KubeconfigIndex.self, from: text)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }
}

private struct KubeconfigIndex: Decodable {
    struct Context: Decodable {
        let cluster: String
    }

    struct Cluster: Decodable {
        let server: String
    }

    struct NamedContext: Decodable {
        let name: String
        let context: Context
    }

    struct NamedCluster: Decodable {
        let name: String
        let cluster: Cluster
    }

    struct NamedUser: Decodable {
        let name: String
    }

    let clusters: [NamedCluster]?
    let contexts: [NamedContext]?
    let users: [NamedUser]?

    var names: Set<String> {
        Set((clusters ?? []).map(\.name) + (contexts ?? []).map(\.name) + (users ?? []).map(\.name))
    }
}
