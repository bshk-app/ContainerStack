import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

/// The helper itself: ending it, and Start's handling of one still running. The interleavings of
/// Start, Stop and Restart are in `RuntimeLifecycleScenarioTests`.
@Suite("Runtime helper lifecycle")
@MainActor
struct RuntimeHelperLifecycleTests {
    /// Codex reproduced this: a stop begun before Stop failed after it with the connection gone,
    /// and the recovery it asked for started the runtime the user had just stopped.
    @Test("An action that fails after a Stop asks for no recovery (#70)")
    func actionFailingAfterStopRequestsNoRecovery() async throws {
        let model = makeModel()
        model.steps = FakeRuntime().steps()
        model.applyState(socketResponds: true)
        let container = try JSONDecoder().decode(
            DockerContainerSummary.self,
            from: Data(#"{"Id":"web","Names":["/web"],"State":"running"}"#.utf8)
        )

        await model.withContainer(container, action: "Stopping", recoversRuntime: true) {
            await model.stopRuntime()
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
