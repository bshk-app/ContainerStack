import AppKit
import ContainerStackCore
import Darwin
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class RuntimeViewModel {
    static let defaultSocketPath = RuntimeProcessConfiguration.defaultSocketPath

    let client: DockerAPIClient
    @ObservationIgnored var steps: RuntimeSteps
    nonisolated static let launchAgentPlistName = "com.containerstack.runtime.plist"
    private let service = SMAppService.agent(plistName: RuntimeViewModel.launchAgentPlistName)
    var runtimeProcess: Process?
    /// Decides which of Start, Stop and Restart runs (#102). Unobserved, so the Doctor's
    /// `isRestarting` watcher sees only the edges the operations themselves make.
    @ObservationIgnored var lifecycle = RuntimeLifecycleQueue()
    /// Requests waiting behind the running operation, by their queue number.
    @ObservationIgnored var lifecycleTickets: [Int: LifecycleTicket] = [:]
    /// The user's last instruction is a Stop, running or waiting: the only time Stop is disabled.
    internal(set) var isStopping = false
    var runtimeLogHandle: FileHandle?
    @ObservationIgnored var monitorTask: Task<Void, Never>?
    /// `container system status` costs a CLI spawn plus an XPC round trip, so the poll reuses
    /// its last answer between checks instead of asking on every 3s tick.
    private var appRootCadence = DiagnosticCadence(interval: .seconds(30))
    private var lastMissingAppRoot: String?
    /// Same cadence and the same reason: answering "who holds the socket" costs
    /// an `lsof` and a `ps`, which is too much for a 3-second poll.
    private var bridgeOwnerCadence = DiagnosticCadence(interval: .seconds(30))
    private var lastForeignBridge: ForeignBridge?
    /// Weighs consecutive probe answers, so one unanswered ping cannot condemn the runtime.
    /// Internal so a test can seed the silence a stopped runtime accumulates.
    var livenessFilter = RuntimeLivenessFilter()
    var dockerContextPreferenceSequencer = DockerContextPreferenceSequencer()
    var dockerContextRefreshSequencer = DockerContextRefreshSequencer()
    /// Set by the window: only it shows the Docker context, and each read spawns `docker`.
    @ObservationIgnored var isDashboardOpen = false
    @ObservationIgnored var isAdoptingDockerContext = false
    @ObservationIgnored var isDockerContextAdoptionPending = false
    @ObservationIgnored var readDockerContext: @Sendable (Bool) async -> DockerContextReading = {
        RuntimeViewModel.readDockerContextFromCLI(includeInstalledContext: $0)
    }
    /// Held while a Docker context CLI mutation is running; see `acquireDockerContextMutationSlot`.
    var isMutatingDockerContext = false
    /// FIFO queue for callers waiting on `isMutatingDockerContext`.
    var dockerContextMutationWaiters: [CheckedContinuation<Void, Never>] = []
    let dockerContextTakeoverPreference: DockerContextTakeoverPreference
    internal(set) var runtimeFailure: String?
    internal(set) var isRestarting = false
    /// Raised by a stop that lost the XPC connection, consumed by the monitor poll: the poll is the
    /// only place that restarts the runtime, so a failed stop and a probe can never race two
    /// recoveries.
    @ObservationIgnored var runtimeRecoveryRequested = false
    /// One bridge-identity check per launch; see `adoptBridgeIfStale`.
    internal(set) var hasCheckedBridgeIdentity = false
    private(set) var runtimeState: RuntimeState = .unknown
    private(set) var snapshot: RuntimeHealthSnapshot?
    internal(set) var images: [DockerImageSummary] = []
    internal(set) var containers: [DockerContainerSummary] = []
    internal(set) var volumes: [DockerVolumeSummary] = []
    internal(set) var networks: [DockerNetworkSummary] = []
    internal(set) var diskUsage: DockerDiskUsage?
    /// Bumped whenever the inventory is cleared, so a read in flight can tell it was superseded.
    private(set) var inventoryEpoch = 0
    internal(set) var logs: String?
    internal(set) var logsContainerName: String?
    internal(set) var busyResource: String?
    internal(set) var resourceMessage: String?
    internal(set) var volumesErrorMessage: String?
    internal(set) var networksErrorMessage: String?
    private(set) var isLoading = false
    internal(set) var isStarting = false
    internal(set) var isRunningContainer = false
    /// Every container acting at this moment, not "something is acting". Docker
    /// serializes nothing across containers, and a stop can occupy the full
    /// lifecycle timeout, so one slow container must not freeze the others.
    internal(set) var busyContainerIDs: Set<String> = []
    var selectedContainerID: String?

    internal(set) var errorMessage: String?
    internal(set) var imagesErrorMessage: String?
    internal(set) var containersErrorMessage: String?
    /// Image platform, keyed by image id. The outer optional means "not fetched", the inner
    /// means "fetched and the runtime reported nothing".
    var imageDetails: [String: DockerImageDetail?] = [:]
    internal(set) var serviceMessage: String? {
        didSet {
            serviceMessageExpiresAt =
                serviceMessage == nil
                ? nil : clock().addingTimeInterval(Self.serviceMessageLifetime)
        }
    }
    static let serviceMessageLifetime: TimeInterval = 5
    private(set) var serviceMessageExpiresAt: Date?
    /// Seam for the expiry deadline only. `Date()` has microsecond resolution, so two
    /// back-to-back `serviceMessage` assignments can stamp the same instant and make the
    /// deadline look unchanged. Production always uses `Date.init`.
    var clock: () -> Date = Date.init

    internal(set) var containerMessage: String?
    internal(set) var containerOutput: String?
    internal(set) var runtimeMessage: String?
    internal(set) var runtimeLogPath: String?
    internal(set) var activeDockerContext: String?
    internal(set) var isDockerContextInstalled: Bool?
    internal(set) var defaultDockerSocketStatus: DockerSocketStatus?
    /// The registry: stacks the user added by hand. Persisted; the merge below never writes here.
    internal(set) var stacks: [ComposeStack] = []

    /// Compose projects the runtime is holding containers for, read from their labels on every
    /// container refresh. Not persisted — a project is listed for exactly as long as it exists.
    internal(set) var discoveredProjects: [DiscoveredComposeProject] = []

    /// What the Stacks screen shows: the registry plus whatever is actually running. Starting a
    /// project from a terminal used to leave the screen empty while Containers listed its containers.
    var allStacks: [ComposeStack] {
        ComposeProjectDiscovery.merge(registered: stacks, discovered: discoveredProjects)
    }

    /// A stack the registry does not carry: it disappears from the list when its containers do, and
    /// "unregister" has nothing to remove.
    func isDiscovered(_ stack: ComposeStack) -> Bool {
        !stacks.contains { $0.id == stack.id }
    }
    internal(set) var stackStatuses: [UUID: [ComposeServiceStatus]] = [:]
    internal(set) var stackModels: [UUID: ComposeProjectModel] = [:]
    internal(set) var busyStackID: UUID?
    internal(set) var stackMessage: String?
    internal(set) var stacksErrorMessage: String?
    let socketPath: String

    init(
        socketPath: String = RuntimeViewModel.defaultSocketPath,
        startsRuntime: Bool = true,
        dockerContextTakeoverPreference: DockerContextTakeoverPreference = DockerContextTakeoverPreference(),
        client: DockerAPIClient? = nil
    ) {
        self.socketPath = socketPath
        self.dockerContextTakeoverPreference = dockerContextTakeoverPreference
        self.client =
            client
            ?? DockerAPIClient(
                socketPath: socketPath,
                retryPolicy: DockerRetryPolicy(maxAttempts: 3, delay: .milliseconds(250))
            )
        steps = .live(client: self.client)
        guard startsRuntime else { return }
        isStarting = true
        runtimeState = .starting
        let observed = lifecycle.generation
        Task { [weak self] in
            _ = await self?.run(.start, origin: .launch, observed: observed)
        }
    }

    var isHealthy: Bool {
        runtimeState.isHealthy
    }

    /// Whether an action is worth attempting, which is not the same as whether the
    /// API answers: against a bridge from another build every read succeeded while
    /// start and stop hung past 150s.
    var canMutate: Bool {
        runtimeState.allowsMutations
    }

    var statusTitle: String {
        runtimeState.title
    }

    var statusDetail: String? {
        runtimeState.detail
    }

    var launchAgentStatus: String {
        switch service.status {
        case .notRegistered:
            "Not registered — use 'Enable at Login' to start the runtime at login"
        case .enabled:
            "Enabled"
        case .requiresApproval:
            "Requires approval"
        case .notFound:
            // Per Apple, `.notFound` only says the framework "couldn't find this service" —
            // it is not a statement about the bundle. Check the bundle ourselves so a
            // correctly installed app is not reported as broken.
            Self.notFoundStatusDescription(
                plistStaged: Self.launchAgentPlistIsStaged(in: Bundle.main.bundleURL))
        @unknown default:
            "Unknown"
        }
    }

    /// Tells the two `.notFound` situations apart: a plist that launchd does not know yet
    /// is fixed by registering, while a missing plist means this build never staged one.
    nonisolated static func notFoundStatusDescription(plistStaged: Bool) -> String {
        plistStaged
            ? "Not registered — use 'Enable at Login' to start the runtime at login"
            : "Not staged in this build — run the app from an installed bundle"
    }

    nonisolated static func launchAgentPlistIsStaged(in bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let plistURL =
            bundleURL
            .appending(path: "Contents/Library/LaunchAgents/\(launchAgentPlistName)")
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    func registerRuntime() {
        do {
            try service.register()
            serviceMessage = "Runtime LaunchAgent registered."
        } catch {
            serviceMessage = "LaunchAgent registration failed: \(error)"
        }
    }

    func unregisterRuntime() {
        do {
            try service.unregister()
            serviceMessage = "Runtime LaunchAgent disabled."
        } catch {
            serviceMessage = "LaunchAgent removal failed: \(error)"
        }
    }

    func revealRuntimeLog() {
        guard let logURL = try? Self.runtimeLogURL() else {
            serviceMessage = "Runtime log is not available yet."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    func startRuntime() {
        // A helper still running is either one still starting, left alone, or one this app has
        // already given up on, which only Start can clear (#71).
        guard runtimeProcess?.isRunning != true || runtimeFailure != nil else { return }
        let turn = admit(.start, origin: .user)
        Task { _ = await execute(.start, turn) }
    }

    func probeRuntime() async {
        let epoch = inventoryEpoch
        let observed = lifecycle.generation
        let responds: Bool
        let probeError: Error?
        do {
            responds = try await steps.ping()
            probeError = nil
        } catch {
            responds = false
            probeError = error
        }
        let wasHealthy = runtimeState.isHealthy
        let hasGoneQuiet = livenessFilter.recordProbe(responds: responds)

        if responds, runtimeRecoveryRequested {
            runtimeRecoveryRequested = false
        }
        let shouldCheckSystemStatus = RuntimeConnectionRecovery.shouldCheckSystemStatus(
            after: probeError,
            recoveryRequested: runtimeRecoveryRequested
        )
        let apiserverRunning =
            shouldCheckSystemStatus ? await appleContainerSystemIsRunning() : nil
        if apiserverRunning != nil {
            runtimeRecoveryRequested = false
        }

        if RuntimeConnectionRecovery.shouldAttemptRestart(
            apiserverRunning: apiserverRunning,
            hasRuntimeFailure: runtimeFailure != nil
        ) {
            await completeAutomaticRuntimeRecovery(restart: {
                await self.run(.restart(replacingSibling: false), origin: .recovery, observed: observed)
            })
            return
        }

        if responds, !wasHealthy {
            // `responds` predates the system-status await above, so the same staleness applies here.
            guard inventoryEpochIsCurrent(epoch) else { return }
            applyState(socketResponds: true)
            await adoptBridgeIfStale(observed: observed)
            await refresh()
            await adoptDockerContextIfEnabled()
        } else if !responds, wasHealthy {
            // One unanswered probe is not proof: this branch also clears the inventory and bumps
            // the epoch, discarding a refresh in flight. Let the next tick agree first. Silence
            // with a cause does not wait here — the restart above already returned. `responds`/
            // `wasHealthy` predate those awaits too, so the same epoch check applies (#70).
            guard hasGoneQuiet, inventoryEpochIsCurrent(epoch) else { return }
            applyState(socketResponds: false)
            clearInventory()
        } else if responds {
            // Steady state still has to look: the Stacks list is built from container labels and the
            // route check from the networks containers sit on, so polling only the socket left a
            // project started while the app was open invisible until the user navigated away and
            // back, and a network created after launch unchecked. Two calls rather than the full
            // refresh — images, volumes and disk usage feed neither.
            await refreshContainers(epoch: epoch)
            await refreshNetworks(epoch: epoch)
            let unroutable = await unroutablePublishingNetworks()
            let missingAppRoot = await throttledMissingAppRoot()
            // `responds` was read before all of those awaits. If the runtime has been declared dead
            // since, publishing it as responding puts a healthy verdict over the offline state (#43).
            guard inventoryEpochIsCurrent(epoch) else { return }
            applyState(
                socketResponds: true,
                unroutableNetworks: unroutable,
                missingAppRoot: missingAppRoot,
                foreignBridge: throttledForeignBridge()
            )
        } else {
            applyState(socketResponds: false)
        }
    }

    private func appleContainerSystemIsRunning() async -> Bool? {
        let status = await systemStatusOutput()
        return status.isEmpty ? nil : RuntimeStatusParser.isRunning(status)
    }

    /// The poll's view of the app root. Asks the CLI at most once per cadence and reuses the
    /// last answer in between, so a 3s socket poll no longer implies a 3s process spawn.
    ///
    /// Latency is the whole trade: a deleted app root now surfaces within 30s rather than 3s.
    /// Nothing else can see it — with its app root gone the runtime still answers `_ping` with
    /// 200 — but reaching that state takes deliberate damage to the runtime's data directory,
    /// and every user-initiated refresh still asks immediately.
    private func throttledMissingAppRoot() async -> String? {
        if appRootCadence.shouldRun() {
            lastMissingAppRoot = await missingAppRoot()
        }
        return lastMissingAppRoot
    }

    /// The bridge holding the socket when it is not ours, otherwise nil.
    /// Re-asked on the cadence so the banner clears by itself once the other
    /// bridge is gone - the reported case sat there for hours with nothing to see.
    private func throttledForeignBridge() -> ForeignBridge? {
        if bridgeOwnerCadence.shouldRun() {
            lastForeignBridge = currentForeignBridge()
        }
        return lastForeignBridge
    }

    /// Probes now and feeds the same cache, for the same reason `freshMissingAppRoot`
    /// does: a refresh that answered from nothing would clear the banner the poll
    /// had just raised.
    private func freshForeignBridge() -> ForeignBridge? {
        lastForeignBridge = currentForeignBridge()
        bridgeOwnerCadence.recordRun()
        return lastForeignBridge
    }

    /// Probes now and feeds the cache, so the next poll does not revert to a stale answer.
    /// Without sharing the cache, a refresh that raised the banner would have it cleared again
    /// on the following tick — the failure the comment in `refresh(health:)` already warns of.
    private func freshMissingAppRoot() async -> String? {
        lastMissingAppRoot = await missingAppRoot()
        appRootCadence.recordRun()
        return lastMissingAppRoot
    }

    func probeAfterControlChange() async {
        await probeRuntime()
    }

    func clearInventoryForStop() {
        clearInventory()
    }

    func socketRespondsNow() async -> Bool {
        await socketResponds()
    }

    var isAgentRegistered: Bool {
        service.status == .enabled
    }

    func runtimeConfiguration() -> RuntimeProcessConfiguration {
        let helpers = Bundle.main.bundleURL.appending(path: "Contents/Helpers")
        return RuntimeProcessConfiguration.make(
            socktainerPath: helpers.appending(path: "socktainer").path,
            socketPath: socketPath,
            bundledInstallRoot: RuntimeProcessConfiguration.bundledInstallRoot(
                forExecutableAt: Bundle.main.executableURL
            )
        )
    }

    private func clearInventory() {
        inventoryEpoch &+= 1
        snapshot = nil
        images = []
        containers = []
        volumes = []
        networks = []
        diskUsage = nil
        // Derived from containers, so it goes with them: leaving it behind kept running-project rows
        // on the Stacks screen after the runtime stopped, pointing at containers that are gone.
        discoveredProjects = []
        // Same reasoning one level up: a registered stack's status describes containers that are now
        // gone, so the Stacks screen would keep showing Running for a runtime that is not there.
        // `stackModels` stays — it is read from compose files, not from the runtime.
        stackStatuses.removeAll()
    }

    /// Whether an inventory read started under `epoch` may still be published.
    ///
    /// Every refresh reads across an await, so the runtime can fail and the inventory be cleared
    /// while the call is in flight. Writing the result back then resurrects rows describing a dead
    /// runtime, and nothing cleans up after: the model is already offline, so the poll's
    /// `!responds, wasHealthy` branch never fires again (#43).
    func inventoryEpochIsCurrent(_ epoch: Int) -> Bool {
        epoch == inventoryEpoch
    }

    /// A read in flight for an operation that has just been superseded must publish nothing (#102).
    func supersedeInventoryReads() {
        inventoryEpoch &+= 1
    }

    private func socketResponds() async -> Bool {
        (try? await steps.ping()) ?? false
    }

    func applyState(
        socketResponds: Bool,
        unroutableNetworks: [UnroutableNetwork] = [],
        missingAppRoot: String? = nil,
        foreignBridge: ForeignBridge? = nil
    ) {
        runtimeState = RuntimeState.resolve(
            socketResponds: socketResponds,
            helperRunning: runtimeProcess?.isRunning == true,
            isStarting: isStarting,
            failure: runtimeFailure,
            unroutableNetworks: unroutableNetworks,
            missingAppRoot: socketResponds ? missingAppRoot : nil,
            foreignBridge: socketResponds ? foreignBridge : nil
        )

        if socketResponds {
            runtimeFailure = nil
            errorMessage = nil
            // Every healthy verdict lands here, including the ones that never probe. Without this
            // the silence counted while the runtime was stopped survives the restart, and the
            // first dropped connection after it clears the inventory on a single sample.
            livenessFilter.reset()
        }
    }

    /// Declaring the runtime failed is also declaring its inventory stale: every caller here has
    /// established the socket is gone, so the containers, images and volumes last read describe a
    /// runtime that no longer exists. The poll cannot clean up afterwards — `applyState` below
    /// publishes the offline state, so the probe's `!responds, wasHealthy` branch never fires (#39).
    func failRuntime(_ reason: String) {
        runtimeFailure = reason
        runtimeMessage = reason
        errorMessage = reason
        clearInventory()
        applyState(socketResponds: false)
    }

    /// A recovery that failed while the runtime was still coming up must not stay `.starting`:
    /// `RuntimeState.resolve` reports `.starting` for as long as `isStarting` holds, and
    /// `.starting` is also what disables the manual restart — so the app would show progress
    /// forever and offer no way out.
    func endStartupAfterFailedRecovery() {
        isStarting = false
        applyState(socketResponds: false)
    }

    func refresh() async {
        await refresh(health: { try await client.health() })
    }

    func refresh(health: () async throws -> RuntimeHealthSnapshot) async {
        let epoch = inventoryEpoch
        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await health()
            // The runtime can die while health is in flight. Publishing then would put a healthy
            // state and a fresh snapshot back over the cleared inventory, which nothing undoes.
            guard inventoryEpochIsCurrent(epoch) else { return }
            snapshot = fetched
            runtimeFailure = nil
            // Supplied here as well as in the poll: a full refresh that left it out would clear the
            // banner it had just raised and put it back on the next tick.
            let missingAppRoot = await freshMissingAppRoot()
            // Re-checked, because the line above is another await: publishing `socketResponds: true`
            // after the runtime died would overwrite the offline state with a healthy verdict, which
            // is worse than stale rows and equally permanent.
            guard inventoryEpochIsCurrent(epoch) else { return }
            applyState(
                socketResponds: true,
                missingAppRoot: missingAppRoot,
                foreignBridge: freshForeignBridge()
            )
            // One epoch for every list: each fetch capturing its own let a supersede during the
            // images fetch discard images and still publish the containers fetched after it (#102).
            await refreshImages(epoch: epoch)
            await refreshContainers(epoch: epoch)
            await refreshVolumes(epoch: epoch)
            await refreshNetworks(epoch: epoch)
            await refreshDiskUsage(epoch: epoch)
        } catch is CancellationError {
            return
        } catch {
            // Same hazard as the try path above (#70).
            guard inventoryEpochIsCurrent(epoch) else { return }
            clearInventory()
            // clearInventory() bumped the epoch; re-read it as the new baseline below.
            let epochAfterClear = inventoryEpoch
            imagesErrorMessage = nil
            containersErrorMessage = nil
            volumesErrorMessage = nil
            networksErrorMessage = nil
            if !isStarting {
                runtimeFailure = userFacingError(error)
                errorMessage = runtimeFailure
            }
            // `health()` is exactly what fails when the runtime's storage is gone, so this is the path
            // that state arrives on. Without the probe here the refresh reported the socket as not
            // responding while the poll reported the missing storage, and the two took turns.
            let missingAppRoot = await freshMissingAppRoot()
            // Re-checked against the post-clear baseline (#70).
            guard inventoryEpochIsCurrent(epochAfterClear) else { return }
            applyState(socketResponds: false, missingAppRoot: missingAppRoot)
        }
    }
}
