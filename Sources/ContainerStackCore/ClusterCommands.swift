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
        let deadline: ProcessRunner.Deadline?
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
    private let lock: ClusterOperationLock

    public init(containerPath: String, home: URL, environment: [String: String]) {
        self.init(containerPath: containerPath, home: home, environment: environment, spawn: Self.processRunnerSpawn)
    }

    init(
        containerPath: String,
        home: URL,
        environment: [String: String],
        spawn: @escaping Spawn,
        capabilityCache: ClusterCapabilityCache = .shared,
        lock: ClusterOperationLock = .shared
    ) {
        self.containerPath = containerPath
        self.home = home
        self.environment = environment
        self.spawn = spawn
        self.capabilityCache = capabilityCache
        self.lock = lock
    }

    public var managedKubeconfig: URL {
        home.appending(path: ".containerstack/kubeconfig")
    }

    var userKubeconfig: URL {
        home.appending(path: ".kube/config")
    }

    public func list() async throws -> String {
        try await list(budget: nil)
    }

    func list(budget: ClusterCommandBudget?) async throws -> String {
        try await run(
            ["list", "--format", "json"], timeout: .seconds(20), output: .captureSeparately,
            changesState: false, budget: budget)
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

    func stop(name: String, budget: ClusterCommandBudget) async throws {
        let timeout = budget.timeoutError(containerPath)
        let result = try await lock.run(before: budget.latestStart, timeout: timeout) {
            try await invoke(timeout: .seconds(120), output: .captureSeparately, budget: budget) { remaining in
                let grace = min(30, remaining.components.seconds / 3)
                guard grace >= 1 else { throw timeout }
                return ["cluster", "stop", "--name", name, "--time", String(grace)]
            }
        }
        _ = try checkedOutput(result, subcommand: "stop")
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
        output: ProcessRunner.OutputMode = .inherit,
        kubeconfig: Kubeconfig = .managed,
        changesState: Bool = true,
        budget: ClusterCommandBudget? = nil
    ) async throws -> String {
        let execute = { @Sendable in
            try await launch(
                ["cluster"] + arguments, timeout: timeout, output: output, kubeconfig: kubeconfig, budget: budget)
        }
        let result = try await changesState ? lock.run(execute) : execute()
        return try checkedOutput(result, subcommand: arguments[0])
    }

    private func checkedOutput(_ result: ProcessRunner.Result, subcommand: String) throws -> String {
        guard result.status == 0 else {
            throw ClusterCommandError.failed(
                command: "cluster \(subcommand)", status: result.status,
                message: result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output
    }

    func launch(
        _ arguments: [String],
        timeout: Duration,
        output: ProcessRunner.OutputMode = .capture(includingStandardError: true),
        kubeconfig: Kubeconfig = .managed,
        budget: ClusterCommandBudget? = nil
    ) async throws -> ProcessRunner.Result {
        try await invoke(timeout: timeout, output: output, kubeconfig: kubeconfig, budget: budget) { _ in arguments }
    }

    private func invoke(
        timeout: Duration,
        output: ProcessRunner.OutputMode,
        kubeconfig: Kubeconfig = .managed,
        budget: ClusterCommandBudget?,
        arguments: @escaping @Sendable (Duration) throws -> [String]
    ) async throws -> ProcessRunner.Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        if let budget, !budget.canLaunch { throw budget.timeoutError(containerPath) }
                        try prepareKubeconfig()
                        let now = budget?.now() ?? .now
                        if let budget, now > budget.latestStart { throw budget.timeoutError(containerPath) }
                        let available = budget.map { min(timeout, now.duration(to: $0.end)) } ?? timeout
                        var environment = environment
                        environment["KUBECONFIG"] = (kubeconfig == .managed ? managedKubeconfig : userKubeconfig).path
                        return try spawn(
                            Launch(
                                executablePath: containerPath, arguments: arguments(available),
                                environment: environment,
                                output: output, timeout: available,
                                deadline: budget.map { .init(end: now + available, latestStart: $0.latestStart) }
                            ))
                    })
            }
        }
    }

    func prepareKubeconfig() throws {
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
        if let deadline = launch.deadline {
            return try ProcessRunner.run(
                executablePath: launch.executablePath, arguments: launch.arguments, output: launch.output,
                environment: launch.environment, deadline: deadline)
        }
        return try ProcessRunner.run(
            executablePath: launch.executablePath,
            arguments: launch.arguments,
            output: launch.output,
            environment: launch.environment,
            timeout: launch.timeout
        )
    }
}

struct ClusterCommandBudget: Sendable {
    let end: ContinuousClock.Instant
    let now: @Sendable () -> ContinuousClock.Instant

    var remaining: Duration { now().duration(to: end) }
    var latestStart: ContinuousClock.Instant { end - .seconds(5) }
    var canLaunch: Bool { now() <= latestStart }

    func timeoutError(_ containerPath: String) -> ProcessRunnerError {
        .timedOut(executablePath: containerPath, seconds: 0)
    }
}
