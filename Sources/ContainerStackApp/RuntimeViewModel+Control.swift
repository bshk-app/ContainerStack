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
        runtimeRecoveryRequested = false

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

    /// The probe returns straight after this call, so a restart that failed has to leave the model
    /// offline here — otherwise the inventory captured before the restart stays on screen while the
    /// runtime is gone.
    func completeAutomaticRuntimeRecovery(restart: () async -> Bool) async {
        if await restart() {
            containerMessage = "Runtime recovered."
            return
        }
        clearInventoryForStop()
        endStartupAfterFailedRecovery()
    }

    func completeRuntimeRestart(
        waitForSocket: () async throws -> Bool,
        refreshHealth: (() async throws -> RuntimeHealthSnapshot)? = nil
    ) async -> Bool {
        let socketReady: Bool
        do {
            socketReady = try await waitForSocket()
        } catch {
            return false
        }
        guard socketReady else {
            failRuntime("Runtime did not come back within 60 seconds.")
            return false
        }

        runtimeMessage = "Runtime restarted."
        // A socket that answers is not yet a healthy runtime: `/version` and `/info` can still
        // fail, and reporting recovery then would contradict the state the refresh just published.
        if let refreshHealth {
            await refresh(health: refreshHealth)
        } else {
            await refresh()
        }
        return runtimeState.isHealthy
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
        runtimeRecoveryRequested = false

        isRestarting = true
        runtimeMessage = "Stopping Docker bridge…"
        defer { isRestarting = false }

        for step in RuntimeRestartPlan.stopSteps(configuration: runtimeConfiguration()) {
            try? await perform(step)
        }
        clearInventoryForStop()
        // Said here rather than left to the probe: a stop is the one silence with a known cause,
        // and `RuntimeLivenessFilter` makes the probe wait for a second opinion it does not need.
        applyState(socketResponds: false)
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
        guard NetworkRouteHealth.canJudgeRoutes(routes) else { return [] }
        return NetworkRouteHealth.unroutableNetworks(candidates, routes: routes)
    }

    /// The runtime cannot report this over the Docker API: with its app root deleted it still answers
    /// `_ping` with 200 (measured), so the only witness is `container system status`.
    func missingAppRoot() async -> String? {
        let status = await systemStatusOutput()
        return RuntimeStatusParser.missingAppRoot(status)
    }

    /// The single witness behind both the missing-app-root banner and the API-server proof that
    /// gates a restart. Async and off the main thread for the same reason as the routing table —
    /// spawning the CLI blocks until it exits, and the resolutions this feeds also run inside a
    /// sixty-attempt wait loop.
    func systemStatusOutput() async -> String {
        let containerPath = runtimeConfiguration().containerPath
        return await Task.detached {
            RuntimeShell.output(executablePath: containerPath, arguments: ["system", "status"])
        }.value
    }

    private func perform(_ step: RuntimeControlStep) async throws {
        switch step {
        case .stopBridge(let executablePath):
            await Task.detached { RuntimeShell.terminate(executablePath: executablePath) }.value
        case .stopContainers(let executablePath, let graceSeconds):
            // `try?`, not `try`: `restartRuntime` abandons the sequence on a throw, and this step
            // throws exactly when the runtime is wedged — which is when the steps after it are the
            // ones that repair it. A container that will not exit must not cost the user the fix.
            try? await Task.detached {
                try RuntimeShell.run(
                    executablePath: executablePath,
                    arguments: RuntimeControlStep.stopContainersArguments(graceSeconds: graceSeconds),
                    timeout: .seconds(graceSeconds + 10)
                )
            }.value
        case .run(let executablePath, let arguments):
            try await Task.detached {
                try RuntimeShell.run(executablePath: executablePath, arguments: arguments)
            }.value
        case .startBridge:
            await launchRuntimeHelperForRestart()
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
        case .stopContainers: "Asking containers to exit…"
        case .run(_, let arguments) where arguments.contains("stop"): "Stopping Apple Container…"
        case .run: "Starting Apple Container…"
        case .startBridge: "Starting Docker bridge…"
        case .kickstartAgent: "Restarting the runtime LaunchAgent…"
        }
    }
}

/// Process plumbing kept out of the view model so the decision logic stays testable.
enum RuntimeShell {
    /// `container system start`/`stop` boots or tears down a micro-VM, so this defaults to the
    /// lifecycle deadline. Bounded either way: on the old unbounded wait a wedged runtime left
    /// `runtimeProcess?.isRunning` true forever, which made every later Start click a silent
    /// no-op and could strand Restart with `isRestarting` stuck true.
    ///
    /// The graceful container stop overrides it: that call carries its own `--time` budget, so the
    /// lifecycle deadline would only add two minutes to a recovery already known to be needed.
    static func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration = ProcessRunner.lifecycleTimeout
    ) throws {
        _ = try ProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            timeout: timeout
        )
    }

    /// Called from the 3s monitor loop, so it has to return on a schedule that loop can keep.
    /// An empty string already meant "could not ask", and a timeout is that same answer.
    static func output(executablePath: String, arguments: [String]) -> String {
        let result = try? ProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            output: .capture(includingStandardError: false),
            timeout: ProcessRunner.diagnosticTimeout
        )
        return result?.output ?? ""
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
