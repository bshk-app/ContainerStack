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
            recordIdentity: { self.recordBridgeIdentity() },
            servesOurBridge: { self.servesOurBridge() }
        )
    }

    func adoptBridgeIfStale(
        loadRecorded: () -> RuntimeHelperIdentity?,
        loadCurrent: () -> RuntimeHelperIdentity?,
        restart: () async -> Bool,
        recordIdentity: () -> Void,
        servesOurBridge: () -> Bool = { true }
    ) async {
        guard !hasCheckedBridgeIdentity else { return }
        await adoptBridgeIfStale(
            recorded: loadRecorded(),
            current: loadCurrent(),
            restart: restart,
            recordIdentity: recordIdentity,
            servesOurBridge: servesOurBridge
        )
    }

    /// One wording for both places that can discover it, so the two cannot drift.
    var foreignBridgeMessage: String {
        "Another Docker bridge holds \(socketPath). Stop it and start the runtime again; "
            + "until then starting and stopping containers can hang."
    }

    func adoptBridgeIfStale(
        recorded: RuntimeHelperIdentity?,
        current: RuntimeHelperIdentity?,
        restart: () async -> Bool,
        recordIdentity: () -> Void,
        servesOurBridge: () -> Bool = { true }
    ) async {
        guard !hasCheckedBridgeIdentity else { return }
        hasCheckedBridgeIdentity = true

        // Ownership first, and independent of build staleness. `needsRestart` is
        // `recorded != current`, and the app records its own helper whenever it
        // launches one - so on a stable build the identities match and this
        // routine would return before ever asking who is actually serving. That
        // is the reported case: a foreign bridge takes the socket, every check
        // passes, and lifecycle calls hang with nothing to look at.
        guard runtimeState.isHealthy else { return }

        guard servesOurBridge() else {
            serviceMessage = foreignBridgeMessage
            return
        }

        guard
            RuntimeStaleness.needsRestart(
                isServing: true,
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

        // A restart stops only the bridge this build ships, deliberately - a
        // socktainer someone runs from elsewhere is theirs. So a restart can
        // "succeed" while a foreign bridge has taken the socket in the meantime,
        // and recording our identity there would declare the mismatch resolved.
        guard servesOurBridge() else {
            serviceMessage = foreignBridgeMessage
            return
        }

        recordIdentity()
        guard !Task.isCancelled else { return }
        if serviceMessage == nil {
            serviceMessage = "Runtime restarted on the current build."
        }
    }

    /// Whether the bridge this bundle ships is the process serving. The Docker
    /// API cannot answer this - every socktainer replies the same - so the
    /// process table is asked instead.
    func servesOurBridge() -> Bool {
        let plan = RuntimeLaunchPlan(appBundleURL: Bundle.main.bundleURL)
        let listing = RuntimeShell.output(
            executablePath: "/bin/ps",
            arguments: ["-A", "-o", "pid=,command="]
        )
        return !ProcessTable.pids(forExecutable: plan.bridgePath, in: listing).isEmpty
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
