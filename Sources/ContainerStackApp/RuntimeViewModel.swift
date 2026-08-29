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
    nonisolated static let launchAgentPlistName = "com.containerstack.runtime.plist"
    private let service = SMAppService.agent(plistName: RuntimeViewModel.launchAgentPlistName)
    private var runtimeProcess: Process?
    private var runtimeLogHandle: FileHandle?
    private var monitorTask: Task<Void, Never>?
    /// `container system status` costs a CLI spawn plus an XPC round trip, so the poll reuses
    /// its last answer between checks instead of asking on every 3s tick.
    private var appRootCadence = DiagnosticCadence(interval: .seconds(30))
    private var lastMissingAppRoot: String?
    /// Same cadence and the same reason: answering "who holds the socket" costs
    /// an `lsof` and a `ps`, which is too much for a 3-second poll.
    private var bridgeOwnerCadence = DiagnosticCadence(interval: .seconds(30))
    private var lastForeignBridge: String?
    var dockerContextPreferenceSequencer = DockerContextPreferenceSequencer()
    var dockerContextRefreshSequencer = DockerContextRefreshSequencer()
    let dockerContextTakeoverPreference = DockerContextTakeoverPreference()
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

    private(set) var errorMessage: String?
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
    private(set) var runtimeLogPath: String?
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
        startsRuntime: Bool = true
    ) {
        self.socketPath = socketPath
        client = DockerAPIClient(
            socketPath: socketPath,
            retryPolicy: DockerRetryPolicy(maxAttempts: 3, delay: .milliseconds(250))
        )
        guard startsRuntime else { return }
        isStarting = true
        runtimeState = .starting
        Task { [weak self] in
            self?.startRuntime()
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
        guard let logURL = try? runtimeLogURL() else {
            serviceMessage = "Runtime log is not available yet."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    func startRuntime() {
        guard runtimeProcess?.isRunning != true else {
            return
        }

        isStarting = true
        // Cleared as the attempt begins, matching the launch path and the manual restart: now that an
        // explicit failure outranks `.starting`, a leftover reason would surface as offline here.
        runtimeFailure = nil
        applyState(socketResponds: false)

        Task { [weak self] in
            await self?.startRuntimeIfSocketIsDown()
        }
    }

    /// Polls the Docker socket so the UI tracks the runtime even when the helper is not ours:
    /// another ContainerStack instance, a LaunchAgent or a manually started bridge all count.
    func startMonitoring(interval: Duration = .seconds(3)) {
        guard monitorTask == nil else { return }

        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeRuntime()
                await self?.refreshDockerContext(includeInstalledContext: false)
                self?.expireServiceMessage()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func expireServiceMessage(now: Date = Date()) {
        guard serviceMessage != nil, let serviceMessageExpiresAt, now >= serviceMessageExpiresAt
        else { return }
        serviceMessage = nil
    }

    private func startRuntimeIfSocketIsDown() async {
        if await socketResponds() {
            runtimeFailure = nil
            runtimeMessage = "Adopted the Docker socket already serving this machine."
            isStarting = false
            applyState(socketResponds: true)
            // Adopting a socket is exactly when to ask whose bridge it is: this path marks the
            // runtime healthy before the first probe, so the probe's transition branch never fires.
            await adoptBridgeIfStale()
            await refresh()
            return
        }

        launchRuntimeHelper()
    }

    private func launchRuntimeHelper() {
        let launchPlan = RuntimeLaunchPlan(appBundleURL: Bundle.main.bundleURL)
        guard FileManager.default.isExecutableFile(atPath: launchPlan.executablePath) else {
            isStarting = false
            failRuntime("Runtime helper is missing: \(launchPlan.executablePath)")
            return
        }

        do {
            let logURL = try runtimeLogURL()
            let logHandle = try FileHandle(forWritingTo: logURL)
            try logHandle.seekToEnd()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPlan.executablePath)
            process.arguments = launchPlan.arguments
            process.standardOutput = logHandle
            process.standardError = logHandle
            try process.run()

            runtimeProcess = process
            runtimeLogHandle = logHandle
            runtimeLogPath = logURL.path
            isStarting = true
            runtimeFailure = nil
            errorMessage = nil
            runtimeMessage = "Starting Apple Container and Docker bridge…"
            applyState(socketResponds: false)

            Task { [weak self] in
                await self?.waitForRuntime()
            }
        } catch {
            isStarting = false
            failRuntime("Runtime could not start: \(error)")
        }
    }

    private func probeRuntime() async {
        let responds: Bool
        let probeError: Error?
        do {
            responds = try await client.ping()
            probeError = nil
        } catch {
            responds = false
            probeError = error
        }
        let wasHealthy = runtimeState.isHealthy

        if responds, runtimeRecoveryRequested {
            runtimeRecoveryRequested = false
            containerMessage = "Container stop timed out; runtime remains available."
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
            isStarting: isStarting,
            isRestarting: isRestarting,
            hasRuntimeFailure: runtimeFailure != nil
        ) {
            runtimeMessage = "Apple Container API server stopped. Restarting runtime…"
            await completeAutomaticRuntimeRecovery(restart: { await self.restartRuntime() })
            return
        }

        if responds, !wasHealthy {
            applyState(socketResponds: true)
            await adoptBridgeIfStale()
            await refresh()
            await adoptDockerContextIfEnabled()
        } else if !responds, wasHealthy {
            applyState(socketResponds: false)
            clearInventory()
        } else if responds {
            // Steady state still has to look: the Stacks list is built from container labels and the
            // route check from the networks containers sit on, so polling only the socket left a
            // project started while the app was open invisible until the user navigated away and
            // back, and a network created after launch unchecked. Two calls rather than the full
            // refresh — images, volumes and disk usage feed neither.
            await refreshContainers()
            await refreshNetworks()
            applyState(
                socketResponds: true,
                unroutableNetworks: await unroutablePublishingNetworks(),
                missingAppRoot: await throttledMissingAppRoot(),
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

    /// The socket path when a bridge that is not ours holds it, otherwise nil.
    /// Re-asked on the cadence so the banner clears by itself once the other
    /// bridge is gone - the reported case sat there for hours with nothing to see.
    private func throttledForeignBridge() -> String? {
        if bridgeOwnerCadence.shouldRun() {
            lastForeignBridge = servesOurBridge() ? nil : socketPath
        }
        return lastForeignBridge
    }

    /// Probes now and feeds the same cache, for the same reason `freshMissingAppRoot`
    /// does: a refresh that answered from nothing would clear the banner the poll
    /// had just raised.
    private func freshForeignBridge() -> String? {
        lastForeignBridge = servesOurBridge() ? nil : socketPath
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

    func launchRuntimeHelperForRestart() {
        launchRuntimeHelper()
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
        snapshot = nil
        images = []
        containers = []
        volumes = []
        networks = []
        diskUsage = nil
        // Derived from containers, so it goes with them: leaving it behind kept running-project rows
        // on the Stacks screen after the runtime stopped, pointing at containers that are gone.
        discoveredProjects = []
    }

    private func socketResponds() async -> Bool {
        (try? await client.ping()) ?? false
    }

    func applyState(
        socketResponds: Bool,
        unroutableNetworks: [UnroutableNetwork] = [],
        missingAppRoot: String? = nil,
        foreignBridge: String? = nil
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
        isLoading = true
        defer { isLoading = false }

        do {
            snapshot = try await health()
            runtimeFailure = nil
            // Supplied here as well as in the poll: a full refresh that left it out would clear the
            // banner it had just raised and put it back on the next tick.
            applyState(
                socketResponds: true,
                missingAppRoot: await freshMissingAppRoot(),
                foreignBridge: freshForeignBridge()
            )
            await refreshImages()
            await refreshContainers()
            await refreshVolumes()
            await refreshNetworks()
            await refreshDiskUsage()
        } catch is CancellationError {
            return
        } catch {
            clearInventory()
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
            applyState(socketResponds: false, missingAppRoot: await freshMissingAppRoot())
        }
    }

    private func waitForRuntime() async {
        defer {
            isStarting = false
            applyState(socketResponds: runtimeState.isHealthy)
        }

        for attempt in 1...60 {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            if await socketResponds() {
                runtimeFailure = nil
                runtimeMessage = "Runtime ready."
                applyState(socketResponds: true)
                // This app launched this bridge, so its identity is known exactly. Recording it here
                // is what stops the next launch from mistaking a current bridge for a foreign one.
                recordBridgeIdentity()
                hasCheckedBridgeIdentity = true
                await refresh()
                return
            }

            guard runtimeProcess?.isRunning == true else {
                failRuntime("Runtime helper exited. Check \(runtimeLogPath ?? "the runtime log").")
                return
            }

            runtimeMessage = "Waiting for Docker socket… (\(attempt)/60)"
        }

        failRuntime("Docker socket did not become ready within 60 seconds.")
    }

    private func runtimeLogURL() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/ContainerStack")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appending(path: "runtime.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        return logURL
    }

    private func userFacingError(_ error: Error) -> String {
        guard let socketError = error as? UnixSocketError else {
            return String(describing: error)
        }

        switch socketError {
        case .pathTooLong:
            return "Docker socket path is too long: \(socketPath)"
        case .timedOut:
            return "Timed out connecting to Docker socket: \(socketPath)"
        case .systemCallFailed(let code):
            return
                "Docker socket error \(code): \(Darwin.strerror(code).map { String(cString: $0) } ?? "unknown error")"
        }
    }
}
