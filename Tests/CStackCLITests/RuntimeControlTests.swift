import ContainerStackCore
import Testing

@testable import CStackCLI

@MainActor
struct RuntimeControlTests {
    @Test(arguments: [true, false])
    func restartFromAPipeRequiresYesAndReportsClustersBeforeSystemStop(yes: Bool) async throws {
        let fake = FakeRuntimeControl()
        let invocation = CStackInvocation(arguments: ["runtime", "restart"] + (yes ? ["--yes"] : []))
        let status = try await fake.cli.run(invocation, configuration: fake.configuration)
        #expect(status == (yes ? 0 : 1))
        if yes {
            #expect(
                fake.events == [
                    "preflight", "clusters", "dev: stopped in order\n",
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
    let configuration = RuntimeProcessConfiguration(containerPath: "/fake/container", socktainerPath: "/fake/bridge")
    var events: [String] = []

    var cli: RuntimeCLI {
        RuntimeCLI(
            preflight: {
                self.events.append("preflight")
                return "Clusters dev stop and stay stopped."
            },
            stopClusters: {
                self.events.append("clusters")
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
