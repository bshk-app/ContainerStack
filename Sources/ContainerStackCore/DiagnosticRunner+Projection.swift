import Foundation

/// How a resolved run becomes checks. Separated from the gathering so `DiagnosticRunner.swift`
/// carries only what a run measures, never how a measurement is worded.
extension DiagnosticRunner {
    /// Exhaustive by construction: a new `RuntimeState` has to be given a projection here
    /// rather than silently inheriting one.
    static func project(_ signals: Signals, onto id: CheckID) -> DiagnosticCheck {
        let state = signals.state
        // What this check's own measurement cost, carried whatever the verdict: a check the
        // precedence order made moot still spent whatever it spent before that was known.
        let took = signals.duration(of: id)
        switch state {
        case .foreignBridge(let socketPath):
            guard id == .foreignBridge else {
                return skipped(id, because: "Another Docker bridge holds \(socketPath).", took: took)
            }
            // F-005: a restart of our runtime cannot evict a process it did not start, so the
            // only honest repair is one the person performs.
            return failed(
                id,
                summary: state.title,
                detail: state.detail,
                remedy: .manual(
                    "Stop the other Docker bridge holding \(socketPath), then start the runtime again."
                ),
                took: took
            )
        case .detached(let appRoot):
            // `resolve` reaches this state only with the socket answering, so the socket check keeps
            // the answer it already has (`CStackCommands.swift:24`) instead of being made moot.
            if id == .socket, signals.socket.responds {
                return passed(id, summary: Self.socketHealthy, detail: nil, took: took)
            }
            guard id == .appRoot else {
                return skipped(
                    id,
                    because: "The runtime is storing into \(appRoot), which no longer exists.",
                    took: took
                )
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
                remedy: .restartRuntime,
                took: took
            )
        case .offline, .starting, .unknown:
            // A socket that timed out was not measured, and only the checks that needed it turn
            // amber: the rest are grey because this one already decided (F-010).
            if case .unmeasurable(let reason) = signals.socket, id == .socket || id == .versions {
                return indeterminate(id, summary: unmeasuredSummary(for: id), detail: reason, took: took)
            }
            return skipped(id, because: state.detail ?? state.title, took: took)
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
        let took = signals.duration(of: id)
        if id == .appRoot { return appRootCheck(signals.appRoot, took: took) }
        // F-003: the bytes `cstack doctor` prints today (`CStackCommands.swift:32`).
        if id == .socket { return passed(id, summary: Self.socketHealthy, detail: nil, took: took) }
        if id == .versions { return versionsCheck(signals.versions, took: took) }
        if id == .routes { return routesCheck(signals.routes, ranked: ranked, took: took) }
        if id == .foreignBridge { return bridgeCheck(signals.bridge, took: took) }
        if id == .memoryCommitment { return memoryCheck(signals.memory, took: took) }
        return notRun(id, took: took)
    }

    /// F-003: `CStackCommands.swift:37-38` prints storage only when the status named a root, and
    /// `resolve` owns the missing one, so `.missing` cannot reach a runtime it called usable.
    private static func appRootCheck(_ measurement: AppRootMeasurement, took: Duration) -> DiagnosticCheck {
        switch measurement {
        case .unmeasurable(let reason):
            return indeterminate(
                .appRoot,
                summary: "Runtime storage: UNKNOWN — the runtime status could not be read.",
                detail: reason,
                took: took
            )
        case .intact(let root?):
            return passed(.appRoot, summary: "Runtime storage: \(root)", detail: nil, took: took)
        case .intact, .missing:
            return notRun(.appRoot, took: took)
        }
    }

    private static let socketHealthy = "Docker socket: healthy"

    /// F-003: the bytes `cstack doctor` prints today (`CStackCommands.swift:107`, `:117`, `:120`,
    /// `:123`, `:126-128`, `:132`, `:138`, `:143`), copied rather than reworded.
    private static func memoryCheck(_ measurement: MemoryMeasurement, took: Duration) -> DiagnosticCheck {
        switch measurement {
        case .notAsked:
            return notRun(.memoryCommitment, took: took)
        case .nothingRunning:
            // F-003's table sanctions this line for the state the CLI returns from at
            // `CStackCommands.swift:46`, and a `.skipped` verdict would render it as silence.
            return passed(.memoryCommitment, summary: Self.noRunningContainers, detail: nil, took: took)
        case .unmeasurable(let reason):
            return indeterminate(.memoryCommitment, summary: Self.unlistedContainers, detail: reason, took: took)
        case .noneInspected(let failures):
            return indeterminate(
                .memoryCommitment,
                summary: "Container memory limits: unavailable — \(failures) running container(s)"
                    + " could not be inspected.",
                detail: nil,
                took: took
            )
        case .inspected(let commitment, let failures):
            return commitmentCheck(commitment, failures: failures, took: took)
        }
    }

    /// Decisions 5 and 6 in `spec-gaps.md`: over-commitment is amber rather than red, and an
    /// unread host size or a failed inspect is amber because it was not measured.
    private static func commitmentCheck(
        _ commitment: MemoryCommitment,
        failures: Int,
        took: Duration
    ) -> DiagnosticCheck {
        let trailing = trailingLines(commitment, failures: failures)
        guard commitment.hostBytes > 0 else {
            return indeterminate(
                .memoryCommitment,
                summary: "Container memory limits: \(ByteSize.formatted(commitment.configuredBytes))"
                    + " configured (host memory unknown)",
                detail: trailing.isEmpty ? nil : trailing.joined(separator: "\n"),
                took: took
            )
        }

        let summary =
            "\(ByteSize.formatted(commitment.configuredBytes)) in explicit container limits"
            + " vs \(ByteSize.formatted(commitment.hostBytes)) host memory"
        var lines = trailing
        var text: String
        var remedy: Remedy?
        switch commitment.verdict {
        case .within:
            text = "Container memory limits: \(summary)"
        case .approaching:
            text =
                "Container memory limits: \(summary)"
                + " — guests approaching their limits may pressure other applications"
        case .exceeding:
            text = "Container memory limits: HIGH — \(summary)"
            lines.insert(Self.growthTowardLimits, at: 0)
            lines.insert(Self.smallerMemoryAdvice, at: 1)
            remedy = .manual(Self.smallerMemoryAdvice)
        }

        let detail = lines.isEmpty ? nil : lines.joined(separator: "\n")
        // Decision 6's exception: an uninspected limit only adds, so nothing unmeasured can
        // un-exceed a total that already does. The other two verdicts a missing sample can flip.
        guard failures == 0 || commitment.verdict == .exceeding else {
            return indeterminate(.memoryCommitment, summary: text, detail: detail, took: took)
        }
        guard commitment.verdict == .within else {
            return warned(.memoryCommitment, summary: text, detail: detail, remedy: remedy, took: took)
        }
        return passed(.memoryCommitment, summary: text, detail: detail, took: took)
    }

    /// The two lines the CLI appends after its verdict, each only when it has something to
    /// say: an excluded container and an uninspected one are different admissions.
    private static func trailingLines(_ commitment: MemoryCommitment, failures: Int) -> [String] {
        var lines: [String] = []
        if commitment.containersWithoutLimit > 0 {
            lines.append(
                "\(commitment.containersWithoutLimit) running container(s) have no explicit memory limit"
                    + " and are excluded from that total."
            )
        }
        if failures > 0 {
            lines.append("\(failures) running container(s) could not be inspected, so the total is incomplete.")
        }
        return lines
    }

    private static let growthTowardLimits =
        "Guests do not reserve every byte immediately, but host use can grow toward these limits."
    private static let smallerMemoryAdvice = "Stop a container or recreate it with a smaller --memory."

    /// F-003's table, row 7: today `cstack doctor` returns before the memory report in this state,
    /// so the line is sanctioned rather than copied. The next one throws out of `:43`.
    private static let noRunningContainers = "Container memory limits: no running containers to check"
    private static let unlistedContainers = "Container memory limits: UNKNOWN — the Docker API did not answer."

    /// The one check with no CLI line behind it: `cstack doctor` never measured ownership,
    /// so this wording is new rather than reproduced (F-003).
    private static func bridgeCheck(_ measurement: BridgeMeasurement, took: Duration) -> DiagnosticCheck {
        switch measurement {
        case .notAsked:
            return notRun(.foreignBridge, took: took)
        case .ours:
            return passed(.foreignBridge, summary: "Docker bridge: ours", detail: nil, took: took)
        case .unmeasurable(let reason):
            return indeterminate(.foreignBridge, summary: unidentifiedHolder, detail: reason, took: took)
        case .unseenHolder:
            return indeterminate(
                .foreignBridge,
                summary: unidentifiedHolder,
                detail: Self.holderOutOfSight,
                took: took
            )
        case .foreign(let socketPath):
            // `resolve` is the only thing that ranks ownership, so a foreign bridge it never
            // saw is reported unjudged rather than condemned twice over (F-013).
            return indeterminate(
                .foreignBridge,
                summary: unidentifiedHolder,
                detail: "Another bridge was measured holding \(socketPath), "
                    + "but the resolved runtime state did not carry it.",
                took: took
            )
        }
    }

    /// One summary for every way ownership goes unanswered: a probe that died, a holder out
    /// of sight and one nothing ranked are all "we cannot say", and none of them is ours.
    private static let unidentifiedHolder =
        "Docker bridge: UNKNOWN — the process holding the socket could not be identified."
    private static let holderOutOfSight =
        "The socket answers, but lsof named no process holding it, so its owner is not visible from here."

    /// F-003: `CStackCommands.swift:33-36` prints these four fields as one block, so they stay
    /// one check with the remaining three lines as detail.
    private static func versionsCheck(_ measurement: VersionsMeasurement, took: Duration) -> DiagnosticCheck {
        switch measurement {
        case .measured(let version, let info):
            return passed(
                .versions,
                summary: "API version: \(version.apiVersion ?? "unknown")",
                detail: """
                    Engine: \(version.version ?? "unknown")
                    Containers: \(info.containers.map(String.init) ?? "unknown")
                    Images: \(info.images.map(String.init) ?? "unknown")
                    """,
                took: took
            )
        case .unmeasurable(let reason):
            return indeterminate(
                .versions,
                summary: unmeasuredSummary(for: .versions),
                detail: reason,
                took: took
            )
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
    private static func routesCheck(
        _ measurement: RoutesMeasurement,
        ranked: [UnroutableNetwork],
        took: Duration
    ) -> DiagnosticCheck {
        switch measurement {
        case .notAsked:
            return notRun(.routes, took: took)
        case .nothingToCheck(let summary):
            return passed(.routes, summary: summary, detail: nil, took: took)
        case .reachable(let networks, let uncheckable):
            let summary = "Container routes: reachable (\(labels(networks)))"
            // `CStackCommands.swift:81` follows `:67` rather than replacing it: the networks that
            // were judged keep their verdict, and the check stays amber for the one that was not.
            guard uncheckable.isEmpty else {
                return indeterminate(.routes, summary: summary, detail: noSubnetLine(uncheckable), took: took)
            }
            return passed(.routes, summary: summary, detail: nil, took: took)
        case .unroutable(let networks):
            // `resolve` is the only thing that ranks unroutability (T-008), so networks it
            // never saw are reported unjudged rather than condemned twice over.
            guard !ranked.isEmpty else { return unrankedRoutes(networks, took: took) }
            return failed(
                .routes,
                summary: "Container routes: NO ROUTE to \(labels(ranked))",
                detail: """
                    Published ports accept connections and then hang.
                    Restarting the containers does not fix it. Run: cstack runtime restart
                    """,
                remedy: .restartRuntime,
                took: took
            )
        case .unmeasurable(let summary, let reason):
            return indeterminate(.routes, summary: summary, detail: reason, took: took)
        }
    }

    /// Reachable only when the runner stops handing `resolve` what the probe found: the
    /// measurement stands, the verdict does not, because nothing ranked it (F-013).
    private static func unrankedRoutes(_ networks: [UnroutableNetwork], took: Duration) -> DiagnosticCheck {
        indeterminate(
            .routes,
            summary: "Container routes: UNKNOWN — \(labels(networks)) was measured but never ranked",
            detail: "The resolved runtime state did not carry these networks, so no route verdict can be given.",
            took: took
        )
    }

    private static func labels(_ networks: [UnroutableNetwork]) -> String {
        networks.map(\.label).joined(separator: ", ")
    }
}
