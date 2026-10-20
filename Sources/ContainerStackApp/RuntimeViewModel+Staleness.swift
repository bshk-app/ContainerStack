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
    /// From the probe, whose restart is a request the queue may drop while a Start runs.
    func adoptBridgeIfStale(observed: Int) async {
        await adoptBridgeIfStale(restart: {
            await self.run(.restart(replacingSibling: false), origin: .staleBridge, observed: observed)
        })
    }

    /// From inside Start, which restarts under its own token: a request from inside an operation
    /// would be dropped or wait on itself (#102).
    func adoptBridgeIfStale(during token: Int) async {
        await adoptBridgeIfStale(restart: {
            let restarted = await self.performRestart(replacingSibling: false, token: token)
            return self.lifecycle.isCurrent(token) ? .completed(restarted) : .superseded
        })
    }

    private func adoptBridgeIfStale(restart: () async -> RuntimeOperationOutcome) async {
        await adoptBridgeIfStale(
            loadRecorded: { RuntimeHelperIdentityStore().load() },
            loadCurrent: { self.bundledBridgeIdentity() },
            restart: restart,
            recordIdentity: { self.recordBridgeIdentity() },
            foreignBridge: { self.currentForeignBridge() }
        )
    }

    func adoptBridgeIfStale(
        loadRecorded: () -> RuntimeHelperIdentity?,
        loadCurrent: () -> RuntimeHelperIdentity?,
        restart: () async -> RuntimeOperationOutcome,
        recordIdentity: () -> Void,
        foreignBridge: () -> ForeignBridge? = { nil }
    ) async {
        guard !hasCheckedBridgeIdentity else { return }
        await adoptBridgeIfStale(
            recorded: loadRecorded(),
            current: loadCurrent(),
            restart: restart,
            recordIdentity: recordIdentity,
            foreignBridge: foreignBridge
        )
    }

    func adoptBridgeIfStale(
        recorded: RuntimeHelperIdentity?,
        current: RuntimeHelperIdentity?,
        restart: () async -> RuntimeOperationOutcome,
        recordIdentity: () -> Void,
        foreignBridge: () -> ForeignBridge? = { nil }
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

        if let foreign = foreignBridge() {
            serviceMessage = Self.foreignBridgeMessage(foreign)
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
        let outcome = await restart()
        if serviceMessage == progressMessage {
            serviceMessage = nil
        }
        // A dropped restart replaced nothing, so the check is unspent again: left spent, Start's own
        // adoption would skip it and the outdated bridge would serve for the rest of the session.
        if outcome == .dropped {
            hasCheckedBridgeIdentity = false
        }
        // Superseded, it ran under an operation that no longer publishes (#102).
        guard outcome == .completed(true) else { return }

        // A restart stops only the bridge this build ships, deliberately - a
        // socktainer someone runs from elsewhere is theirs. So a restart can
        // "succeed" while a foreign bridge has taken the socket in the meantime,
        // and recording our identity there would declare the mismatch resolved.
        if let foreign = foreignBridge() {
            serviceMessage = Self.foreignBridgeMessage(foreign)
            return
        }

        recordIdentity()
        guard !Task.isCancelled else { return }
        if serviceMessage == nil {
            serviceMessage = "Runtime restarted on the current build."
        }
    }

    /// The banner owns this wording; the launch-time discovery reuses it so the
    /// two cannot drift apart.
    static func foreignBridgeMessage(_ bridge: ForeignBridge) -> String {
        RuntimeState.foreignBridge(bridge).detail ?? ""
    }

    /// Who holds the socket when it is not the bridge this bundle ships, named so the banner
    /// can say which process it is and whether a restart replaces it (F-014).
    /// The Docker API cannot answer this - every socktainer replies the same - and
    /// neither can "is our binary running", since the bridge takes a `--socket`
    /// argument and ours may be serving a different path.
    func currentForeignBridge() -> ForeignBridge? {
        BridgeOwnership.foreignBridge(
            socketPath: socketPath,
            holder: BridgeOwnership.holder(
                lsofOutput: RuntimeShell.output(
                    executablePath: "/usr/sbin/lsof",
                    arguments: ["-Fpcn", "--", socketPath]
                )
            ),
            ourBridgePath: RuntimeLaunchPlan(appBundleURL: Bundle.main.bundleURL).bridgePath,
            listing: RuntimeShell.output(
                executablePath: "/bin/ps",
                arguments: ["-A", "-o", "pid=,command="]
            )
        )
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
