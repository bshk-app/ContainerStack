import Foundation
import Synchronization
import Testing

@testable import ContainerStackCore

@MainActor
struct ClusterRuntimeLifecycleTests {
    @Test(arguments: [false, true])
    func failedOrTimedOutInventoryHasOneUnknownLine(timedOut: Bool) async throws {
        let home = try TemporaryHome()
        let recorder = ClusterSpawnRecorder { launch in
            if launch.arguments == ["cluster", "list", "--format", "json"] {
                if timedOut {
                    throw ProcessRunnerError.timedOut(executablePath: launch.executablePath, seconds: 20)
                }
                return .init(status: 1, output: "[]", errorOutput: "lost connection")
            }
            return capabilityReply(launch.arguments)
        }
        let lifecycle = makeLifecycle(home, recorder)
        #expect(await lifecycle.stopClusters() == ["cluster inventory unknown"])
        #expect(await lifecycle.preflight() == "Cluster inventory unknown: running clusters may stop.")
        #expect(!recorder.launches.contains { $0.arguments.contains("--name") })
    }

    @Test func oneBudgetCoversSeveralTimedOutProbesAndTheStops() async throws {
        let home = try TemporaryHome()
        let clock = ClusterTestClock()
        let inventory = clusterInventory(
            cluster("last", day: 3),
            cluster("first", day: 1, count: 2),
            cluster("middle", day: 2, count: 2, state: "degraded"),
            cluster("stopped", day: 4, count: 2, state: "stopped")
        )
        let recorder = ClusterSpawnRecorder { launch in
            switch launch.arguments.prefix(2) {
            case ["cluster", "list"]:
                clock.advance(by: .seconds(20))
                return .init(status: 0, output: inventory)
            case ["exec", "first"], ["exec", "middle"]:
                clock.advance(by: launch.timeout)
                throw ProcessRunnerError.timedOut(executablePath: launch.executablePath, seconds: 10)
            case ["cluster", "stop"] where launch.arguments.contains("--name"):
                if launch.arguments.contains("first") {
                    clock.advance(by: .seconds(65))
                    return .init(status: 0, output: "first")
                }
                clock.advance(by: launch.timeout)
                throw ProcessRunnerError.timedOut(executablePath: launch.executablePath, seconds: 15)
            default:
                return capabilityReply(launch.arguments)
            }
        }
        let lifecycle = makeLifecycle(home, recorder, clock: clock)
        var progress: [String] = []
        let result = await lifecycle.stopClusters(progress: { progress.append($0) })

        #expect(
            result == [
                "first: stopped in order. It has more than one node and may not start again.",
                "middle: left to system stop. It has more than one node and may not start again.",
                "last: left to system stop",
            ])
        #expect(progress == ["first", "middle"])
        #expect(
            recorder.launches.filter { $0.arguments.contains("--name") }.map(\.arguments) == [
                ["cluster", "stop", "--name", "first", "--time", "26"],
                ["cluster", "stop", "--name", "middle", "--time", "5"],
            ])
        #expect(clock.elapsed == .seconds(120))
    }

    @Test(arguments: [true, false])
    func removableNodesAreReportedGoneOnlyAfterASecondListing(nodesAreGone: Bool) async throws {
        let home = try TemporaryHome()
        let inventory = clusterInventory(cluster("ephemeral", remove: true))
        let recorder = ClusterSpawnRecorder { launch in
            switch launch.arguments.prefix(2) {
            case ["cluster", "list"]: .init(status: 0, output: inventory)
            case ["cluster", "stop"] where launch.arguments.contains("--name"): .init(status: 0, output: "")
            default: capabilityReply(launch.arguments)
            }
        }
        let lifecycle = ClusterRuntimeLifecycle(
            commands: makeCommands(home, recorder),
            listNodes: { _ in nodesAreGone ? [] : ["ephemeral"] }
        )
        #expect(await lifecycle.preflight() == "Cluster ephemeral was created with --rm: its nodes will be removed.")
        let expected = nodesAreGone ? "ephemeral: nodes removed" : "ephemeral: stopped in order. Created with --rm."
        #expect(await lifecycle.stopClusters() == [expected])
    }

    @Test(arguments: [
        ("kind: ClusterConfiguration\ncontrolPlaneEndpoint: \"dev:6443\" # retained", true),
        ("kind: ClusterConfiguration\ncontrolPlaneEndpoint: \"\" # empty", false),
        ("kind: ClusterConfiguration\n# controlPlaneEndpoint: dev:6443", false),
        ("kind: InitConfiguration\ncontrolPlaneEndpoint: dev:6443\n---\nkind: ClusterConfiguration", false),
        ("kind: ClusterConfiguration\nnetworking:\n  controlPlaneEndpoint: dev:6443", false),
    ])
    func endpointProbeUsesOnlyTheRootKeyOfTheClusterConfiguration(yaml: String, proven: Bool) async throws {
        let home = try TemporaryHome()
        let inventory = clusterInventory(cluster("dev", count: 2))
        let recorder = ClusterSpawnRecorder { launch in
            switch launch.arguments.prefix(2) {
            case ["cluster", "list"]: .init(status: 0, output: inventory)
            case ["exec", "dev"]: .init(status: 0, output: yaml)
            default: capabilityReply(launch.arguments)
            }
        }
        let result = await makeLifecycle(home, recorder).preflight()
        #expect(
            result
                == (proven
                    ? "Clusters dev stop and stay stopped."
                    : "Cluster dev has more than one node and may not start again."))
        #expect(
            recorder.launches.contains {
                $0.arguments == ["exec", "dev", "cat", "/etc/kubernetes/kubeadm-config.yaml"]
            })
    }

    @Test(arguments: [true, false])
    func emptyInventoryOrUnsupportedRuntimeAddsNoPromptOrStop(supported: Bool) async throws {
        let home = try TemporaryHome()
        let recorder = ClusterSpawnRecorder { launch in
            if !supported, launch.arguments.first == "cluster" {
                return .init(status: 0, output: "USAGE: cluster <subcommand>")
            }
            if launch.arguments == ["cluster", "list", "--format", "json"] {
                return .init(status: 0, output: "[]")
            }
            return capabilityReply(launch.arguments)
        }
        let lifecycle = makeLifecycle(home, recorder)
        #expect(await lifecycle.preflight() == nil)
        #expect(await lifecycle.stopClusters() == [])
        #expect(!recorder.launches.contains { $0.arguments.contains("--name") })
    }

    @Test func preflightStopsAtThirtySecondsAndTheTimeToConfirmDoesNotUseTheStopBudget() async throws {
        let home = try TemporaryHome()
        let clock = ClusterTestClock()
        let inventory = clusterInventory(cluster("first", count: 2), cluster("second", day: 2, count: 2))
        let recorder = ClusterSpawnRecorder { launch in
            switch launch.arguments.prefix(2) {
            case ["cluster", "list"]:
                clock.advance(by: .seconds(20))
                return .init(status: 0, output: inventory)
            case ["exec", "first"], ["exec", "second"]:
                clock.advance(by: launch.timeout)
                throw ProcessRunnerError.timedOut(executablePath: launch.executablePath, seconds: 10)
            default:
                return capabilityReply(launch.arguments)
            }
        }
        let lifecycle = makeLifecycle(home, recorder, clock: clock)
        let preflight = await lifecycle.preflight()
        #expect(clock.elapsed == .seconds(30))
        #expect(preflight?.contains("Cluster second has more than one node and may not start again.") == true)
        #expect(recorder.launches.filter { $0.arguments.first == "exec" }.count == 1)
        #expect(!recorder.launches.contains { $0.arguments.contains("--name") })

        clock.advance(by: .seconds(300))
        _ = await lifecycle.stopClusters()
        #expect(
            recorder.launches.filter { $0.arguments.contains("--name") }.map(\.timeout) == [
                .seconds(80), .seconds(80),
            ])
        #expect(clock.elapsed == .seconds(370))
    }

    @Test func aStopWithLessThanFiveSecondsLeftIsNotLaunched() async throws {
        let home = try TemporaryHome()
        let clock = ClusterTestClock()
        let inventory = clusterInventory(cluster("first"), cluster("second", day: 2))
        let recorder = ClusterSpawnRecorder { launch in
            if launch.arguments.last == "json" { return .init(status: 0, output: inventory) }
            if launch.arguments.contains("first") { clock.advance(by: .seconds(116)) }
            return capabilityReply(launch.arguments)
        }
        let result = await makeLifecycle(home, recorder, clock: clock).stopClusters()
        #expect(result == ["first: stopped in order", "second: left to system stop"])
        #expect(recorder.launches.filter { $0.arguments.contains("--name") }.count == 1)
    }

    private func makeLifecycle(
        _ home: borrowing TemporaryHome, _ recorder: ClusterSpawnRecorder, clock: ClusterTestClock = .init()
    ) -> ClusterRuntimeLifecycle {
        ClusterRuntimeLifecycle(commands: makeCommands(home, recorder), now: clock.now)
    }
}

private func makeCommands(
    _ home: borrowing TemporaryHome, _ recorder: ClusterSpawnRecorder
) -> ClusterCommands {
    ClusterCommands(
        containerPath: "/fake/runtime", home: home.url, environment: [:], spawn: recorder.spawn,
        capabilityCache: .init(), lock: .init())
}

private func capabilityReply(_ arguments: [String]) -> ProcessRunner.Result {
    .init(status: 0, output: arguments.last == "--help" ? "USAGE: cluster \(arguments[1])" : "test build")
}

private func clusterInventory(_ entries: String...) -> String {
    "[" + entries.joined(separator: ",") + "]"
}

private func cluster(
    _ name: String, day: Int = 1, remove: Bool = false, count: Int = 1, state: String = "running"
) -> String {
    let workers = (1..<count).map { _ in ",{\"name\":\"worker\",\"roles\":[\"worker\"]}" }.joined()
    return """
        {"configuration":{"name":"\(name)","creationDate":"2026-11-0\(day)T00:00:00Z","kubernetesVersion":"v1",
        "remove":\(remove),"sharedImageStore":false,
        "nodes":[{"name":"\(name)","roles":["control-plane"]}\(workers)]},
        "status":{"state":"\(state)","nodes":[]}}
        """
}

private final class ClusterTestClock: Sendable {
    private let started = ContinuousClock.now
    private let offset = Mutex(Duration.zero)

    var elapsed: Duration { offset.withLock { $0 } }
    func now() -> ContinuousClock.Instant { started + elapsed }
    func advance(by duration: Duration) { offset.withLock { $0 += duration } }
}
