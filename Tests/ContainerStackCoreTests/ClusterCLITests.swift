import Foundation
import Testing

@testable import ContainerStackCore

private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var out: [String] = []
    private var err: [String] = []

    var standardOutput: String { lock.withLock { out.joined() } }
    var standardError: String { lock.withLock { err.joined() } }

    func write(_ text: String) { lock.withLock { out.append(text) } }
    func writeError(_ text: String) { lock.withLock { err.append(text) } }
}

struct ClusterCLITests {
    private static let capableHelp: [String: String] = [
        "start": "USAGE: cluster start [--name <name>]",
        "stop": "USAGE: cluster stop [--name <name>]",
    ]

    private func runtime(
        running: Bool = true,
        capable: Bool = true,
        listJSON: String = String(decoding: clusterListFixture, as: UTF8.self),
        clusterExit: Int32 = 0
    ) -> ClusterSpawnRecorder {
        ClusterSpawnRecorder { launch in
            switch launch.arguments {
            case ["system", "status"]: return .init(status: running ? 0 : 1, output: "")
            case ["--version"]: return .init(status: 0, output: "1.7.1 (build: release, commit: 17bb57e)")
            case let help where help.last == "--help":
                return .init(
                    status: 0, output: capable ? Self.capableHelp[help[1]] ?? "" : "USAGE: cluster <subcommand>")
            case ["cluster", "list", "--format", "json"]: return .init(status: 0, output: listJSON)
            default: return .init(status: clusterExit, output: "")
            }
        }
    }

    private func run(
        _ arguments: [String],
        _ recorder: ClusterSpawnRecorder,
        environment: [String: String] = [:]
    ) async throws -> (Int32, Output, URL) {
        let home = try TemporaryHome()
        let output = Output()
        let commands = ClusterCommands(
            containerPath: "/opt/runtime/bin/container", home: home.url, environment: environment,
            spawn: recorder.spawn, capabilityCache: ClusterCapabilityCache(), lock: ClusterOperationLock())
        let status = await ClusterCLI(commands: commands, write: output.write, writeError: output.writeError)
            .run(arguments)
        return (status, output, home.url)
    }

    private func clusterLaunches(_ recorder: ClusterSpawnRecorder) -> [[String]] {
        recorder.launches.map(\.arguments).filter { $0.first == "cluster" && $0.last != "--help" }
    }

    @Test(
        "each subcommand runs one runtime command",
        arguments: [
            (["ls"], ["cluster", "list", "--format", "json"]),
            (["ls", "--json"], ["cluster", "list", "--format", "json"]),
            (["create", "dev"], ["cluster", "create", "--name", "dev"]),
            (
                [
                    "create", "dev", "--cpus", "4", "--memory", "8g", "--workers", "2", "--workers",
                    "count=1,cpus=2,memory=4g", "--node-image", "kindest/node:v1.35.5", "--cni", "NONE",
                    "--shared-image-store",
                ],
                [
                    "cluster", "create", "--name", "dev", "--cpus", "4", "--memory", "8g", "--workers", "2",
                    "--workers",
                    "count=1,cpus=2,memory=4g", "--node-image", "kindest/node:v1.35.5", "--cni", "NONE",
                    "--shared-image-store",
                ]
            ),
            (["start", "dev"], ["cluster", "start", "--name", "dev"]),
            (["stop", "dev"], ["cluster", "stop", "--name", "dev"]),
            (["rm", "dev"], ["cluster", "delete", "--name", "dev"]),
            (["kubeconfig", "dev"], ["cluster", "write-config", "--name", "dev"]),
        ])
    func argumentMapping(arguments: [String], expected: [String]) async throws {
        let recorder = runtime()

        let (status, _, _) = try await run(arguments, recorder)

        #expect(status == 0)
        #expect(clusterLaunches(recorder) == [expected])
    }

    @Test("the shell's KUBECONFIG is not passed")
    func shellKubeconfigIsNotPassed() async throws {
        let recorder = runtime()

        let (_, _, home) = try await run(["start", "dev"], recorder, environment: ["KUBECONFIG": "/tmp/shell-config"])

        #expect(recorder.launches.count == 5)
        #expect(
            Set(recorder.launches.map { $0.environment["KUBECONFIG"] })
                == [home.appending(path: ".containerstack/kubeconfig").path])
    }

    @Test(
        "usage errors exit 64 and run nothing",
        arguments: [
            [], ["unknown"], ["start"], ["start", "a", "b"], ["create"], ["create", "dev", "--rm"],
            ["create", "dev", "--cpus"], ["create", "dev", "--cpus", "--shared-image-store"], ["ls", "--all"], ["rm"],
            ["kubeconfig"],
        ])
    func usageErrors(arguments: [String]) async throws {
        let recorder = runtime()

        let (status, output, _) = try await run(arguments, recorder)

        #expect(status == 64)
        #expect(recorder.launches.isEmpty)
        #expect(!output.standardError.isEmpty)
    }

    @Test("a runtime that does not run exits 69")
    func runtimeDownExits69() async throws {
        let recorder = runtime(running: false)

        let (status, output, _) = try await run(["ls"], recorder)

        #expect(status == 69)
        #expect(output.standardError == "cstack cluster: The runtime is not running. Start it to manage clusters.\n")
        #expect(clusterLaunches(recorder).isEmpty)
    }

    @Test("a runtime with no cluster start exits 69")
    func noClusterStartExits69() async throws {
        let recorder = runtime(capable: false)

        let (status, output, _) = try await run(["start", "dev"], recorder)

        #expect(status == 69)
        #expect(output.standardError == "cstack cluster: This runtime has no cluster start; update ContainerStack\n")
        #expect(clusterLaunches(recorder).isEmpty)
    }

    @Test("a failed runtime command exits 1", arguments: [["create", "dev"], ["start", "dev"], ["rm", "dev"]])
    func failedCommandExits1(arguments: [String]) async throws {
        let (status, output, _) = try await run(arguments, runtime(clusterExit: 1))

        #expect(status == 1)
        #expect(
            output.standardError
                == "cstack cluster: container cluster \(arguments[0] == "rm" ? "delete" : arguments[0]) exited with status 1\n"
        )
    }

    @Test("a list that does not decode exits 1 and names the key")
    func undecodableListExits1() async throws {
        let (status, output, _) = try await run(["ls"], runtime(listJSON: #"[{"configuration":{}}]"#))

        #expect(status == 1)
        #expect(output.standardError.hasPrefix("cstack cluster: cluster list: missing key"))
    }

    @Test("--json prints the runtime JSON unchanged")
    func jsonIsUnchanged() async throws {
        let json = String(decoding: clusterListFixture, as: UTF8.self)

        let (_, output, _) = try await run(["ls", "--json"], runtime(listJSON: json))

        #expect(output.standardOutput == json)
    }

    @Test("the table has one row per cluster")
    func table() async throws {
        let stopped = String(decoding: clusterListJSON([(#""state":"running""#, #""state":"stopped""#)]), as: UTF8.self)

        let (status, output, _) = try await run(["ls"], runtime(listJSON: stopped))

        #expect(status == 0)
        #expect(
            output.standardOutput
                == "NAME\tSTATE\tAPI-READY\tVERSION\tNODES\tAPI\ncs-spec\tstopped\t-\tv1.35.5\t1\thttps://127.0.0.1:6445\n"
        )
    }

    @Test("a running cluster that the app kubeconfig does not know is not API ready")
    func runningWithoutContextIsNotReady() async throws {
        let (_, output, _) = try await run(["ls"], runtime())

        #expect(output.standardOutput.hasSuffix("\ncs-spec\trunning\tno\tv1.35.5\t1\thttps://127.0.0.1:6445\n"))
    }

    @Test("kubeconfig prints the two lines")
    func kubeconfigPrintsTheTwoLines() async throws {
        let (_, output, _) = try await run(["kubeconfig", "dev"], runtime())

        #expect(
            output.standardOutput
                == "kubectl --kubeconfig ~/.containerstack/kubeconfig --context dev get nodes\n"
                + "export KUBECONFIG=~/.containerstack/kubeconfig\n")
    }
}
