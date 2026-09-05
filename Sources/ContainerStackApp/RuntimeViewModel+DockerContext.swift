import ContainerStackCore
import Foundation
import Observation

@Observable
final class DockerContextTakeoverPreference {
    static let defaultKey = "com.containerstack.dockerContextTakeover"

    private(set) var isEnabled: Bool
    @ObservationIgnored private(set) var isConfigured: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = DockerContextTakeoverPreference.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
        let stored = defaults.object(forKey: key) as? Bool
        isEnabled = stored ?? false
        isConfigured = stored != nil
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        isConfigured = true
        defaults.set(isEnabled, forKey: key)
    }

    func preserveActiveContextIfUnconfigured(_ activeContext: String?) {
        guard !isConfigured, activeContext == DockerContext.name else { return }
        setEnabled(true)
    }
}

struct DockerContextPreferenceSequencer {
    private var desiredState: Bool?
    private var isApplying = false

    mutating func request(_ desiredState: Bool) -> Bool? {
        self.desiredState = desiredState
        guard !isApplying else { return nil }
        isApplying = true
        return desiredState
    }

    mutating func completed(_ appliedState: Bool) -> Bool? {
        guard desiredState != appliedState else {
            isApplying = false
            return nil
        }
        return desiredState
    }
}

struct DockerContextRefreshSequencer {
    private var latestGeneration: UInt64 = 0

    mutating func begin() -> UInt64 {
        latestGeneration &+= 1
        return latestGeneration
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        generation == latestGeneration
    }
}

@MainActor
extension RuntimeViewModel {

    var isDockerContextActive: Bool {
        activeDockerContext == DockerContext.name
    }

    var conflictingDockerContext: String? {
        DockerContext.conflictingContext(
            activeContext: activeDockerContext,
            takeoverEnabled: takesOverDockerContext
        )
    }

    var dockerContextEnvironmentConflict: String? {
        DockerCLI.contextEnvironmentConflict(
            activeContext: activeDockerContext,
            isContextInstalled: isDockerContextInstalled
        )
    }

    /// The system socket only earns screen space when it is a live hazard: served by
    /// someone else, so tools that bypass the Docker context reach a different runtime.
    /// A dangling or absent socket is noise — then there is no row at all.
    var systemSocketNotice: String? {
        guard let status = defaultDockerSocketStatus,
            status.isReachable,
            status.target != socketPath
        else { return nil }
        return
            "System socket (/var/run/docker.sock) is served by another runtime; tools that ignore the Docker context use it."
    }

    /// Persisted so the app keeps its promise across launches: either it owns the Docker context
    /// or it never touches the user's client configuration.
    var takesOverDockerContext: Bool {
        get { dockerContextTakeoverPreference.isEnabled }
        set {
            dockerContextTakeoverPreference.setEnabled(newValue)
            guard let initialState = dockerContextPreferenceSequencer.request(newValue) else {
                return
            }
            Task { [weak self] in
                await self?.applyDockerContextPreference(startingWith: initialState)
            }
        }
    }

    func refreshDockerContext(includeInstalledContext: Bool = true) async {
        let generation = dockerContextRefreshSequencer.begin()
        let state = await Task.detached {
            let active = DockerCLI.activeContext()
            let installed: Bool?
            if includeInstalledContext {
                installed = try? DockerCLI.installedContexts().contains(DockerContext.name)
            } else {
                installed = nil
            }
            let defaultSocket = DockerContext.socketStatus(atPath: "/var/run/docker.sock")
            return (active: active, installed: installed, defaultSocket: defaultSocket)
        }.value
        guard dockerContextRefreshSequencer.isCurrent(generation) else { return }
        activeDockerContext = state.active
        dockerContextTakeoverPreference.preserveActiveContextIfUnconfigured(state.active)
        if let installed = state.installed {
            isDockerContextInstalled = installed
        }
        defaultDockerSocketStatus = state.defaultSocket
    }

    /// A missing context is first-run setup. An existing context that is no longer active is a
    /// conflict: silently reclaiming it would undo a choice the user made in another product.
    func adoptDockerContextIfEnabled() async {
        await refreshDockerContext()
        guard
            DockerContext.shouldAdopt(
                activeContext: activeDockerContext,
                installed: isDockerContextInstalled,
                takeoverEnabled: takesOverDockerContext
            )
        else {
            await repairStaleContextRecordIfNeeded()
            return
        }
        guard let initialState = dockerContextPreferenceSequencer.request(true) else { return }
        await applyDockerContextPreference(startingWith: initialState)
    }

    /// `shouldAdopt` deliberately never activates an installed-but-inactive context; this repairs
    /// its record anyway, without ever running `context use`.
    private func repairStaleContextRecordIfNeeded() async {
        guard takesOverDockerContext, isDockerContextInstalled == true,
            activeDockerContext != DockerContext.name
        else { return }
        let currentSocketPath = socketPath
        let recorded = await Task.detached {
            try? DockerCLI.recordedSocketPath(for: DockerContext.name)
        }.value
        guard
            DockerContext.shouldRepairStaleRecord(
                activeContext: activeDockerContext,
                installed: isDockerContextInstalled,
                takeoverEnabled: takesOverDockerContext,
                recordedSocketPath: recorded,
                currentSocketPath: currentSocketPath
            )
        else { return }
        // Shares install/uninstall's mutation slot so the two never write to the context store at
        // the same time; never touches dockerContextPreferenceSequencer itself.
        await acquireDockerContextMutationSlot()
        defer { releaseDockerContextMutationSlot() }
        // Re-checked after the slot is granted: an uninstall could have run first and cleared
        // ownership.
        guard activeDockerContext != DockerContext.name, isDockerContextInstalled == true,
            takesOverDockerContext
        else { return }
        do {
            try await Task.detached { try DockerCLI.repairRecord(socketPath: currentSocketPath) }.value
            serviceMessage =
                "Docker context '\(DockerContext.name)' pointed at a retired socket; repaired the record without switching to it."
        } catch {
            // Best-effort: retried on the next launch, not worth surfacing as an error.
        }
    }

    func useDockerContext() async {
        dockerContextTakeoverPreference.setEnabled(true)
        guard let initialState = dockerContextPreferenceSequencer.request(true) else { return }
        await applyDockerContextPreference(startingWith: initialState)
    }

    /// Grants the slot immediately if free, otherwise queues rather than polls -- a cancelled
    /// waiter simply waits its turn instead of spinning on a repeatedly-thrown cancellation.
    private func acquireDockerContextMutationSlot() async {
        guard isMutatingDockerContext else {
            isMutatingDockerContext = true
            return
        }
        await withCheckedContinuation { dockerContextMutationWaiters.append($0) }
    }

    /// Hands the slot directly to the next waiter instead of clearing it first, so a third caller
    /// cannot slip in between.
    private func releaseDockerContextMutationSlot() {
        guard dockerContextMutationWaiters.isEmpty else {
            dockerContextMutationWaiters.removeFirst().resume()
            return
        }
        isMutatingDockerContext = false
    }

    private func applyDockerContextPreference(startingWith initialState: Bool) async {
        var nextState = initialState
        while true {
            await acquireDockerContextMutationSlot()
            if nextState {
                await installDockerContext()
            } else {
                await uninstallDockerContext()
            }
            releaseDockerContextMutationSlot()
            guard let pendingState = dockerContextPreferenceSequencer.completed(nextState) else { return }
            nextState = pendingState
        }
    }

    private func installDockerContext() async {
        let socketPath = socketPath
        do {
            try await Task.detached { try DockerCLI.installContext(socketPath: socketPath) }.value
            await refreshDockerContext()
            if isDockerContextActive {
                serviceMessage = "Docker context '\(DockerContext.name)' is active."
            } else if let environmentOverride = dockerContextEnvironmentConflict {
                serviceMessage =
                    "Docker context configured. Unset \(environmentOverride) to make it active."
            } else {
                serviceMessage = "Docker context configured, but it is not active."
            }
        } catch {
            serviceMessage = "Docker context not updated: \(error)"
            await refreshDockerContext()
        }
    }

    private func uninstallDockerContext() async {
        do {
            let removed = try await Task.detached { try DockerCLI.uninstallContext() }.value
            serviceMessage =
                removed
                ? "Docker context '\(DockerContext.name)' removed."
                : "Docker context takeover disabled."
        } catch {
            serviceMessage = "Docker context not removed: \(error)"
        }
        await refreshDockerContext()
    }
}
