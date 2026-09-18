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

    /// What `resolve` ranked, plus the one thing it cannot express: that a check was
    /// attempted and could not be measured.
    private struct Signals {
        let state: RuntimeState
        let appRoot: AppRootMeasurement
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

    /// Gathers what `RuntimeState.resolve` takes and calls it once. Which failure
    /// outranks which is decided there and nowhere else, so nothing here compares two.
    private func signals(for checks: Set<CheckID>) async -> Signals {
        var failure: String?
        var socketResponds = false
        do {
            socketResponds = try await client.ping()
        } catch {
            failure = error.localizedDescription
        }

        let appRoot = checks.contains(.appRoot) ? await appRootMeasurement() : .intact
        let bridge = checks.contains(.foreignBridge) ? await bridgeOwnership() : nil
        let state = RuntimeState.resolve(
            socketResponds: socketResponds,
            // Means "a helper this caller launched", as it does in the app. A report launches
            // nothing, so a bridge started by launchd is `.offline`, never `.starting` (#44).
            helperRunning: false,
            isStarting: false,
            failure: failure,
            // Gated exactly as `RuntimeViewModel.applyState` gates them, so both callers hand
            // `resolve` the same inputs. The app's call convention, not a second ranking.
            missingAppRoot: socketResponds ? appRoot.missingRoot : nil,
            foreignBridge: socketResponds ? bridge?.foreignSocketPath : nil
        )
        return Signals(state: state, appRoot: appRoot)
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
            return skipped(id, because: state.detail ?? state.title)
        case .running, .degraded:
            // Nothing outranked this check, so a probe that could not run is its own answer:
            // amber, never the grey of a check something else made moot.
            if id == .appRoot, case .unmeasurable(let reason) = signals.appRoot {
                return indeterminate(
                    id,
                    summary: "Runtime storage: UNKNOWN — the runtime status could not be read.",
                    detail: reason
                )
            }
            return notRun(id)
        }
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
