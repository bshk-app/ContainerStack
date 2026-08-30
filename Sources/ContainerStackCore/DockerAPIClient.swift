import Darwin
import Foundation

func makeUnixSocketAddress(path: String) throws -> sockaddr_un {
    let pathBytes = Array(path.utf8)
    var address = sockaddr_un()
    guard pathBytes.count + 1 <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw UnixSocketError.pathTooLong
    }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { storage in
        storage.initializeMemory(as: UInt8.self, repeating: 0)
        pathBytes.withUnsafeBytes { storage.copyBytes(from: $0) }
    }
    return address
}

public protocol DockerAPITransport: Sendable {
    func send(request: Data) async throws -> Data
    func send(request: Data, timeout: Duration?) async throws -> Data
}

extension DockerAPITransport {
    public func send(request: Data, timeout: Duration?) async throws -> Data {
        try await send(request: request)
    }
}

public struct DockerVersion: Codable, Equatable, Sendable {
    public let version: String?
    public let apiVersion: String?
    public let minAPIVersion: String?
    public let gitCommit: String?
    public let operatingSystem: String?
    public let architecture: String?

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case apiVersion = "ApiVersion"
        case minAPIVersion = "MinAPIVersion"
        case gitCommit = "GitCommit"
        case operatingSystem = "Os"
        case architecture = "Arch"
    }
}

public struct DockerInfo: Codable, Equatable, Sendable {
    public let serverVersion: String?
    public let operatingSystem: String?
    public let architecture: String?
    public let containers: Int?
    public let images: Int?

    enum CodingKeys: String, CodingKey {
        case serverVersion = "ServerVersion"
        case operatingSystem = "OperatingSystem"
        case architecture = "Architecture"
        case containers = "Containers"
        case images = "Images"
    }
}

public struct DockerImageSummary: Codable, Equatable, Sendable {
    public let id: String
    public let repositoryTags: [String]?
    public let size: Int64?
    public let created: Int64?
    public let architecture: String?
    public let operatingSystem: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case repositoryTags = "RepoTags"
        case size = "Size"
        case created = "Created"
        case architecture = "Architecture"
        case operatingSystem = "Os"
    }
}

public struct DockerRunResult: Equatable, Sendable {
    public let containerID: String
    public let exitCode: Int
    public let output: String

    public init(containerID: String, exitCode: Int, output: String) {
        self.containerID = containerID
        self.exitCode = exitCode
        self.output = output
    }
}

public struct ContainerResourceLimits: Equatable, Sendable {
    static let nanoCPUsPerCPU: Int64 = 1_000_000_000

    public let cpus: Int
    public let memoryInBytes: Int64

    var nanoCPUs: Int64 { Int64(cpus) * Self.nanoCPUsPerCPU }

    public init(cpus: Int, memoryInBytes: Int64) {
        precondition(cpus > 0, "cpus must be positive")
        precondition(Int64(cpus) <= Int64.max / Self.nanoCPUsPerCPU, "cpus exceeds the nano-CPU range")
        precondition(memoryInBytes > 0, "memoryInBytes must be positive")
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
    }
}

private struct ContainerCreateResponse: Decodable {
    let id: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

private struct ContainerWaitResponse: Decodable {
    let statusCode: Int

    enum CodingKeys: String, CodingKey {
        case statusCode = "StatusCode"
    }
}

private struct ContainerCreateHostConfig: Encodable {
    let memory: Int64
    let nanoCpus: Int64

    init(resourceLimits: ContainerResourceLimits) {
        memory = resourceLimits.memoryInBytes
        nanoCpus = resourceLimits.nanoCPUs
    }

    enum CodingKeys: String, CodingKey {
        case memory = "Memory"
        case nanoCpus = "NanoCpus"
    }
}

private struct ContainerCreateRequest: Encodable {
    let image: String
    let command: [String]?
    let hostConfig: ContainerCreateHostConfig?
    let attachStdout = true
    let attachStderr = true
    let tty = false

    enum CodingKeys: String, CodingKey {
        case image = "Image"
        case command = "Cmd"
        case attachStdout = "AttachStdout"
        case attachStderr = "AttachStderr"
        case tty = "Tty"
        case hostConfig = "HostConfig"
    }
}

public struct DockerPort: Codable, Equatable, Sendable {
    public let ip: String?
    public let privatePort: Int?
    public let publicPort: Int?
    public let type: String?

    public var summary: String {
        let port = privatePort.map(String.init) ?? "?"
        let networkType = type.map { "/\($0)" } ?? ""
        guard let publicPort else {
            return "\(port)\(networkType)"
        }
        let host = ip.map { "\($0):" } ?? ""
        return "\(host)\(publicPort)->\(port)\(networkType)"
    }

    enum CodingKeys: String, CodingKey {
        case ip = "IP"
        case privatePort = "PrivatePort"
        case publicPort = "PublicPort"
        case type = "Type"
    }
}
public struct DockerNetworkEndpoint: Codable, Equatable, Sendable {}

/// Only which networks a container belongs to matters here; endpoint addressing is not used.
public struct DockerNetworkSettings: Codable, Equatable, Sendable {
    public let networks: [String: DockerNetworkEndpoint]?

    enum CodingKeys: String, CodingKey {
        case networks = "Networks"
    }
}

public struct DockerContainerSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let names: [String]?
    public let image: String?
    public let imageID: String?
    public let command: String?
    public let created: Int64?
    public let state: String?
    public let status: String?
    public let labels: [String: String]?
    public let ports: [DockerPort]?
    public let networkSettings: DockerNetworkSettings?

    public var name: String {
        names?.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? id
    }

    public var isRunning: Bool {
        state?.lowercased() == "running"
    }

    public var composeProject: String? {
        labels?["com.docker.compose.project"]
    }

    public var composeService: String? {
        labels?["com.docker.compose.service"]
    }

    public var portSummary: String? {
        guard let ports, !ports.isEmpty else { return nil }
        return ports.map(\.summary).joined(separator: ", ")
    }

    /// Network names from the container list, so route checks can tell an in-use network from an idle one.
    public var networkNames: [String] {
        networkSettings?.networks?.keys.sorted() ?? []
    }

    /// Ports mapped to the host are the ones a missing route would actually break.
    public var publishesPorts: Bool {
        ports?.contains { ($0.publicPort ?? 0) != 0 } ?? false
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case image = "Image"
        case imageID = "ImageID"
        case command = "Command"
        case created = "Created"
        case state = "State"
        case status = "Status"
        case labels = "Labels"
        case ports = "Ports"
        case networkSettings = "NetworkSettings"
    }
}

public struct RuntimeHealthSnapshot: Equatable, Sendable {
    public let pingOK: Bool
    public let version: DockerVersion
    public let info: DockerInfo

    public init(pingOK: Bool, version: DockerVersion, info: DockerInfo) {
        self.pingOK = pingOK
        self.version = version
        self.info = info
    }
}

public enum DockerAPIError: Error, Equatable, Sendable {
    /// The daemon's own words travel with the status. socktainer's error bodies name the object and,
    /// for a network whose helper died, the one step that clears it — a bare status code throws all of
    /// that away and leaves the caller to invent an explanation.
    case httpStatus(Int, message: String?)
    case invalidResponseBody
    case invalidRequestBody
    case invalidPingBody
    case remoteFailure(String)
}

extension DockerAPIError: LocalizedError, CustomStringConvertible {
    public var description: String {
        switch self {
        case .httpStatus(let code, let message):
            if let message, !message.isEmpty { return message }
            return "Docker API returned status \(code)."
        case .invalidResponseBody: return "The Docker API sent a response that could not be read."
        case .invalidRequestBody: return "The request could not be encoded."
        case .invalidPingBody: return "The Docker API answered a ping with something unexpected."
        case .remoteFailure(let reason): return reason
        }
    }

    public var errorDescription: String? { description }
}

public actor DockerAPIClient {
    private let transport: any DockerAPITransport
    private let retryPolicy: DockerRetryPolicy
    static let streamingRequestTimeout: Duration? = nil
    /// Starting, restarting and removing a container boot or tear down a virtual machine.
    /// They routinely exceed the five-second timeout used for plain API calls.
    static let lifecycleRequestTimeout: Duration? = .seconds(120)
    /// Pin the daemon's graceful stop window to five seconds, but leave enough client-side time
    /// for Socktainer's VM-lifecycle admission queue and teardown. When Apple Container loses its
    /// XPC service, the caller checks `container system status` before deciding to restart.
    static let gracefulStopRequestTimeout: Duration? = .seconds(30)
    public init(socketPath: String, retryPolicy: DockerRetryPolicy = DockerRetryPolicy()) {
        self.transport = UnixSocketTransport(path: socketPath)
        self.retryPolicy = retryPolicy
    }

    public init(transport: any DockerAPITransport, retryPolicy: DockerRetryPolicy = DockerRetryPolicy()) {
        self.transport = transport
        self.retryPolicy = retryPolicy
    }

    public func health() async throws -> RuntimeHealthSnapshot {
        let pingResponse = try await requestWithRetry(path: "/_ping")
        guard
            String(decoding: pingResponse.body, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
        else {
            throw DockerAPIError.invalidPingBody
        }

        let version = try await decode(DockerVersion.self, response: requestWithRetry(path: "/version"))
        let info = try await decode(DockerInfo.self, response: requestWithRetry(path: "/info"))
        return RuntimeHealthSnapshot(pingOK: true, version: version, info: info)
    }

    public func listImages() async throws -> [DockerImageSummary] {
        try await decode([DockerImageSummary].self, response: requestWithRetry(path: "/images/json"))
    }

    public func listContainers(all: Bool = true) async throws -> [DockerContainerSummary] {
        let path = all ? "/containers/json?all=1" : "/containers/json"
        return try await decode(
            [DockerContainerSummary].self,
            response: requestWithRetry(path: path)
        )
    }

    public func startContainer(id: String) async throws {
        _ = try await request(method: "POST", path: "/containers/\(id)/start", timeout: Self.lifecycleRequestTimeout)
    }

    public func stopContainer(id: String) async throws {
        do {
            _ = try await request(
                method: "POST",
                path: "/containers/\(id)/stop?t=5",
                timeout: Self.gracefulStopRequestTimeout
            )
        } catch DockerAPIError.httpStatus(let status, _) where status == 304 || status == 404 {
            return
        }
    }

    public func removeContainer(id: String, force: Bool = false) async throws {
        _ = try await request(
            method: "DELETE",
            path: "/containers/\(id)?force=\(force ? 1 : 0)",
            timeout: Self.lifecycleRequestTimeout
        )
    }

    public func run(
        image: String,
        command: [String],
        resourceLimits: ContainerResourceLimits?
    ) async throws -> DockerRunResult {
        let createRequest = ContainerCreateRequest(
            image: image,
            command: command.isEmpty ? nil : command,
            hostConfig: resourceLimits.map(ContainerCreateHostConfig.init)
        )
        let createBody: Data
        do {
            createBody = try JSONEncoder().encode(createRequest)
        } catch {
            throw DockerAPIError.invalidRequestBody
        }

        let createResponse = try await decode(
            ContainerCreateResponse.self,
            response: try await request(method: "POST", path: "/containers/create", body: createBody)
        )

        var isRunning = false
        do {
            _ = try await request(
                method: "POST",
                path: "/containers/\(createResponse.id)/start",
                timeout: Self.lifecycleRequestTimeout
            )
            isRunning = true
            let waitResponse = try await request(
                method: "POST",
                path: "/containers/\(createResponse.id)/wait",
                timeout: Self.streamingRequestTimeout
            )
            isRunning = false
            let waitResult = try await decode(
                ContainerWaitResponse.self,
                response: waitResponse
            )
            let logs = try await request(
                method: "GET",
                path: "/containers/\(createResponse.id)/logs?stdout=1&stderr=1",
                timeout: Self.streamingRequestTimeout
            )
            let output = Self.decodeLogs(logs.body)
            _ = try await request(
                method: "DELETE",
                path: "/containers/\(createResponse.id)?force=1",
                timeout: Self.lifecycleRequestTimeout
            )
            return DockerRunResult(
                containerID: createResponse.id,
                exitCode: waitResult.statusCode,
                output: output
            )
        } catch {
            if !isRunning {
                _ = try? await request(
                    method: "DELETE",
                    path: "/containers/\(createResponse.id)?force=1",
                    timeout: Self.lifecycleRequestTimeout
                )
            }
            throw error
        }
    }

    func decode<Value: Decodable & Sendable>(
        _ type: Value.Type,
        response: DockerHTTPResponse
    ) async throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            throw DockerAPIError.invalidResponseBody
        }
    }

    func request(path: String) async throws -> DockerHTTPResponse {
        try await request(method: "GET", path: path)
    }

    private func requestWithRetry(path: String) async throws -> DockerHTTPResponse {
        try await requestRetrying(path: path, while: Self.isRetryable)
    }

    /// The retry budget for a caller on a clock: see `failsImmediately`.
    func requestRetryingImmediateFailures(path: String) async throws -> DockerHTTPResponse {
        try await requestRetrying(path: path, while: Self.failsImmediately)
    }

    private func requestRetrying(
        path: String,
        while shouldRetry: (Error) -> Bool
    ) async throws -> DockerHTTPResponse {
        var attempts = 0
        while true {
            do {
                return try await request(path: path)
            } catch {
                attempts += 1
                guard attempts < retryPolicy.maxAttempts, shouldRetry(error) else {
                    throw error
                }
                try await Task.sleep(for: retryPolicy.delay)
            }
        }
    }

    func request(
        method: String,
        path: String,
        body: Data? = nil,
        timeout: Duration? = .seconds(5)
    ) async throws -> DockerHTTPResponse {
        var headers = [
            "\(method) \(path) HTTP/1.1",
            "Host: localhost",
            "Connection: close",
            "Accept: application/json",
        ]
        if let body {
            headers.append("Content-Type: application/json")
            headers.append("Content-Length: \(body.count)")
        }
        let requestData = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + (body ?? Data())
        let rawResponse = try await transport.send(request: requestData, timeout: timeout)
        let response = try DockerHTTPResponseParser.parse(rawResponse)
        guard (200..<300).contains(response.statusCode) else {
            throw DockerAPIError.httpStatus(response.statusCode, message: Self.failureMessage(in: response.body))
        }
        return response
    }

    /// Docker error bodies are `{"message": "..."}` and socktainer matches that shape (#18). A few of
    /// its routes still answer with bare text, so fall back to the body itself rather than dropping a
    /// sentence that was written for the person reading it.
    static func failureMessage(in body: Data) -> String? {
        struct Failure: Decodable { let message: String? }
        if let decoded = try? JSONDecoder().decode(Failure.self, from: body),
            let message = decoded.message?.trimmingCharacters(in: .whitespacesAndNewlines),
            !message.isEmpty
        {
            return message
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.count > 500 ? nil : text
    }

    static func decodeLogs(_ body: Data) -> String {
        guard body.count >= 8 else {
            return String(decoding: body, as: UTF8.self)
        }

        var offset = 0
        var output = Data()
        while offset + 8 <= body.count {
            let length =
                (UInt32(body[offset + 4]) << 24)
                | (UInt32(body[offset + 5]) << 16)
                | (UInt32(body[offset + 6]) << 8)
                | UInt32(body[offset + 7])
            let payloadLength = Int(length)
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + payloadLength
            guard payloadEnd <= body.count else {
                return String(decoding: body, as: UTF8.self)
            }
            output.append(body[payloadStart..<payloadEnd])
            offset = payloadEnd
        }

        guard offset == body.count else {
            return String(decoding: body, as: UTF8.self)
        }
        return String(decoding: output, as: UTF8.self)
    }
}

public struct UnixSocketTransport: DockerAPITransport, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func send(request: Data) async throws -> Data {
        try await send(request: request, timeout: .seconds(5))
    }

    public func send(request: Data, timeout: Duration?) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try Self.sendBlocking(request: request, path: path, timeout: timeout)
        }.value
    }

    private static func sendBlocking(
        request: Data,
        path: String,
        timeout: Duration?
    ) throws -> Data {

        var address = try makeUnixSocketAddress(path: path)

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw socketFailure()
        }
        defer { Darwin.close(descriptor) }

        let originalFlags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard originalFlags >= 0, Darwin.fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw socketFailure()
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else {
                throw socketFailure()
            }

            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard Darwin.poll(&descriptorState, 1, 5_000) > 0 else {
                throw UnixSocketError.timedOut
            }

            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            let errorResult = withUnsafeMutablePointer(to: &socketError) { pointer in
                Darwin.getsockopt(descriptor, SOL_SOCKET, SO_ERROR, pointer, &socketErrorLength)
            }
            guard errorResult == 0, socketError == 0 else {
                throw socketError == 0 ? socketFailure() : UnixSocketError.systemCallFailed(socketError)
            }
        }

        guard Darwin.fcntl(descriptor, F_SETFL, originalFlags) == 0 else {
            throw socketFailure()
        }
        try configureTimeouts(for: descriptor, timeout: timeout)

        var offset = 0
        while offset < request.count {
            let written = request.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), request.count - offset)
            }
            guard written > 0 else {
                throw socketFailure()
            }
            offset += written
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 {
                break
            }
            guard count > 0 else {
                throw socketFailure()
            }
            response.append(buffer, count: count)
        }
        return response
    }

    private static func configureTimeouts(for descriptor: Int32, timeout: Duration?) throws {
        guard let timeout else {
            return
        }

        let components = timeout.components
        let microseconds = components.attoseconds / 1_000_000_000_000
        var socketTimeout = timeval(
            tv_sec: Int(components.seconds),
            tv_usec: Int32(microseconds)
        )
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            let result = withUnsafePointer(to: &socketTimeout) { pointer in
                Darwin.setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    option,
                    pointer,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }
            guard result == 0 else {
                throw socketFailure()
            }
        }
    }

    private static func socketFailure() -> UnixSocketError {
        let code = Int32(errno)
        if code == EAGAIN || code == EWOULDBLOCK {
            return .timedOut
        }
        return .systemCallFailed(code)
    }
}

public enum UnixSocketError: Error, Equatable, Sendable {
    case pathTooLong
    case timedOut
    case systemCallFailed(Int32)
}
