import Foundation

/// Assembles a `DiagnosticReport` over the Docker API and the external commands
/// a Docker call cannot answer. Prints nothing and touches no view state.
public struct DiagnosticRunner: Sendable {
    private let client: DockerAPIClient
    private let probe: any SystemProbe
    private let socketPath: String
    /// Which bridge counts as ours: `lsof` names the pid holding the socket, and only
    /// the process table can say whether that pid is the helper this build ships.
    private let bridgePath: String
    /// Asked for at run time rather than captured, so a runner that outlives a change to the
    /// takeover preference judges the record against the preference as it now stands.
    private let dockerContextSetting: @Sendable () async -> DockerContextSetting?
    /// The read the repair makes before it writes. Injected because its command runner is the
    /// one place a test can see every `docker` command the check spawned.
    private let recordedSocketPath: @Sendable (String) throws -> String?
    /// Injected so the "host memory unknown" branch is reachable in a test; nil is the
    /// sysctl's own answer when it could not be read, never a guess.
    private let hostMemoryBytes: @Sendable () -> Int64?
    /// Injected so `ranAt` is assertable; a report never stamps itself from `Date()`.
    private let now: @Sendable () -> Date
    /// Monotonic and separate from `now`: a wall clock adjusted mid-run would report a check
    /// as having taken a negative time. Injected so a duration is assertable without waiting.
    private let ticks: @Sendable () -> Duration
    /// NFR-005's one line per run. Injected so what it says is assertable.
    private let log: @Sendable (String) -> Void
    /// The whole run's budget, not one probe's. Injected so a test can expire it without
    /// waiting for it; the clock above stamps a report and schedules nothing.
    private let budget: Duration

    /// NFR-002: four probes at `ProcessRunner.diagnosticTimeout` (10s) are 40s in sequence,
    /// so a per-probe bound is no bound at all.
    public static let defaultBudget: Duration = .seconds(20)

    /// The inputs of `DockerContext.shouldRepairStaleRecord` a report cannot measure: the takeover
    /// preference is the app's, and asking `docker context show` would be a sixth spawn (NFR-001).
    public struct DockerContextSetting: Equatable, Sendable {
        public let takeoverEnabled: Bool
        public let installed: Bool?
        public let activeContext: String?

        public init(takeoverEnabled: Bool, installed: Bool?, activeContext: String?) {
            self.takeoverEnabled = takeoverEnabled
            self.installed = installed
            self.activeContext = activeContext
        }
    }

    public init(
        client: DockerAPIClient,
        probe: any SystemProbe,
        socketPath: String,
        bridgePath: String,
        dockerContextSetting: @escaping @Sendable () async -> DockerContextSetting? = { nil },
        recordedSocketPath: @escaping @Sendable (String) throws -> String? = {
            try DockerCLI.recordedSocketPath(for: $0)
        },
        hostMemoryBytes: @escaping @Sendable () -> Int64? = HostMemory.totalBytes,
        now: @escaping @Sendable () -> Date = Date.init,
        ticks: @escaping @Sendable () -> Duration = MonotonicTicks.sinceStart,
        log: @escaping @Sendable (String) -> Void = DiagnosticLog.line,
        budget: Duration = DiagnosticRunner.defaultBudget
    ) {
        self.client = client
        self.probe = probe
        self.socketPath = socketPath
        self.bridgePath = bridgePath
        self.dockerContextSetting = dockerContextSetting
        self.recordedSocketPath = recordedSocketPath
        self.hostMemoryBytes = hostMemoryBytes
        self.now = now
        self.ticks = ticks
        self.log = log
        self.budget = budget
    }

    /// Answers every requested id and only those: a check that was not run is
    /// `.skipped` with no remedy, never dropped from the report.
    public func run(checks: Set<CheckID>) async -> DiagnosticReport {
        let ordered = CheckID.allCases.filter(checks.contains)
        let signals = await signals(for: checks)
        let report = DiagnosticReport(checks: ordered.map { Self.project(signals, onto: $0) }, ranAt: now())
        logUnmeasured(report)
        return report
    }

    /// NFR-005: one line per run naming what could not be measured, so an incident has the
    /// names and their cost without the report in hand.
    private func logUnmeasured(_ report: DiagnosticReport) {
        let unmeasured = report.checks.filter { $0.verdict == .indeterminate }
        guard !unmeasured.isEmpty else { return }
        let named = unmeasured.map { "\($0.id.rawValue) after \($0.duration)" }.joined(separator: ", ")
        log("Diagnostic run could not measure: \(named)")
    }

    /// What `resolve` ranked, plus the things it cannot express: that a check was attempted
    /// and could not be measured.
    struct Signals {
        let state: RuntimeState
        let appRoot: AppRootMeasurement
        let socket: SocketMeasurement
        let versions: VersionsMeasurement
        let routes: RoutesMeasurement
        let bridge: BridgeMeasurement
        let memory: MemoryMeasurement
        let context: ContextMeasurement
        let durations: [CheckID: Duration]

        /// Zero for a check nothing measured: a skipped check spent nothing, which is not an
        /// unfinished measurement.
        func duration(of id: CheckID) -> Duration { durations[id] ?? .zero }
    }

    /// Each measurement is nil until it answers. The budget reads this once and builds the
    /// report from that copy, so an answer arriving afterwards has nothing left to change.
    private struct Partial {
        var socket: SocketMeasurement?
        var versions: VersionsMeasurement?
        var appRoot: AppRootMeasurement?
        var bridge: BridgeMeasurement?
        var routes: RoutesMeasurement?
        var memory: MemoryMeasurement?
        var context: ContextMeasurement?
        var durations: [CheckID: Duration] = [:]

        /// The checks no branch answered: the gather was abandoned before it reached them,
        /// which is the only way a measurement stays nil.
        var unanswered: [CheckID] {
            var ids: [CheckID] = []
            if socket == nil { ids.append(.socket) }
            if versions == nil { ids.append(.versions) }
            if appRoot == nil { ids.append(.appRoot) }
            if bridge == nil { ids.append(.foreignBridge) }
            if routes == nil { ids.append(.routes) }
            if memory == nil { ids.append(.memoryCommitment) }
            if context == nil { ids.append(.dockerContext) }
            return ids
        }
    }

    /// Serialises the writes of the concurrent branches and hands out one snapshot.
    private actor Measurements {
        private var partial = Partial()

        var taken: Partial { partial }

        func socket(_ value: SocketMeasurement, took: Duration) {
            partial.socket = value
            partial.durations[.socket] = took
        }

        func versions(_ value: VersionsMeasurement, took: Duration) {
            partial.versions = value
            partial.durations[.versions] = took
        }

        func appRoot(_ value: AppRootMeasurement, took: Duration) {
            partial.appRoot = value
            partial.durations[.appRoot] = took
        }

        func bridge(_ value: BridgeMeasurement, took: Duration) {
            partial.bridge = value
            partial.durations[.foreignBridge] = took
        }

        func routes(_ value: RoutesMeasurement, took: Duration) {
            partial.routes = value
            partial.durations[.routes] = took
        }

        func memory(_ value: MemoryMeasurement, took: Duration) {
            partial.memory = value
            partial.durations[.memoryCommitment] = took
        }

        func context(_ value: ContextMeasurement, took: Duration) {
            partial.context = value
            partial.durations[.dockerContext] = took
        }
    }

    /// Resumes its one waiter exactly once, whichever of the gathering and the budget gets
    /// here first, so a run can never publish two reports.
    private actor CompletionGate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var hasSignalled = false

        func signal() {
            guard !hasSignalled else { return }
            hasSignalled = true
            waiter?.resume()
            waiter = nil
        }

        func wait() async {
            guard !hasSignalled else { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }

    /// A refused socket and one that never answered both resolve to `.offline`, and F-010 needs
    /// them apart. Only the transport knows which happened, so the split is made here.
    enum SocketMeasurement {
        case responds
        case silent(reason: String?)
        case unmeasurable(reason: String)

        var responds: Bool {
            if case .responds = self { return true }
            return false
        }

        /// What `resolve` takes as `failure`: a timeout is still a reason the socket gave no answer.
        var failure: String? {
            switch self {
            case .responds: return nil
            case .silent(let reason): return reason
            case .unmeasurable(let reason): return reason
            }
        }
    }

    enum VersionsMeasurement {
        case measured(version: DockerVersion, info: DockerInfo)
        case unmeasurable(reason: String)
    }

    /// Three-valued because two values is the bug: `nil` from a probe that never ran is
    /// read as "no missing root", which is a healthy runtime (F-009).
    enum AppRootMeasurement {
        case missing(String)
        /// Carries the root the status named, which is the line the CLI prints at
        /// `CStackCommands.swift:38`; nil when the status named none.
        case intact(root: String?)
        case unmeasurable(reason: String)

        /// Only a root the probe actually reported: `resolve` ranks states, and a
        /// measurement failure is not one of them.
        var missingRoot: String? {
            if case .missing(let root) = self { return root }
            return nil
        }
    }

    /// "Nothing publishes", "could not tell" and "unroutable" are three answers, and merging
    /// any two of them is the defect this split exists to keep out (#45).
    enum RoutesMeasurement {
        case notAsked
        case nothingToCheck(summary: String)
        /// `uncheckable` rides along rather than replacing the verdict: the CLI prints `:81`
        /// after `:67`, so a network nobody can judge does not unsay the ones that were judged.
        case reachable([UnroutableNetwork], uncheckable: [String])
        case unroutable([UnroutableNetwork])
        case unmeasurable(summary: String, reason: String)

        /// Only networks a readable routing table condemned: a check that could not run
        /// gives `resolve` nothing to rank.
        var unroutableNetworks: [UnroutableNetwork] {
            if case .unroutable(let networks) = self { return networks }
            return []
        }
    }

    /// Four answers because the two that matter are the ones a boolean loses: a probe that
    /// could not run, and a holder nobody could see, are neither ours nor foreign.
    enum BridgeMeasurement {
        case notAsked
        case ours
        case foreign(socketPath: String)
        case unseenHolder
        case unmeasurable(reason: String)

        /// Only a bridge the probes named: `resolve` ranks ownership it was told about,
        /// and an unreadable probe tells it nothing.
        var foreignSocketPath: String? {
            if case .foreign(let socketPath) = self { return socketPath }
            return nil
        }
    }

    /// One container listing serves both the routes and memory checks: NFR-001 budgets a
    /// single `listContainers` for the run, however many checks want it.
    private enum ContainersMeasurement {
        case notAsked
        case listed([DockerContainerSummary])
        case unmeasurable(reason: String)
    }

    /// An inspect that failed is kept apart from a limit the runtime reported as absent: the
    /// first makes the total incomplete, the second is a container the total never covered.
    enum MemoryMeasurement {
        case notAsked
        case nothingRunning
        case noneInspected(failures: Int)
        case inspected(MemoryCommitment, failures: Int)
        case unmeasurable(reason: String)
    }

    /// Judged by the rule the repair acts on, so Doctor offers `.repairDockerContext` exactly
    /// when `repairDockerContextRecord()` would rewrite something.
    enum ContextMeasurement {
        case notAsked
        case nothingToRepair
        case stale(recorded: String, current: String)
        case unmeasurable(reason: String)
    }

    /// Abandoned rather than cancelled: `ProcessRunner.run` blocks on a semaphore no
    /// cancellation reaches, so the budget stops waiting and never stops the probe.
    private func signals(for checks: Set<CheckID>) async -> Signals {
        let measurements = Measurements()
        let gate = CompletionGate()
        let started = ticks()
        _ = Task {
            await gather(checks: checks, into: measurements)
            await gate.signal()
        }
        let expiry = Task {
            try? await Task.sleep(for: budget)
            await gate.signal()
        }
        await gate.wait()
        expiry.cancel()
        return resolved(await measurements.taken, abandonedAfter: ticks() - started)
    }

    /// What one check's own measurement cost, not its share of the run: the branches overlap,
    /// so these never sum to the run's elapsed time.
    private func timed<T>(_ work: () async -> T) async -> (value: T, elapsed: Duration) {
        let started = ticks()
        let value = await work()
        return (value, ticks() - started)
    }

    /// The groups that share no input. Concurrent with each other and sequential
    /// inside, so the request order NFR-001 pins is the order one socket still sees.
    private func gather(checks: Set<CheckID>, into measurements: Measurements) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.gatherOverTheAPI(checks: checks, into: measurements) }
            group.addTask {
                let appRoot = await self.timed { () async -> AppRootMeasurement in
                    checks.contains(.appRoot) ? await self.appRootMeasurement() : .intact(root: nil)
                }
                await measurements.appRoot(appRoot.value, took: appRoot.elapsed)
            }
            group.addTask {
                let bridge = await self.timed { () async -> BridgeMeasurement in
                    checks.contains(.foreignBridge) ? await self.bridgeOwnership() : .notAsked
                }
                await measurements.bridge(bridge.value, took: bridge.elapsed)
            }
            group.addTask {
                let context = await self.timed { () async -> ContextMeasurement in
                    checks.contains(.dockerContext) ? await self.contextMeasurement() : .notAsked
                }
                await measurements.context(context.value, took: context.elapsed)
            }
        }
    }

    private func gatherOverTheAPI(checks: Set<CheckID>, into measurements: Measurements) async {
        let socket = await timed { await socketMeasurement() }
        await measurements.socket(socket.value, took: socket.elapsed)
        let versions = await timed { () async -> VersionsMeasurement in
            socket.value.responds && checks.contains(.versions)
                ? await versionsMeasurement()
                : .unmeasurable(reason: socket.value.failure ?? RuntimeState.genericFailure)
        }
        await measurements.versions(versions.value, took: versions.elapsed)
        // Every route signal arrives over the socket, so asking a dead one buys nothing but
        // more waiting inside the same budget (NFR-002).
        let wantsContainers = checks.contains(.routes) || checks.contains(.memoryCommitment)
        let containers = await timed { () async -> ContainersMeasurement in
            socket.value.responds && wantsContainers ? await containersMeasurement() : .notAsked
        }
        let routes = await timed { () async -> RoutesMeasurement in
            socket.value.responds && checks.contains(.routes)
                ? await routesMeasurement(containers.value)
                : .notAsked
        }
        // The one listing NFR-001 budgets is charged to both checks that waited on it, which is
        // the other reason these durations do not sum to the run's.
        await measurements.routes(routes.value, took: containers.elapsed + routes.elapsed)
        let memory = await timed { () async -> MemoryMeasurement in
            socket.value.responds && checks.contains(.memoryCommitment)
                ? await memoryMeasurement(containers.value)
                : .notAsked
        }
        await measurements.memory(memory.value, took: containers.elapsed + memory.elapsed)
    }

    /// Calls `RuntimeState.resolve` once. Which failure outranks which is decided there and
    /// nowhere else, so nothing here compares two.
    private func resolved(_ partial: Partial, abandonedAfter: Duration) -> Signals {
        let socket = partial.socket ?? .unmeasurable(reason: Self.budgetExpired)
        let appRoot = partial.appRoot ?? .unmeasurable(reason: Self.budgetExpired)
        let routes = partial.routes ?? .unmeasurable(summary: Self.unfinishedRoutes, reason: Self.budgetExpired)
        let bridge = partial.bridge ?? .unmeasurable(reason: Self.budgetExpired)
        let state = RuntimeState.resolve(
            socketResponds: socket.responds,
            // Means "a helper this caller launched", as it does in the app. A report launches
            // nothing, so a bridge started by launchd is `.offline`, never `.starting` (#44).
            helperRunning: false,
            isStarting: false,
            failure: socket.failure,
            unroutableNetworks: routes.unroutableNetworks,
            // Gated exactly as `RuntimeViewModel.applyState` gates them, so both callers hand
            // `resolve` the same inputs. The app's call convention, not a second ranking.
            missingAppRoot: socket.responds ? appRoot.missingRoot : nil,
            foreignBridge: socket.responds ? bridge.foreignSocketPath : nil
        )
        var durations = partial.durations
        // A check that never answered carries the budget it burned, which no finished
        // measurement can be read as and `.zero` would be indistinguishable from instant.
        for id in partial.unanswered { durations[id] = abandonedAfter }
        return Signals(
            state: state,
            appRoot: appRoot,
            socket: socket,
            versions: partial.versions ?? .unmeasurable(reason: Self.budgetExpired),
            routes: routes,
            bridge: bridge,
            memory: partial.memory ?? .unmeasurable(reason: Self.budgetExpired),
            context: partial.context ?? .unmeasurable(reason: Self.budgetExpired),
            durations: durations
        )
    }

    static let budgetExpired = "The run's time budget expired before this check answered."
    private static let unfinishedRoutes = "Container routes: UNKNOWN — the check did not finish in time."
    private static let contextSettingUnknown =
        "The app did not say whether ContainerStack manages the Docker context."
    private static let noRecordedSocket =
        "docker context ls named no unix socket for \(DockerContext.name), so its record could not be compared."
    private static let installationUnknown =
        "The app has not yet read whether the \(DockerContext.name) context is installed."

    /// Reads and never writes (decision 8): the listing is the repair's own first step, and
    /// nothing here reaches its second.
    private func contextMeasurement() async -> ContextMeasurement {
        guard let setting = await dockerContextSetting() else {
            return .unmeasurable(reason: Self.contextSettingUnknown)
        }
        let recorded: String?
        do {
            recorded = try await Self.offTheCooperativePool { [recordedSocketPath] in
                try recordedSocketPath(DockerContext.name)
            }
        } catch {
            // Not `localizedDescription`: neither `DockerCLIError` nor `ProcessRunnerError` is a
            // `LocalizedError`, so that would be Foundation's bridge text (T-016b).
            return .unmeasurable(reason: String(describing: error))
        }
        if let recorded, isStale(setting, installed: setting.installed, recorded: recorded) {
            return .stale(recorded: recorded, current: socketPath)
        }
        // The rule reads `nil` as "decline" for both of these unknowns. Asked again with them assumed
        // stale (a NUL ends no path, so it matches no socket), it says whether it answered or missed.
        let couldBeStale = isStale(
            setting,
            installed: setting.installed ?? true,
            recorded: recorded ?? socketPath + "\u{0}"
        )
        guard couldBeStale else { return .nothingToRepair }
        return .unmeasurable(reason: recorded == nil ? Self.noRecordedSocket : Self.installationUnknown)
    }

    private func isStale(_ setting: DockerContextSetting, installed: Bool?, recorded: String?) -> Bool {
        DockerContext.shouldRepairStaleRecord(
            activeContext: setting.activeContext,
            installed: installed,
            takeoverEnabled: setting.takeoverEnabled,
            recordedSocketPath: recorded,
            currentSocketPath: socketPath
        )
    }

    /// `ProcessRunner.run` holds its thread until the child exits. On the cooperative pool that can
    /// be the thread the budget's timer needs, and the run outlasts its own deadline (NFR-002).
    private static func offTheCooperativePool<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// `ping` retries only what costs a syscall to re-ask (`DockerAPIClient.failsImmediately`), so
    /// a hang is reported after one wait rather than three (NFR-002).
    private func socketMeasurement() async -> SocketMeasurement {
        do {
            return try await client.ping() ? .responds : .silent(reason: nil)
        } catch UnixSocketError.timedOut {
            return .unmeasurable(reason: UnixSocketError.timedOut.localizedDescription)
        } catch {
            return .silent(reason: error.localizedDescription)
        }
    }

    /// Not `health()`: that asks three times through the general policy, which retries `.timedOut`
    /// — ~46s against a wedged socket, inside a 20s budget (NFR-002).
    private func versionsMeasurement() async -> VersionsMeasurement {
        do {
            let version = try await client.decode(
                DockerVersion.self,
                response: client.requestRetryingImmediateFailures(path: "/version")
            )
            let info = try await client.decode(
                DockerInfo.self,
                response: client.requestRetryingImmediateFailures(path: "/info")
            )
            return .measured(version: version, info: info)
        } catch {
            return .unmeasurable(reason: error.localizedDescription)
        }
    }

    /// Empty output is still a measurement — the parser looked and found no missing root.
    /// A probe that could not run is not, and the two never collapse into one answer.
    private func appRootMeasurement() async -> AppRootMeasurement {
        switch await probe.runtimeStatus() {
        case .output(let status):
            guard let root = RuntimeStatusParser.missingAppRoot(status) else {
                return .intact(root: RuntimeStatusParser.appRoot(status))
            }
            return .missing(root)
        case .failed(let reason):
            return .unmeasurable(reason: reason)
        }
    }

    /// A listing that never arrived is not an empty machine, so the failure is carried rather
    /// than laundered into `[]` (F-009).
    private func containersMeasurement() async -> ContainersMeasurement {
        do {
            return .listed(
                try await client.decode(
                    [DockerContainerSummary].self,
                    response: client.requestRetryingImmediateFailures(path: "/containers/json")
                )
            )
        } catch {
            return .unmeasurable(reason: error.localizedDescription)
        }
    }

    /// Two independent ways to fail to measure — the Docker call and `netstat` — and neither may
    /// arrive as an empty answer, which reads as "no route needed" (F-009, #45).
    private func routesMeasurement(_ listing: ContainersMeasurement) async -> RoutesMeasurement {
        let containers: [DockerContainerSummary]
        switch listing {
        case .notAsked:
            return .notAsked
        case .unmeasurable(let reason):
            return .unmeasurable(summary: Self.unlistedNetworks, reason: reason)
        case .listed(let listed):
            containers = listed
        }

        let networks: [DockerNetworkSummary]
        do {
            networks = try await client.decode(
                [DockerNetworkSummary].self,
                response: client.requestRetryingImmediateFailures(path: "/networks")
            )
        } catch {
            return .unmeasurable(summary: Self.unlistedNetworks, reason: error.localizedDescription)
        }

        guard containers.contains(where: \.isRunning) else {
            return .nothingToCheck(summary: "Container routes: no running containers to check")
        }
        let publishing = NetworkRouteHealth.publishingNetworks(containers: containers, networks: networks)
        let uncheckable = NetworkRouteHealth.uncheckablePublishingNetworks(containers: containers, networks: networks)
        if publishing.isEmpty, uncheckable.isEmpty {
            return .nothingToCheck(summary: "Container routes: no running container publishes ports")
        }
        guard !publishing.isEmpty else { return Self.noSubnetReported(uncheckable) }

        switch await probe.routingTable() {
        case .failed(let reason):
            return .unmeasurable(summary: Self.unreadableRoutingTable, reason: reason)
        case .output(let table):
            // `canJudgeRoutes` after the probe, never instead of it: an empty table from a dead
            // netstat is "could not ask", and only `ProbeResult` knows which happened.
            guard NetworkRouteHealth.canJudgeRoutes(table) else {
                return .unmeasurable(summary: Self.unreadableRoutingTable, reason: Self.emptyRoutingTable)
            }
            let unroutable = NetworkRouteHealth.unroutableNetworks(publishing, routes: table)
            if !unroutable.isEmpty { return .unroutable(unroutable) }
            return .reachable(publishing, uncheckable: uncheckable)
        }
    }

    /// F-003: `CStackCommands.swift:81`, with the reason the CLI leaves to its own line.
    private static func noSubnetReported(_ networks: [String]) -> RoutesMeasurement {
        .unmeasurable(
            summary: noSubnetLine(networks),
            reason: "The runtime reported no subnet for these networks, so the host route cannot be judged."
        )
    }

    /// One spelling for `CStackCommands.swift:81`, whether it stands alone or follows `:67`.
    static func noSubnetLine(_ networks: [String]) -> String {
        "Container routes: cannot check \(networks.joined(separator: ", ")) — no subnet reported"
    }

    private static let unreadableRoutingTable = "Container routes: could not read the routing table"
    private static let emptyRoutingTable = "netstat returned no routing table."

    /// Invented, not copied: today `cstack doctor` throws out of `listNetworks` (`CStackCommands.swift:51`)
    /// rather than printing a line here. Same shape as `unmeasuredSummary`, for the same reason.
    private static let unlistedNetworks = "Container routes: UNKNOWN — the Docker API did not answer."

    /// The one check whose cost grows with the container count (NFR-001): one inspect per
    /// running container, which is why F-002 keeps it out of the UI set.
    private func memoryMeasurement(_ listing: ContainersMeasurement) async -> MemoryMeasurement {
        let running: [DockerContainerSummary]
        switch listing {
        case .notAsked:
            return .notAsked
        case .unmeasurable(let reason):
            return .unmeasurable(reason: reason)
        case .listed(let listed):
            running = listed.filter(\.isRunning)
        }
        guard !running.isEmpty else { return .nothingRunning }

        var limits: [Int64?] = []
        var failures = 0
        for container in running {
            do {
                limits.append(try await client.memoryLimitBytes(containerID: container.id))
            } catch {
                failures += 1
            }
        }
        guard !limits.isEmpty else { return .noneInspected(failures: failures) }
        // 0 is `HostMemory`'s own "could not read", and the one value `fraction` refuses to divide by.
        let commitment = MemoryCommitment.measure(limits: limits, hostBytes: hostMemoryBytes() ?? 0)
        return .inspected(commitment, failures: failures)
    }

    /// An unheld socket is not a foreign one: with no holder there is nothing to outrank
    /// the local runtime, and a socket that answers while `lsof` names nobody is held out of sight.
    private func bridgeOwnership() async -> BridgeMeasurement {
        let lsof: String
        switch await probe.socketHolder(socketPath: socketPath) {
        case .output(let output): lsof = output
        case .failed(let reason): return .unmeasurable(reason: reason)
        }
        let listing: String
        switch await probe.processTable() {
        case .output(let output): listing = output
        case .failed(let reason): return .unmeasurable(reason: reason)
        }

        guard let holder = BridgeOwnership.holder(lsofOutput: lsof) else { return .unseenHolder }
        let ourPIDs = ProcessTable.pids(forExecutable: bridgePath, in: listing)
        return BridgeOwnership.isOurs(holder: holder, ourPIDs: ourPIDs)
            ? .ours
            : .foreign(socketPath: socketPath)
    }
}
