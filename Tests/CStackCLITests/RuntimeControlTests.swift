import Foundation
import Synchronization
import Testing

@testable import CStackCLI
@testable import ContainerStackCore

@MainActor
struct RuntimeControlTests {
    @Test(arguments: ["stopped", "failed", "timed out", "unsupported"], [true, false])
    func unavailableClusterInventoryDoesNotBlockRuntimeRestart(kind: String, terminal: Bool) async throws {
        let fake = FakeRuntimeControl()
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let managed = home.appending(path: ".containerstack/kubeconfig")
        try FileManager.default.createDirectory(
            at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("contexts:\n- name: dev\n  context:\n    cluster: dev\n".utf8).write(to: managed)
        let calls = Mutex([[String]]())
        let commands = ClusterCommands(
            containerPath: fake.configuration.containerPath, home: home, environment: [:],
            spawn: { launch in
                calls.withLock { $0.append(launch.arguments) }
                if launch.arguments == ["system", "status"] {
                    switch kind {
                    case "stopped": return .init(status: 1, output: "apiserver is not running")
                    case "failed": return .init(status: 1, output: "", errorOutput: "transport failure")
                    case "timed out":
                        throw ProcessRunnerError.timedOut(executablePath: launch.executablePath, seconds: 10)
                    default: break
                    }
                }
                return .init(status: 0, output: "USAGE: cluster")
            }, capabilityCache: .init(), lock: .init())
        fake.clusters = ClusterRuntimeLifecycle(commands: commands)
        var cli = fake.cli
        if terminal {
            cli.readConfirmation = {
                Issue.record("Restart asked for confirmation")
                return false
            }
        }
        #expect(try await cli.run(.init(arguments: ["runtime", "restart"]), configuration: fake.configuration) == 0)
        #expect(calls.withLock { $0.filter { $0 == ["system", "status"] }.count } == 1)
        #expect(!calls.withLock { $0.contains { $0.contains("list") } })
        #expect(
            fake.events.contains("cluster inventory unknown: running clusters may have been stopped\n")
                == ["failed", "timed out"].contains(kind))
        #expect(fake.events.contains("system stop"))
    }

    @Test(arguments: [true, false])
    func restartFromAPipeRequiresYesAndReportsClustersBeforeSystemStop(yes: Bool) async throws {
        let fake = FakeRuntimeControl()
        let invocation = CStackInvocation(arguments: ["runtime", "restart"] + (yes ? ["--yes"] : []))
        let status = try await fake.cli.run(invocation, configuration: fake.configuration)
        #expect(status == (yes ? 0 : 1))
        if yes {
            #expect(
                fake.events == [
                    "clusters", "dev: stopped in order\n",
                    "bridge stop", "stop --all --time 5", "system stop", "system start --enable-kernel-install",
                    "bridge start", "Runtime restarted. Check with: cstack doctor\n",
                ])
        } else {
            #expect(fake.events == ["preflight", "Clusters dev stop and stay stopped.\n"])
        }
    }

    @Test func stopFromAPipeOnlyStopsTheBridge() async throws {
        let fake = FakeRuntimeControl()
        let invocation = CStackInvocation(arguments: ["runtime", "stop"])
        #expect(try await fake.cli.run(invocation, configuration: fake.configuration) == 0)
        #expect(fake.events == ["bridge stop", "Docker bridge stopped. Apple Container is still running.\n"])
    }

    @Test func terminalPromptDefaultsToNo() async throws {
        let fake = FakeRuntimeControl()
        var cli = fake.cli
        cli.readConfirmation = { false }
        let invocation = CStackInvocation(arguments: ["runtime", "restart"])
        #expect(try await cli.run(invocation, configuration: fake.configuration) == 1)
        #expect(fake.events == ["preflight", "Clusters dev stop and stay stopped. [y/N] "])
    }
}

@MainActor
private final class FakeRuntimeControl {
    let configuration = RuntimeProcessConfiguration(containerPath: "/fake/\(UUID())", socktainerPath: "/fake/bridge")
    var events: [String] = []
    var clusters: ClusterRuntimeLifecycle?

    var cli: RuntimeCLI {
        RuntimeCLI(
            preflight: {
                self.events.append("preflight")
                if let clusters = self.clusters { return await clusters.preflight() }
                return .inspect(question: "Clusters dev stop and stay stopped.")
            },
            stopClusters: { preparation in
                self.events.append("clusters")
                if let clusters = self.clusters { return await clusters.stopClusters(preflight: preparation) ?? [] }
                return ["dev: stopped in order"]
            },
            runStep: { step in
                switch step {
                case .stopClusters: Issue.record("The cluster step is advisory")
                case .run(_, let arguments): self.events.append(arguments.joined(separator: " "))
                case .stopBridge: self.events.append("bridge stop")
                case .startBridge: self.events.append("bridge start")
                case .kickstartAgent: Issue.record("The fake has no agent")
                case .stopContainers(_, let grace):
                    self.events.append(
                        RuntimeControlStep.stopContainersArguments(graceSeconds: grace).joined(separator: " "))
                }
                return nil
            },
            agentRegistered: { false },
            write: { self.events.append($0) },
            writeError: { self.events.append($0) },
            readConfirmation: nil
        )
    }
}
