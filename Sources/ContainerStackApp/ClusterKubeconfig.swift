import ContainerStackCore
import Darwin
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
        try prepareEmptyUserConfig()
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

    private func prepareEmptyUserConfig() throws {
        let path = commands.userKubeconfig
        guard let text = try Self.readText(path), Self.isEmptyDocument(text) else { return }

        let descriptor = open(path.path, O_RDWR | O_APPEND)
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data = try file.readToEnd() ?? Data()
        guard let current = String(data: data, encoding: .utf8), Self.isEmptyDocument(current) else {
            throw ClusterKubeconfigError.unreadable
        }
        let separator = current.isEmpty || current.last?.isNewline == true ? "" : "\n"
        try file.write(contentsOf: Data("\(separator)apiVersion: v1\nkind: Config\n".utf8))
    }

    private static func read(_ path: URL) throws -> KubeconfigIndex? {
        guard let text = try readText(path), !isEmptyDocument(text) else { return nil }
        return try YAMLDecoder().decode(KubeconfigIndex.self, from: text)
    }

    private static func readText(_ path: URL) throws -> String? {
        do {
            return try String(contentsOf: path, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private static func isEmptyDocument(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).allSatisfy { line in
            let content = line.trimmingCharacters(in: .whitespaces)
            return content.isEmpty || content.hasPrefix("#")
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
