import ContainerStackCore
import Foundation

@MainActor
extension RuntimeViewModel {
    /// Restarts the bridge when the one serving is not the one this bundle ships.
    ///
    /// The bridge runs under a LaunchAgent, so replacing the app — an update, or a developer
    /// restaging a build — leaves the old process alive from the old executable image, under an
    /// unchanged path. Nothing looks wrong, and the app keeps driving a bridge whose code it no longer
    /// contains: during this feature's own development that silently invalidated two rounds of live
    /// verification.
    ///
    /// Attempted at most once per launch. A restart that keeps failing must not become a loop, and the
    /// identity is recorded only on success, so a failure is visible in the sidebar rather than
    /// papered over.
    func adoptBridgeIfStale() async {
        await adoptBridgeIfStale(
            loadRecorded: { RuntimeHelperIdentityStore().load() },
            loadCurrent: { self.bundledBridgeIdentity() },
            restart: { await self.restartRuntime() },
            recordIdentity: { self.recordBridgeIdentity() }
        )
    }

    func adoptBridgeIfStale(
        loadRecorded: () -> RuntimeHelperIdentity?,
        loadCurrent: () -> RuntimeHelperIdentity?,
        restart: () async -> Bool,
        recordIdentity: () -> Void
    ) async {
        guard !hasCheckedBridgeIdentity else { return }
        await adoptBridgeIfStale(
            recorded: loadRecorded(),
            current: loadCurrent(),
            restart: restart,
            recordIdentity: recordIdentity
        )
    }

    func adoptBridgeIfStale(
        recorded: RuntimeHelperIdentity?,
        current: RuntimeHelperIdentity?,
        restart: () async -> Bool,
        recordIdentity: () -> Void
    ) async {
        guard !hasCheckedBridgeIdentity else { return }
        hasCheckedBridgeIdentity = true

        guard
            RuntimeStaleness.needsRestart(
                isServing: runtimeState.isHealthy,
                recorded: recorded,
                current: current
            )
        else {
            return
        }

        let progressMessage =
            "Restarting the runtime: the running bridge is from an older build."
        serviceMessage = progressMessage
        let didRestart = await restart()
        if serviceMessage == progressMessage {
            serviceMessage = nil
        }

        guard didRestart else { return }
        recordIdentity()
        guard !Task.isCancelled else { return }
        if serviceMessage == nil {
            serviceMessage = "Runtime restarted on the current build."
        }
    }

    /// Records the bridge this app just launched, so a later launch can tell it apart from one it
    /// knows nothing about. Called where the app starts the helper itself — without it the cold-start
    /// path leaves no record, and the *next* launch would restart a perfectly current bridge and tell
    /// the user it was the wrong build.
    func recordBridgeIdentity() {
        guard let identity = bundledBridgeIdentity() else { return }
        do {
            try RuntimeHelperIdentityStore().save(identity)
            // Nothing to say when it worked: the interesting case is the failure below.
        } catch {
            serviceMessage = "Runtime started, but its identity could not be recorded: \(error)"
        }
    }

    private func bundledBridgeIdentity() -> RuntimeHelperIdentity? {
        let plan = RuntimeLaunchPlan(appBundleURL: Bundle.main.bundleURL)
        return RuntimeHelperIdentity.read(
            helperURL: URL(fileURLWithPath: plan.bridgePath),
            bundleVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        )
    }
}
