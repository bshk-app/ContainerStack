import DiagnosticTestSupport
import Foundation
import Synchronization
import Testing

@testable import ContainerStackCore

struct ClusterDiagnosticsTests {
    @Test func listsClusterWarningsWithTheirNamesAndActions() async throws {
        let home = try TemporaryHome()
        let clusters =
            "["
            + [
                clusterJSON("stopped", state: "stopped"),
                clusterJSON("degraded", state: "degraded"),
                clusterJSON("broken", state: "running"),
                clusterJSON("missing", state: "stopped"),
            ].joined(separator: ",") + "]"
        let transport = nodeTransport(present: ["stopped", "degraded", "broken"])
        let commands = clusterCommands(home, inventory: clusters)
        let check = await ClusterDiagnostics(
            commands: commands, client: DockerAPIClient(transport: transport),
            probe: { _, _, _ in .notReady }
        ).run()
        #expect(check.id == .clusters)
        #expect(check.verdict == .warning)
        #expect(
            check.detail?.contains("stopped: Stopped. Start it in Kubernetes or with `cstack cluster start stopped`.")
                == true)
        #expect(check.detail?.contains("degraded: Degraded") == true)
        #expect(check.detail?.contains("broken: API not ready") == true)
        #expect(check.detail?.contains("missing: Node missing: missing") == true)
        #expect(check.detail?.contains("broken: no context in the app kubeconfig") == true)
        #expect(check.detail?.contains("Likely cause:") == false)
    }

    @Test(arguments: [true, false])
    func undecodableListAndUnsupportedRuntimeAreFailures(supported: Bool) async throws {
        let home = try TemporaryHome()
        let check = await ClusterDiagnostics(
            commands: clusterCommands(home, inventory: "[{}]", supported: supported),
            client: DockerAPIClient(transport: nodeTransport(present: []))
        ).run()
        #expect(check.verdict == .failure)
        #expect(check.detail?.contains(supported ? "configuration" : "no cluster start") == true)
    }

    @Test func clustersAreIncludedInBothDoctorReports() async throws {
        let home = try TemporaryHome()
        let transport = nodeTransport(present: [])
        let client = DockerAPIClient(transport: transport)
        let diagnostic = ClusterDiagnostics(commands: clusterCommands(home, inventory: "[]"), client: client)
        let runner = DiagnosticRunner(
            client: client,
            probe: RecordingSystemProbe(),
            socketPath: "/fake/socket",
            bridgePath: "/fake/bridge",
            clusterDiagnostics: diagnostic
        )
        let report = await runner.run(checks: [.clusters])
        #expect(CheckID.uiSet.contains(.clusters))
        #expect(CheckID.cliSet.contains(.clusters))
        #expect(report.check(.clusters)?.verdict == .ok)
        #expect(DoctorTextRenderer.render(report) == "0 clusters, 0 running")
    }

    @Test(arguments: [0, 1, 2])
    func doctorCountsClustersWithNumberAgreement(count: Int) async throws {
        let home = try TemporaryHome()
        let names = (0..<count).map { "node-\($0)" }
        let inventory = "[" + names.map { clusterJSON($0, state: "running") }.joined(separator: ",") + "]"
        let check = await ClusterDiagnostics(
            commands: clusterCommands(home, inventory: inventory),
            client: DockerAPIClient(transport: nodeTransport(present: names)),
            probe: { _, _, _ in .ready }
        ).run()
        #expect(check.summary == ["0 clusters, 0 running", "1 cluster, 1 running", "2 clusters, 2 running"][count])
    }

    @Test func memoryIncludesRunningNodesOnlyFoundThroughTheLabelFilter() async throws {
        let home = try TemporaryHome()
        let transport = StubDockerTransport(byPath: [
            "/_ping": .success(jsonResponse("OK")),
            "/containers/json?all=1": .success(jsonResponse("[]")),
            DockerAPIClient.clusterNodesPath: .success(
                jsonResponse(
                    #"[{"Id":"n1","Names":["/dev"],"State":"running"},{"Id":"n2","State":"exited"}]"#)),
            DockerAPIClient.runningBuildersPath: .success(jsonResponse("[]")),
            "/containers/n1/json": .success(
                jsonResponse(
                    #"{"Id":"n1","Name":"/dev","State":{"Running":true},"HostConfig":{"Memory":4000000000}}"#)),
        ])
        let client = DockerAPIClient(transport: transport)
        let diagnostic = ClusterDiagnostics(commands: clusterCommands(home, inventory: "[]"), client: client)
        let runner = DiagnosticRunner(
            client: client,
            probe: RecordingSystemProbe(),
            socketPath: "/fake/socket",
            bridgePath: "/fake/bridge",
            hostMemoryBytes: { 16_000_000_000 },
            clusterDiagnostics: diagnostic
        )
        let check = await runner.run(checks: [.memoryCommitment]).check(.memoryCommitment)
        #expect(check?.verdict == .ok)
        #expect(check?.summary.contains("4.0 GB in configured container limits") == true)
        let requests = await transport.paths.compactMap(\.removingPercentEncoding)
        #expect(requests.contains(#"/containers/json?all=1&filters={"label":["com.apple.container.plugin=cluster"]}"#))
        #expect(await !transport.paths.contains("/containers/n2/json"))
    }

    @Test(arguments: [true, false], [true, false])
    func resetOrRefusalNeedsAllNodesAndEvidenceTheAPIAlreadyStarted(allRunning: Bool, created: Bool) async throws {
        let home = try TemporaryHome()
        let record = clusterJSON("dev", state: "running").replacingOccurrences(
            of: #""status":"running""#, with: allRunning ? #""status":"running""# : #""status":"exited""#)
        let commands = clusterCommands(home, inventory: "[\(record)]")
        let transport = nodeTransport(present: ["dev"])
        let diagnosis = ClusterDiagnostics(
            commands: commands, client: DockerAPIClient(transport: transport),
            probe: { _, _, _ in .connectionFailed })
        let beforeStart = await diagnosis.run()
        #expect(beforeStart.detail?.contains("Likely cause:") == false)
        #expect(
            beforeStart.detail?.contains(
                "The API can still be starting if the cluster started in the last minute; else the runtime probably has "
                    + "no Local Network permission. Allow container-runtime-linux in System Settings > Privacy & Security > Local Network."
            ) == allRunning)
        if created {
            try await commands.create(name: "dev", options: [])
        } else {
            try await commands.start(name: "dev")
        }
        let afterStart = await diagnosis.run()
        #expect(
            afterStart.detail?.contains(
                "Likely cause: the runtime has no Local Network permission. Allow container-runtime-linux "
                    + "in System Settings > Privacy & Security > Local Network.") == allRunning)
    }

    @Test(arguments: [false, true])
    func usesPriorProbesWithoutWaitingOrRetryingInAReport(interrupted: Bool) async throws {
        let home = try TemporaryHome()
        let start = ContinuousClock.now
        let offset = Mutex(Duration.zero)
        let probes = Mutex(0)
        let commands = clusterCommands(home, inventory: "[\(clusterJSON("dev", state: "running"))]")
        let diagnostic = ClusterDiagnostics(
            commands: commands,
            client: DockerAPIClient(transport: nodeTransport(present: ["dev"])),
            now: { start + offset.withLock { $0 } },
            probe: { _, _, _ in
                probes.withLock { $0 += 1 }
                return interrupted && offset.withLock({ $0 }) == .seconds(25) ? .notReady : .connectionFailed
            })
        for tick in 0...6 {
            offset.withLock { $0 = .seconds(tick * 5) }
            let check = await diagnostic.run()
            #expect(probes.withLock { $0 } == tick + 1)
            #expect(check.detail?.contains("Likely cause:") == (tick == 6 && !interrupted))
        }
    }

    @Test func aRunningRecordWithAMissingNodeStillGetsOneProbeAndNoPermissionHint() async throws {
        let home = try TemporaryHome()
        let probes = Mutex(0)
        let commands = clusterCommands(home, inventory: "[\(clusterJSON("dev", state: "running"))]")
        let diagnostic = ClusterDiagnostics(
            commands: commands,
            client: DockerAPIClient(transport: nodeTransport(present: [])),
            probe: { _, _, _ in
                probes.withLock { $0 += 1 }
                return .connectionFailed
            })
        let check = await diagnostic.run()
        #expect(probes.withLock { $0 } == 1)
        #expect(check.detail?.contains("Node missing:") == true)
        #expect(check.detail?.contains("Local Network permission") == false)
    }

    @Test func capsTheProbeAtTheReportDeadlineAndSkipsItAfterExpiry() async throws {
        let home = try TemporaryHome()
        let start = ContinuousClock.now
        let offset = Mutex(Duration.zero)
        let limits = Mutex([Duration]())
        let diagnostic = ClusterDiagnostics(
            commands: clusterCommands(home, inventory: "[\(clusterJSON("dev", state: "running"))]"),
            client: DockerAPIClient(transport: nodeTransport(present: ["dev"])),
            now: { start + offset.withLock { $0 } },
            probe: { _, _, limit in
                limits.withLock { $0.append(limit) }
                return .connectionFailed
            })
        let deadline = start + .milliseconds(500)
        let withinBudget = await diagnostic.run(until: deadline)
        #expect(withinBudget.verdict == .warning)
        #expect(limits.withLock { $0 } == [.milliseconds(500)])

        offset.withLock { $0 = .milliseconds(500) }
        let expired = await diagnostic.run(until: deadline)
        #expect(expired.verdict == .indeterminate)
        #expect(limits.withLock { $0 } == [.milliseconds(500)])
    }

    private func clusterCommands(
        _ home: borrowing TemporaryHome, inventory: String, supported: Bool = true
    ) -> ClusterCommands {
        let recorder = ClusterSpawnRecorder { launch in
            if launch.arguments.last == "json" { return .init(status: 0, output: inventory) }
            if launch.arguments.last == "--help" {
                return .init(status: 0, output: supported ? "USAGE: cluster \(launch.arguments[1])" : "USAGE: cluster")
            }
            return .init(status: 0, output: "fake version")
        }
        return ClusterCommands(
            containerPath: "/fake/container", home: home.url, environment: [:],
            spawn: recorder.spawn, capabilityCache: .init(), lock: .init())
    }

    private func nodeTransport(present: [String]) -> StubDockerTransport {
        let nodes = present.map { #"{"Id":"\#($0)","Names":["/\#($0)"],"State":"running"}"# }
        return StubDockerTransport(byPath: [
            "/_ping": .success(jsonResponse("OK")),
            DockerAPIClient.clusterNodesPath: .success(jsonResponse("[\(nodes.joined(separator: ","))]")),
        ])
    }

    private func clusterJSON(_ name: String, state: String) -> String {
        """
        {"configuration":{"name":"\(name)","creationDate":"2026-11-01T00:00:00Z","kubernetesVersion":"v1",
        "remove":false,"sharedImageStore":false,"nodes":[{"name":"\(name)","roles":["control-plane"]}]},
        "status":{"state":"\(state)","nodes":[{"name":"\(name)","status":"\(state)","ports":["6445->6443"]}]}}
        """
    }
}
