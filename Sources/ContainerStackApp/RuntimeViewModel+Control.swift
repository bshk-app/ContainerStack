import AppKit
import ContainerStackCore
import Foundation

@MainActor
extension RuntimeViewModel {
    var canRestartRuntime: Bool {
        !isRestarting && runtimeState != .starting
    }

    static let checkingRuntimeMessage = "Runtime connection lost. Checking the runtime…"

    /// The poll consumes a recovery request on several paths, and a manual restart or stop clears
    /// it too. Whichever ended the check, a "Checking the runtime…" left behind is settled here by
    /// the state the runtime is actually in.
    func settleFinishedRuntimeCheck() {
        guard !runtimeRecoveryRequested, !isRestarting, !isStarting else { return }
        if runtimeState.isHealthy {
            resolveRuntimeCheck(
                container: "Container stop timed out; runtime remains available.",
                resource: "Stop timed out; runtime remains available.",
                stack: "Stack action failed; runtime remains available."
            )
        } else {
            resolveRuntimeCheck(
                container: "Container stop failed; the runtime is offline.",
                resource: "Stop failed; the runtime is offline.",
                stack: "Stack action failed; the runtime is offline."
            )
        }
    }

    /// The recovery request is global, so only the screens that announced the check get its
    /// outcome; the rest keep what they last reported.
    private func resolveRuntimeCheck(container: String, resource: String, stack: String) {
        if containerMessage == Self.checkingRuntimeMessage { containerMessage = container }
        if resourceMessage == Self.checkingRuntimeMessage { resourceMessage = resource }
        if stackMessage == Self.checkingRuntimeMessage { stackMessage = stack }
    }

    static let recoveringRuntimeMessage = "Apple Container API server stopped. Restarting runtime…"

    /// The probe returns straight after this call, so a restart that failed has to leave the model
    /// offline here — otherwise the inventory captured before the restart stays on screen while the
    /// runtime is gone. Only a restart that ran and failed: one dropped or superseded left the
    /// runtime to whatever runs instead (#102).
    func completeAutomaticRuntimeRecovery(restart: () async -> RuntimeOperationOutcome) async {
        let previousMessage = runtimeMessage
        runtimeMessage = Self.recoveringRuntimeMessage
        switch await restart() {
        case .completed(true):
            resolveRuntimeCheck(
                container: "Runtime recovered.", resource: "Runtime recovered.", stack: "Runtime recovered.")
        case .completed(false):
            clearInventoryForStop()
            endStartupAfterFailedRecovery()
        case .dropped:
            runtimeMessage = previousMessage
        case .superseded:
            break
        }
    }

    /// `isCurrent` is the restart's checkpoint: once superseded, it publishes nothing more.
    func completeRuntimeRestart(
        isCurrent: () -> Bool = { true },
        waitForSocket: () async throws -> Bool,
        refreshHealth: (() async throws -> RuntimeHealthSnapshot)? = nil
    ) async -> Bool {
        let socketReady: Bool
        do {
            socketReady = try await waitForSocket()
        } catch {
            return false
        }
        guard isCurrent() else { return false }
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
        // A refresh superseded midway publishes nothing, so the state it would have replaced
        // says nothing about this restart.
        return isCurrent() && runtimeState.isHealthy
    }

    static func waitForRestartedSocket(
        attempts: Int = 60,
        delay: Duration = .seconds(1),
        responds: () async throws -> Bool
    ) async throws -> Bool {
        for _ in 0..<attempts {
            try await Task.sleep(for: delay)
            if try await responds() {
                return true
            }
        }
        return false
    }

    /// Stop and a replacing Start both need the helper this app spawned gone, not just signalled:
    /// a helper still inside `container system start` brings the bridge up after either of them.
    @discardableResult
    func endRuntimeHelper(grace: Duration = .seconds(2)) async -> Bool {
        guard let process = runtimeProcess else { return false }
        runtimeProcess = nil
        guard process.isRunning else { return true }
        await steps.endHelper(process, grace)
        return true
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
    /// gates a restart.
    func systemStatusOutput() async -> String {
        await steps.systemStatus(runtimeConfiguration().containerPath)
    }

    func message(for step: RuntimeControlStep) -> String {
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
    static func perform(_ step: RuntimeControlStep) async throws {
        switch step {
        case .stopBridge(let executablePath, let socketPath):
            await Task.detached {
                RuntimeShell.terminateBridge(executablePath: executablePath, socketPath: socketPath)
            }.value
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
            preconditionFailure("The view model launches the helper; see RuntimeViewModel.perform(_:).")
        case .kickstartAgent(let label):
            try await Task.detached {
                try RuntimeShell.run(
                    executablePath: "/bin/launchctl",
                    arguments: ["kickstart", "-k", "gui/\(getuid())/\(label)"]
                )
            }.value
        }
    }

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

    /// F-014: this build's bridge, and another ContainerStack copy's when it holds the socket.
    static func terminateBridge(executablePath: String, socketPath: String?) {
        let pids = BridgeOwnership.pidsToStop(
            bridgePath: executablePath,
            lsofOutput: socketPath.map { output(executablePath: "/usr/sbin/lsof", arguments: ["-Fpcn", "--", $0]) }
                ?? "",
            listing: output(executablePath: "/bin/ps", arguments: ["-A", "-o", "pid=,command="])
        )
        for pid in pids {
            kill(pid, SIGTERM)
        }
    }
}
