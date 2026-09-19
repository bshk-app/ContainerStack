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
    /// Injected so `ranAt` is assertable; a report never stamps itself from `Date()`.
    private let now: @Sendable () -> Date

    public init(
        client: DockerAPIClient,
        probe: any SystemProbe,
        socketPath: String,
        bridgePath: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.probe = probe
        self.socketPath = socketPath
        self.bridgePath = bridgePath
        self.now = now
    }

    /// Answers every requested id and only those: a check that was not run is
    /// `.skipped` with no remedy, never dropped from the report.
    public func run(checks: Set<CheckID>) async -> DiagnosticReport {
        let ordered = CheckID.allCases.filter(checks.contains)
        let signals = await signals(for: checks)
        return DiagnosticReport(checks: ordered.map { Self.project(signals, onto: $0) }, ranAt: now())
    }

    /// What `resolve` ranked, plus the things it cannot express: that a check was attempted
    /// and could not be measured.
    private struct Signals {
        let state: RuntimeState
        let appRoot: AppRootMeasurement
        let socket: SocketMeasurement
        let versions: VersionsMeasurement
        let routes: RoutesMeasurement
    }

    /// A refused socket and one that never answered both resolve to `.offline`, and F-010 needs
    /// them apart. Only the transport knows which happened, so the split is made here.
    private enum SocketMeasurement {
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

    private enum VersionsMeasurement {
        case measured(version: DockerVersion, info: DockerInfo)
        case unmeasurable(reason: String)
    }

    /// Three-valued because two values is the bug: `nil` from a probe that never ran is
    /// read as "no missing root", which is a healthy runtime (F-009).
    private enum AppRootMeasurement {
        case missing(String)
        case intact
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
    private enum RoutesMeasurement {
        case notAsked
        case nothingToCheck(summary: String)
        case reachable([UnroutableNetwork])
        case unroutable([UnroutableNetwork])
        case unmeasurable(summary: String, reason: String)

        /// Only networks a readable routing table condemned: a check that could not run
        /// gives `resolve` nothing to rank.
        var unroutableNetworks: [UnroutableNetwork] {
            if case .unroutable(let networks) = self { return networks }
            return []
        }
    }

    /// Gathers what `RuntimeState.resolve` takes and calls it once. Which failure
    /// outranks which is decided there and nowhere else, so nothing here compares two.
    private func signals(for checks: Set<CheckID>) async -> Signals {
        let socket = await socketMeasurement()
        let versions =
            socket.responds && checks.contains(.versions)
            ? await versionsMeasurement()
            : VersionsMeasurement.unmeasurable(reason: socket.failure ?? RuntimeState.genericFailure)

        let appRoot = checks.contains(.appRoot) ? await appRootMeasurement() : .intact
        let bridge = checks.contains(.foreignBridge) ? await bridgeOwnership() : nil
        // Every route signal arrives over the socket, so asking a dead one buys nothing but
        // more waiting inside the same budget (NFR-002).
        let routes =
            socket.responds && checks.contains(.routes)
            ? await routesMeasurement()
            : RoutesMeasurement.notAsked
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
            foreignBridge: socket.responds ? bridge?.foreignSocketPath : nil
        )
        return Signals(state: state, appRoot: appRoot, socket: socket, versions: versions, routes: routes)
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
            guard let root = RuntimeStatusParser.missingAppRoot(status) else { return .intact }
            return .missing(root)
        case .failed(let reason):
            return .unmeasurable(reason: reason)
        }
    }

    /// Two independent ways to fail to measure — the Docker call and `netstat` — and neither may
    /// arrive as an empty answer, which reads as "no route needed" (F-009, #45).
    private func routesMeasurement() async -> RoutesMeasurement {
        let containers: [DockerContainerSummary]
        let networks: [DockerNetworkSummary]
        do {
            containers = try await client.decode(
                [DockerContainerSummary].self,
                response: client.requestRetryingImmediateFailures(path: "/containers/json")
            )
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
            guard uncheckable.isEmpty else { return Self.noSubnetReported(uncheckable) }
            return .reachable(publishing)
        }
    }
    /// An unheld socket is not a foreign one: with no holder there is nothing to outrank
    /// the local runtime, and `lsof` reporting nobody is a stale socket file.
    private func bridgeOwnership() async -> (foreignSocketPath: String?, ourBridgeRunning: Bool) {
        guard case .output(let lsof) = await probe.socketHolder(socketPath: socketPath),
            case .output(let listing) = await probe.processTable()
        else { return (nil, false) }

        let holder = BridgeOwnership.holder(lsofOutput: lsof)
        let ourPIDs = ProcessTable.pids(forExecutable: bridgePath, in: listing)
        let isForeign = holder != nil && !BridgeOwnership.isOurs(holder: holder, ourPIDs: ourPIDs)
        return (isForeign ? socketPath : nil, !ourPIDs.isEmpty)
    }

    /// Exhaustive by construction: a new `RuntimeState` has to be given a projection here
    /// rather than silently inheriting one.
    private static func project(_ signals: Signals, onto id: CheckID) -> DiagnosticCheck {
        let state = signals.state
        switch state {
        case .foreignBridge(let socketPath):
            guard id == .foreignBridge else {
                return skipped(id, because: "Another Docker bridge holds \(socketPath).")
            }
            return failed(id, summary: state.title, detail: state.detail, remedy: nil)
        case .detached(let appRoot):
            guard id == .appRoot else {
                return skipped(id, because: "The runtime is storing into \(appRoot), which no longer exists.")
            }
            // F-003: the bytes `cstack doctor` prints today (`CStackCommands.swift:25-27`),
            // copied rather than reworded, because T-016 renders these back out.
            return failed(
                id,
                summary: "Runtime storage: MISSING — storing into \(appRoot), which no longer exists.",
                detail: """
                    Images, volumes and containers kept there cannot be found.
                    The restart moves it back to the default location. Run: cstack runtime restart
                    """,
                remedy: .restartRuntime
            )
        case .offline, .starting, .unknown:
            // A socket that timed out was not measured, and only the checks that needed it turn
            // amber: the rest are grey because this one already decided (F-010).
            if case .unmeasurable(let reason) = signals.socket, id == .socket || id == .versions {
                return indeterminate(id, summary: unmeasuredSummary(for: id), detail: reason)
            }
            return skipped(id, because: state.detail ?? state.title)
        case .running:
            return usableRuntimeCheck(signals, onto: id, ranked: [])
        case .degraded(let networks):
            return usableRuntimeCheck(signals, onto: id, ranked: networks)
        }
    }

    /// `ranked` is what `resolve` condemned, and the routes check reports that rather than
    /// re-deciding it: the two answers cannot drift apart if only one of them judges (F-013).
    private static func usableRuntimeCheck(
        _ signals: Signals,
        onto id: CheckID,
        ranked: [UnroutableNetwork]
    ) -> DiagnosticCheck {
        // Nothing outranked this check, so a probe that could not run is its own answer:
        // amber, never the grey of a check something else made moot.
        if id == .appRoot, case .unmeasurable(let reason) = signals.appRoot {
            return indeterminate(
                id,
                summary: "Runtime storage: UNKNOWN — the runtime status could not be read.",
                detail: reason
            )
        }
        // F-003: the bytes `cstack doctor` prints today (`CStackCommands.swift:32`).
        if id == .socket { return passed(id, summary: "Docker socket: healthy", detail: nil) }
        if id == .versions { return versionsCheck(signals.versions) }
        if id == .routes { return routesCheck(signals.routes, ranked: ranked) }
        return notRun(id)
    }

    /// F-003: `CStackCommands.swift:33-36` prints these four fields as one block, so they stay
    /// one check with the remaining three lines as detail.
    private static func versionsCheck(_ measurement: VersionsMeasurement) -> DiagnosticCheck {
        switch measurement {
        case .measured(let version, let info):
            return passed(
                .versions,
                summary: "API version: \(version.apiVersion ?? "unknown")",
                detail: """
                    Engine: \(version.version ?? "unknown")
                    Containers: \(info.containers.map(String.init) ?? "unknown")
                    Images: \(info.images.map(String.init) ?? "unknown")
                    """
            )
        case .unmeasurable(let reason):
            return indeterminate(.versions, summary: unmeasuredSummary(for: .versions), detail: reason)
        }
    }

    /// Invented, not copied: today `cstack doctor` aborts at `health()` (`CStackCommands.swift:31`)
    /// rather than printing a line here. F-003's amendment sanctions that second CLI difference.
    private static func unmeasuredSummary(for id: CheckID) -> String {
        id == .socket
            ? "Docker socket: UNKNOWN — the socket did not answer before the timeout."
            : "API version: UNKNOWN — the Docker API did not answer."
    }

    /// F-003: the bytes `cstack doctor` prints today (`CStackCommands.swift:45`, `:56`, `:63`,
    /// `:67`, `:69`, `:74-75`), copied rather than reworded, because T-016 renders these back out.
    private static func routesCheck(_ measurement: RoutesMeasurement, ranked: [UnroutableNetwork]) -> DiagnosticCheck {
        switch measurement {
        case .notAsked:
            return notRun(.routes)
        case .nothingToCheck(let summary):
            return passed(.routes, summary: summary, detail: nil)
        case .reachable(let networks):
            return passed(.routes, summary: "Container routes: reachable (\(labels(networks)))", detail: nil)
        case .unroutable(let networks):
            // `resolve` is the only thing that ranks unroutability (T-008), so networks it
            // never saw are reported unjudged rather than condemned twice over.
            guard !ranked.isEmpty else { return unrankedRoutes(networks) }
            return failed(
                .routes,
                summary: "Container routes: NO ROUTE to \(labels(ranked))",
                detail: """
                    Published ports accept connections and then hang.
                    Restarting the containers does not fix it. Run: cstack runtime restart
                    """,
                remedy: .restartRuntime
            )
        case .unmeasurable(let summary, let reason):
            return indeterminate(.routes, summary: summary, detail: reason)
        }
    }

    /// Reachable only when the runner stops handing `resolve` what the probe found: the
    /// measurement stands, the verdict does not, because nothing ranked it (F-013).
    private static func unrankedRoutes(_ networks: [UnroutableNetwork]) -> DiagnosticCheck {
        indeterminate(
            .routes,
            summary: "Container routes: UNKNOWN — \(labels(networks)) was measured but never ranked",
            detail: "The resolved runtime state did not carry these networks, so no route verdict can be given."
        )
    }
    private static func labels(_ networks: [UnroutableNetwork]) -> String {
        networks.map(\.label).joined(separator: ", ")
    }

    /// F-003: `CStackCommands.swift:81`, with the reason the CLI leaves to its own line.
    private static func noSubnetReported(_ networks: [String]) -> RoutesMeasurement {
        .unmeasurable(
            summary: "Container routes: cannot check \(networks.joined(separator: ", ")) — no subnet reported",
            reason: "The runtime reported no subnet for these networks, so the host route cannot be judged."
        )
    }

    private static let unreadableRoutingTable = "Container routes: could not read the routing table"
    private static let emptyRoutingTable = "netstat returned no routing table."

    /// Invented, not copied: today `cstack doctor` throws out of `listNetworks` (`CStackCommands.swift:51`)
    /// rather than printing a line here. Same shape as `unmeasuredSummary`, for the same reason.
    private static let unlistedNetworks = "Container routes: UNKNOWN — the Docker API did not answer."

    private static func passed(_ id: CheckID, summary: String, detail: String?) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .ok,
            summary: summary,
            detail: detail,
            remedy: nil,
            duration: .zero
        )
    }

    private static func failed(
        _ id: CheckID,
        summary: String,
        detail: String?,
        remedy: Remedy?
    ) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .failure,
            summary: summary,
            detail: detail,
            remedy: remedy,
            duration: .zero
        )
    }

    /// Amber, and the reason the measurement failed travels with it: "could not tell" is
    /// only actionable when the report names what did not answer.
    private static func indeterminate(_ id: CheckID, summary: String, detail: String?) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .indeterminate,
            summary: summary,
            detail: detail,
            // No repair: an unmeasured root gives no grounds to restart anything.
            remedy: nil,
            duration: .zero
        )
    }

    /// A reason, never a bare "not applicable": the check below a failure is grey because
    /// something above it already decided, and the report has to say what.
    private static func skipped(_ id: CheckID, because reason: String) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .skipped,
            summary: reason,
            detail: nil,
            remedy: nil,
            duration: .zero
        )
    }

    private static func notRun(_ id: CheckID) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .skipped,
            summary: "Not run.",
            detail: nil,
            remedy: nil,
            duration: .zero
        )
    }
}
