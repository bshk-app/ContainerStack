import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

/// Start, Stop and Restart run whole here, on substituted steps: nothing reaches the machine's
/// runtime or bridge (#102). A scenario holds an operation at one of its awaits and clicks
/// something else, the interleavings #105 found one review at a time.
@Suite("Runtime lifecycle scenarios")
@MainActor
struct RuntimeLifecycleScenarioTests {
    @Test("Stop runs every stop step on the substituted steps and reports the bridge stopped")
    func stopRunsWhole() async {
        let (model, runtime) = makeModel()

        await model.stopRuntime()

        #expect(
            runtime.performed
                == RuntimeRestartPlan.stopSteps(
                    configuration: model.runtimeConfiguration(), replacingSibling: false))
        #expect(model.runtimeMessage == "Docker bridge stopped.")
        #expect(model.runtimeFailure == nil)
        #expect(!model.isRestarting)
    }

    @Test("A Stop clicked during Start's ping launches nothing (#70)")
    func stopDuringStartupPingLaunchesNothing() async {
        let (model, runtime) = makeModel()
        await runtime.gates.hold("ping")
        let start = Task { await model.run(.start, origin: .user) }
        await runtime.gates.waitUntilEntered("ping")

        let stop = Task { await model.stopRuntime() }
        await runtime.gates.release("ping")

        #expect(await start.value == .superseded)
        await stop.value
        // Not even the version check, which can hold the Stop for its ten-second deadline.
        #expect(await runtime.gates.count("launchComplaint") == 0)
        #expect(runtime.spawned.isEmpty)
        #expect(model.runtimeMessage == "Docker bridge stopped.")
    }

    /// Stop's own message would cover an adoption that ran, so this asks the API instead: adopting
    /// refreshes, and the refresh's first request is health's ping. Only Start's ping finds the
    /// socket, or Stop's closing probe would refresh too.
    @Test("A Stop clicked during Start's ping does not adopt the socket (#70)")
    func stopDuringStartupPingDoesNotAdopt() async {
        let transport = GatedDockerTransport(answers: [:])
        let (model, runtime) = makeModel(client: DockerAPIClient(transport: transport))
        var pings = 0
        runtime.onPing = {
            pings += 1
            runtime.socketAnswers = pings == 1
        }
        await runtime.gates.hold("ping")
        let start = Task { await model.run(.start, origin: .user) }
        await runtime.gates.waitUntilEntered("ping")

        let stop = Task { await model.stopRuntime() }
        await runtime.gates.release("ping")
        _ = await start.value
        await stop.value

        #expect(await !transport.wasRequested("/_ping"))
        #expect(model.runtimeMessage == "Docker bridge stopped.")
    }

    /// Codex reproduced this on #102: the Start asked the queue from its own task, which ran after
    /// a Stop called later, and the runtime started after the user had stopped it.
    @Test("A Start asked for before a Stop does not run after it")
    func earlierStartDoesNotRunAfterLaterStop() async {
        let (model, runtime) = makeModel()

        model.startRuntime()
        await model.stopRuntime()
        await waitUntilIdle(model)

        #expect(await runtime.gates.count("launchComplaint") == 0)
        #expect(runtime.spawned.isEmpty)
        #expect(model.runtimeMessage == "Docker bridge stopped.")
    }

    /// Codex reproduced this on #102: Restart handed the queue to a waiting Start, a Stop
    /// superseded that Start before its task resumed, and the Start still wrote its flags.
    @Test("A request superseded before its task resumes never begins")
    func requestSupersededBeforeResumingNeverBegins() async {
        let (model, runtime) = makeModel()
        await runtime.gates.hold("system stop")
        let restart = Task { await model.restartRuntime() }
        await runtime.gates.waitUntilEntered("system stop")
        let start = model.admit(.start, origin: .user)
        await runtime.gates.release("system stop")
        _ = await restart.value

        let stop = model.admit(.stop(replacingSibling: false), origin: .user)

        #expect(await model.execute(.start, start) == .superseded)
        #expect(!model.isStarting)
        _ = await model.execute(.stop(replacingSibling: false), stop)
    }

    /// Codex reproduced this on #102: a Stop clicked while Start's socket wait slept waited behind
    /// one more ping, which can take the socket's whole timeout.
    @Test("A Start superseded while its socket wait sleeps pings no more")
    func supersededSocketWaitPingsNoMore() async throws {
        let (model, runtime) = makeModel()
        model.steps.socketWaitTick = .milliseconds(300)
        let start = Task { await model.run(.start, origin: .user) }
        for _ in 0..<200 where runtime.spawned.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!runtime.spawned.isEmpty)

        let stop = model.admit(.stop(replacingSibling: false), origin: .user)

        #expect(await start.value == .superseded)
        #expect(await runtime.gates.count("ping") == 1)
        _ = await model.execute(.stop(replacingSibling: false), stop)
    }

    @Test("A helper retired by Stop is not reported as having failed (#70)")
    func retiredHelperIsNotAFailure() async {
        let (model, runtime) = makeModel()
        await runtime.gates.hold("ping")
        let start = Task { await model.run(.start, origin: .user) }
        // The second ping is the socket wait's, after the helper was spawned.
        await runtime.gates.waitUntilEntered("ping")
        await runtime.gates.release("ping")
        await runtime.gates.hold("ping")
        await runtime.gates.waitUntilEntered("ping", count: 2)

        let stop = Task { await model.stopRuntime() }
        await runtime.gates.release("ping")
        _ = await start.value
        await stop.value

        #expect(runtime.spawned.count == 1)
        #expect(model.runtimeFailure == nil)
    }

    /// Codex reproduced this with a fake CLI: the check fails or times out after the user stopped,
    /// and its complaint overwrote "Docker bridge stopped."
    @Test("A Stop during the version check publishes nothing the check found (#70)")
    func stopDuringVersionCheckPublishesNoFailure() async {
        let (model, runtime) = makeModel()
        runtime.complaint = "container 1.2.0 is too old"
        await runtime.gates.hold("launchComplaint")
        let start = Task { await model.run(.start, origin: .user) }
        await runtime.gates.waitUntilEntered("launchComplaint")

        let stop = Task { await model.stopRuntime() }
        await runtime.gates.release("launchComplaint")
        _ = await start.value
        await stop.value

        #expect(model.runtimeFailure == nil)
        #expect(model.runtimeMessage == "Docker bridge stopped.")
    }

    /// Codex reproduced this: Start waited on its version check, Restart launched a newer helper,
    /// and the old check's failure then ended the newer start and published itself.
    @Test("A version complaint found after Restart superseded the Start is not published (#70)")
    func supersededVersionComplaintIsNotPublished() async {
        let (model, runtime) = makeModel()
        runtime.complaint = "too old"
        await runtime.gates.hold("launchComplaint")
        await runtime.gates.hold("system stop")
        let start = Task { await model.run(.start, origin: .user) }
        await runtime.gates.waitUntilEntered("launchComplaint")

        let restart = Task { await model.restartRuntime() }
        await runtime.gates.release("launchComplaint")
        #expect(await start.value == .superseded)
        await runtime.gates.waitUntilEntered("system stop")

        #expect(model.runtimeFailure == nil)
        #expect(model.isRestarting)
        await runtime.gates.release("system stop")
        _ = await restart.value
    }

    @Test("For the current start, the version check's complaint is published and the start ends")
    func versionComplaintIsPublished() async {
        let (model, runtime) = makeModel()
        runtime.complaint = "too old"

        #expect(await model.run(.start, origin: .user) == .completed(false))

        #expect(model.runtimeFailure == "too old")
        #expect(!model.isStarting)
        #expect(runtime.spawned.isEmpty)
    }

    /// Codex reproduced this: a refresh failing while Start waited on its ping left the start with
    /// nothing to finish it, `.starting` for good.
    @Test("A start whose socket was declared dead during its ping ends instead of hanging")
    func startInvalidatedDuringPingEnds() async {
        let (model, runtime) = makeModel()
        runtime.socketAnswers = true
        runtime.onPing = { model.clearInventoryForStop() }

        _ = await model.run(.start, origin: .user)

        #expect(!model.isStarting)
        #expect(model.runtimeState != .starting)
    }

    @Test("A Stop before the launch-time start runs keeps it from starting (#70)")
    func stopBeforeInitialStartKeepsItStopped() async throws {
        let model = RuntimeViewModel(
            socketPath: "/tmp/containerstack-scenario-\(UUID().uuidString).sock",
            startsRuntime: true
        )
        let runtime = FakeRuntime()
        model.steps = runtime.steps()

        await model.stopRuntime()
        try await Task.sleep(for: .milliseconds(200))

        #expect(!model.isStarting)
        #expect(runtime.spawned.isEmpty)
        #expect(model.runtimeFailure == nil)
    }

    /// Before the queue, a wait whose helper Restart retired had to end its own start (#71); now
    /// the superseded Start ends at its checkpoint and Restart's end settles what it left.
    @Test("A Start superseded by Restart does not leave the runtime starting")
    func startSupersededByRestartDoesNotStayStarting() async {
        let (model, runtime) = makeModel()
        await runtime.gates.hold("ping")
        let start = Task { await model.run(.start, origin: .user) }
        await runtime.gates.waitUntilEntered("ping")

        let restart = Task { await model.restartRuntime() }
        await runtime.gates.release("ping")
        _ = await start.value
        _ = await restart.value

        #expect(!model.isStarting)
        #expect(!model.isRestarting)
        #expect(model.runtimeState != .starting)
    }

    /// Codex reproduced both: an old wait, or Restart's cleanup, ended the start a Start clicked
    /// meanwhile had begun, turning `.starting` into offline while that Start was still running.
    @Test("A Restart superseded by Start leaves the newer start starting")
    func supersededRestartLeavesNewerStartAlone() async {
        let (model, runtime) = makeModel()
        await runtime.gates.hold("system stop")
        let restart = Task { await model.restartRuntime() }
        await runtime.gates.waitUntilEntered("system stop")

        await runtime.gates.hold("ping")
        let start = Task { await model.run(.start, origin: .user) }
        await runtime.gates.release("system stop")
        #expect(await restart.value == false)
        await runtime.gates.waitUntilEntered("ping")

        #expect(model.isStarting)
        #expect(!model.isRestarting)
        await runtime.gates.release("ping")
        _ = await start.value
    }

    private func makeModel(client: DockerAPIClient? = nil) -> (RuntimeViewModel, FakeRuntime) {
        let model = RuntimeViewModel(
            socketPath: "/tmp/containerstack-scenario-\(UUID().uuidString).sock",
            startsRuntime: false,
            client: client
        )
        let runtime = FakeRuntime()
        model.steps = runtime.steps()
        return (model, runtime)
    }

    private func waitUntilIdle(_ model: RuntimeViewModel) async {
        for _ in 0..<500 where model.lifecycle.latest != nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Holds named steps until a test releases them, so a scenario can act while an operation waits.
/// Suspends rather than blocks: a blocked pool thread hung CI on #104.
actor StepGates {
    private var held: Set<String> = []
    private var parked: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var entered: [String: Int] = [:]
    private var arrivals: [(name: String, count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func hold(_ name: String) {
        held.insert(name)
    }

    func release(_ name: String) {
        held.remove(name)
        for waiter in parked.removeValue(forKey: name) ?? [] { waiter.resume() }
    }

    func pass(_ name: String) async {
        entered[name, default: 0] += 1
        let count = entered[name] ?? 0
        let ready = arrivals.filter { $0.name == name && $0.count <= count }
        arrivals.removeAll { $0.name == name && $0.count <= count }
        for arrival in ready { arrival.continuation.resume() }
        if held.contains(name) {
            await withCheckedContinuation { parked[name, default: []].append($0) }
        }
    }

    func count(_ name: String) -> Int {
        entered[name, default: 0]
    }

    /// Returns once `name` has been entered `count` times.
    func waitUntilEntered(_ name: String, count: Int = 1) async {
        guard entered[name, default: 0] < count else { return }
        await withCheckedContinuation { arrivals.append((name, count, $0)) }
    }
}

/// A runtime that exists only in the test: every step passes through `gates` under its name, the
/// control steps by their CLI words ("system stop", "system start", "stopBridge").
@MainActor
final class FakeRuntime {
    let gates = StepGates()
    var socketAnswers = false
    var complaint: String?
    var onPing: () -> Void = {}
    private(set) var performed: [RuntimeControlStep] = []
    private(set) var spawned: [Process] = []

    func steps() -> RuntimeSteps {
        RuntimeSteps(
            control: { step in
                await self.gates.pass(Self.name(of: step))
                self.performed.append(step)
            },
            ping: {
                await self.gates.pass("ping")
                self.onPing()
                return self.socketAnswers
            },
            launchComplaint: { _ in
                await self.gates.pass("launchComplaint")
                return self.complaint
            },
            spawnHelper: {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sleep")
                process.arguments = ["60"]
                try process.run()
                self.spawned.append(process)
                return LaunchedHelper(process: process, log: .nullDevice, logPath: "/dev/null")
            },
            systemStatus: { _ in "" },
            endHelper: { process, _ in
                process.terminate()
                while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
            },
            socketWaitTick: .milliseconds(10)
        )
    }

    deinit {
        for process in spawned where process.isRunning { process.terminate() }
    }

    static func name(of step: RuntimeControlStep) -> String {
        switch step {
        case .stopBridge: "stopBridge"
        case .stopContainers: "stopContainers"
        case .run(_, let arguments): arguments.prefix(2).joined(separator: " ")
        case .startBridge: "startBridge"
        case .kickstartAgent: "kickstartAgent"
        }
    }
}
