import ContainerStackCore
import Darwin
import Foundation

/// Minimal process plumbing for the CLI. The decisions live in `RuntimeRestartPlan`.
enum CommandShell {
    /// Backs `container system start`/`stop` and `launchctl kickstart`, so the deadline is the
    /// lifecycle one. Output stays inherited: the person ran the command and wants to see it.
    @discardableResult
    static func run(executablePath: String, arguments: [String]) throws -> Int32 {
        try ProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            output: .inherit,
            timeout: ProcessRunner.lifecycleTimeout
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

    static func terminate(executablePath: String) -> Int {
        let listing = output(executablePath: "/bin/ps", arguments: ["-A", "-o", "pid=,command="])
        let pids = ProcessTable.pids(forExecutable: executablePath, in: listing)
        for pid in pids {
            kill(pid, SIGTERM)
        }
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

extension CStackCLI {
    static func runtimeControl(_ invocation: CStackInvocation) throws {
        let configuration = runtimeConfiguration(socketPath: invocation.socketPath)

        switch invocation.positional.first {
        case "restart", .none:
            let failed = try apply(
                RuntimeRestartPlan.steps(configuration: configuration, agentRegistered: agentRegistered()),
                configuration: configuration
            )
            guard failed.isEmpty else {
                throw RuntimeControlError.incompleteRestart(failedSteps: failed.count)
            }
            print("Runtime restarted. Check with: cstack doctor")
        case "stop":
            try apply(RuntimeRestartPlan.stopSteps(configuration: configuration), configuration: configuration)
            print("Docker bridge stopped. Apple Container is still running.")
        case "start":
            try apply([.startBridge], configuration: configuration)
            print("Docker bridge starting. Check with: cstack doctor")
        case let other?:
            fputs("cstack runtime: unknown action '\(other)'\n", stderr)
            exit(64)
        }
    }

    /// Returns the steps that failed. Apple Container's `system stop`/`start` are
    /// best-effort inside a recovery sequence, so a non-zero exit, launch failure,
    /// or timeout is reported rather than aborting the remaining steps — but an
    /// incomplete sequence must still make `cstack` exit non-zero.
    @discardableResult
    private static func apply(
        _ steps: [RuntimeControlStep],
        configuration: RuntimeProcessConfiguration
    ) throws -> [String] {
        var failed: [String] = []
        for step in steps {
            switch step {
            case .stopBridge(let executablePath):
                let stopped = CommandShell.terminate(executablePath: executablePath)
                print("Stopped \(stopped) bridge process(es)")
            case .run(let executablePath, let arguments):
                let description = "\(executablePath) \(arguments.joined(separator: " "))"
                print("Running \(description)")
                do {
                    let status = try CommandShell.run(
                        executablePath: executablePath,
                        arguments: arguments
                    )
                    if status != 0 {
                        failed.append(description)
                        fputs("warning: \(description) exited with status \(status)\n", stderr)
                    }
                } catch {
                    failed.append(description)
                    fputs("warning: \(description) failed: \(error)\n", stderr)
                }
            case .startBridge:
                print("Starting \(configuration.socktainerPath)")
                try startBridge(configuration: configuration)
            case .kickstartAgent(let label):
                let description = "launchctl kickstart gui/\(getuid())/\(label)"
                print("Restarting LaunchAgent \(label)")
                do {
                    let status = try CommandShell.run(
                        executablePath: "/bin/launchctl",
                        arguments: ["kickstart", "-k", "gui/\(getuid())/\(label)"]
                    )
                    if status != 0 {
                        failed.append(description)
                        fputs("warning: \(description) exited with status \(status)\n", stderr)
                    }
                } catch {
                    failed.append(description)
                    fputs("warning: \(description) failed: \(error)\n", stderr)
                }
            }
        }
        return failed
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

    private static func runtimeConfiguration(socketPath: String?) -> RuntimeProcessConfiguration {
        RuntimeProcessConfiguration.make(
            socktainerPath: bundledSocktainerPath(),
            socketPath: socketPath ?? RuntimeProcessConfiguration.defaultSocketPath,
            bundledInstallRoot: RuntimeProcessConfiguration.bundledInstallRoot(
                forExecutableAt: Bundle.main.executableURL
            )
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
