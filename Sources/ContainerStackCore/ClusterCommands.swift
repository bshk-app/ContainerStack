import Darwin
import Foundation

public enum ClusterCommandError: Error, Equatable, Sendable, CustomStringConvertible {
    case kubeconfigAlias
    case kubeconfigNotCreated(path: String, errno: Int32)
    case failed(command: String, status: Int32, message: String)

    public var description: String {
        switch self {
        case .kubeconfigAlias:
            "~/.containerstack/kubeconfig is the same file as ~/.kube/config; remove the link"
        case .kubeconfigNotCreated(let path, let code):
            "cannot create \(path): \(String(cString: strerror(code)))"
        case .failed(let command, let status, let message):
            "container \(command) exited with status \(status)" + (message.isEmpty ? "" : ": \(message)")
        }
    }
}

public struct ClusterCommands: Sendable {
    public struct Launch: Equatable, Sendable {
        public let executablePath: String
        public let arguments: [String]
        public let environment: [String: String]
        public let output: ProcessRunner.OutputMode
        public let timeout: Duration
    }

    public typealias Spawn = @Sendable (Launch) throws -> ProcessRunner.Result

    public enum Kubeconfig: Sendable {
        case managed, userDefault
    }

    public let containerPath: String
    public let home: URL
    private let environment: [String: String]
    private let spawn: Spawn
    let capabilityCache: ClusterCapabilityCache
    private let mutationOutput: ProcessRunner.OutputMode
    private let lock: ClusterOperationLock

    public init(
        containerPath: String, home: URL, environment: [String: String],
        mutationOutput: ProcessRunner.OutputMode = .inherit
    ) {
        self.init(
            containerPath: containerPath, home: home, environment: environment,
            mutationOutput: mutationOutput, spawn: Self.processRunnerSpawn)
    }

    init(
        containerPath: String,
        home: URL,
        environment: [String: String],
        mutationOutput: ProcessRunner.OutputMode = .inherit,
        spawn: @escaping Spawn,
        capabilityCache: ClusterCapabilityCache = .shared,
        lock: ClusterOperationLock = .shared
    ) {
        self.containerPath = containerPath
        self.home = home
        self.environment = environment
        self.mutationOutput = mutationOutput
        self.spawn = spawn
        self.capabilityCache = capabilityCache
        self.lock = lock
    }

    public var managedKubeconfig: URL {
        home.appending(path: ".containerstack/kubeconfig")
    }

    public var userKubeconfig: URL {
        home.appending(path: ".kube/config")
    }

    public func list() async throws -> String {
        try await run(
            ["list", "--format", "json"], timeout: .seconds(20), output: .captureSeparately,
            changesState: false)
    }

    public func create(name: String, options: [String]) async throws {
        try await run(["create", "--name", name] + options, timeout: .seconds(15 * 60))
    }

    public func start(name: String) async throws {
        try await run(["start", "--name", name], timeout: .seconds(10 * 60))
    }

    public func stop(name: String) async throws {
        try await run(["stop", "--name", name], timeout: .seconds(2 * 60))
    }

    public func delete(name: String) async throws {
        try await run(["delete", "--name", name], timeout: .seconds(5 * 60))
    }

    public func writeConfig(name: String, into target: Kubeconfig = .managed) async throws {
        try await run(["write-config", "--name", name], timeout: .seconds(30), kubeconfig: target)
    }

    @discardableResult
    private func run(
        _ arguments: [String],
        timeout: Duration,
        output: ProcessRunner.OutputMode? = nil,
        kubeconfig: Kubeconfig = .managed,
        changesState: Bool = true
    ) async throws -> String {
        let execute = { @Sendable in
            try await launch(
                ["cluster"] + arguments, timeout: timeout, output: output ?? mutationOutput, kubeconfig: kubeconfig)
        }
        let result = try await changesState ? lock.run(execute) : execute()
        guard result.status == 0 else {
            throw ClusterCommandError.failed(
                command: "cluster \(arguments[0])", status: result.status,
                message: result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output
    }

    func launch(
        _ arguments: [String],
        timeout: Duration,
        output: ProcessRunner.OutputMode = .capture(includingStandardError: true),
        kubeconfig: Kubeconfig = .managed
    ) async throws -> ProcessRunner.Result {
        try prepareKubeconfig()
        var environment = environment
        environment["KUBECONFIG"] = (kubeconfig == .managed ? managedKubeconfig : userKubeconfig).path
        let launch = Launch(
            executablePath: containerPath, arguments: arguments, environment: environment, output: output,
            timeout: timeout)
        let spawn = spawn
        return try await Task.detached { try spawn(launch) }.value
    }

    public func prepareKubeconfig() throws {
        if let managed = Self.fileID(managedKubeconfig.path), managed == Self.fileID(userKubeconfig.path) {
            throw ClusterCommandError.kubeconfigAlias
        }
        try FileManager.default.createDirectory(
            at: managedKubeconfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(managedKubeconfig.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST { return }
            throw ClusterCommandError.kubeconfigNotCreated(path: managedKubeconfig.path, errno: errno)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard Self.fileID(managedKubeconfig.path) != Self.fileID(userKubeconfig.path) else {
            unlink(managedKubeconfig.path)
            throw ClusterCommandError.kubeconfigAlias
        }
        try handle.write(contentsOf: Data("apiVersion: v1\nkind: Config\n".utf8))
    }

    private static func fileID(_ path: String) -> [UInt64]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return [UInt64(info.st_dev), info.st_ino]
    }

    private static let processRunnerSpawn: Spawn = { launch in
        try ProcessRunner.run(
            executablePath: launch.executablePath,
            arguments: launch.arguments,
            output: launch.output,
            environment: launch.environment,
            timeout: launch.timeout
        )
    }
}
