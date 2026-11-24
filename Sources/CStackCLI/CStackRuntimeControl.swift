import ContainerStackCore
import Darwin
import Foundation

/// Minimal process plumbing for the CLI. The decisions live in `RuntimeRestartPlan`.
enum CommandShell {
    /// Backs `container system start`/`stop` and `launchctl kickstart`, so the deadline defaults to
    /// the lifecycle one. Output stays inherited: the person ran the command and wants to see it.
    ///
    /// The graceful container stop passes a shorter deadline: it carries its own `--time` budget, so
    /// waiting two minutes past it only delays a recovery that is already overdue.
    @discardableResult
    static func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration = ProcessRunner.lifecycleTimeout
    ) throws -> Int32 {
        try ProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            output: .inherit,
            timeout: timeout
        ).status
    }

    /// stderr stays discarded on purpose: `launchctl print` reports a missing service on
    /// stderr with an empty stdout, and `agentRegistered()` depends on that split to tell a
    /// registered agent from an unregistered one.
    static func output(executablePath: String, arguments: [String]) -> String {
        let result = try? ProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            output: .capture(includingStandardError: false),
            timeout: ProcessRunner.diagnosticTimeout
        )
        return result?.output ?? ""
    }

    /// F-014: this build's bridge, and another ContainerStack copy's when it holds the socket.
    static func terminateBridge(executablePath: String, socketPath: String?) throws -> Int {
        let pids = BridgeOwnership.pidsToStop(
            bridgePath: executablePath,
            lsofOutput: socketPath.map { output(executablePath: "/usr/sbin/lsof", arguments: ["-Fpcn", "--", $0]) }
                ?? "",
            listing: output(executablePath: "/bin/ps", arguments: ["-A", "-o", "pid=,command="])
        )
        try BridgeTermination.stop(pids)
        return pids.count
    }
}

private enum RuntimeControlError: Error, CustomStringConvertible {
    case incompleteRestart(failedSteps: Int)

    var description: String {
        switch self {
        case .incompleteRestart(let failedSteps):
            return "runtime restart incomplete: \(failedSteps) step(s) failed. Check with: cstack doctor"
        }
    }
}

@MainActor
struct RuntimeCLI {
    let preflight: () async -> String?
    let stopClusters: () async -> [String]
    let runStep: (RuntimeControlStep) throws -> String?
    let agentRegistered: () -> Bool
    let write: (String) -> Void
    let writeError: (String) -> Void
    var readConfirmation: (() -> Bool)?

    func run(_ invocation: CStackInvocation, configuration: RuntimeProcessConfiguration) async throws -> Int32 {
        switch invocation.positional.first {
        case "restart", .none:
            if let question = await preflight(), !invocation.isSet("yes") {
                guard let readConfirmation else {
                    writeError(question + "\n")
                    return 1
                }
                writeError(question + " [y/N] ")
                guard readConfirmation() else { return 1 }
            }
            let steps = RuntimeRestartPlan.steps(
                configuration: configuration, agentRegistered: agentRegistered(), replacingSibling: true)
            let failed = try await apply(steps)
            guard failed == 0 else { throw RuntimeControlError.incompleteRestart(failedSteps: failed) }
            write("Runtime restarted. Check with: cstack doctor\n")
        case "stop":
            _ = try await apply(RuntimeRestartPlan.stopSteps(configuration: configuration, replacingSibling: true))
            write("Docker bridge stopped. Apple Container is still running.\n")
        case "start":
            _ = try await apply([.startBridge])
            write("Docker bridge starting. Check with: cstack doctor\n")
        case let other?:
            writeError("cstack runtime: unknown action '\(other)'\n")
            return 64
        }
        return 0
    }

    private func apply(_ steps: [RuntimeControlStep]) async throws -> Int {
        var failed = 0
        for step in steps {
            if case .stopClusters = step {
                for line in await stopClusters() { write(line + "\n") }
            } else if try runStep(step) != nil {
                failed += 1
            }
        }
        return failed
    }
}

extension CStackCLI {
    @MainActor
    static func runtimeControl(_ invocation: CStackInvocation, client: DockerAPIClient) async throws -> Int32 {
        let configuration = runtimeConfiguration(socketPath: invocation.socketPath)
        let clusters = ClusterRuntimeLifecycle(
            containerPath: configuration.containerPath, client: client,
            home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment)
        let cli = RuntimeCLI(
            preflight: { await clusters.preflight() },
            stopClusters: { await clusters.stopClusters() ?? [] },
            runStep: { try perform($0, configuration: configuration) },
            agentRegistered: agentRegistered,
            write: writeRuntimeOutput,
            writeError: { FileHandle.standardError.write(Data($0.utf8)) },
            readConfirmation: isatty(STDIN_FILENO) == 1
                ? {
                    let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return answer == "y" || answer == "yes"
                } : nil
        )
        return try await cli.run(invocation, configuration: configuration)
    }

    private static func writeRuntimeOutput(_ value: String) {
        FileHandle.standardOutput.write(Data(value.utf8))
    }

    private static func perform(
        _ step: RuntimeControlStep,
        configuration: RuntimeProcessConfiguration
    ) throws -> String? {
        switch step {
        case .stopClusters:
            preconditionFailure("RuntimeCLI handles the cluster step.")
        case .stopBridge(let executablePath, let socketPath):
            let stopped = try CommandShell.terminateBridge(executablePath: executablePath, socketPath: socketPath)
            writeRuntimeOutput("Stopped \(stopped) bridge process(es)\n")
        case .stopContainers(let executablePath, let graceSeconds):
            writeRuntimeOutput("Asking containers to exit (\(graceSeconds)s grace)\n")
            _ = try? CommandShell.run(
                executablePath: executablePath,
                arguments: RuntimeControlStep.stopContainersArguments(graceSeconds: graceSeconds),
                timeout: RuntimeControlStep.stopContainersTimeout(graceSeconds: graceSeconds))
        case .run(let executablePath, let arguments):
            let description = "\(executablePath) \(arguments.joined(separator: " "))"
            writeRuntimeOutput("Running \(description)\n")
            return runRecoveryCommand(executablePath, arguments, description: description)
        case .startBridge:
            writeRuntimeOutput("Starting \(configuration.socktainerPath)\n")
            try startBridge(configuration: configuration)
        case .kickstartAgent(let label):
            let target = "gui/\(getuid())/\(label)"
            writeRuntimeOutput("Restarting LaunchAgent \(label)\n")
            return runRecoveryCommand(
                "/bin/launchctl", ["kickstart", "-k", target],
                description: "launchctl kickstart \(target)")
        }
        return nil
    }

    private static func runRecoveryCommand(_ path: String, _ arguments: [String], description: String) -> String? {
        do {
            let status = try CommandShell.run(executablePath: path, arguments: arguments)
            guard status != 0 else { return nil }
            fputs("warning: \(description) exited with status \(status)\n", stderr)
        } catch {
            fputs("warning: \(description) failed: \(error)\n", stderr)
        }
        return description
    }

    static func cluster(_ invocation: CStackInvocation) async -> Never {
        let commands = ClusterCommands(
            containerPath: runtimeConfiguration(socketPath: invocation.socketPath).containerPath,
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        )
        let cli = ClusterCLI(
            commands: commands,
            write: { FileHandle.standardOutput.write(Data($0.utf8)) },
            writeError: { FileHandle.standardError.write(Data($0.utf8)) }
        )
        exit(await cli.run(invocation.passthrough))
    }

    /// The bridge must outlive the CLI invocation, so it is detached instead of waited on.
    private static func startBridge(configuration: RuntimeProcessConfiguration) throws {
        guard FileManager.default.isExecutableFile(atPath: configuration.socktainerPath) else {
            fputs("cstack runtime: bridge not found at \(configuration.socktainerPath)\n", stderr)
            exit(69)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.socktainerPath)
        process.arguments = configuration.socktainerArguments
        // Same quieting as the supervisor applies, so which path started the bridge does not
        // decide how much it writes to runtime.log.
        process.environment = RuntimeProcessConfiguration.socktainerEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func agentRegistered() -> Bool {
        let label = RuntimeRestartPlan.agentLabel
        let listing = CommandShell.output(
            executablePath: "/bin/launchctl",
            arguments: ["print", "gui/\(getuid())/\(label)"]
        )
        return listing.contains(label)
    }

    static func runtimeConfiguration(socketPath: String?) -> RuntimeProcessConfiguration {
        RuntimeProcessConfiguration.make(
            socktainerPath: bundledSocktainerPath(),
            socketPath: socketPath ?? RuntimeProcessConfiguration.defaultSocketPath,
            bundledInstallRoot: RuntimeProcessConfiguration.bundledInstallRoot(
                forExecutableAt: Bundle.main.executableURL
            ),
            sharedRuntimes: SharedRuntimesFlag.needed(
                for: RuntimeGroupsFile.read(
                    at: RuntimeGroupsFile.url(home: FileManager.default.homeDirectoryForCurrentUser)))
        )
    }

    /// `cstack` ships in `Contents/MacOS`, the bridge in `Contents/Helpers`.
    private static func bundledSocktainerPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CONTAINERSTACK_SOCKTAINER_PATH"] {
            return override
        }

        // `CommandLine.arguments[0]` is whatever the caller typed. Invoked by name through
        // `$PATH` it is the bare string "cstack", which resolves against the current working
        // directory, so Contents/Helpers is never found and this falls through to a
        // ~/.local/bin path that does not exist in a normal install.
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".local/bin/socktainer").path
        }
        let helpers =
            executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Helpers/socktainer")
        if FileManager.default.isExecutableFile(atPath: helpers.path) {
            return helpers.path
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/socktainer").path
    }
}
