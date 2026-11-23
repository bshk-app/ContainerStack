import Foundation
import Testing

@testable import ContainerStackCore

private func helpFixture(_ name: String) -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

struct ClusterCapabilityTests {
    private let startHelp = helpFixture("cluster-start-help.txt")
    private let stopHelp = helpFixture("cluster-stop-help.txt")
    private let oldHelp = helpFixture("cluster-old-help.txt")

    private func runtime(
        statusExit: Int32 = 0,
        version: String = "container CLI version 1.7.1 (build: release, commit: 17bb57e)",
        start: String,
        stop: String
    ) -> ClusterSpawnRecorder {
        ClusterSpawnRecorder { launch in
            switch launch.arguments {
            case ["system", "status"]: .init(status: statusExit, output: "")
            case ["--version"]: .init(status: 0, output: version)
            case ["cluster", "start", "--help"]: .init(status: 0, output: start)
            case ["cluster", "stop", "--help"]: .init(status: 0, output: stop)
            default: .init(status: 99, output: "")
            }
        }
    }

    private func probe(
        _ home: borrowing TemporaryHome, _ recorder: ClusterSpawnRecorder, cache: ClusterCapabilityCache
    ) async throws -> ClusterCapability {
        try await ClusterCommands(
            containerPath: "/opt/runtime/bin/container", home: home.url, environment: [:], spawn: recorder.spawn,
            capabilityCache: cache
        ).capability()
    }

    @Test("the help of the patched plugin gives capable")
    func patchedPluginIsCapable() async throws {
        let home = try TemporaryHome()
        let recorder = runtime(start: startHelp, stop: stopHelp)

        #expect(try await probe(home, recorder, cache: ClusterCapabilityCache()) == .capable)
        #expect(
            recorder.launches.map(\.arguments) == [
                ["system", "status"], ["--version"], ["cluster", "start", "--help"], ["cluster", "stop", "--help"],
            ])
    }

    @Test("the top-level help of the old plugin with exit 0 gives not capable")
    func oldPluginIsNotCapable() async throws {
        let home = try TemporaryHome()
        let recorder = runtime(start: oldHelp, stop: oldHelp)

        #expect(try await probe(home, recorder, cache: ClusterCapabilityCache()) == .noClusterStart)
    }

    @Test("start present and stop missing gives not capable")
    func stopMissingIsNotCapable() async throws {
        let home = try TemporaryHome()
        let recorder = runtime(start: startHelp, stop: oldHelp)

        #expect(try await probe(home, recorder, cache: ClusterCapabilityCache()) == .noClusterStart)
    }

    @Test("a runtime that does not run is reported and no plugin runs")
    func runtimeNotRunning() async throws {
        let home = try TemporaryHome()
        let recorder = runtime(statusExit: 1, start: startHelp, stop: stopHelp)

        #expect(try await probe(home, recorder, cache: ClusterCapabilityCache()) == .runtimeNotRunning)
        #expect(recorder.launches.map(\.arguments) == [["system", "status"]])
    }

    @Test("the result is kept for the running build and probed again for another")
    func resultIsKeptPerBuild() async throws {
        let home = try TemporaryHome()
        let cache = ClusterCapabilityCache()
        let first = runtime(start: startHelp, stop: stopHelp)
        let same = runtime(start: oldHelp, stop: oldHelp)
        let other = runtime(
            version: "container CLI version 1.7.1 (build: release, commit: abc1234)", start: oldHelp, stop: oldHelp)

        #expect(try await probe(home, first, cache: cache) == .capable)
        #expect(try await probe(home, same, cache: cache) == .capable)
        #expect(try await probe(home, other, cache: cache) == .noClusterStart)
        #expect(same.launches.map(\.arguments) == [["system", "status"], ["--version"]])
    }

    @Test("a help call that fails is not kept for the build")
    func failedHelpIsNotKept() async throws {
        let home = try TemporaryHome()
        let cache = ClusterCapabilityCache()
        let failing = ClusterSpawnRecorder { launch in
            launch.arguments.last == "--help"
                ? .init(status: 1, output: "Error: XPC connection error") : .init(status: 0, output: "v1")
        }

        #expect(try await probe(home, failing, cache: cache) == .noClusterStart)
        #expect(
            try await probe(home, runtime(version: "v1", start: startHelp, stop: stopHelp), cache: cache) == .capable)
    }

    @Test("the command tokens of a usage line must end with cluster and the subcommand")
    func usageLineRule() {
        #expect(ClusterCapability.usageNames("start", in: "USAGE: cluster start"))
        #expect(ClusterCapability.usageNames("start", in: "x\n  USAGE: cluster start [--name <name>]\n"))
        #expect(!ClusterCapability.usageNames("start", in: "USAGE: cluster <subcommand>"))
        #expect(!ClusterCapability.usageNames("start", in: "USAGE: cluster started"))
        #expect(!ClusterCapability.usageNames("start", in: "  $ container cluster start --name my-cluster"))
        #expect(ClusterCapability.usageNames("start", in: "USAGE: container cluster start [--name <name>]"))
        #expect(ClusterCapability.usageNames("stop", in: "USAGE: container cluster stop [--time <time>]"))
        #expect(!ClusterCapability.usageNames("start", in: "USAGE: container cluster <subcommand>"))
        #expect(!ClusterCapability.usageNames("start", in: "USAGE: container cluster start-all"))
    }
}
