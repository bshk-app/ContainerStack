import ContainerStackCore
import Darwin
import Foundation

@main
struct ContainerStackRuntime {
    static func main() async {
        redirectOutputToRuntimeLog()

        // Resolved once: the same root decides both which binary runs and
        // whether the daemon is told where its plugins live. Deriving them
        // separately is how they drift apart.
        let installRoot = bundledContainerInstallRoot()
        let configuration = RuntimeProcessConfiguration(
            containerPath: containerPath(),
            socktainerPath: socktainerPath(),
            containerInstallRoot: installRoot
        )

        do {
            let version = try output(
                executablePath: configuration.containerPath,
                arguments: ["--version"]
            )
            guard version.contains(configuration.expectedContainerVersion) else {
                fputs("ContainerStackRuntime: unsupported Apple Container version: \(version)\n", stderr)
                exit(EXIT_FAILURE)
            }

            try await runRuntime(configuration)
        } catch {
            fputs("ContainerStackRuntime: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    /// launchd gives the agent no output destination, so the helper owns its log file.
    /// Append mode keeps it safe when the app is also writing to the same file.
    private static func redirectOutputToRuntimeLog() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/ContainerStack")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let logPath = directory.appending(path: "runtime.log").path
        let descriptor = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        dup2(descriptor, STDOUT_FILENO)
        dup2(descriptor, STDERR_FILENO)
        setvbuf(stdout, nil, _IOLBF, 0)
        print("--- ContainerStackRuntime started \(Date().formatted(.iso8601)) ---")
    }

    /// The vendored Apple Container install root, staged beside this helper at
    /// `Contents/Resources/container`. Resolved from the executable exactly the
    /// way `socktainerPath()` resolves its sidecar, so the bundle stays
    /// relocatable.
    ///
    /// nil in a development checkout, where the helper runs out of `.build`
    /// with no bundle around it; the caller then falls back to a system install.
    private static func bundledContainerInstallRoot() -> String? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        // …/Contents/Helpers/ContainerStackRuntime → …/Contents/Resources/container
        let root = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/container")
        let cli = root.appending(path: "bin/container").path
        return FileManager.default.isExecutableFile(atPath: cli) ? root.path : nil
    }

    private static func containerPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CONTAINERSTACK_CONTAINER_PATH"] {
            return override
        }

        return RuntimeProcessConfiguration.resolvedContainerPath(
            bundledInstallRoot: bundledContainerInstallRoot()
        )
    }

    private static func socktainerPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CONTAINERSTACK_SOCKTAINER_PATH"] {
            return override
        }

        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            return executable.deletingLastPathComponent().appending(path: "socktainer").path
        }

        return RuntimePaths.sibling(
            named: "socktainer",
            ofExecutableAt: CommandLine.arguments[0],
            workingDirectory: FileManager.default.currentDirectoryPath
        )
    }

    private static func output(executablePath: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RuntimeProcessError.failed(
                executablePath: executablePath,
                status: process.terminationStatus
            )
        }

        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// Apple Container may already be up and another ContainerStack instance may already own the
    /// Docker socket. Starting a second bridge in that case fails and leaves the app reporting a
    /// dead runtime while the socket is perfectly healthy, so adopt what is already running.
    private static func runRuntime(_ configuration: RuntimeProcessConfiguration) async throws {
        try run(
            executablePath: configuration.containerPath,
            arguments: configuration.containerStartArguments
        )
        try waitForContainerSystem(executablePath: configuration.containerPath)

        let decision = RuntimeStartupPlanner.decide(
            socketFileExists: FileManager.default.fileExists(atPath: configuration.socketPath),
            bridgeResponds: await bridgeResponds(socketPath: configuration.socketPath)
        )

        switch decision {
        case .bridgeAlreadyRunning:
            print("Docker bridge already listening on \(configuration.socketPath); adopting it.")
        case .removeStaleSocket:
            try? FileManager.default.removeItem(atPath: configuration.socketPath)
            print("Removed stale socket \(configuration.socketPath).")
            try run(
                executablePath: configuration.socktainerPath,
                arguments: configuration.socktainerArguments
            )
        case .startBridge:
            try run(
                executablePath: configuration.socktainerPath,
                arguments: configuration.socktainerArguments
            )
        }
    }

    private static func bridgeResponds(socketPath: String) async -> Bool {
        let client = DockerAPIClient(
            socketPath: socketPath,
            retryPolicy: DockerRetryPolicy(maxAttempts: 1, delay: .zero)
        )
        return (try? await client.ping()) ?? false
    }

    private static func waitForContainerSystem(executablePath: String) throws {
        var lastStatus = ""
        for _ in 0..<30 {
            if let status = try? output(
                executablePath: executablePath,
                arguments: ["system", "status"]
            ) {
                lastStatus = status
                if RuntimeStatusParser.isRunning(status) {
                    return
                }
            }
            sleep(1)
        }
        throw RuntimeProcessError.notReady(
            executablePath: executablePath,
            statusOutput: lastStatus
        )
    }

    private static func run(executablePath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RuntimeProcessError.failed(
                executablePath: executablePath,
                status: process.terminationStatus
            )
        }
    }
}

enum RuntimeProcessError: Error, CustomStringConvertible {
    case failed(executablePath: String, status: Int32)
    case notReady(executablePath: String, statusOutput: String)

    var description: String {
        switch self {
        case let .failed(executablePath, status):
            "\(executablePath) exited with status \(status)"
        case let .notReady(executablePath, statusOutput):
            "\(executablePath) did not report a running API server. Last status: \(statusOutput)"
        }
    }
}
