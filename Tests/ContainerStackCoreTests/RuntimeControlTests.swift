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

    @Test
    func selectsOnlyTheLegacyBundledSocktainerOwner() {
        let bundled = "/Applications/ContainerStack.app/Contents/Helpers/socktainer"
        let listing = """
              10001 \(bundled) --no-check-compatibility --no-docker-context
              10002 \(bundled) --no-check-compatibility --no-docker-context --socket /Users/me/.containerstack/docker.sock --startup-housekeeping
              10003 /Users/me/.local/bin/socktainer --no-check-compatibility --no-docker-context
              10004 /tmp/socktainer --no-check-compatibility --no-docker-context
              10005 \(bundled) --no-docker-context --no-check-compatibility
            """

        #expect(ProcessTable.legacyBundledSocktainerPIDs(forExecutable: bundled, in: listing) == [10001])
        #expect(
            ProcessTable.legacyBundledSocktainerPIDs(
                forExecutable: "/Users/me/.local/bin/socktainer",
                in: listing
            ).isEmpty
        )
    }
}

struct LegacySocktainerRetirementTests {
    private let bundled = "/Applications/ContainerStack.app/Contents/Helpers/socktainer"

    @Test
    func waitsUntilEverySelectedLegacyProcessHasExited() throws {
        var listings = [
            legacyListing(pid: 10001),
            legacyListing(pid: 10001),
            "",
        ]
        var signaled: [Int32] = []
        var waits = 0

        try LegacySocktainerRetirement.retire(
            executablePath: bundled,
            maxChecks: 3,
            processListing: { listings.removeFirst() },
            signal: { pid in
                signaled.append(pid)
                return .delivered
            },
            wait: { waits += 1 }
        )

        #expect(signaled == [10001])
        #expect(waits == 1)
    }

    @Test
    func treatsAlreadyExitedProcessAsRetired() throws {
        var listings = [legacyListing(pid: 10001), ""]

        try LegacySocktainerRetirement.retire(
            executablePath: bundled,
            maxChecks: 2,
            processListing: { listings.removeFirst() },
            signal: { _ in .alreadyExited },
            wait: {}
        )
    }

    @Test
    func failedProcessEnumerationIsAnError() {
        #expect(throws: LegacySocktainerRetirementError.processEnumerationFailed) {
            try LegacySocktainerRetirement.retire(
                executablePath: bundled,
                maxChecks: 1,
                processListing: { throw ProbeError.failed },
                signal: { _ in .delivered },
                wait: {}
            )
        }
    }

    @Test
    func failedSignalDeliveryIsAnError() {
        #expect(throws: LegacySocktainerRetirementError.signalFailed(pid: 10001)) {
            try LegacySocktainerRetirement.retire(
                executablePath: bundled,
                maxChecks: 1,
                processListing: { legacyListing(pid: 10001) },
                signal: { _ in throw ProbeError.failed },
                wait: {}
            )
        }
    }

    @Test
    func remainingLegacyProcessAfterBoundedChecksAbortsStartup() {
        var waits = 0

        #expect(throws: LegacySocktainerRetirementError.timedOut(pids: [10001])) {
            try LegacySocktainerRetirement.retire(
                executablePath: bundled,
                maxChecks: 2,
                processListing: { legacyListing(pid: 10001) },
                signal: { _ in .delivered },
                wait: { waits += 1 }
            )
        }
        #expect(waits == 2)
    }

    private func legacyListing(pid: Int32) -> String {
        "\(pid) /Applications/ContainerStack.app/Contents/Helpers/socktainer --no-check-compatibility --no-docker-context"
    }

    private enum ProbeError: Error {
        case failed
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
                .stopContainers(executablePath: "/usr/local/bin/container", graceSeconds: 5),
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

    /// `container system stop` takes the whole service down, and the containers with it. Asking them
    /// to exit first is what keeps a database's volume consistent: a restart run to recover a wedged
    /// network once left postgres with an unreplayable WAL and an ext4 that needed `e2fsck`.
    @Test
    func restartAsksContainersToExitBeforeStoppingTheService() {
        let steps = RuntimeRestartPlan.steps(configuration: configuration, agentRegistered: false)

        let gracefulStop = steps.firstIndex(
            of: .stopContainers(executablePath: "/usr/local/bin/container", graceSeconds: 5))
        let serviceStop = steps.firstIndex(
            of: .run(executablePath: "/usr/local/bin/container", arguments: ["system", "stop"]))

        #expect(gracefulStop != nil)
        #expect(serviceStop != nil)
        guard let gracefulStop, let serviceStop else { return }
        #expect(gracefulStop < serviceStop)
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
