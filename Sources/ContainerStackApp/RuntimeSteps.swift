import ContainerStackCore
import Foundation

/// The helper as launched, and where its output goes.
struct LaunchedHelper {
    let process: Process
    let log: FileHandle
    let logPath: String
}

/// What Start, Stop and Restart wait on outside the app. Tests substitute steps that suspend at a
/// gate, so an operation can be held at any await, and Start, Stop and Restart run whole without
/// touching the machine's runtime (#102).
struct RuntimeSteps {
    /// Every `RuntimeControlStep` but `.startBridge`, which launches the helper the view model owns.
    var control: @MainActor (RuntimeControlStep) async throws -> Void
    var ping: @MainActor () async throws -> Bool
    /// What stands in the way of launching the helper: a bundle without one, or a `container`
    /// whose version this build was not tested against. Nil when nothing does.
    var launchComplaint: @MainActor (RuntimeProcessConfiguration) async -> String?
    var spawnHelper: @MainActor () throws -> LaunchedHelper
    var systemStatus: @MainActor (_ containerPath: String) async -> String
    /// SIGTERM, then SIGKILL if the helper outlives `grace`.
    var endHelper: @MainActor (Process, _ grace: Duration) async -> Void
    /// How long a socket wait sleeps between pings.
    var socketWaitTick: Duration = .seconds(1)

    static func live(client: DockerAPIClient) -> RuntimeSteps {
        RuntimeSteps(
            control: { try await RuntimeShell.perform($0) },
            ping: { try await client.ping() },
            launchComplaint: { configuration in
                let helper = RuntimeLaunchPlan(appBundleURL: Bundle.main.bundleURL).executablePath
                guard FileManager.default.isExecutableFile(atPath: helper) else {
                    return "Runtime helper is missing: \(helper)"
                }
                // Detached because this waits on `container --version` and the diagnostic deadline
                // is ten seconds: run on the main actor, a wedged binary freezes the window for all
                // of it.
                return await Task.detached { ContainerVersionCheck.run(configuration) }.value.userFacingMessage
            },
            spawnHelper: {
                let plan = RuntimeLaunchPlan(appBundleURL: Bundle.main.bundleURL)
                let logURL = try RuntimeViewModel.runtimeLogURL()
                let log = try FileHandle(forWritingTo: logURL)
                try log.seekToEnd()

                let process = Process()
                process.executableURL = URL(fileURLWithPath: plan.executablePath)
                process.arguments = plan.arguments
                process.standardOutput = log
                process.standardError = log
                try process.run()
                return LaunchedHelper(process: process, log: log, logPath: logURL.path)
            },
            // Off the main thread for the same reason: spawning the CLI blocks until it exits, and
            // the resolutions this feeds also run inside a sixty-attempt wait loop.
            systemStatus: { containerPath in
                await Task.detached {
                    RuntimeShell.output(executablePath: containerPath, arguments: ["system", "status"])
                }.value
            },
            endHelper: { process, grace in
                process.terminate()
                if await !waitForExit(of: process, within: grace) {
                    kill(process.processIdentifier, SIGKILL)
                    _ = await waitForExit(of: process, within: grace)
                }
            }
        )
    }

    @MainActor
    private static func waitForExit(of process: Process, within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while process.isRunning {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}
