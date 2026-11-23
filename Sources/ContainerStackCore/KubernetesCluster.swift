import Foundation

public enum ClusterListError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let reason): "cluster list: \(reason)"
        }
    }
}

public struct KubernetesCluster: Decodable, Equatable, Sendable {
    public enum State: String, Sendable {
        case running, degraded, stopped
    }

    public struct Node: Decodable, Equatable, Sendable {
        public let name: String
        public let roles: [String]
    }

    public struct NodeStatus: Decodable, Equatable, Sendable {
        public let name: String
        public let status: String
        public let addresses: [String]?
        public let ports: [String]?
    }

    public let name: String
    public let kubernetesVersion: String
    public let remove: Bool
    public let sharedImageStore: Bool
    public let creationDate: Date
    public let cni: String?
    public let fqdn: String?
    public let nodes: [Node]
    public let state: State
    public let nodeStatuses: [NodeStatus]

    private enum Keys: String, CodingKey {
        case configuration, status
        case name, kubernetesVersion, remove, sharedImageStore, creationDate, cni, fqdn, nodes, state
    }

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: Keys.self)
        let configuration = try root.nestedContainer(keyedBy: Keys.self, forKey: .configuration)
        name = try configuration.decode(String.self, forKey: .name)
        kubernetesVersion = try configuration.decode(String.self, forKey: .kubernetesVersion)
        remove = try configuration.decode(Bool.self, forKey: .remove)
        sharedImageStore = try configuration.decode(Bool.self, forKey: .sharedImageStore)
        creationDate = try configuration.decode(Date.self, forKey: .creationDate)
        cni = try configuration.decodeIfPresent(String.self, forKey: .cni)
        fqdn = try configuration.decodeIfPresent(String.self, forKey: .fqdn)
        nodes = try configuration.decode([Node].self, forKey: .nodes)
        let status = try root.nestedContainer(keyedBy: Keys.self, forKey: .status)
        let rawState = try status.decode(String.self, forKey: .state)
        guard let state = State(rawValue: rawState) else {
            throw DecodingError.dataCorruptedError(forKey: .state, in: status, debugDescription: rawState)
        }
        self.state = state
        nodeStatuses = try status.decode([NodeStatus].self, forKey: .nodes)
    }

    public var apiEndpoint: URL? {
        if let fqdn, !fqdn.isEmpty {
            return URL(string: "https://\(fqdn):6443")
        }
        let controlPlane = nodes.first { $0.roles.contains("control-plane") }?.name
        let ports = nodeStatuses.first { $0.name == controlPlane }?.ports ?? []
        for port in ports {
            let sides = port.split(separator: "->")
            if sides.count == 2, sides[1].split(separator: "/").first == "6443", let host = Int(sides[0]) {
                return URL(string: "https://127.0.0.1:\(host)")
            }
        }
        return nil
    }

    public static func decodeList(_ data: Data) throws -> [KubernetesCluster] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([KubernetesCluster].self, from: data)
        } catch DecodingError.keyNotFound(let key, let context) {
            throw ClusterListError.invalid("missing key \(path(context.codingPath + [key]))")
        } catch DecodingError.dataCorrupted(let context) where context.codingPath.last?.stringValue == "state" {
            throw ClusterListError.invalid("unknown value '\(context.debugDescription)' at \(path(context.codingPath))")
        } catch let error as DecodingError {
            throw ClusterListError.invalid(String(describing: error))
        }
    }

    private static func path(_ keys: [any CodingKey]) -> String {
        let names = keys.dropFirst().map { key in key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)" }
        return String(names.joined().dropFirst())
    }
}
