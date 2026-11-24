import Foundation

public struct ClusterDiagnostics: Sendable {
    typealias Probe = @Sendable (KubernetesCluster, URL) async -> ClusterAPIReady.Observation

    private let commands: ClusterCommands
    private let client: DockerAPIClient
    private let probe: Probe

    public init(commands: ClusterCommands, client: DockerAPIClient) {
        self.init(commands: commands, client: client, probe: Self.apiObservation)
    }

    init(commands: ClusterCommands, client: DockerAPIClient, probe: @escaping Probe) {
        self.commands = commands
        self.client = client
        self.probe = probe
    }

    func run() async -> DiagnosticCheck {
        let started = ContinuousClock.now
        do {
            let capability = try await commands.capability()
            if capability != .capable {
                return check(
                    capability == .noClusterStart ? .failure : .skipped,
                    summary: "Kubernetes clusters", detail: capability.description, started: started)
            }
            let list = try await commands.list()
            let clusters = try KubernetesCluster.decodeList(Data(list.utf8))
            return await measure(clusters, started: started)
        } catch {
            return check(
                .failure, summary: "Kubernetes clusters: could not read inventory",
                detail: String(describing: error), started: started)
        }
    }

    private func measure(_ clusters: [KubernetesCluster], started: ContinuousClock.Instant) async -> DiagnosticCheck {
        let summary = "\(clusters.count) clusters, \(clusters.filter { $0.state == .running }.count) running"
        guard !clusters.isEmpty else { return check(.ok, summary: summary, detail: nil, started: started) }

        let presentNodes = try? await Set(client.listClusterNodes().map(\.name))
        let kubeconfig = commands.managedKubeconfig
        let text = (try? String(contentsOf: kubeconfig, encoding: .utf8)) ?? ""
        let contexts = Set(KubeconfigCA.entries(of: "contexts", in: text).compactMap { $0["name"] })
        var issues = await withTaskGroup(of: [String].self) { group in
            for cluster in clusters {
                group.addTask { await warnings(for: cluster, nodes: presentNodes, contexts: contexts) }
            }
            var details: [[String]] = []
            for await warnings in group where !warnings.isEmpty { details.append(warnings) }
            return details.sorted { ($0.first ?? "") < ($1.first ?? "") }.flatMap { $0 }
        }
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
        for cluster: KubernetesCluster, nodes: Set<String>?, contexts: Set<String>
    ) async -> [String] {
        let name = cluster.name
        var issues: [String] = []
        let missing = nodes.map { present in cluster.nodes.map(\.name).filter { !present.contains($0) } } ?? []
        if !missing.isEmpty {
            issues.append("\(name): Node missing: \(missing.joined(separator: ", "))")
        } else {
            switch cluster.state {
            case .stopped:
                issues.append("\(name): Stopped. Start it in Kubernetes or with `cstack cluster start \(name)`.")
            case .degraded:
                issues.append("\(name): Degraded")
            case .running:
                let status = await probe(cluster, commands.managedKubeconfig)
                if status != .ready { issues.append("\(name): API not ready") }
                if status == .connectionRefusedOrReset, allNodesRunning(cluster),
                    commands.sawSuccessfulStart(of: cluster)
                {
                    issues.append(Self.localNetworkLikelyCause)
                }
            }
        }
        if !contexts.contains(name) { issues.append("\(name): no context in the app kubeconfig") }
        return issues
    }

    private func allNodesRunning(_ cluster: KubernetesCluster) -> Bool {
        let running = Set(cluster.nodeStatuses.filter { $0.status == "running" }.map(\.name))
        return !cluster.nodes.isEmpty && cluster.nodes.allSatisfy { running.contains($0.name) }
    }

    static let localNetworkLikelyCause =
        "Likely cause: the runtime has no Local Network permission. Allow container-runtime-linux "
        + "in System Settings > Privacy & Security > Local Network."

    private static func apiObservation(_ cluster: KubernetesCluster, _ kubeconfig: URL) async
        -> ClusterAPIReady.Observation
    {
        await ClusterAPIReady.observe(endpoint: cluster.apiEndpoint, context: cluster.name, kubeconfig: kubeconfig)
    }

    private func check(
        _ verdict: Verdict, summary: String, detail: String?, started: ContinuousClock.Instant
    ) -> DiagnosticCheck {
        DiagnosticCheck(
            id: .clusters, verdict: verdict, summary: summary, detail: detail, remedy: nil,
            duration: started.duration(to: .now))
    }
}
