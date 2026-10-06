import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

/// The app's Stop cannot run here: it signals the machine's real bridge. These tests call the
/// part of it that matters, `cancelPendingStart`, at the moment a click could land.
@Suite("Runtime helper lifecycle")
@MainActor
struct RuntimeHelperLifecycleTests {
    @Test("A stop that lands during the startup ping launches nothing (#70)")
    func stopDuringStartupPingLaunchesNothing() async {
        let model = makeModel()
        var launched = false

        await model.startRuntimeIfSocketIsDown(
            attempt: model.beginStartAttempt(),
            ping: {
                model.cancelPendingStart()
                return false
            },
            launch: { launched = true }
        )

        #expect(!launched)
    }

    @Test("A stop that lands during the startup ping does not adopt the socket (#70)")
    func stopDuringStartupPingDoesNotAdopt() async {
        let model = makeModel()

        await model.startRuntimeIfSocketIsDown(
            attempt: model.beginStartAttempt(),
            ping: {
                model.cancelPendingStart()
                return true
            },
            launch: {}
        )

        // Asserting on the state would pass anyway: the adoption's own refresh finds no socket here.
        #expect(model.runtimeMessage != "Adopted the Docker socket already serving this machine.")
    }

    @Test("A helper retired by Stop is not reported as having failed (#70)")
    func retiredHelperIsNotAFailure() async throws {
        let model = makeModel()
        let helper = try Self.spawn("/usr/bin/true")
        helper.waitUntilExit()
        model.runtimeProcess = helper

        let launch = model.beginStartAttempt()
        let wait = Task { await model.waitForRuntime(on: helper, launch: launch) }
        await model.endRuntimeHelper()
        await wait.value

        #expect(model.runtimeFailure == nil)
    }

    /// Codex reproduced this with a fake CLI: the check fails or times out after the user stopped,
    /// and its complaint overwrote "Docker bridge stopped."
    @Test("A stop during the version check publishes nothing the check found (#70)")
    func stopDuringVersionCheckPublishesNoFailure() {
        let model = makeModel()
        let attempt = model.beginStartAttempt()
        model.cancelPendingStart()

        #expect(!model.acceptLaunchPreflight(attempt: attempt, complaint: "container 1.2.0 is too old"))
        #expect(model.runtimeFailure == nil)
    }

    /// Codex reproduced this: Start waited on its version check, Restart launched a newer helper,
    /// and the old check's failure then ended the newer start and published itself.
    @Test("An older version check's complaint leaves a newer start alone (#70)")
    func olderVersionComplaintLeavesNewerStart() {
        let model = makeModel()
        let older = model.beginStartAttempt()
        model.beginStartAttempt()

        #expect(!model.acceptLaunchPreflight(attempt: older, complaint: "too old"))
        #expect(model.runtimeFailure == nil)
        #expect(model.isStarting)
    }

    @Test("For the current start, the version check's complaint is published and the start ends")
    func versionComplaintIsPublished() {
        let model = makeModel()
        let attempt = model.beginStartAttempt()

        #expect(model.acceptLaunchPreflight(attempt: attempt, complaint: nil))
        #expect(!model.acceptLaunchPreflight(attempt: attempt, complaint: "too old"))
        #expect(model.runtimeFailure == "too old")
        #expect(!model.isStarting)
    }

    /// Codex reproduced this: a refresh failing while Start waited on its ping left the start with
    /// nothing to finish it, `.starting` for good.
    @Test("A start whose socket was declared dead during its ping ends instead of hanging")
    func startInvalidatedDuringPingEnds() async {
        let model = makeModel()
        let attempt = model.beginStartAttempt()
        model.applyState(socketResponds: false)

        await model.startRuntimeIfSocketIsDown(
            attempt: attempt,
            ping: {
                model.clearInventoryForStop()
                return true
            },
            launch: {}
        )

        #expect(!model.isStarting)
        #expect(model.runtimeState != .starting)
    }

    @Test("A Stop before the launch-time start runs keeps it from starting (#70)")
    func stopBeforeInitialStartKeepsItStopped() async throws {
        let model = RuntimeViewModel(
            socketPath: "/tmp/containerstack-lifecycle-\(UUID().uuidString).sock",
            startsRuntime: true
        )
        model.cancelPendingStart()

        try await Task.sleep(for: .milliseconds(200))

        // A start that ran anyway is still pinging (starting) or has already failed to find the
        // helper this test bundle lacks, depending on timing; either trips one of these.
        #expect(!model.isStarting)
        #expect(model.runtimeFailure == nil)
    }

    /// With the LaunchAgent registered, Restart kickstarts it and launches no helper of its own, so
    /// nothing else would ever end the start the retired helper's wait was tracking.
    @Test("A wait whose helper Restart retired still ends its own start (#71)")
    func retiredWaitEndsItsOwnStart() async throws {
        let model = makeModel()
        let helper = try Self.spawn("/bin/sleep", "60")
        defer { helper.terminate() }
        model.runtimeProcess = helper
        let launch = model.beginStartAttempt()

        let wait = Task { await model.waitForRuntime(on: helper, launch: launch) }
        await model.endRuntimeHelper()
        await wait.value

        #expect(!model.isStarting)
    }

    /// Codex reproduced both: an old wait, or Restart's cleanup, ended the start a Start clicked
    /// meanwhile had begun, turning `.starting` into offline while that Start was still running.
    @Test("A wait for a retired helper leaves a newer start alone")
    func retiredWaitLeavesNewerStartAlone() async throws {
        let model = makeModel()
        let helper = try Self.spawn("/bin/sleep", "60")
        defer { helper.terminate() }
        model.runtimeProcess = helper
        let launch = model.beginStartAttempt()

        let wait = Task { await model.waitForRuntime(on: helper, launch: launch) }
        await model.endRuntimeHelper()
        model.beginStartAttempt()
        await wait.value

        #expect(model.isStarting)
    }

    /// Codex reproduced this: a stop begun before Stop failed after it with the connection gone,
    /// and the recovery it asked for started the runtime the user had just stopped.
    @Test("An action that fails after a Stop asks for no recovery (#70)")
    func actionFailingAfterStopRequestsNoRecovery() async throws {
        let model = makeModel()
        model.applyState(socketResponds: true)
        let container = try JSONDecoder().decode(
            DockerContainerSummary.self,
            from: Data(#"{"Id":"web","Names":["/web"],"State":"running"}"#.utf8)
        )

        await model.withContainer(container, action: "Stopping", recoversRuntime: true) {
            model.cancelPendingStart()
            throw DockerAPIError.httpStatus(500, message: "XPC connection error: Connection invalid")
        }

        #expect(!model.runtimeRecoveryRequested)
        #expect(model.containerMessage?.hasPrefix("Container action failed") == true)
    }

    @Test("Ending the helper stops one that honours SIGTERM")
    func endingHelperTerminates() async throws {
        let model = makeModel()
        let helper = try Self.spawn("/bin/sleep", "60")
        defer { helper.terminate() }
        model.runtimeProcess = helper

        await model.endRuntimeHelper()

        #expect(!helper.isRunning)
        #expect(model.runtimeProcess == nil)
    }

    @Test("Ending the helper kills one that ignores SIGTERM")
    func endingHelperKillsAfterGrace() async throws {
        let model = makeModel()
        let output = Pipe()
        let helper = try Self.spawn(
            "/bin/sh", "-c", #"trap "" TERM; echo ready; exec sleep 60"#, output: output)
        defer { kill(helper.processIdentifier, SIGKILL) }
        // Signalled before the trap is installed, the shell would die of SIGTERM and this would
        // pass without ever reaching SIGKILL.
        _ = output.fileHandleForReading.availableData
        model.runtimeProcess = helper

        await model.endRuntimeHelper(grace: .milliseconds(300))

        #expect(!helper.isRunning)
    }

    @Test("Start replaces a helper the app has given up on (#71)")
    func startReplacesAbandonedHelper() async throws {
        let model = makeModel()
        let wedged = try Self.spawn("/bin/sleep", "60")
        defer { wedged.terminate() }
        model.runtimeProcess = wedged
        model.failRuntime("Docker socket did not become ready within 60 seconds.")

        model.startRuntime()

        // The test bundle ships no helper, so a launch attempt that got as far as spawning one
        // ends here. Before #71 it never got past the wedged helper.
        let attempted = await Self.eventually {
            model.runtimeFailure?.hasPrefix("Runtime helper is missing") == true
        }
        #expect(attempted)
        #expect(!wedged.isRunning)
    }

    @Test("Start leaves a helper that is still starting alone")
    func startLeavesStartingHelper() throws {
        let model = makeModel()
        let starting = try Self.spawn("/bin/sleep", "60")
        defer { starting.terminate() }
        model.runtimeProcess = starting

        model.startRuntime()

        // The replacement runs in a task, so the helper would still look alive here either way;
        // an attempt that began is visible at once.
        #expect(!model.isStarting)
        #expect(model.runtimeProcess === starting)
    }

    private func makeModel() -> RuntimeViewModel {
        RuntimeViewModel(
            socketPath: "/tmp/containerstack-lifecycle-\(UUID().uuidString).sock",
            startsRuntime: false
        )
    }

    private static func spawn(
        _ executable: String, _ arguments: String..., output: Pipe? = nil
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let output { process.standardOutput = output }
        try process.run()
        return process
    }

    private static func eventually(
        within limit: Duration = .seconds(10), _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}
