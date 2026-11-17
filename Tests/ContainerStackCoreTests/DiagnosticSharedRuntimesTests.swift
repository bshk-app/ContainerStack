import DiagnosticTestSupport
import Foundation
import Testing

@testable import ContainerStackCore

struct DiagnosticSharedRuntimesTests {
    @Test func statusTableAndOrphans() async throws {
        for (labels, warnings, expected) in [
            ([], [], (Verdict.ok, "Shared runtimes: off")),
            (["containerstack.shared-runtimes=on"], [], (.ok, "Shared runtimes: on")),
            (
                ["containerstack.shared-runtimes=off"],
                ["shared runtimes are off: the removal of shared containers of a previous run has not finished"],
                (.indeterminate, "Shared runtimes: starting")
            ),
            (
                ["containerstack.shared-runtimes=off"], ["shared runtimes are off: bad file"],
                (.warning, "Shared runtimes are off: bad file")
            ),
        ] as [([String], [String], (Verdict, String))] {
            let infoData = try JSONSerialization.data(withJSONObject: ["Labels": labels, "Warnings": warnings])
            let transport = StubDockerTransport(byPath: [
                "/_ping": .success(jsonResponse("OK")), "/version": .success(jsonResponse("{}")),
                "/info": .success(httpResponse(status: 200, body: infoData)),
                "/containers/json?all=1": .success(jsonResponse("[]")),
            ])
            let runner = makeRunner(transport: transport)
            let check = await runner.run(checks: [.sharedRuntimes]).check(.sharedRuntimes)
            #expect(check?.verdict == expected.0)
            #expect(check?.summary == expected.1)
            #expect(await transport.paths == ["/_ping", "/version", "/info", "/containers/json?all=1"])
        }
        for socket in ["/ours", "/dead", "/live"] {
            let transport = StubDockerTransport(responses: [])
            let runner = DiagnosticRunner(
                client: DockerAPIClient(transport: transport), probe: RecordingSystemProbe(),
                socketPath: "/ours", bridgePath: "/bridge", sharedRuntimeSocketResponds: { $0 == "/live" })
            let info = try JSONDecoder().decode(DockerInfo.self, from: Data("{}".utf8))
            let container = try JSONDecoder().decode(
                DockerContainerSummary.self,
                from: JSONSerialization.data(withJSONObject: [
                    "Id": "parent", "Names": ["/parent"], "State": "exited",
                    "Labels": ["containerstack.shared.group": "mcp", "containerstack.shared.socket": socket],
                ]))
            let check = await runner.sharedRuntimesMeasurement(
                versions: .measured(
                    version: try JSONDecoder().decode(DockerVersion.self, from: Data("{}".utf8)), info: info),
                containers: .listed([container]))
            #expect(check.verdict == (socket == "/live" ? .ok : .warning))
            #expect(check.remedy == (socket == "/live" ? nil : .manual("docker rm -f 'parent'")))
        }
    }
}
