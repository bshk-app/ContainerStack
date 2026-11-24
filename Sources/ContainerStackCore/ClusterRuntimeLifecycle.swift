import Foundation

public struct ClusterRuntimeLifecycle: Sendable {
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
    public func preflight(isCurrent: () -> Bool = { true }) async -> String? {
        let budget = ClusterCommandBudget(end: now() + .seconds(30), now: now)
        guard let inventory = await inventory(budget, isCurrent: isCurrent) else { return nil }
        switch inventory {
        case .unknown:
            return "Cluster inventory unknown: running clusters may stop."
        case .listed(let entries, _):
            let warnings = entries.compactMap(\.warning)
            let ordinary = entries.filter { $0.risk == nil }.map(\.cluster.name)
            let question =
                warnings
                + (ordinary.isEmpty
                    ? []
                    : [
                        "Clusters \(ordinary.joined(separator: ", ")) stop and stay stopped."
                    ])
            return question.isEmpty ? nil : question.joined(separator: " ")
        }
    }

    @MainActor
    public func stopClusters(
        isCurrent: () -> Bool = { true },
        progress: (String) -> Void = { _ in }
    ) async -> [String]? {
        let budget = ClusterCommandBudget(end: now() + .seconds(120), now: now)
        guard let inventory = await inventory(budget, isCurrent: isCurrent) else { return nil }
        guard case .listed(let entries, let canStop) = inventory else { return ["cluster inventory unknown"] }

        var lines: [String] = []
        for entry in entries {
            let outcome: String
            if canStop, budget.canLaunch {
                progress(entry.cluster.name)
                outcome = await stop(entry, budget: budget, isCurrent: isCurrent)
            } else {
                outcome = "left to system stop"
            }
            guard isCurrent() else { return nil }
            lines.append(entry.result(outcome))
        }
        return lines
    }

    private enum Inventory {
        case unknown
        case listed([Entry], canStop: Bool)
    }

    @MainActor
    private func inventory(_ budget: ClusterCommandBudget, isCurrent: () -> Bool) async -> Inventory? {
        let capability = try? await commands.capability(budget: budget)
        guard isCurrent() else { return nil }
        if capability == .noClusterStart { return .listed([], canStop: false) }

        let clusters: [KubernetesCluster]
        do {
            let listing = try await commands.list(budget: budget)
            guard isCurrent() else { return nil }
            clusters = try KubernetesCluster.decodeList(Data(listing.utf8))
        } catch {
            return isCurrent() ? .unknown : nil
        }
        let active = clusters.filter { $0.state != .stopped }.sorted { $0.creationDate < $1.creationDate }
        var entries: [Entry] = []
        for cluster in active {
            let risk = await risk(for: cluster, budget: budget)
            guard isCurrent() else { return nil }
            entries.append(Entry(cluster: cluster, risk: risk))
        }
        return .listed(entries, canStop: capability == .capable)
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
    private func stop(_ entry: Entry, budget: ClusterCommandBudget, isCurrent: () -> Bool) async -> String {
        do {
            try await commands.stop(name: entry.cluster.name, budget: budget)
        } catch {
            return "left to system stop"
        }
        guard isCurrent() else { return "" }
        if entry.risk == .removedOnStop, budget.remaining > .zero,
            let names = try? await listNodes(min(.seconds(5), budget.remaining)),
            !entry.cluster.nodes.isEmpty, entry.cluster.nodes.allSatisfy({ !names.contains($0.name) })
        {
            return "nodes removed"
        }
        return "stopped in order"
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

        func result(_ outcome: String) -> String {
            let detail: String
            switch risk {
            case .removedOnStop where outcome != "nodes removed": detail = ". Created with --rm."
            case .endpointUnproven: detail = ". It has more than one node and may not start again."
            default: detail = ""
            }
            return "\(cluster.name): \(outcome)\(detail)"
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
