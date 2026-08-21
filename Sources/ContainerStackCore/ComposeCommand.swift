import Foundation

/// Compose is a client of the Docker API, so it works against ContainerStack unchanged as long as
/// `DOCKER_HOST` points at our socket. This builds that invocation instead of reimplementing Compose.
public enum ComposeCommand {
    public struct Plan: Equatable, Sendable {
        public let executablePath: String?
        public let arguments: [String]
        public let environment: [String: String]
    }

    public static let searchPaths = DockerCLI.searchPaths

    public static func plan(
        socketPath: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableExists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> Plan {
        var resolvedEnvironment = environment
        resolvedEnvironment["DOCKER_HOST"] = "unix://\(socketPath)"

        return Plan(
            executablePath: searchPaths.first(where: executableExists),
            arguments: ["compose"] + (arguments.isEmpty ? ["--help"] : arguments),
            environment: resolvedEnvironment
        )
    }
}
