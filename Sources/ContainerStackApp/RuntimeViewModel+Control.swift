import AppKit
import ContainerStackCore
import Foundation

@MainActor
extension RuntimeViewModel {
    var canRestartRuntime: Bool {
        !isRestarting && runtimeState != .starting
    }

    /// Recovers a wedged runtime: Apple Container can keep answering the API after its vmnet
    /// attachment is gone, and only a full stop/start rebuilds it.
    @discardableResult
    func restartRuntime() async -> Bool {
        guard !isRestarting else { return false }

        isRestarting = true
        runtimeFailure = nil
        defer { isRestarting = false }

        let configuration = runtimeConfiguration()
        let steps = RuntimeRestartPlan.steps(
            configuration: configuration,
            agentRegistered: isAgentRegistered
        )

        for step in steps {
            runtimeMessage = message(for: step)
            do {
                try await perform(step)
            } catch {
                failRuntime("Restart failed at \(message(for: step)): \(error)")
                return false
            }
        }

        runtimeMessage = "Waiting for Docker socket…"
        return await completeRuntimeRestart(waitForSocket: {
            try await Self.waitForRestartedSocket {
                await self.socketRespondsNow()
            }
        })
    }

    func completeRuntimeRestart(waitForSocket: () async throws -> Bool) async -> Bool {
        let socketReady: Bool
        do {
            socketReady = try await waitForSocket()
        } catch {
            return false
        }
        if socketReady {
            runtimeMessage = "Runtime restarted."
            await refresh()
            return true
        }
        failRuntime("Runtime did not come back within 60 seconds.")
        return false
    }

    static func waitForRestartedSocket(
        attempts: Int = 60,
        delay: Duration = .seconds(1),
        responds: () async -> Bool
    ) async throws -> Bool {
        for _ in 0..<attempts {
            try await Task.sleep(for: delay)
            if await responds() {
                return true
            }
        }
        return false
    }

    func stopRuntime() async {
        guard !isRestarting else { return }

        isRestarting = true
        runtimeMessage = "Stopping Docker bridge…"
        defer { isRestarting = false }

        for step in RuntimeRestartPlan.stopSteps(configuration: runtimeConfiguration()) {
            try? await perform(step)
        }
        clearInventoryForStop()
        runtimeMessage = "Docker bridge stopped."
        await probeAfterControlChange()
    }

    /// Published ports depend on a host route to the container's network subnet. Without this
    /// check a wedged network looks perfectly healthy over the Docker API — but only networks
    /// actually carrying published ports count, so a broken unused `default` stays silent.
    func unroutablePublishingNetworks() async -> [UnroutableNetwork] {
        let candidates = NetworkRouteHealth.publishingNetworks(containers: containers, networks: networks)
        guard !candidates.isEmpty else { return [] }

        let routes = await Task.detached { RuntimeShell.routingTable() }.value
        return NetworkRouteHealth.unroutableNetworks(candidates, routes: routes)
    }

    /// The runtime cannot report this over the Docker API: with its app root deleted it still answers
    /// `_ping` with 200 (measured), so the only witness is `container system status`. Async and off the
    /// main thread for the same reason as the routing table — spawning the CLI blocks until it exits,
    /// and the resolution this feeds also runs inside a sixty-attempt wait loop.
    func missingAppRoot() async -> String? {
        let containerPath = runtimeConfiguration().containerPath
        let status = await Task.detached {
            RuntimeShell.output(executablePath: containerPath, arguments: ["system", "status"])
        }.value
        return RuntimeStatusParser.missingAppRoot(status)
    }

    private func perform(_ step: RuntimeControlStep) async throws {
        switch step {
        case .stopBridge(let executablePath):
            await Task.detached { RuntimeShell.terminate(executablePath: executablePath) }.value
        case .run(let executablePath, let arguments):
            try await Task.detached {
                try RuntimeShell.run(executablePath: executablePath, arguments: arguments)
            }.value
        case .startBridge:
            launchRuntimeHelperForRestart()
        case .kickstartAgent(let label):
            try await Task.detached {
                try RuntimeShell.run(
                    executablePath: "/bin/launchctl",
                    arguments: ["kickstart", "-k", "gui/\(getuid())/\(label)"]
                )
            }.value
        }
    }

    private func message(for step: RuntimeControlStep) -> String {
        switch step {
        case .stopBridge: "Stopping Docker bridge…"
        case .run(_, let arguments) where arguments.contains("stop"): "Stopping Apple Container…"
        case .run: "Starting Apple Container…"
        case .startBridge: "Starting Docker bridge…"
        case .kickstartAgent: "Restarting the runtime LaunchAgent…"
        }
    }
}

/// Process plumbing kept out of the view model so the decision logic stays testable.
enum RuntimeShell {
    static func run(executablePath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    static func output(executablePath: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func routingTable() -> String {
        output(executablePath: "/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
    }

    static func terminate(executablePath: String) {
        let listing = output(executablePath: "/bin/ps", arguments: ["-A", "-o", "pid=,command="])
        for pid in ProcessTable.pids(forExecutable: executablePath, in: listing) {
            kill(pid, SIGTERM)
        }
    }
}
