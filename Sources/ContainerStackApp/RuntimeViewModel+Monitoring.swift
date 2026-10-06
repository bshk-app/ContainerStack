import Foundation

@MainActor
extension RuntimeViewModel {
    /// Polls the Docker socket so the UI tracks the runtime even when the helper is not ours:
    /// another ContainerStack instance, a LaunchAgent or a manually started bridge all count.
    /// Runs for the life of the process: the menu bar extra and automatic recovery depend on it
    /// after the window closes.
    func startMonitoring(interval: Duration = .seconds(3)) {
        guard monitorTask == nil else { return }

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.monitorTick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// The context read stays inside the tick, after the probe: a probe that sees the socket come
    /// back adopts the context, and a read running beside it could leave that adoption deciding on
    /// a cached context the user has since switched away from. An adoption running for another
    /// caller reads the context itself; a tick read beside it would only make it read again, and
    /// reads slower than the tick would never get through.
    func monitorTick() async {
        await probeRuntime()
        settleFinishedRuntimeCheck()
        if isDashboardOpen, !isAdoptingDockerContext {
            await refreshDockerContext(includeInstalledContext: false)
        }
        expireServiceMessage()
    }

    func expireServiceMessage(now: Date = Date()) {
        guard serviceMessage != nil, let serviceMessageExpiresAt, now >= serviceMessageExpiresAt
        else { return }
        serviceMessage = nil
    }
}
