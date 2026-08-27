import Foundation

/// Short-syntax representation of a single compose port mapping (`"3000:3000"`,
/// `"127.0.0.1:8080:80/tcp"`). Compose's `config` command normalizes these into long-form
/// objects and rewrites some fields, so `parse` only ever accepts the short syntax a human
/// writes in a file; long form is decoded separately by `ComposeProjectModel.parse`.
public struct ComposePortMapping: Equatable, Sendable, Identifiable {
    public var id: String { raw }
    public var hostIP: String?
    public var hostPort: Int?
    public var containerPort: Int
    public var transport: String?
    public var raw: String

    public init(hostIP: String? = nil, hostPort: Int?, containerPort: Int, transport: String? = nil) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.transport = transport
        var raw = ""
        if let hostIP { raw += "\(hostIP):" }
        if let hostPort { raw += "\(hostPort):" }
        raw += "\(containerPort)"
        if let transport { raw += "/\(transport)" }
        self.raw = raw
    }

    /// Parses compose port short syntax. Returns nil for anything it cannot represent rather
    /// than guessing. Ranges (`"8080-8090:80"`) keep their original text as `raw` and expose
    /// only the first container port, since the host side is a span the UI cannot edit field by field.
    public static func parse(_ raw: String) -> ComposePortMapping? {
        let body: String
        var transport: String?
        if let slash = raw.firstIndex(of: "/") {
            body = String(raw[..<slash])
            let suffix = String(raw[raw.index(after: slash)...])
            transport = suffix.isEmpty ? nil : suffix
        } else {
            body = raw
        }

        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            let candidate = parts[0]
            if isRange(candidate) {
                guard let containerPort = firstPort(candidate) else { return nil }
                return rangeMapping(hostIP: nil, containerPort: containerPort, transport: transport, raw: raw)
            }
            guard let containerPort = Int(candidate) else { return nil }
            return ComposePortMapping(hostPort: nil, containerPort: containerPort, transport: transport)
        case 2:
            let (host, container) = (parts[0], parts[1])
            if isRange(host) || isRange(container) {
                guard let containerPort = firstPort(container) else { return nil }
                return rangeMapping(hostIP: nil, containerPort: containerPort, transport: transport, raw: raw)
            }
            guard let hostPort = Int(host), let containerPort = Int(container) else { return nil }
            return ComposePortMapping(hostPort: hostPort, containerPort: containerPort, transport: transport)
        case 3:
            let (ip, host, container) = (parts[0], parts[1], parts[2])
            if isRange(host) || isRange(container) {
                guard let containerPort = firstPort(container) else { return nil }
                return rangeMapping(hostIP: ip, containerPort: containerPort, transport: transport, raw: raw)
            }
            guard let hostPort = Int(host), let containerPort = Int(container) else { return nil }
            return ComposePortMapping(
                hostIP: ip, hostPort: hostPort, containerPort: containerPort, transport: transport)
        default:
            return nil
        }
    }

    private static func rangeMapping(hostIP: String?, containerPort: Int, transport: String?, raw: String)
        -> ComposePortMapping
    {
        // init builds a canonical raw from fields, which cannot reproduce a span; preserve the
        // original text so re-parsing the same string yields an equal mapping.
        var mapping = ComposePortMapping(
            hostIP: hostIP, hostPort: nil, containerPort: containerPort, transport: transport)
        mapping.raw = raw
        return mapping
    }

    private static func isRange(_ candidate: String) -> Bool {
        candidate.contains("-")
    }

    private static func firstPort(_ candidate: String) -> Int? {
        let head = candidate.split(separator: "-").first.map(String.init) ?? candidate
        return Int(head)
    }
}

/// Short-syntax representation of a single compose volume mount (`"/host:/data"`,
/// `"./conf:/etc/conf:ro"`, named `"data:/data"`, anonymous `"/data"`).
public struct ComposeVolumeMount: Equatable, Sendable, Identifiable {
    public var id: String { raw }
    public var source: String
    public var target: String
    public var isReadOnly: Bool
    public var raw: String

    public var isBindMount: Bool {
        source.hasPrefix("/") || source.hasPrefix("./") || source.hasPrefix("../") || source.hasPrefix("~")
    }

    public init(source: String, target: String, isReadOnly: Bool) {
        self.source = source
        self.target = target
        self.isReadOnly = isReadOnly
        if source.isEmpty {
            self.raw = target
        } else {
            var raw = "\(source):\(target)"
            if isReadOnly { raw += ":ro" }
            self.raw = raw
        }
    }

    /// Parses compose volume short syntax: `SOURCE:TARGET[:MODE]`, or a lone `TARGET`
    /// (anonymous volume, empty source). Returns nil for anything it cannot represent.
    public static func parse(_ raw: String) -> ComposeVolumeMount? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            let target = parts[0]
            guard !target.isEmpty else { return nil }
            return ComposeVolumeMount(source: "", target: target, isReadOnly: false)
        case 2:
            let (source, target) = (parts[0], parts[1])
            guard !source.isEmpty, !target.isEmpty else { return nil }
            return ComposeVolumeMount(source: source, target: target, isReadOnly: false)
        case 3:
            let (source, target, mode) = (parts[0], parts[1], parts[2])
            guard !source.isEmpty, !target.isEmpty else { return nil }
            return ComposeVolumeMount(source: source, target: target, isReadOnly: mode.lowercased() == "ro")
        default:
            return nil
        }
    }
}

/// One service within a compose project, capturing only the fields the Stacks UI edits.
public struct ComposeService: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var image: String?
    public var restart: String?
    public var ports: [ComposePortMapping]
    public var volumes: [ComposeVolumeMount]

    public init(
        name: String,
        image: String? = nil,
        restart: String? = nil,
        ports: [ComposePortMapping] = [],
        volumes: [ComposeVolumeMount] = []
    ) {
        self.name = name
        self.image = image
        self.restart = restart
        self.ports = ports
        self.volumes = volumes
    }
}

/// A compose project as seen by `docker compose config --format json`: a name plus its
/// services, with ports/volumes decoded back into the short-syntax types the editor works in.
public struct ComposeProjectModel: Equatable, Sendable {
    public var name: String
    public var services: [ComposeService]

    public init(name: String, services: [ComposeService]) {
        self.name = name
        self.services = services
    }

    enum DecodeError: Error, Equatable {
        case invalidJSON
    }

    /// Parses `docker compose config --format json`. Compose normalizes short syntax into long
    /// objects (and resolves bind sources to absolute paths): ports arrive as objects with
    /// `target`, `published` (a string, absent for ephemeral ports, a range string for spans),
    /// `host_ip`, `protocol`; volumes as objects with `type`, `source`, `target`, `read_only`.
    /// Older Compose emits plain strings for both, which are accepted too. Services come back
    /// sorted by name for stable UI.
    public static func parse(configJSON: Data, fallbackName: String) throws -> ComposeProjectModel {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: configJSON, options: [])
        } catch {
            throw DecodeError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw DecodeError.invalidJSON
        }

        let name = (root["name"] as? String) ?? fallbackName
        let servicesObject = (root["services"] as? [String: Any]) ?? [:]
        let services =
            servicesObject
            .map { serviceName, body -> ComposeService in
                let dict = (body as? [String: Any]) ?? [:]
                return ComposeService(
                    name: serviceName,
                    image: dict["image"] as? String,
                    restart: dict["restart"] as? String,
                    ports: portMappings(from: dict["ports"]),
                    volumes: volumeMounts(from: dict["volumes"])
                )
            }
            .sorted { $0.name < $1.name }

        return ComposeProjectModel(name: name, services: services)
    }

    private static func portMappings(from value: Any?) -> [ComposePortMapping] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { entry -> ComposePortMapping? in
            if let string = entry as? String {
                return ComposePortMapping.parse(string)
            }
            if let dict = entry as? [String: Any] {
                guard let containerPort = intValue(dict["target"]) else { return nil }
                return ComposePortMapping(
                    hostIP: dict["host_ip"] as? String,
                    // `published` is a string in current Compose, a number in older builds, and a
                    // range string ("8090-8092") or absent for spans/ephemeral ports — all collapse
                    // to nil here, which the editor matches by container port + transport.
                    hostPort: intValue(dict["published"]),
                    containerPort: containerPort,
                    transport: dict["protocol"] as? String
                )
            }
            return nil
        }
    }

    private static func volumeMounts(from value: Any?) -> [ComposeVolumeMount] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { entry -> ComposeVolumeMount? in
            if let string = entry as? String {
                return ComposeVolumeMount.parse(string)
            }
            if let dict = entry as? [String: Any] {
                guard let target = dict["target"] as? String else { return nil }
                let source = (dict["source"] as? String) ?? ""
                let readOnly = (dict["read_only"] as? Bool) ?? false
                return ComposeVolumeMount(source: source, target: target, isReadOnly: readOnly)
            }
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? Int { return number }
        if let string = value as? String { return Int(string) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
