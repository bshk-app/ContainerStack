import Foundation
import Synchronization
import Testing

@testable import ContainerStackCore

private final class Output: Sendable {
    private let out = Mutex<[String]>([])
    private let err = Mutex<[String]>([])

    var standardOutput: String { out.withLock { $0.joined() } }
    var standardError: String { err.withLock { $0.joined() } }

    func write(_ text: String) { out.withLock { $0.append(text) } }
    func writeError(_ text: String) { err.withLock { $0.append(text) } }
}

private final class ReadinessTestClock: Clock {
    let origin = ContinuousClock.now
    private let elapsed = Mutex(Duration.zero)

    var now: ContinuousClock.Instant { origin + elapsed.withLock { $0 } }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let offset = origin.duration(to: deadline)
        elapsed.withLock { $0 = max($0, offset) }
    }
}

private actor Timeline {
    private(set) var entries: [(offset: Duration, limit: Duration)] = []

    func add(_ offset: Duration, _ limit: Duration) {
        entries.append((offset, limit))
    }
}

private actor Counter {
    private(set) var names: [String] = []

    func add(_ name: String) {
        names.append(name)
    }
}

struct ClusterCLITests {
    @Test(arguments: ["create", "start"], [true, false])
    func readinessFailurePrintsPermissionHintOnlyWhenAllNodesRun(command: String, allRunning: Bool) async throws {
        let json = String(decoding: clusterListFixture, as: UTF8.self)
        let listing =
            allRunning ? json : json.replacingOccurrences(of: #""status":"running""#, with: #""status":"exited""#)
        let (status, output, _) = try await run(
            [command, "cs-spec"], runtime(listJSON: listing), apiObservation: { _, _ in .connectionFailed })
        #expect(status == 1)
        #expect(output.standardError.contains(ClusterAPIReady.localNetworkHint) == allRunning)
        let recovery = "To recover, run 'cstack cluster stop cs-spec', then 'cstack cluster start cs-spec'."
        #expect(output.standardError.contains(recovery))
        if allRunning {
            #expect(output.standardError.hasPrefix(ClusterAPIReady.localNetworkHint + "\n"))
        }
    }

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
        environment: [String: String] = [:],
        apiReady: @escaping @Sendable (KubernetesCluster, Duration) async -> Bool = { _, _ in true },
        readyWait: ClusterCLI.ReadyWait = .init(interval: .seconds(5), probe: .seconds(3), limit: .seconds(30)),
        clock: ReadinessTestClock = ReadinessTestClock(),
        apiObservation: (@Sendable (KubernetesCluster, Duration) async -> ClusterAPIReady.Result)? = nil
    ) async throws -> (Int32, Output, URL) {
        let home = try TemporaryHome()
        let output = Output()
        let commands = ClusterCommands(
            containerPath: "/opt/runtime/bin/container", home: home.url, environment: environment,
            spawn: recorder.spawn, capabilityCache: ClusterCapabilityCache(), lock: ClusterOperationLock())
        let status = await ClusterCLI(
            commands: commands, write: output.write, writeError: output.writeError,
            apiObservation: apiObservation ?? { cluster, limit in
                await apiReady(cluster, limit) ? .ready : .notReady
            },
            readyWait: readyWait, clock: .init(clock)
        ).run(arguments)
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
        let recorder = runtime(listJSON: String(decoding: clusterListJSON([("cs-spec", "dev")]), as: UTF8.self))
        let startsCluster = ["create", "start"].contains(arguments[0])

        let (status, _, _) = try await run(arguments, recorder)

        #expect(status == 0)
        #expect(
            clusterLaunches(recorder) == [expected] + (startsCluster ? [["cluster", "list", "--format", "json"]] : []))
    }

    @Test("the shell's KUBECONFIG is not passed")
    func shellKubeconfigIsNotPassed() async throws {
        let recorder = runtime()

        let (_, _, home) = try await run(["start", "dev"], recorder, environment: ["KUBECONFIG": "/tmp/shell-config"])

        #expect(recorder.launches.count == 6)
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

    @Test("start and create check the API after the runtime command", arguments: ["start", "create"])
    func startChecksTheAPI(subcommand: String) async throws {
        let checked = Counter()

        let (status, output, _) = try await run(
            [subcommand, "cs-spec"], runtime(),
            apiReady: { cluster, _ in
                await checked.add(cluster.name)
                return true
            })

        #expect(status == 0)
        #expect(output.standardError.isEmpty)
        #expect(await checked.names == ["cs-spec"])
    }

    @Test("the API check waits and asks again until the API is ready")
    func checkWaitsForTheAPI() async throws {
        let checked = Counter()

        let (status, _, _) = try await run(
            ["start", "cs-spec"], runtime(),
            apiReady: { cluster, _ in
                await checked.add(cluster.name)
                return await checked.names.count >= 3
            })

        #expect(status == 0)
        #expect(await checked.names.count == 3)
    }

    @Test("an API that is not ready inside the limit exits 1 and names the recovery", arguments: ["start", "create"])
    func apiNotReadyExits1(subcommand: String) async throws {
        let checked = Counter()
        let clock = ReadinessTestClock()

        let (status, output, _) = try await run(
            [subcommand, "cs-spec"], runtime(),
            apiReady: { cluster, _ in
                await checked.add(cluster.name)
                return false
            },
            clock: clock)

        #expect(status == 1)
        #expect(await checked.names.count == 6)
        #expect(clock.origin.duration(to: clock.now) == .seconds(25))
        #expect(
            output.standardError
                == "cstack cluster: cluster cs-spec started, but its API is not ready after 30 s. "
                + "To recover, run 'cstack cluster stop cs-spec', then 'cstack cluster start cs-spec'.\n")
    }

    @Test("probes start on fixed ticks and never run past the limit")
    func probesFollowTicks() async throws {
        let calls = Timeline()
        let clock = ReadinessTestClock()

        let (status, _, _) = try await run(
            ["start", "cs-spec"], runtime(),
            apiReady: { _, limit in
                await calls.add(clock.origin.duration(to: clock.now), limit)
                try? await clock.sleep(for: min(.milliseconds(150), limit))
                return false
            },
            readyWait: .init(interval: .milliseconds(200), probe: .milliseconds(300), limit: .milliseconds(700)),
            clock: clock)

        let entries = await calls.entries
        #expect(status == 1)
        #expect(entries.map(\.offset) == [.zero, .milliseconds(200), .milliseconds(400), .milliseconds(600)])
        #expect(
            entries.map(\.limit) == [.milliseconds(300), .milliseconds(300), .milliseconds(300), .milliseconds(100)])
        #expect(clock.origin.duration(to: clock.now) == .milliseconds(700))
    }

    @Test("a cluster that is not in the list after start exits 1 and says so")
    func missingClusterExits1() async throws {
        let (status, output, _) = try await run(["start", "cs-spec"], runtime(listJSON: "[]"))

        #expect(status == 1)
        #expect(
            output.standardError
                == "cstack cluster: cluster cs-spec started, but it is not in the cluster list. "
                + "To recover, run 'cstack cluster stop cs-spec', then 'cstack cluster start cs-spec'.\n")
    }

    @Test("a cluster with no published API port and no FQDN skips the check and says so")
    func noEndpointSkipsTheCheck() async throws {
        let checked = Counter()
        let noPort = String(decoding: clusterListJSON([(#""ports":["6445->6443"],"#, "")]), as: UTF8.self)

        let (status, output, _) = try await run(
            ["start", "cs-spec"], runtime(listJSON: noPort),
            apiReady: { cluster, _ in
                await checked.add(cluster.name)
                return false
            })

        #expect(status == 0)
        #expect(await checked.names.isEmpty)
        #expect(
            output.standardError
                == "cstack cluster: cluster cs-spec has no published API port and no FQDN; the API check is skipped.\n")
    }

    @Test("stop, rm and kubeconfig do not check the API", arguments: ["stop", "rm", "kubeconfig"])
    func otherCommandsDoNotCheck(subcommand: String) async throws {
        let checked = Counter()

        let (status, _, _) = try await run(
            [subcommand, "cs-spec"], runtime(),
            apiReady: { cluster, _ in
                await checked.add(cluster.name)
                return false
            })

        #expect(status == 0)
        #expect(await checked.names.isEmpty)
    }

    @Test("a failed list exits 1 and shows the runtime's error text")
    func failedListShowsTheErrorText() async throws {
        let recorder = ClusterSpawnRecorder { launch in
            switch launch.arguments {
            case ["cluster", "list", "--format", "json"]:
                return .init(status: 1, output: "", errorOutput: "Error: cluster service is not available\n")
            case let help where help.last == "--help":
                return .init(status: 0, output: Self.capableHelp[help[1]] ?? "")
            default: return .init(status: 0, output: "")
            }
        }

        let (status, output, _) = try await run(["ls"], recorder)

        #expect(status == 1)
        #expect(
            output.standardError
                == "cstack cluster: container cluster list exited with status 1: Error: cluster service is not available\n"
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

    @Test(
        "ls prints one row for each live output of the patched runtime",
        arguments: [
            ("running", "running\tno"), ("stopped", "stopped\t-"), ("degraded", "degraded\t-"),
            ("running-after-interrupted-start", "running\tno"),
        ])
    func tableOfLiveOutputs(fixture: String, stateAndReady: String) async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/cluster-list-\(fixture).json")
        let json = try String(contentsOf: url, encoding: .utf8)

        let (status, output, _) = try await run(["ls"], runtime(listJSON: json))

        #expect(status == 0)
        #expect(
            output.standardOutput
                == "NAME\tSTATE\tAPI-READY\tVERSION\tNODES\tAPI\n"
                + "cs-b\t\(stateAndReady)\tv1.35.5\t3\thttps://127.0.0.1:6445\n")
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
