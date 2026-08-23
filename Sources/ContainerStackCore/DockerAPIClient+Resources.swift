import Foundation

private struct VolumeListPayload: Decodable {
    let volumes: [DockerVolumeSummary]?

    enum CodingKeys: String, CodingKey {
        case volumes = "Volumes"
    }
}

private struct VolumeCreateRequest: Encodable {
    let name: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
    }
}

private struct NetworkCreateRequest: Encodable {
    let name: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
    }
}

private struct NetworkCreateResponse: Decodable {
    let id: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

private struct ImageDeleteRecord: Decodable {
    let deleted: String?
    let untagged: String?

    enum CodingKeys: String, CodingKey {
        case deleted = "Deleted"
        case untagged = "Untagged"
    }
}

private struct PrunePayload: Decodable {
    let spaceReclaimed: Int64?
    let containersDeleted: [String]?
    let volumesDeleted: [String]?
    let imagesDeleted: [ImageDeleteRecord]?

    enum CodingKeys: String, CodingKey {
        case spaceReclaimed = "SpaceReclaimed"
        case containersDeleted = "ContainersDeleted"
        case volumesDeleted = "VolumesDeleted"
        case imagesDeleted = "ImagesDeleted"
    }

    var result: DockerPruneResult {
        let deleted = containersDeleted
            ?? volumesDeleted
            ?? imagesDeleted?.compactMap { $0.deleted ?? $0.untagged }
            ?? []
        return DockerPruneResult(spaceReclaimed: spaceReclaimed ?? 0, deleted: deleted)
    }
}

private struct ContainerStatePayload: Decodable {
    let status: String?
    let running: Bool?
    let exitCode: Int?
    let startedAt: String?
    let finishedAt: String?

    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case running = "Running"
        case exitCode = "ExitCode"
        case startedAt = "StartedAt"
        case finishedAt = "FinishedAt"
    }
}

private struct ContainerConfigPayload: Decodable {
    let image: String?
    let command: [String]?
    let entrypoint: [String]?
    let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case image = "Image"
        case command = "Cmd"
        case entrypoint = "Entrypoint"
        case labels = "Labels"
    }
}

/// Only the fields this app reads. `HostConfig` was already arriving on every inspect and
/// being discarded; the micro-VM size is the part worth keeping.
private struct ContainerHostConfigPayload: Decodable {
    let memory: Int64?

    enum CodingKeys: String, CodingKey {
        case memory = "Memory"
    }
}

private struct ContainerDetailPayload: Decodable {
    let id: String
    let name: String?
    let created: String?
    let image: String?
    let state: ContainerStatePayload?
    let config: ContainerConfigPayload?
    let hostConfig: ContainerHostConfigPayload?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case created = "Created"
        case image = "Image"
        case state = "State"
        case config = "Config"
        case hostConfig = "HostConfig"
    }

    var detail: DockerContainerDetail {
        let arguments = (config?.entrypoint ?? []) + (config?.command ?? [])
        return DockerContainerDetail(
            id: id,
            name: name?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? id,
            image: image ?? config?.image,
            created: created,
            status: state?.status,
            isRunning: state?.running ?? false,
            exitCode: state?.exitCode,
            startedAt: state?.startedAt,
            finishedAt: state?.finishedAt,
            command: arguments.isEmpty ? nil : arguments.joined(separator: " "),
            labels: config?.labels ?? [:],
            // Docker writes 0 for "no limit", which is not the same as a 0-byte VM.
            memoryLimitBytes: (hostConfig?.memory).flatMap { $0 > 0 ? $0 : nil }
        )
    }
}

private struct PullEventPayload: Decodable {
    let id: String?
    let status: String?
    let progress: String?
    let error: String?

    var event: DockerPullEvent {
        DockerPullEvent(id: id, status: status, progress: progress, error: error)
    }
}

public struct DockerImageReference: Equatable, Sendable {
    public let name: String
    public let tag: String

    public init(_ reference: String) {
        if let digestSeparator = reference.range(of: "@", options: .backwards) {
            name = String(reference[reference.startIndex..<digestSeparator.lowerBound])
            tag = String(reference[digestSeparator.upperBound...])
            return
        }

        let lastSlash = reference.range(of: "/", options: .backwards)?.upperBound ?? reference.startIndex
        if let tagSeparator = reference.range(of: ":", options: .backwards, range: lastSlash..<reference.endIndex) {
            name = String(reference[reference.startIndex..<tagSeparator.lowerBound])
            tag = String(reference[tagSeparator.upperBound...])
        } else {
            name = reference
            tag = "latest"
        }
    }
}

public extension DockerAPIClient {
    /// Cheap liveness probe for status polling: one request, no version or info lookups.
    func ping() async throws -> Bool {
        let response = try await request(path: "/_ping")
        return String(decoding: response.body, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
    }

    func listVolumes() async throws -> [DockerVolumeSummary] {
        let payload = try await decode(VolumeListPayload.self, response: request(path: "/volumes"))
        return payload.volumes ?? []
    }

    func createVolume(name: String) async throws -> DockerVolumeSummary {
        let body = try Self.encode(VolumeCreateRequest(name: name))
        let response = try await request(method: "POST", path: "/volumes/create", body: body)
        return try await decode(DockerVolumeSummary.self, response: response)
    }

    func removeVolume(name: String, force: Bool = false) async throws {
        let segment = Self.pathEncoded(name)
        let path = force ? "/volumes/\(segment)?force=1" : "/volumes/\(segment)"
        _ = try await request(method: "DELETE", path: path)
    }

    func pruneVolumes() async throws -> DockerPruneResult {
        try await prune(path: "/volumes/prune")
    }

    func listNetworks() async throws -> [DockerNetworkSummary] {
        try await decode([DockerNetworkSummary].self, response: request(path: "/networks"))
    }

    func createNetwork(name: String) async throws -> String {
        let body = try Self.encode(NetworkCreateRequest(name: name))
        let response = try await request(method: "POST", path: "/networks/create", body: body)
        return try await decode(NetworkCreateResponse.self, response: response).id
    }

    /// Removing a network tears down its vmnet helper, so it belongs with the other lifecycle calls
    /// rather than on the 5s read default. It also has to outlast the bridge's own 60s bound on a
    /// wedged removal: on the short default the socket gave up first and the explanation the bridge
    /// had prepared — restart the runtime — never arrived.
    func removeNetwork(id: String) async throws {
        _ = try await request(
            method: "DELETE",
            path: "/networks/\(Self.pathEncoded(id))",
            timeout: DockerAPIClient.lifecycleRequestTimeout
        )
    }

    func diskUsage() async throws -> DockerDiskUsage {
        try await decode(DockerDiskUsage.self, response: request(path: "/system/df"))
    }

    func pruneContainers() async throws -> DockerPruneResult {
        try await prune(path: "/containers/prune")
    }

    func pruneImages() async throws -> DockerPruneResult {
        try await prune(path: "/images/prune")
    }

    func restartContainer(id: String) async throws {
        _ = try await request(
            method: "POST", path: "/containers/\(id)/restart", timeout: DockerAPIClient.lifecycleRequestTimeout)
    }

    func inspectContainer(id: String) async throws -> DockerContainerDetail {
        let response = try await request(path: "/containers/\(id)/json")
        return try await decode(ContainerDetailPayload.self, response: response).detail
    }

    func containerLogs(id: String, tail: Int? = nil) async throws -> String {
        var path = "/containers/\(id)/logs?stdout=1&stderr=1"
        if let tail {
            path += "&tail=\(tail)"
        }
        let response = try await request(
            method: "GET",
            path: path,
            timeout: Self.streamingRequestTimeout
        )
        return Self.decodeLogs(response.body)
    }

    @discardableResult
    func pullImage(reference: String) async throws -> [DockerPullEvent] {
        let image = DockerImageReference(reference)
        let path = "/images/create?fromImage=\(Self.queryEncoded(image.name))&tag=\(Self.queryEncoded(image.tag))"
        let response = try await request(
            method: "POST",
            path: path,
            timeout: Self.streamingRequestTimeout
        )

        let decoder = JSONDecoder()
        let events = DockerJSONStream.objects(in: response.body).compactMap { object in
            try? decoder.decode(PullEventPayload.self, from: object).event
        }

        if let failure = events.compactMap(\.error).first {
            throw DockerAPIError.remoteFailure(failure)
        }
        return events
    }

    func removeImage(reference: String, force: Bool = false) async throws {
        _ = try await request(
            method: "DELETE",
            path: "/images/\(Self.pathEncoded(reference))?force=\(force ? 1 : 0)"
        )
    }

    private func prune(path: String) async throws -> DockerPruneResult {
        let response = try await request(method: "POST", path: path)
        return try await decode(PrunePayload.self, response: response).result
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw DockerAPIError.invalidRequestBody
        }
    }

    /// Names reach the request line verbatim, so every reserved character has to be escaped.
    private static func queryEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .dockerPathSegment) ?? value
    }

    private static func pathEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .dockerPathSegment) ?? value
    }
}

private extension CharacterSet {
    static let dockerPathSegment = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
}
