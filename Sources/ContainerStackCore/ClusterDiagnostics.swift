import Foundation

public struct ClusterDiagnostics: Sendable {
    typealias Probe = @Sendable (KubernetesCluster, URL, Duration) async -> ClusterAPIReady.Result

    private let commands: ClusterCommands
    private let client: DockerAPIClient
    private let probe: Probe
    private let history: ClusterAPIHistory
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(commands: ClusterCommands, client: DockerAPIClient) {
        self.init(commands: commands, client: client, history: .shared) { cluster, kubeconfig, timeout in
            await ClusterAPIReady.observe(
                endpoint: cluster.apiEndpoint, context: cluster.name, kubeconfig: kubeconfig, timeout: timeout)
        }
    }

    init(
        commands: ClusterCommands, client: DockerAPIClient, history: ClusterAPIHistory = .init(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, probe: @escaping Probe
    ) {
        self.commands = commands
        self.client = client
        self.probe = probe
        self.history = history
        self.now = now
    }

    func run(until deadline: ContinuousClock.Instant? = nil) async -> DiagnosticCheck {
        let started = now()
        let deadline = deadline ?? started + DiagnosticRunner.defaultBudget
        guard started < deadline else { return timedOut(started) }
        do {
            let capability = try await commands.capability()
            guard now() < deadline else { return timedOut(started) }
            if capability != .capable {
                return check(
                    capability == .noClusterStart ? .failure : .skipped,
                    summary: "Kubernetes clusters", detail: capability.description, started: started)
            }
            let list = try await commands.list()
            let clusters = try KubernetesCluster.decodeList(Data(list.utf8))
            guard now() < deadline else { return timedOut(started) }
            return await measure(clusters, started: started, deadline: deadline)
        } catch {
            guard now() < deadline else { return timedOut(started) }
            return check(
                .failure, summary: "Kubernetes clusters: could not read inventory",
                detail: String(describing: error), started: started)
        }
    }

    private func measure(
        _ clusters: [KubernetesCluster], started: ContinuousClock.Instant, deadline: ContinuousClock.Instant
    ) async -> DiagnosticCheck {
        let summary = "\(clusters.count) clusters, \(clusters.filter { $0.state == .running }.count) running"
        guard !clusters.isEmpty else { return check(.ok, summary: summary, detail: nil, started: started) }

        let remaining = now().duration(to: deadline)
        guard remaining > .zero else { return timedOut(started) }
        let presentNodes = try? await Set(client.listClusterNodes(timeout: min(.seconds(5), remaining)).map(\.name))
        let kubeconfig = commands.managedKubeconfig
        let text = (try? String(contentsOf: kubeconfig, encoding: .utf8)) ?? ""
        let contexts = Set(KubeconfigCA.entries(of: "contexts", in: text).compactMap { $0["name"] })
        var issues = await withTaskGroup(of: [String].self) { group in
            for cluster in clusters {
                group.addTask {
                    await warnings(for: cluster, nodes: presentNodes, contexts: contexts, deadline: deadline)
                }
            }
            var details: [[String]] = []
            for await warnings in group where !warnings.isEmpty { details.append(warnings) }
            return details.sorted { ($0.first ?? "") < ($1.first ?? "") }.flatMap { $0 }
        }
        guard now() < deadline else { return timedOut(started) }
        let verdict: Verdict
        if presentNodes == nil {
            verdict = issues.isEmpty ? .indeterminate : .warning
            issues.append("Cluster nodes could not be listed through the Docker bridge.")
        } else {
            verdict = issues.isEmpty ? .ok : .warning
        }
        return check(
            verdict, summary: summary, detail: issues.isEmpty ? nil : issues.joined(separator: "\n"),
            started: started)
    }

    private func warnings(
        for cluster: KubernetesCluster, nodes: Set<String>?, contexts: Set<String>, deadline: ContinuousClock.Instant
    ) async -> [String] {
        let name = cluster.name
        var issues: [String] = []
        let missing = nodes.map { present in cluster.nodes.map(\.name).filter { !present.contains($0) } } ?? []
        let remaining = now().duration(to: deadline)
        guard remaining > .zero else { return [] }
        let status =
            cluster.state == .running
            ? await probe(cluster, commands.managedKubeconfig, min(.seconds(3), remaining)) : .notReady
        let observedAt = now()
        guard observedAt < deadline else { return [] }
        let connectionFailed = status == .connectionFailed && missing.isEmpty && cluster.allNodesRunning
        let persistent = history.record(
            connectionFailed ? status : .notReady,
            for: .init(endpoint: cluster.apiEndpoint, context: name, kubeconfig: commands.managedKubeconfig),
            at: observedAt)
        if !missing.isEmpty {
            issues.append("\(name): Node missing: \(missing.joined(separator: ", "))")
        } else {
            switch cluster.state {
            case .stopped:
                issues.append("\(name): Stopped. Start it in Kubernetes or with `cstack cluster start \(name)`.")
            case .degraded:
                issues.append("\(name): Degraded")
            case .running:
                if status != .ready { issues.append("\(name): API not ready") }
                if connectionFailed {
                    issues.append(
                        persistent || commands.sawSuccessfulStart(of: cluster)
                            ? ClusterAPIReady.localNetworkHint : Self.localNetworkPossibleCause)
                }
            }
        }
        if !contexts.contains(name) { issues.append("\(name): no context in the app kubeconfig") }
        return issues
    }

    private static let localNetworkPossibleCause =
        "The API can still be starting if the cluster started in the last minute; else the runtime probably has "
        + "no Local Network permission. Allow container-runtime-linux in System Settings > Privacy & Security > Local Network."

    private func timedOut(_ started: ContinuousClock.Instant) -> DiagnosticCheck {
        check(
            .indeterminate, summary: "Kubernetes clusters: could not check",
            detail: DiagnosticRunner.budgetExpired, started: started)
    }

    private func check(
        _ verdict: Verdict, summary: String, detail: String?, started: ContinuousClock.Instant
    ) -> DiagnosticCheck {
        DiagnosticCheck(
            id: .clusters, verdict: verdict, summary: summary, detail: detail, remedy: nil,
            duration: started.duration(to: now()))
    }
}
