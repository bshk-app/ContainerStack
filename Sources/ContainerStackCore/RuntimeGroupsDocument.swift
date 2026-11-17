import Foundation

public struct RuntimeGroup: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case exec
        /// Reserved; a `pod` group is disabled in version 1.
        case pod
    }

    public var name: String
    public var kind: Kind
    public var idleMinutes: Int
    public var enabled: Bool

    /// Whether runs can be sessions of this group.
    public var isActive: Bool { enabled && kind == .exec }
}

public enum RuntimeGroupRule: Equatable, Sendable {
    /// A glob on the image name as the client wrote it, with no tag and no `docker.io/` prefix.
    case image(group: String, pattern: String)
    /// Matches each eligible run.
    case stdioSession(group: String)

    public var group: String {
        switch self {
        case .image(let group, _), .stdioSession(let group): group
        }
    }
}

public enum RuntimeGroupsDocumentError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .malformed(let detail): "runtime-groups.json does not parse: \(detail)"
        case .unsupportedVersion(let version): "runtime-groups.json: unsupported version \(version)"
        }
    }
}

/// `~/.containerstack/runtime-groups.json`, version 1 (frozen contract).
public struct RuntimeGroupsDocument: Equatable, Sendable {
    public static let supportedVersion = 1
    public static let allowedIdleMinutes: Set<Int> = [0, 5, 10, 30, 60]

    public let version: Int
    public var groups: [RuntimeGroup]
    public let rules: [RuntimeGroupRule]

    public func group(named name: String) -> RuntimeGroup? {
        groups.first { $0.name == name }
    }

    /// The document used when the file is missing; also the fixture `runtime-groups.v1.json`.
    public static let defaultJSON = """
        {
          "version": 1,
          "groups": [
            { "name": "mcp-catalog",    "kind": "exec", "idleMinutes": 10, "enabled": false },
            { "name": "stdio-sessions", "kind": "exec", "idleMinutes": 10, "enabled": false }
          ],
          "rules": [
            { "group": "mcp-catalog",    "image": "mcp/*" },
            { "group": "stdio-sessions", "stdioSession": true }
          ]
        }

        """

    public static let defaults: RuntimeGroupsDocument = {
        do {
            return try decode(Data(defaultJSON.utf8))
        } catch {
            preconditionFailure("the built-in runtime groups document does not decode: \(error)")
        }
    }()

    /// Strict decoder: unknown keys, a missing field or an invalid value make the file malformed.
    public static func decode(_ data: Data) throws -> RuntimeGroupsDocument {
        let root: [String: SharedRuntimeJSON]
        do {
            root = try object(SharedRuntimeJSON.parse(data), "the document")
        } catch let error as RuntimeGroupsDocumentError {
            throw error
        } catch {
            throw RuntimeGroupsDocumentError.malformed("not JSON")
        }
        let version = try integer(root["version"], "version")
        guard version == supportedVersion else { throw RuntimeGroupsDocumentError.unsupportedVersion(version) }
        try onlyKeys(root, ["version", "groups", "rules"], "the document")

        var groups: [RuntimeGroup] = []
        for (index, value) in try array(root["groups"], "groups").enumerated() {
            let group = try decodeGroup(value, "groups[\(index)]")
            guard !groups.contains(where: { $0.name == group.name }) else {
                throw RuntimeGroupsDocumentError.malformed("groups[\(index)]: duplicate name \"\(group.name)\"")
            }
            groups.append(group)
        }

        var rules: [RuntimeGroupRule] = []
        for (index, value) in try array(root["rules"], "rules").enumerated() {
            let rule = try decodeRule(value, "rules[\(index)]")
            guard groups.contains(where: { $0.name == rule.group }) else {
                throw RuntimeGroupsDocumentError.malformed("rules[\(index)]: unknown group \"\(rule.group)\"")
            }
            rules.append(rule)
        }
        return RuntimeGroupsDocument(version: version, groups: groups, rules: rules)
    }

    private static func decodeGroup(_ value: SharedRuntimeJSON, _ path: String) throws -> RuntimeGroup {
        let fields = try object(value, path)
        try onlyKeys(fields, ["name", "kind", "idleMinutes", "enabled"], path)
        let name = try string(fields["name"], "\(path).name")
        guard (1...32).contains(name.count),
            name.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
        else {
            throw RuntimeGroupsDocumentError.malformed("\(path).name: \"\(name)\" is not [a-z0-9-]{1,32}")
        }
        let kindName = try string(fields["kind"], "\(path).kind")
        guard let kind = RuntimeGroup.Kind(rawValue: kindName) else {
            throw RuntimeGroupsDocumentError.malformed("\(path).kind: unknown kind \"\(kindName)\"")
        }
        let idleMinutes = try integer(fields["idleMinutes"], "\(path).idleMinutes")
        guard allowedIdleMinutes.contains(idleMinutes) else {
            throw RuntimeGroupsDocumentError.malformed("\(path).idleMinutes: \(idleMinutes) is not 0, 5, 10, 30 or 60")
        }
        guard case .bool(let enabled) = fields["enabled"] else {
            throw RuntimeGroupsDocumentError.malformed("\(path).enabled: expected true or false")
        }
        return RuntimeGroup(name: name, kind: kind, idleMinutes: idleMinutes, enabled: enabled)
    }

    private static func decodeRule(_ value: SharedRuntimeJSON, _ path: String) throws -> RuntimeGroupRule {
        let fields = try object(value, path)
        try onlyKeys(fields, ["group", "image", "stdioSession"], path)
        let group = try string(fields["group"], "\(path).group")
        switch (fields["image"], fields["stdioSession"]) {
        case (.some(let pattern), nil):
            let pattern = try string(pattern, "\(path).image")
            guard !pattern.isEmpty else { throw RuntimeGroupsDocumentError.malformed("\(path).image: empty pattern") }
            return .image(group: group, pattern: pattern)
        case (nil, .some(.bool(true))):
            return .stdioSession(group: group)
        case (nil, .some):
            throw RuntimeGroupsDocumentError.malformed("\(path).stdioSession: expected true")
        default:
            throw RuntimeGroupsDocumentError.malformed(
                "\(path): a rule needs exactly one of \"image\" and \"stdioSession\"")
        }
    }

    private static func object(_ value: SharedRuntimeJSON?, _ path: String) throws -> [String: SharedRuntimeJSON] {
        guard let object = value?.objectValue else {
            throw RuntimeGroupsDocumentError.malformed("\(path): expected an object")
        }
        return object
    }

    private static func array(_ value: SharedRuntimeJSON?, _ path: String) throws -> [SharedRuntimeJSON] {
        guard case .array(let array) = value else {
            throw RuntimeGroupsDocumentError.malformed("\(path): expected an array")
        }
        return array
    }

    private static func string(_ value: SharedRuntimeJSON?, _ path: String) throws -> String {
        guard case .string(let string) = value else {
            throw RuntimeGroupsDocumentError.malformed("\(path): expected a string")
        }
        return string
    }

    private static func integer(_ value: SharedRuntimeJSON?, _ path: String) throws -> Int {
        guard case .integer(let integer) = value else {
            throw RuntimeGroupsDocumentError.malformed("\(path): expected an integer")
        }
        return integer
    }

    private static func onlyKeys(_ object: [String: SharedRuntimeJSON], _ allowed: Set<String>, _ path: String) throws {
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw RuntimeGroupsDocumentError.malformed("\(path): unknown key \"\(unknown)\"")
        }
    }
}
