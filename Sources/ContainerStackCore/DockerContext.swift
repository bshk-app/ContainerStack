import Darwin
import Foundation

/// Registers ContainerStack as a Docker context so `docker`, Compose and IDEs reach our socket
/// without `--host` or `DOCKER_HOST`. `/var/run/docker.sock` is deliberately left alone: it is
/// shared with Docker Desktop and OrbStack and needs root to change.
public enum DockerContext {
    public static let name = "containerstack"
    public static let description = "ContainerStack"
    public static let fallbackName = "default"

    /// Just the `context update`/`create` half of `installCommands`, without switching to it.
    public static func recordCommand(socketPath: String, exists: Bool) -> [String] {
        [
            "context", exists ? "update" : "create", name,
            "--description", description,
            "--docker", "host=unix://\(socketPath)",
        ]
    }

    public static func installCommands(socketPath: String, exists: Bool) -> [[String]] {
        [recordCommand(socketPath: socketPath, exists: exists), ["context", "use", name]]
    }

    public static func uninstallCommands(
        activeContext: String?,
        previousContext: String?,
        availableContexts: Set<String>,
        removeContextOnUninstall: Bool
    ) -> [[String]] {
        var commands: [[String]] = []
        if activeContext == name {
            if let previousContext, availableContexts.contains(previousContext) {
                commands.append(["context", "use", previousContext])
            } else if availableContexts.contains(fallbackName) {
                commands.append(["context", "use", fallbackName])
            }
        }
        if removeContextOnUninstall, availableContexts.contains(name) {
            commands.append(["context", "rm", name])
        }
        return commands
    }

    public static func conflictingContext(
        activeContext: String?,
        takeoverEnabled: Bool
    ) -> String? {
        guard takeoverEnabled, let activeContext, activeContext != name else { return nil }
        return activeContext
    }

    public static func shouldAdopt(
        activeContext: String?,
        installed: Bool?,
        takeoverEnabled: Bool
    ) -> Bool {
        takeoverEnabled && (installed == false || activeContext == name)
    }

    /// True when our own context is inactive and its recorded endpoint no longer matches the
    /// current socket path -- not a reachability check.
    public static func shouldRepairStaleRecord(
        activeContext: String?,
        installed: Bool?,
        takeoverEnabled: Bool,
        recordedSocketPath: String?,
        currentSocketPath: String
    ) -> Bool {
        takeoverEnabled
            && installed == true
            && activeContext != name
            && recordedSocketPath != nil
            && recordedSocketPath != currentSocketPath
    }

    public static func socketStatus(atPath path: String) -> DockerSocketStatus {
        let fileManager = FileManager.default
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: path) else {
            return DockerSocketStatus(
                target: path,
                isReachable: canConnect(toSocketAtPath: path)
            )
        }
        let target: String
        if destination.hasPrefix("/") {
            target = destination
        } else {
            target =
                URL(fileURLWithPath: path)
                .deletingLastPathComponent()
                .appending(path: destination)
                .standardized.path
        }
        return DockerSocketStatus(
            target: target,
            isReachable: canConnect(toSocketAtPath: target)
        )
    }

    public static func contextNames(in output: String) -> Set<String> {
        Set(parsedContextNames(in: output))
    }

    public static func contextName(from output: String) -> String? {
        let names = parsedContextNames(in: output)
        guard names.count == 1 else { return nil }
        return names[0]
    }

    public static func contextExists(in listing: String) -> Bool {
        contextNames(in: listing).contains(name)
    }

    /// The `unix://` socket path a *specific* context records, from `docker context ls --format
    /// {{.Name}}\t{{.DockerEndpoint}}` output. Not the active context -- the caller names which
    /// one. A WARNING line (printed when the client config itself is unreadable) has no tab and
    /// never matches; a non-`unix://` endpoint (`tcp://`, `npipe://`) returns `nil` rather than a
    /// path that was never a filesystem path to begin with.
    public static func recordedSocketPath(for contextName: String, in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                fields[0].trimmingCharacters(in: .whitespaces) == contextName
            else { continue }
            let endpoint = fields[1].trimmingCharacters(in: .whitespaces)
            guard endpoint.hasPrefix("unix://") else { return nil }
            return String(endpoint.dropFirst("unix://".count))
        }
        return nil
    }

    private static func parsedContextNames(in output: String) -> [String] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.+-"))
        return
            output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { candidate in
                guard let first = candidate.unicodeScalars.first,
                    CharacterSet.alphanumerics.contains(first)
                else {
                    return false
                }
                return candidate.unicodeScalars.allSatisfy(allowed.contains)
            }
    }

    private static func canConnect(toSocketAtPath path: String) -> Bool {
        guard var address = try? makeUnixSocketAddress(path: path) else { return false }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var state = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard Darwin.poll(&state, 1, 100) > 0 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let optionResult = withUnsafeMutablePointer(to: &socketError) { pointer in
            Darwin.getsockopt(descriptor, SOL_SOCKET, SO_ERROR, pointer, &length)
        }
        return optionResult == 0 && socketError == 0
    }
}

public struct DockerSocketStatus: Equatable, Sendable {
    public let target: String
    public let isReachable: Bool

    public init(target: String, isReachable: Bool) {
        self.target = target
        self.isReachable = isReachable
    }
}

public struct DockerContextOwnership: Codable, Equatable, Sendable {
    public let previousContext: String?
    public let removeContextOnUninstall: Bool

    public init(previousContext: String?, removeContextOnUninstall: Bool) {
        self.previousContext = previousContext
        self.removeContextOnUninstall = removeContextOnUninstall
    }
}

public struct DockerContextOwnershipStore: Sendable {
    public static var defaultURL: URL {
        defaultURL(for: ProcessInfo.processInfo.environment)
    }

    static func defaultURL(for environment: [String: String]) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standardConfig = home.appending(path: ".docker").standardizedFileURL
        let legacyURL =
            home
            .appending(path: "Library/Application Support/ContainerStack/docker-context-ownership.json")
        guard
            let configuredPath = environment["DOCKER_CONFIG"],
            !configuredPath.isEmpty
        else { return legacyURL }

        let configuredURL = URL(fileURLWithPath: configuredPath).standardizedFileURL
        guard configuredURL != standardConfig else { return legacyURL }

        var scopedURL = home.appending(
            path: "Library/Application Support/ContainerStack/docker-context-ownership"
        )
        for component in configuredURL.pathComponents where component != "/" {
            scopedURL.append(path: component)
        }
        return scopedURL.appending(path: "ownership.json")
    }

    private let fileURL: URL

    public init(fileURL: URL = DockerContextOwnershipStore.defaultURL) {
        self.fileURL = fileURL
    }

    public func ownership() throws -> DockerContextOwnership? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(
                DockerContextOwnership.self,
                from: Data(contentsOf: fileURL)
            )
        } catch is DecodingError {
            return nil
        }
    }

    public func remember(_ ownership: DockerContextOwnership) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(ownership).write(to: fileURL, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
