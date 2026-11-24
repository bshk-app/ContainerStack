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
    var seconds = 0

    func model(inspect: @escaping (String) async -> DockerContainerDetail? = { _ in nil }) -> ClusterSectionModel {
        ClusterSectionModel(
            services: ClusterSectionServices(
                capability: { self.capability },
                list: {
                    self.lists += 1
                    if self.listFails { throw ClusterListError.invalid("missing key status.state") }
                    return ClusterInventory(
                        clusters: self.cluster.map { [$0] } ?? [], nodes: self.nodes,
                        contexts: self.contexts)
                },
                checkAPI: { _ in self.api },
                run: { action, _ in
                    self.calls.append(action)
                    if self.failure == action {
                        let command = action.rawValue.lowercased()
                        throw ClusterCommandError.failed(command: command, status: 1, message: "\(command) stderr")
                    }
                },
                inspect: inspect,
                now: { .seconds(self.seconds) }
            ))
    }
}
