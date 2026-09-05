import Foundation

public enum DockerCLIError: Error, Equatable, Sendable, CustomStringConvertible {
    case notInstalled
    case failed(command: String, status: Int32, output: String)
    case invalidOutput(command: String, output: String)

    public var description: String {
        switch self {
        case .notInstalled:
            "docker CLI not found in \(DockerCLI.searchPaths.joined(separator: ", "))"
        case .failed(let command, let status, let output):
            "docker \(command) exited with status \(status): \(output)"
        case .invalidOutput(let command, let output):
            "docker \(command) returned unexpected output: \(output)"
        }
    }
}

/// Thin wrapper around the local `docker` binary for the few things the Docker API cannot do,
/// such as editing the client's context list.
public enum DockerCLI {
    public static let searchPaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/usr/bin/docker",
    ]

    public static func executablePath(
        exists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String? {
        searchPaths.first(where: exists)
    }

    @discardableResult
    public static func run(_ arguments: [String]) throws -> String {
        try run(
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    private static func run(
        arguments: [String],
        environment: [String: String]?
    ) throws -> String {
        guard let executablePath = executablePath() else {
            throw DockerCLIError.notInstalled
        }

        // Context reads and edits are local file operations behind the CLI, so the diagnostic
        // deadline is generous. It exists so a docker binary wedged on its own daemon socket
        // cannot pin the caller — `refreshDockerContext` runs from the 3s monitor loop.
        let result = try ProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            output: .capture(includingStandardError: true),
            environment: environment,
            timeout: ProcessRunner.diagnosticTimeout
        )

        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else {
            throw DockerCLIError.failed(
                command: arguments.joined(separator: " "),
                status: result.status,
                output: text
            )
        }
        return text
    }

    /// Points the Docker client at the ContainerStack socket and makes it the configured context.
    public static func installContext(
        socketPath: String,
        ownershipStore: DockerContextOwnershipStore = DockerContextOwnershipStore()
    ) throws {
        try installContext(
            socketPath: socketPath,
            ownershipStore: ownershipStore,
            runContextCommand
        )
    }

    static func installContext(
        socketPath: String,
        ownershipStore: DockerContextOwnershipStore,
        _ commandRunner: ([String]) throws -> String
    ) throws {
        let current = try configuredContext(using: commandRunner)
        let contexts = try installedContexts(using: commandRunner)
        let contextExists = contexts.contains(DockerContext.name)
        let existingOwnership = try ownershipStore.ownership()
        let ownership = DockerContextOwnership(
            previousContext: current == DockerContext.name ? existingOwnership?.previousContext : current,
            removeContextOnUninstall: (existingOwnership?.removeContextOnUninstall ?? false)
                || !contextExists
        )
        let commands = DockerContext.installCommands(
            socketPath: socketPath,
            exists: contextExists
        )
        _ = try commandRunner(commands[0])
        do {
            try ownershipStore.remember(ownership)
        } catch {
            if !contextExists {
                _ = try? commandRunner(["context", "rm", DockerContext.name])
            }
            throw error
        }
        for command in commands.dropFirst() {
            _ = try commandRunner(command)
        }
    }

    @discardableResult
    public static func uninstallContext(
        ownershipStore: DockerContextOwnershipStore = DockerContextOwnershipStore()
    ) throws -> Bool {
        try uninstallContext(ownershipStore: ownershipStore, runContextCommand)
    }

    static func uninstallContext(
        ownershipStore: DockerContextOwnershipStore,
        _ commandRunner: ([String]) throws -> String
    ) throws -> Bool {
        let ownership = try ownershipStore.ownership()
        let current = try configuredContext(using: commandRunner)
        let contexts = try installedContexts(using: commandRunner)
        let commands = DockerContext.uninstallCommands(
            activeContext: current,
            previousContext: ownership?.previousContext,
            availableContexts: contexts,
            removeContextOnUninstall: ownership?.removeContextOnUninstall ?? false
        )
        for command in commands {
            _ = try commandRunner(command)
        }
        if ownership != nil {
            try ownershipStore.clear()
        }
        return commands.contains(["context", "rm", DockerContext.name])
    }

    public static func installedContexts() throws -> Set<String> {
        try installedContexts(using: runContextCommand)
    }

    /// The socket a *specific* context records, regardless of whether it is active. Distinct from
    /// `activeContext()`, which only ever names the active one.
    public static func recordedSocketPath(for contextName: String) throws -> String? {
        try recordedSocketPath(for: contextName, using: runContextCommand)
    }

    static func recordedSocketPath(
        for contextName: String,
        using commandRunner: ([String]) throws -> String
    ) throws -> String? {
        DockerContext.recordedSocketPath(
            for: contextName,
            in: try commandRunner(["context", "ls", "--format", "{{.Name}}\t{{.DockerEndpoint}}"])
        )
    }

    /// Rewrites the context's record without switching to it -- never appends `context use`.
    public static func repairRecord(socketPath: String) throws {
        try repairRecord(socketPath: socketPath, runContextCommand)
    }

    static func repairRecord(socketPath: String, _ commandRunner: ([String]) throws -> String) throws {
        _ = try commandRunner(DockerContext.recordCommand(socketPath: socketPath, exists: true))
    }

    public static func activeContext() -> String? {
        activeContext(environment: ProcessInfo.processInfo.environment) { arguments, environment in
            try run(arguments: arguments, environment: environment)
        }
    }

    static func activeContext(
        environment: [String: String],
        _ commandRunner: ([String], [String: String]) throws -> String
    ) -> String? {
        try? configuredContext { try commandRunner($0, environment) }
    }

    public static func contextEnvironmentOverride(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if !(environment["DOCKER_HOST"] ?? "").isEmpty {
            return "DOCKER_HOST"
        }
        if !(environment["DOCKER_CONTEXT"] ?? "").isEmpty {
            return "DOCKER_CONTEXT"
        }
        return nil
    }

    public static func contextEnvironmentConflict(
        activeContext: String?,
        isContextInstalled: Bool?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard activeContext == DockerContext.name, isContextInstalled == true else {
            return contextEnvironmentOverride(from: environment)
        }
        return nil
    }

    static func contextCommandEnvironment(from environment: [String: String]) -> [String: String] {
        var environment = environment
        environment.removeValue(forKey: "DOCKER_CONTEXT")
        environment.removeValue(forKey: "DOCKER_HOST")
        return environment
    }

    private static func runContextCommand(_ arguments: [String]) throws -> String {
        try run(
            arguments: arguments,
            environment: contextCommandEnvironment(from: ProcessInfo.processInfo.environment)
        )
    }

    private static func configuredContext(
        using commandRunner: ([String]) throws -> String
    ) throws -> String {
        let output = try commandRunner(["context", "show"])
        guard let context = DockerContext.contextName(from: output) else {
            throw DockerCLIError.invalidOutput(command: "context show", output: output)
        }
        return context
    }

    private static func installedContexts(
        using commandRunner: ([String]) throws -> String
    ) throws -> Set<String> {
        DockerContext.contextNames(
            in: try commandRunner(["context", "ls", "--format", "{{.Name}}"])
        )
    }
}
