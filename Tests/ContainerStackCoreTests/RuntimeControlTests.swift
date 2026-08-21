import Foundation
import Testing

@testable import ContainerStackCore

struct ProcessTableTests {
    private let listing = """
          41278 /usr/local/bin/container-apiserver start
          75693 /Applications/ContainerStack.app/Contents/Helpers/socktainer --no-check-compatibility
          75669 /Applications/ContainerStack.app/Contents/Helpers/ContainerStackRuntime
          88001 /Users/me/.local/bin/socktainer --no-docker-context
          90210 grep socktainer
        """

    @Test
    func findsProcessesByExactExecutablePath() {
        let pids = ProcessTable.pids(
            forExecutable: "/Applications/ContainerStack.app/Contents/Helpers/socktainer",
            in: listing
        )

        #expect(pids == [75693])
    }

    @Test
    func ignoresUnrelatedExecutablesWithTheSameName() {
        let pids = ProcessTable.pids(forExecutable: "/Users/me/.local/bin/socktainer", in: listing)

        #expect(pids == [88001])
    }

    @Test
    func returnsNothingWhenExecutableIsNotRunning() {
        #expect(ProcessTable.pids(forExecutable: "/nowhere/socktainer", in: listing).isEmpty)
    }
}

struct RuntimeRestartPlanTests {
    private let configuration = RuntimeProcessConfiguration(
        containerPath: "/usr/local/bin/container",
        socktainerPath: "/Applications/ContainerStack.app/Contents/Helpers/socktainer"
    )

    @Test
    func restartStopsBridgeThenCyclesAppleContainer() {
        let steps = RuntimeRestartPlan.steps(configuration: configuration, agentRegistered: false)

        #expect(
            steps == [
                .stopBridge(executablePath: "/Applications/ContainerStack.app/Contents/Helpers/socktainer"),
                .run(executablePath: "/usr/local/bin/container", arguments: ["system", "stop"]),
                .run(executablePath: "/usr/local/bin/container", arguments: ["system", "start"]),
                .startBridge,
            ])
    }

    @Test
    func restartUsesLaunchAgentWhenItOwnsTheRuntime() {
        let steps = RuntimeRestartPlan.steps(configuration: configuration, agentRegistered: true)

        #expect(steps.last == .kickstartAgent(label: RuntimeRestartPlan.agentLabel))
        #expect(
            steps.contains(
                .run(executablePath: "/usr/local/bin/container", arguments: ["system", "stop"])))
    }

    @Test
    func stopLeavesAppleContainerRunning() {
        let steps = RuntimeRestartPlan.stopSteps(configuration: configuration)

        #expect(
            steps == [
                .stopBridge(executablePath: "/Applications/ContainerStack.app/Contents/Helpers/socktainer")
            ])
    }
}
