import Foundation

public struct ClusterRuntimeLifecycle: Sendable {
    public enum Preflight: Sendable {
        case inspect(question: String?)
        case empty
        case statusUnavailable

        public var question: String? {
            if case .inspect(let question) = self { return question }
            return nil
        }
    }

    private let commands: ClusterCommands
    private let listNodes: @Sendable (Duration) async throws -> Set<String>
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(
        commands: ClusterCommands,
        listNodes: @escaping @Sendable (Duration) async throws -> Set<String> = { _ in
            throw URLError(.resourceUnavailable)
        },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.commands = commands
        self.listNodes = listNodes
        self.now = now
    }

    public init(containerPath: String, client: DockerAPIClient, home: URL, environment: [String: String]) {
        self.init(
            commands: ClusterCommands(containerPath: containerPath, home: home, environment: environment),
            listNodes: { timeout in
                Set(try await client.listClusterNodes(timeout: timeout).map(\.name))
            })
    }

    @MainActor
    public func preflight(isCurrent: () -> Bool = { true }) async -> Preflight {
        let budget = ClusterCommandBudget(end: now() + .seconds(30), now: now)
        guard let inventory = await inventory(budget, isCurrent: isCurrent) else { return .empty }
        switch inventory {
        case .empty:
            return .empty
        case .statusUnavailable:
            return .statusUnavailable
        case .unknown:
            return .inspect(question: "Cluster inventory unknown: running clusters may stop.")
        case .listed(let entries):
            guard !entries.isEmpty else { return .empty }
            let warnings = entries.compactMap(\.warning)
            let ordinary = entries.filter { $0.risk == nil }.map(\.cluster.name)
            let question = warnings + ordinaryRestartWarnings(ordinary)
            return .inspect(question: question.joined(separator: " "))
        }
    }

    private func ordinaryRestartWarnings(_ clusterNames: [String]) -> [String] {
        switch clusterNames.count {
        case 0: []
        case 1: ["Cluster \(clusterNames[0]) stops and stays stopped."]
        default: ["Clusters \(clusterNames.joined(separator: ", ")) stop and stay stopped."]
        }
    }

    @MainActor
    public func stopClusters(
        preflight: Preflight = .inspect(question: nil),
        isCurrent: () -> Bool = { true },
        progress: (String) -> Void = { _ in }
    ) async -> [String]? {
        guard isCurrent() else { return nil }
        let budget = ClusterCommandBudget(end: now() + .seconds(120), now: now)
        let inventory: Inventory? =
            switch preflight {
            case .empty: Inventory.empty
            case .statusUnavailable: Inventory.statusUnavailable
            case .inspect: await self.inventory(budget, isCurrent: isCurrent)
            }
        guard let inventory else { return nil }
        switch inventory {
        case .empty: return []
        case .statusUnavailable, .unknown: return unknownInventoryResult(inventory)
        case .listed(let entries): return await stop(entries, budget: budget, isCurrent: isCurrent, progress: progress)
        }
    }

    @MainActor
    private func stop(
        _ entries: [Entry], budget: ClusterCommandBudget, isCurrent: () -> Bool, progress: (String) -> Void
    ) async -> [String]? {
        var lines: [String] = []
        var unconfirmedStops = Set(entries.map(\.cluster.name))
        defer {
            for name in unconfirmedStops { commands.clearStartEvidence(for: name) }
        }
        for entry in entries {
            let outcome: StopOutcome
            if budget.canLaunch {
                progress(entry.cluster.name)
                outcome = await stop(entry, budget: budget, isCurrent: isCurrent)
            } else {
                outcome = .leftToSystemStop
            }
            if outcome != .leftToSystemStop { unconfirmedStops.remove(entry.cluster.name) }
            guard isCurrent() else { return nil }
            lines.append(entry.result(outcome))
        }
        return lines
    }

    private enum Inventory {
        case empty
        case statusUnavailable
        case unknown
        case listed([Entry])
    }

    @MainActor
    private func inventory(_ budget: ClusterCommandBudget, isCurrent: () -> Bool) async -> Inventory? {
        let status = try? await commands.launch(
            ["system", "status"], timeout: ProcessRunner.diagnosticTimeout,
            output: .captureSeparately, budget: budget, preparesKubeconfig: false)
        guard isCurrent() else { return nil }
        guard let status else { return .statusUnavailable }
        if RuntimeStatusParser.isStopped(status.output + "\n" + status.errorOutput) { return .empty }
        guard status.status == 0 else { return .statusUnavailable }

        let capability = try? await commands.clusterCommandCapability(budget: budget)
        guard isCurrent() else { return nil }
        if capability == .noClusterStart { return .empty }
        guard capability == .capable else { return .unknown }

        let clusters: [KubernetesCluster]
        do {
            let listing = try await commands.list(budget: budget)
            guard isCurrent() else { return nil }
            clusters = try KubernetesCluster.decodeList(Data(listing.utf8))
        } catch {
            return isCurrent() ? .unknown : nil
        }
        for cluster in clusters where cluster.state == .stopped {
            commands.clearStartEvidence(for: cluster.name)
        }
        let active = clusters.filter { $0.state != .stopped }.sorted { $0.creationDate < $1.creationDate }
        var entries: [Entry] = []
        for cluster in active {
            let risk = await risk(for: cluster, budget: budget)
            guard isCurrent() else { return nil }
            entries.append(Entry(cluster: cluster, risk: risk))
        }
        return .listed(entries)
    }

    private func unknownInventoryResult(_ inventory: Inventory) -> [String] {
        ClusterCommands.clearRuntimeStartEvidence(containerPath: commands.containerPath)
        if case .statusUnavailable = inventory {
            guard let kubeconfig = try? String(contentsOf: commands.managedKubeconfig, encoding: .utf8),
                KubeconfigCA.entries(of: "contexts", in: kubeconfig).contains(where: { $0["name"] != nil })
            else { return [] }
            return ["cluster inventory unknown: running clusters may have been stopped"]
        }
        return ["cluster inventory unknown"]
    }

    private func risk(for cluster: KubernetesCluster, budget: ClusterCommandBudget) async -> Risk? {
        if cluster.remove { return .removedOnStop }
        guard cluster.nodes.count > 1 else { return nil }
        guard budget.canLaunch,
            let probe = try? await commands.launch(
                ["exec", cluster.name, "cat", "/etc/kubernetes/kubeadm-config.yaml"],
                timeout: ProcessRunner.diagnosticTimeout,
                output: .captureSeparately,
                budget: budget),
            probe.status == 0, Self.hasStableEndpoint(in: probe.output)
        else { return .endpointUnproven }
        return nil
    }

    @MainActor
    private func stop(_ entry: Entry, budget: ClusterCommandBudget, isCurrent: () -> Bool) async -> StopOutcome {
        do {
            try await commands.stop(name: entry.cluster.name, budget: budget)
        } catch {
            return .leftToSystemStop
        }
        guard isCurrent() else { return .stoppedInOrder }
        if entry.risk == .removedOnStop, budget.remaining > .zero,
            let names = try? await listNodes(min(.seconds(5), budget.remaining)),
            !entry.cluster.nodes.isEmpty, entry.cluster.nodes.allSatisfy({ !names.contains($0.name) })
        {
            return .nodesRemoved
        }
        return .stoppedInOrder
    }

    private enum StopOutcome: String {
        case stoppedInOrder = "stopped in order"
        case leftToSystemStop = "left to system stop"
        case nodesRemoved = "nodes removed"
    }

    private enum Risk {
        case removedOnStop, endpointUnproven
    }

    private struct Entry {
        let cluster: KubernetesCluster
        let risk: Risk?

        var warning: String? {
            switch risk {
            case .removedOnStop: "Cluster \(cluster.name) was created with --rm: its nodes will be removed."
            case .endpointUnproven: "Cluster \(cluster.name) has more than one node and may not start again."
            case nil: nil
            }
        }

        func result(_ outcome: StopOutcome) -> String {
            let detail: String
            switch risk {
            case .removedOnStop where outcome != .nodesRemoved: detail = ". Created with --rm."
            case .endpointUnproven: detail = ". It has more than one node and may not start again."
            default: detail = ""
            }
            return "\(cluster.name): \(outcome.rawValue)\(detail)"
        }
    }

    private static func hasStableEndpoint(in yaml: String) -> Bool {
        var document: [Substring] = []
        for line in yaml.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            if !line.hasPrefix(" "), tokens.first == "---" || tokens.first == "..." {
                if documentProvesEndpoint(document) { return true }
                document.removeAll()
            } else if line.first?.isWhitespace == false, !line.hasPrefix("#") {
                document.append(line)
            }
        }
        return documentProvesEndpoint(document)
    }

    private static func documentProvesEndpoint(_ document: [Substring]) -> Bool {
        func value(_ key: String) -> String? {
            let matches = document.compactMap { line -> Substring? in
                guard let colon = line.firstIndex(of: ":"), line[..<colon] == key else { return nil }
                return line[line.index(after: colon)...]
            }
            guard matches.count == 1, let raw = matches.first else { return nil }
            let value = raw.trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'",
                let end = value.dropFirst().firstIndex(of: quote)
            {
                return String(value[value.index(after: value.startIndex)..<end])
            }
            let unquoted = value.prefix { !$0.isWhitespace }
            guard let first = unquoted.first, !"#'\">|[{&*!".contains(first),
                unquoted != "~", unquoted.lowercased() != "null"
            else { return nil }
            return String(unquoted)
        }
        return value("kind") == "ClusterConfiguration" && value("controlPlaneEndpoint")?.isEmpty == false
    }
}
