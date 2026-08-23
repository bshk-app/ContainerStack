import Foundation

public struct DockerVolumeSummary: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let driver: String?
    public let mountpoint: String?
    public let createdAt: String?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case driver = "Driver"
        case mountpoint = "Mountpoint"
        case createdAt = "CreatedAt"
    }
}

public struct DockerIPAMConfig: Codable, Equatable, Sendable {
    public let subnet: String?
    public let gateway: String?

    enum CodingKeys: String, CodingKey {
        case subnet = "Subnet"
        case gateway = "Gateway"
    }
}

public struct DockerIPAM: Codable, Equatable, Sendable {
    public let config: [DockerIPAMConfig]?

    enum CodingKeys: String, CodingKey {
        case config = "Config"
    }
}

public struct DockerNetworkSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let driver: String?
    public let scope: String?
    public let declaredSubnet: String?
    public let declaredGateway: String?
    public let ipam: DockerIPAM?

    public var subnet: String? {
        declaredSubnet ?? ipam?.config?.first?.subnet
    }

    public var gateway: String? {
        declaredGateway ?? ipam?.config?.first?.gateway
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case driver = "Driver"
        case scope = "Scope"
        case declaredSubnet = "Subnet"
        case declaredGateway = "Gateway"
        case ipam = "IPAM"
    }
}

public struct DockerDiskUsage: Codable, Equatable, Sendable {
    public let layersSize: Int64?
    public let images: [DockerImageSummary]
    public let containers: [DockerContainerSummary]
    public let volumes: [DockerVolumeSummary]

    enum CodingKeys: String, CodingKey {
        case layersSize = "LayersSize"
        case images = "Images"
        case containers = "Containers"
        case volumes = "Volumes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layersSize = try container.decodeIfPresent(Int64.self, forKey: .layersSize)
        images = try container.decodeIfPresent([DockerImageSummary].self, forKey: .images) ?? []
        containers = try container.decodeIfPresent([DockerContainerSummary].self, forKey: .containers) ?? []
        volumes = try container.decodeIfPresent([DockerVolumeSummary].self, forKey: .volumes) ?? []
    }
}

public struct DockerPruneResult: Equatable, Sendable {
    public let spaceReclaimed: Int64
    public let deleted: [String]

    public init(spaceReclaimed: Int64, deleted: [String]) {
        self.spaceReclaimed = spaceReclaimed
        self.deleted = deleted
    }
}

public struct DockerPullEvent: Equatable, Sendable {
    public let id: String?
    public let status: String?
    public let progress: String?
    public let error: String?

    public init(id: String?, status: String?, progress: String?, error: String?) {
        self.id = id
        self.status = status
        self.progress = progress
        self.error = error
    }
}

public struct DockerContainerDetail: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let image: String?
    public let created: String?
    public let status: String?
    public let isRunning: Bool
    public let exitCode: Int?
    public let startedAt: String?
    public let finishedAt: String?
    public let command: String?
    public let labels: [String: String]
    /// `HostConfig.Memory`: the size of this container's own micro-VM. nil when the runtime
    /// reports no limit. Host-resident as the guest fills it, not a free ceiling — see
    /// `MemoryCommitment`.
    public let memoryLimitBytes: Int64?

    public var composeProject: String? {
        labels["com.docker.compose.project"]
    }

    public var composeService: String? {
        labels["com.docker.compose.service"]
    }

    public init(
        id: String,
        name: String,
        image: String?,
        created: String?,
        status: String?,
        isRunning: Bool,
        exitCode: Int?,
        startedAt: String?,
        finishedAt: String?,
        command: String?,
        labels: [String: String],
        memoryLimitBytes: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.created = created
        self.status = status
        self.isRunning = isRunning
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.command = command
        self.labels = labels
        self.memoryLimitBytes = memoryLimitBytes
    }
}

/// Docker progress endpoints answer with concatenated JSON objects rather than a JSON array.
public enum DockerJSONStream {
    public static func objects(in data: Data) -> [Data] {
        var objects: [Data] = []
        var depth = 0
        var start: Int?
        var isInString = false
        var isEscaped = false

        for index in data.indices {
            let byte = data[index]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if byte == UInt8(ascii: "\\") {
                    isEscaped = true
                } else if byte == UInt8(ascii: "\"") {
                    isInString = false
                }
                continue
            }

            switch byte {
            case UInt8(ascii: "\""):
                isInString = true
            case UInt8(ascii: "{"):
                if depth == 0 {
                    start = index
                }
                depth += 1
            case UInt8(ascii: "}"):
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let objectStart = start {
                    objects.append(data[objectStart...index])
                    start = nil
                }
            default:
                continue
            }
        }

        return objects
    }
}
