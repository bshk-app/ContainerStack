import ContainerStackCore
import Foundation

/// What Start, Stop and Restart wait on outside the app. Tests substitute steps that suspend at a
/// gate, so an operation can be held at any await, and Stop runs whole without signalling the
/// machine's bridge (#102).
struct RuntimeSteps {
    /// Every `RuntimeControlStep` but `.startBridge`, which launches the helper the view model owns.
    var control: @MainActor (RuntimeControlStep) async throws -> Void
    var ping: @MainActor () async throws -> Bool
    /// What `ContainerVersionCheck` holds against the installed `container`, nil when it is fine.
    var versionComplaint: @MainActor (RuntimeProcessConfiguration) async -> String?
    var systemStatus: @MainActor (_ containerPath: String) async -> String
    /// SIGTERM, then SIGKILL if the helper outlives `grace`.
    var endHelper: @MainActor (Process, _ grace: Duration) async -> Void

    static func live(client: DockerAPIClient) -> RuntimeSteps {
        RuntimeSteps(
            control: { try await RuntimeShell.perform($0) },
            ping: { try await client.ping() },
            // Detached because this waits on `container --version` and the diagnostic deadline is
            // ten seconds: run on the main actor, a wedged binary freezes the window for all of it.
            versionComplaint: { configuration in
                await Task.detached { ContainerVersionCheck.run(configuration) }.value.userFacingMessage
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
