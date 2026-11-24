import DiagnosticTestSupport
import Foundation
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
            probe: { _, _ in .notReady }
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

    @Test(arguments: [true, false])
    func resetOrRefusalNeedsAllNodesAndEvidenceTheAPIAlreadyStarted(allRunning: Bool) async throws {
        let home = try TemporaryHome()
        let record = clusterJSON("dev", state: "running").replacingOccurrences(
            of: #""status":"running""#, with: allRunning ? #""status":"running""# : #""status":"exited""#)
        let commands = clusterCommands(home, inventory: "[\(record)]")
        let transport = nodeTransport(present: ["dev"])
        let diagnosis = ClusterDiagnostics(
            commands: commands, client: DockerAPIClient(transport: transport),
            probe: { _, _ in .connectionRefusedOrReset })
        let beforeStart = await diagnosis.run()
        #expect(beforeStart.detail?.contains("Likely cause:") == false)
        try await commands.start(name: "dev")
        let afterStart = await diagnosis.run()
        #expect(
            afterStart.detail?.contains(
                "Likely cause: the runtime has no Local Network permission. Allow container-runtime-linux "
                    + "in System Settings > Privacy & Security > Local Network.") == allRunning)
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
