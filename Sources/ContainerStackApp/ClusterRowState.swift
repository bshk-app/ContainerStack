import ContainerStackCore

enum ClusterOperation: String, Equatable, Sendable {
    case creating = "Creating"
    case starting = "Starting"
    case stopping = "Stopping"
    case deleting = "Deleting"
    case writing = "Writing Kubeconfig"
}

enum ClusterAction: String, Equatable, Sendable, CaseIterable {
    case start = "Start"
    case stop = "Stop"
    case restart = "Restart"
    case delete = "Delete"
}

enum ClusterRowState: Equatable, Sendable {
    case operating(ClusterOperation)
    case missing([String])
    case startFailed(String)
    case apiNotReady
    case running
    case degraded(Int, Int)
    case stopped

    static func resolve(
        operation: ClusterOperation?, missing: [String], startFailure: String?,
        runtimeState: KubernetesCluster.State, runningNodes: Int, totalNodes: Int, apiReady: Bool
    ) -> Self {
        if let operation { return .operating(operation) }
        if !missing.isEmpty { return .missing(missing) }
        if let startFailure { return .startFailed(startFailure) }
        switch runtimeState {
        case .running: return apiReady ? .running : .apiNotReady
        case .degraded: return .degraded(runningNodes, totalNodes)
        case .stopped: return .stopped
        }
    }

    var actions: [ClusterAction] {
        switch self {
        case .operating: []
        case .missing: [.delete]
        case .startFailed: [.restart, .stop, .delete]
        case .apiNotReady: [.restart, .delete]
        case .running: [.stop, .delete]
        case .degraded: [.start, .stop, .delete]
        case .stopped: [.start, .delete]
        }
    }

    var label: String {
        switch self {
        case .operating(let operation): "\(operation.rawValue)…"
        case .missing(let names): "Node missing: \(names.joined(separator: ", "))"
        case .startFailed: "Start failed"
        case .apiNotReady: "API not ready"
        case .running: "Running"
        case .degraded(let running, let total):
            "Degraded: \(running) of \(KubernetesCluster.nodeCountLabel(total)) running"
        case .stopped: "Stopped"
        }
    }
}
