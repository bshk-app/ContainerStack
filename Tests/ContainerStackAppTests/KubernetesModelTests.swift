import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@MainActor
struct KubernetesModelTests {
    @Test func missingWorkerWinsOverDegradedAndStartFailure() async throws {
        let fake = ClusterFake()
        fake.cluster = try clusterFixture(state: "degraded", worker: "stopped")
        let model = fake.model()
        await model.refresh()
        fake.failure = .start
        await model.perform(.start, name: "dev")
        #expect(model.rows.first?.state == .startFailed("start stderr"))
        fake.nodes.remove("dev-worker-1")
        await model.refresh()
        #expect(model.rows.first?.state == .missing(["dev-worker-1"]))
    }

    @Test func failureStaysWhenReadyAndRestartStopsThenStarts() async throws {
        let fake = ClusterFake()
        fake.cluster = try clusterFixture(state: "stopped", worker: "stopped", controlPlane: "stopped")
        let model = fake.model()
        await model.refresh()
        fake.failure = .start
        await model.perform(.start, name: "dev")
        fake.cluster = try clusterFixture()
        await model.refresh()
        #expect(model.rows.first?.state == .startFailed("start stderr"))
        #expect(model.rows.first?.state.actions == [.restart, .stop, .delete])
        fake.failure = nil
        await model.perform(.restart, name: "dev")
        #expect(fake.calls == [.start, .stop, .start])
        #expect(model.rows.first?.state == .running)
    }

    @Test func apiHintNeedsSixConsecutiveConnectionFailuresOrSuccessfulStart() async throws {
        let fake = ClusterFake()
        fake.cluster = try clusterFixture()
        fake.api = .connectionFailed
        let model = fake.model()
        for _ in 0..<5 {
            await model.refresh()
            #expect(model.rows.first?.state == .apiNotReady)
            #expect(model.rows.first?.localNetworkHint == false)
            fake.seconds += 5
        }
        await model.refresh()
        #expect(model.rows.first?.localNetworkHint == true)
        fake.api = .notReady
        await model.refresh()
        #expect(model.rows.first?.localNetworkHint == false)
        fake.api = .connectionFailed
        await model.refresh()
        #expect(model.rows.first?.localNetworkHint == false)
        await model.perform(.restart, name: "dev")
        #expect(model.rows.first?.localNetworkHint == true)
    }

    @Test func runtimeDownRetainsRowsAndUnsupportedHidesThem() async throws {
        let fake = ClusterFake()
        fake.cluster = try clusterFixture()
        let model = fake.model()
        await model.refresh()
        fake.capability = .runtimeNotRunning
        await model.refresh()
        #expect(model.availability == .runtimeNotRunning)
        #expect(model.rows.count == 1)
        await model.perform(.stop, name: "dev")
        #expect(fake.calls.isEmpty)
        #expect(fake.lists == 1)
        fake.capability = .noClusterStart
        await model.refresh()
        #expect(model.availability == .noClusterStart)
        #expect(fake.lists == 1)
        #expect(!model.canAct)
    }

    @Test func inventoryErrorDoesNotReportAllNodesMissing() async throws {
        let fake = ClusterFake()
        fake.cluster = try clusterFixture()
        let model = fake.model()
        await model.refresh()
        fake.listFails = true
        await model.refresh()
        #expect(model.inventoryError == "cluster list: missing key status.state")
        #expect(!model.canAct)
        #expect(model.rows.first?.state == .running)
    }

    @Test(arguments: [ClusterCapability.runtimeNotRunning, .noClusterStart])
    func listErrorIsVisibleAfterCapabilityRecovers(previous: ClusterCapability) async {
        let fake = ClusterFake()
        fake.capability = previous
        let model = fake.model()
        await model.refresh()
        #expect(model.availability == previous)

        fake.capability = .capable
        fake.listFails = true
        await model.refresh()

        #expect(model.availability == .capable)
        #expect(model.inventoryError == "cluster list: missing key status.state")
        #expect(!model.canAct)
    }

    @Test(arguments: [RacingOperation.delete, .failedCreate, .successfulStart])
    func operationRefreshSurvivesOverlappingPoll(operation: RacingOperation) async throws {
        let (fake, expected) = try operation.fixture()
        let model = fake.model()
        await model.refresh()
        let operationList = ClusterListGate()
        let pollList = ClusterListGate()
        fake.listGates = [2: operationList, 3: pollList]
        defer {
            operationList.open()
            pollList.open()
        }

        let mutation = Task { await operation.run(on: model) }
        await operationList.waitUntilEntered()
        let poll = Task { await model.refresh() }
        await pollList.waitUntilEntered()
        operationList.open()
        await mutation.value

        #expect(model.activity == nil)
        #expect(model.rows.first?.state == expected)
        #expect(model.actionError == nil)
        if operation == .successfulStart {
            #expect(model.rows.first?.localNetworkHint == true)
        }

        pollList.open()
        _ = await poll.value
        #expect(model.rows.first?.state == expected)
        if operation == .successfulStart {
            #expect(model.rows.first?.localNetworkHint == true)
        }
    }

    @Test func successfulCreateClearsPreviousFailureWithoutAnInterveningPoll() async throws {
        let fake = ClusterFake()
        let model = fake.model()
        await model.refresh()
        var draft = ClusterCreateDraft()
        draft.name = "dev"
        fake.createCluster = { throw ClusterCommandError.failed(command: "create", status: 1, message: "old error") }
        await model.create(draft)
        #expect(model.actionError == "Create failed: old error")
        #expect(model.rows.isEmpty)

        let running = try clusterFixture()
        fake.createCluster = { [unowned fake] in fake.cluster = running }
        await model.create(draft)

        #expect(model.rows.first?.state == .running)
        #expect(model.rows.first?.error == nil)
        #expect(model.actionError == nil)
    }

    @Test func stopFailureDisplaysStderrAndDoesNotStartAReboot() async throws {
        let fake = ClusterFake()
        fake.cluster = try clusterFixture()
        let model = fake.model()
        await model.refresh()
        fake.failure = .stop
        await model.perform(.stop, name: "dev")
        #expect(model.rows.first?.error == "stop stderr")
        fake.api = .notReady
        await model.refresh()
        await model.perform(.restart, name: "dev")
        #expect(fake.calls == [.stop, .stop])
        #expect(model.rows.first?.state == .startFailed("stop stderr"))
    }

    @Test func missingWorkerAllowsOnlyDeleteEvenWithRunningControlPlane() async throws {
        let fake = ClusterFake()
        fake.cluster = try clusterFixture(state: "degraded", worker: "stopped")
        fake.nodes.remove("dev-worker-1")
        let model = fake.model()
        await model.refresh()
        #expect(!model.canWrite(name: "dev"))
        #expect(!model.preflightAdd(name: "dev"))
        #expect(model.rows.first?.state.actions == [.delete])
    }

    @Test func runtimeGatePreventsEvenTheCapabilityProbe() async {
        var probes = 0
        let model = ClusterSectionModel(
            services: ClusterSectionServices(
                capability: {
                    probes += 1
                    return .capable
                },
                list: {
                    Issue.record("Unexpected list")
                    return ClusterInventory()
                },
                checkAPI: { _ in .notReady },
                run: { _, _ in Issue.record("Unexpected mutation") },
                canReachRuntime: { false }
            ))
        await model.refresh()
        #expect(probes == 0)
        #expect(model.availability == .runtimeNotRunning)
    }

    @Test func readsLatestIpAndFindsMissingManagedContext() async throws {
        let fake = ClusterFake()
        fake.cluster = try clusterFixture(ip: "192.168.64.3")
        let model = fake.model()
        await model.refresh()
        #expect(model.rows.first?.cluster.nodeStatuses.first?.addresses == ["192.168.64.3"])
        #expect(model.rows.first?.hasContext == false)
        fake.cluster = try clusterFixture(ip: "192.168.64.7")
        fake.contexts = ["dev"]
        await model.refresh()
        #expect(model.rows.first?.cluster.nodeStatuses.first?.addresses == ["192.168.64.7"])
        #expect(model.rows.first?.hasContext == true)
    }
}

enum RacingOperation: Sendable {
    case delete, failedCreate, successfulStart

    @MainActor
    func fixture() throws -> (ClusterFake, ClusterRowState?) {
        let fake = ClusterFake()
        let stopped = try clusterFixture(state: "stopped", worker: "stopped", controlPlane: "stopped")
        let running = try clusterFixture()
        switch self {
        case .delete:
            fake.cluster = running
            fake.mutateCluster = { [unowned fake] _ in fake.cluster = nil }
            return (fake, nil)
        case .failedCreate:
            fake.createCluster = { [unowned fake] in
                fake.cluster = stopped
                throw ClusterCommandError.failed(command: "create", status: 1, message: "new error")
            }
            return (fake, .startFailed("new error"))
        case .successfulStart:
            fake.cluster = stopped
            fake.mutateCluster = { [unowned fake] _ in
                fake.cluster = running
                fake.api = .connectionFailed
            }
            return (fake, .apiNotReady)
        }
    }

    @MainActor
    func run(on model: ClusterSectionModel) async {
        switch self {
        case .delete:
            await model.perform(.delete, name: "dev")
        case .failedCreate:
            var draft = ClusterCreateDraft()
            draft.name = "dev"
            await model.create(draft)
        case .successfulStart:
            await model.perform(.start, name: "dev")
        }
    }
}

@MainActor
final class ClusterListGate {
    private let entered = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()

    func waitUntilEntered() async {
        for await _ in entered.stream {}
    }

    func park() async {
        entered.continuation.finish()
        for await _ in release.stream {}
    }

    func open() { release.continuation.finish() }
}

func clusterFixture(
    state: String = "running", worker: String = "running", controlPlane: String = "running",
    ip: String = "192.168.64.3"
) throws -> KubernetesCluster {
    let list = try KubernetesCluster.decodeList(
        Data(
            """
            [{
              "configuration": {"name":"dev","kubernetesVersion":"v1.35.5","remove":false,"sharedImageStore":false,
                "creationDate":"2026-11-23T17:23:33Z","nodes":[
                  {"name":"dev","roles":["control-plane"]},{"name":"dev-worker-1","roles":["worker"]}]},
              "status":{"state":"\(state)","nodes":[
                {"name":"dev","status":"\(controlPlane)","addresses":["\(ip)"],"ports":["6445->6443"]},
                {"name":"dev-worker-1","status":"\(worker)"}]}
            }]
            """.utf8))
    return try #require(list.first)
}

@MainActor
final class ClusterFake {
    var cluster: KubernetesCluster?
    var nodes: Set<String> = ["dev", "dev-worker-1"]
    var contexts: Set<String> = []
    var capability: ClusterCapability = .capable
    var api: ClusterAPIReady.Result = .ready
    var calls: [ClusterAction] = []
    var failure: ClusterAction?
    var lists = 0
    var listFails = false
    var listGates: [Int: ClusterListGate] = [:]
    var createCluster: () throws -> Void = {}
    var mutateCluster: (ClusterAction) -> Void = { _ in }
    var seconds = 0

    func model(inspect: @escaping (String) async -> DockerContainerDetail? = { _ in nil }) -> ClusterSectionModel {
        ClusterSectionModel(
            services: ClusterSectionServices(
                capability: { self.capability },
                list: {
                    self.lists += 1
                    if self.listFails { throw ClusterListError.invalid("missing key status.state") }
                    let snapshot = ClusterInventory(
                        clusters: self.cluster.map { [$0] } ?? [], nodes: self.nodes,
                        contexts: self.contexts)
                    await self.listGates[self.lists]?.park()
                    return snapshot
                },
                checkAPI: { _ in self.api },
                run: { action, _ in
                    self.calls.append(action)
                    if self.failure == action {
                        let command = action.rawValue.lowercased()
                        throw ClusterCommandError.failed(command: command, status: 1, message: "\(command) stderr")
                    }
                    self.mutateCluster(action)
                },
                create: { _, _ in try self.createCluster() },
                inspect: inspect,
                now: { .seconds(self.seconds) }
            ))
    }
}
