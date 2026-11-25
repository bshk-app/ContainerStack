import ContainerStackCore
import Foundation
import Observation

struct ClusterInventory {
    var clusters: [KubernetesCluster] = []
    var nodes: Set<String> = []
    var contexts: Set<String> = []
}

@MainActor
struct ClusterSectionServices {
    var capability: () async throws -> ClusterCapability
    var list: () async throws -> ClusterInventory
    var checkAPI: @MainActor @Sendable (KubernetesCluster) async -> ClusterAPIReady.Result
    var run: (ClusterAction, String) async throws -> Void
    var create: (String, [String]) async throws -> Void = { _, _ in }
    var checkAdd: (String) throws -> Void = { _ in }
    var write: (String, ClusterCommands.Kubeconfig) async throws -> Void = { _, _ in }
    var cleanup: (KubernetesCluster) -> [String] = { _ in [] }
    var inspect: (String) async -> DockerContainerDetail? = { _ in nil }
    var canReachRuntime: () -> Bool = { true }
    var canMutate: () -> Bool = { true }
    var now: () -> Duration = { ClusterSectionModel.clockOrigin.duration(to: .now) }
}

struct ClusterRow: Identifiable {
    var cluster: KubernetesCluster
    var state: ClusterRowState
    var missing: [String]
    var hasContext: Bool
    var localNetworkHint: Bool
    var error: String?

    var id: String { cluster.name }

    var canWriteKubeconfig: Bool {
        guard missing.isEmpty else { return false }
        guard let node = cluster.nodes.first(where: { $0.roles.contains("control-plane") }) else { return false }
        return !missing.contains(node.name)
            && cluster.nodeStatuses.contains { $0.name == node.name && $0.status == "running" }
    }
}

@MainActor @Observable
final class ClusterSectionModel {
    struct Activity {
        let name: String
        var operation: ClusterOperation
    }

    private struct Refusals {
        var count: Int
        var last: Duration
    }

    static let clockOrigin = ContinuousClock.now
    private let services: ClusterSectionServices
    private var inventory = ClusterInventory()
    private var readiness: [String: ClusterAPIReady.Result] = [:]
    private var refusals: [String: Refusals] = [:]
    private var startFailures: [String: String] = [:]
    private var errors: [String: String] = [:]
    private var refreshToken = 0

    private(set) var availability: ClusterCapability?
    private(set) var inventoryError: String?
    private(set) var actionError: String?
    private(set) var activity: Activity?

    init(services: ClusterSectionServices) {
        self.services = services
    }

    var canAct: Bool {
        availability == .capable && inventoryError == nil && activity == nil && services.canMutate()
    }

    var names: Set<String> { Set(inventory.clusters.map(\.name)) }

    var rows: [ClusterRow] {
        inventory.clusters.map { cluster in
            let name = cluster.name
            let missing = cluster.nodes.map(\.name).filter { !inventory.nodes.contains($0) }
            let running = cluster.nodeStatuses.count { $0.status == "running" }
            let state = ClusterRowState.resolve(
                operation: activity?.name == name ? activity?.operation : nil,
                missing: missing, startFailure: startFailures[name], runtimeState: cluster.state,
                runningNodes: running, totalNodes: cluster.nodes.count, apiReady: readiness[name] == .ready)
            let hint = state == .apiNotReady && refusals[name, default: Refusals(count: 0, last: .zero)].count >= 6
            let error = if case .startFailed(let message) = state { message } else { errors[name] }
            return ClusterRow(
                cluster: cluster, state: state, missing: missing, hasContext: inventory.contexts.contains(name),
                localNetworkHint: hint, error: error)
        }
    }

    func poll() async {
        let clock = ContinuousClock()
        let interval: Duration = .seconds(5)
        while !Task.isCancelled {
            let next = clock.now.advanced(by: interval)
            await refresh()
            try? await clock.sleep(until: next)
        }
    }

    @discardableResult
    func refresh(afterStart: String? = nil) async -> Bool {
        guard !Task.isCancelled else { return false }
        refreshToken += 1
        let token = refreshToken
        guard services.canReachRuntime() else {
            markRuntimeDown()
            return true
        }
        var confirmedCapability = false
        do {
            let capability = try await services.capability()
            guard token == refreshToken, !Task.isCancelled else { return false }
            guard services.canReachRuntime() else {
                markRuntimeDown()
                return true
            }
            guard capability == .capable else {
                availability = capability
                inventoryError = nil
                refusals.removeAll()
                return true
            }

            confirmedCapability = true
            let next = try await services.list()
            let results = await checkReadyClusters(next.clusters)
            guard token == refreshToken, !Task.isCancelled else { return false }
            guard services.canReachRuntime() else {
                markRuntimeDown()
                return true
            }
            publish(next, results: results, afterStart: afterStart)
        } catch {
            guard token == refreshToken, !Task.isCancelled else { return false }
            guard services.canReachRuntime() else {
                markRuntimeDown()
                return true
            }
            if confirmedCapability { availability = .capable }
            inventoryError = Self.message(error)
            refusals.removeAll()
        }
        return true
    }

    private func refreshAfterOperation(afterStart: String? = nil) async {
        while !Task.isCancelled {
            if await refresh(afterStart: afterStart) { return }
        }
    }

    func markRuntimeDown() {
        refreshToken += 1
        availability = .runtimeNotRunning
        inventoryError = nil
        refusals.removeAll()
    }

    private func checkReadyClusters(_ clusters: [KubernetesCluster]) async -> [String: ClusterAPIReady.Result] {
        let checkAPI = services.checkAPI
        return await withTaskGroup(of: (String, ClusterAPIReady.Result).self) { group in
            for cluster in clusters where cluster.state == .running {
                group.addTask { (cluster.name, await checkAPI(cluster)) }
            }
            var results: [String: ClusterAPIReady.Result] = [:]
            for await (name, result) in group { results[name] = result }
            return results
        }
    }

    private func publish(
        _ next: ClusterInventory, results: [String: ClusterAPIReady.Result], afterStart: String?
    ) {
        let previous = Dictionary(
            inventory.clusters.map { ($0.name, $0.creationDate) }, uniquingKeysWith: { _, last in last })
        for cluster in next.clusters
        where previous[cluster.name] != cluster.creationDate && activity?.name != cluster.name {
            startFailures.removeValue(forKey: cluster.name)
            errors.removeValue(forKey: cluster.name)
            refusals.removeValue(forKey: cluster.name)
        }
        inventory = next
        readiness = results
        updateRefusals(afterStart: afterStart)
        let retained = names.union(activity.map { [$0.name] } ?? [])
        startFailures = startFailures.filter { retained.contains($0.key) }
        errors = errors.filter { retained.contains($0.key) }
        availability = .capable
        inventoryError = nil
    }

    private func updateRefusals(afterStart: String?) {
        let now = services.now()
        var next: [String: Refusals] = [:]
        for cluster in inventory.clusters where readiness[cluster.name] == .connectionFailed {
            let running = Set(cluster.nodeStatuses.filter { $0.status == "running" }.map(\.name))
            guard !cluster.nodes.isEmpty,
                cluster.nodes.allSatisfy({ running.contains($0.name) && inventory.nodes.contains($0.name) })
            else { continue }
            let prior = refusals[cluster.name]
            var count = 1
            if cluster.name == afterStart {
                count = 6
            } else if let prior, now - prior.last <= .seconds(8) {
                if now - prior.last < .seconds(4) {
                    next[cluster.name] = prior
                    continue
                }
                count = min(6, prior.count + 1)
            }
            next[cluster.name] = Refusals(count: count, last: now)
        }
        refusals = next
    }

    func perform(_ action: ClusterAction, name: String) async {
        guard canAct, rows.first(where: { $0.id == name })?.state.actions.contains(action) == true else { return }
        let operation: ClusterOperation =
            switch action {
            case .start: .starting
            case .stop, .restart: .stopping
            case .delete: .deleting
            }
        begin(operation, name: name)
        var didStart = false
        do {
            if action == .restart {
                try await services.run(.stop, name)
                startFailures.removeValue(forKey: name)
                guard services.canMutate() else {
                    activity = nil
                    return
                }
                activity?.operation = .starting
                try await services.run(.start, name)
            } else {
                try await services.run(action, name)
            }
            didStart = action == .start || action == .restart
            startFailures.removeValue(forKey: name)
        } catch {
            record(error, name: name, isStartFailure: action == .start || action == .restart)
        }
        await refreshAfterOperation(afterStart: didStart ? name : nil)
        activity = nil
    }

    func create(_ draft: ClusterCreateDraft) async {
        guard canAct, draft.nameError(existing: names) == nil, draft.optionsError == nil else { return }
        let name = draft.name
        begin(.creating, name: name)
        var succeeded = false
        do {
            try await services.create(name, draft.options)
            startFailures.removeValue(forKey: name)
            succeeded = true
        } catch {
            record(error, name: name, isStartFailure: true)
        }
        await refreshAfterOperation(afterStart: succeeded ? name : nil)
        if let failure = startFailures[name], !names.contains(name) {
            actionError = "Create failed: \(failure)"
        }
        activity = nil
    }

    func preflightAdd(name: String) -> Bool {
        guard canWrite(name: name) else { return false }
        do {
            try services.checkAdd(name)
            actionError = nil
            return true
        } catch {
            actionError = Self.message(error)
            return false
        }
    }

    func canWrite(name: String) -> Bool {
        canAct && rows.first(where: { $0.id == name })?.canWriteKubeconfig == true
    }

    func write(name: String, target: ClusterCommands.Kubeconfig) async {
        guard canWrite(name: name) else { return }
        begin(.writing, name: name)
        do { try await services.write(name, target) } catch { record(error, name: name, isStartFailure: false) }
        await refreshAfterOperation()
        activity = nil
    }

    func cleanupCommands(for row: ClusterRow) -> [String] { services.cleanup(row.cluster) }

    func nodeDetails(name: String) async -> DockerContainerDetail? {
        guard availability == .capable, services.canReachRuntime() else { return nil }
        return await services.inspect(name)
    }

    private func begin(_ operation: ClusterOperation, name: String) {
        refreshToken += 1
        activity = Activity(name: name, operation: operation)
        errors.removeValue(forKey: name)
        refusals.removeValue(forKey: name)
        actionError = nil
    }

    private func record(_ error: Error, name: String, isStartFailure: Bool) {
        let message = Self.message(error)
        if isStartFailure {
            startFailures[name] = message
        } else {
            errors[name] = message
        }
    }

    private static func message(_ error: Error) -> String {
        if case ClusterCommandError.failed(_, _, let stderr) = error, !stderr.isEmpty { return stderr }
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        return String(describing: error)
    }
}
