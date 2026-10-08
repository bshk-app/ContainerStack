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

        #expect(await settled(start) == .superseded)
        #expect(await settled(stop) != nil)
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
        runtime.onPing = { [unowned runtime] in
            pings += 1
            runtime.socketAnswers = pings == 1
        }
        await runtime.gates.hold("ping")
        let start = Task { await model.run(.start, origin: .user) }
        await runtime.gates.waitUntilEntered("ping")

        let stop = Task { await model.stopRuntime() }
        await runtime.gates.release("ping")
        #expect(await settled(start) != nil)
        #expect(await settled(stop) != nil)

        #expect(await !transport.wasRequested("/_ping"))
        #expect(model.runtimeMessage == "Docker bridge stopped.")
    }

    /// Codex reproduced this on #102: the Start asked the queue from its own task, which ran after
    /// a Stop called later, and the runtime started after the user had stopped it.
    @Test("A Start asked for before a Stop does not run after it")
    func earlierStartDoesNotRunAfterLaterStop() async {
        let (model, runtime) = makeModel()

        model.startRuntime()
        #expect(await settled(Task { await model.stopRuntime() }) != nil)
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
        #expect(await settled(restart) != nil)

        let stop = model.admit(.stop(replacingSibling: false), origin: .user)

        #expect(await settled(Task { await model.execute(.start, start) }) == .superseded)
        #expect(!model.isStarting)
        #expect(await settled(Task { await model.execute(.stop(replacingSibling: false), stop) }) != nil)
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

        #expect(await settled(start) == .superseded)
        #expect(await runtime.gates.count("ping") == 1)
        #expect(await settled(Task { await model.execute(.stop(replacingSibling: false), stop) }) != nil)
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
        #expect(await settled(start) != nil)
        #expect(await settled(stop) != nil)

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
        #expect(await settled(start) != nil)
        #expect(await settled(stop) != nil)

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
        #expect(await settled(start) == .superseded)
        await runtime.gates.waitUntilEntered("system stop")

        #expect(model.runtimeFailure == nil)
        #expect(model.isRestarting)
        await runtime.gates.release("system stop")
        #expect(await settled(restart) != nil)
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
        runtime.onPing = { [weak model] in model?.clearInventoryForStop() }

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
        #expect(await settled(start) != nil)
        #expect(await settled(restart) != nil)

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
        #expect(await settled(restart) == false)
        await runtime.gates.waitUntilEntered("ping")

        #expect(model.isStarting)
        #expect(!model.isRestarting)
        await runtime.gates.release("ping")
        #expect(await settled(start) != nil)
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

/// The task's result, or nil when it has not settled within `limit`: a regression in how requests
/// settle fails the test instead of hanging the suite behind a gate it never releases. A guard, not
/// a timing: the limit is generous because a refresh runs `lsof` and `ps` on the main actor, which
/// every test in the process shares.
@MainActor
func settled<Value: Sendable>(_ task: Task<Value, Never>, within limit: Duration = .seconds(30)) async -> Value? {
    let race = SettleRace<Value>()
    return await withCheckedContinuation { continuation in
        race.continuation = continuation
        Task { race.finish(await task.value) }
        Task {
            try? await Task.sleep(for: limit)
            race.finish(nil)
        }
    }
}

@MainActor
private final class SettleRace<Value: Sendable> {
    var continuation: CheckedContinuation<Value?, Never>?

    func finish(_ value: Value?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// Holds named steps until a test releases them, so a scenario can act while an operation waits.
/// Suspends rather than blocks: a blocked pool thread hung CI on #104.
actor StepGates {
    private var held: Set<String> = []
    private var parked: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var entered: [String: Int] = [:]
    private struct Arrival {
        let id = UUID()
        let name: String
        let count: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var arrivals: [Arrival] = []

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
        for arrival in ready { arrival.continuation.resume(returning: true) }
        if held.contains(name) {
            await withCheckedContinuation { parked[name, default: []].append($0) }
        }
    }

    func count(_ name: String) -> Int {
        entered[name, default: 0]
    }

    /// Returns once `name` has been entered `count` times, or records an issue after `limit`: an
    /// operation stranded by a regression fails the test instead of hanging the suite.
    func waitUntilEntered(_ name: String, count: Int = 1, within limit: Duration = .seconds(30)) async {
        guard entered[name, default: 0] < count else { return }
        let arrived = await withCheckedContinuation { continuation in
            let arrival = Arrival(name: name, count: count, continuation: continuation)
            arrivals.append(arrival)
            Task {
                try? await Task.sleep(for: limit)
                expire(arrival.id)
            }
        }
        if !arrived {
            Issue.record("\(name) was not entered \(count) times within \(limit)")
        }
    }

    private func expire(_ id: UUID) {
        guard let index = arrivals.firstIndex(where: { $0.id == id }) else { return }
        arrivals.remove(at: index).continuation.resume(returning: false)
    }
}

/// A runtime that exists only in the test: every step passes through `gates` under its name, the
/// control steps by their CLI words ("system stop", "system start", "stopBridge").
@MainActor
final class FakeRuntime {
    let gates = StepGates()
    var socketAnswers = false
    /// Thrown by the ping instead of answering, as a lost XPC connection does.
    var pingError: (any Error)?
    var complaint: String?
    var status = ""
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
                if let error = self.pingError { throw error }
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
            systemStatus: { _ in
                await self.gates.pass("systemStatus")
                return self.status
            },
            endHelper: { process, _ in
                process.terminate()
                while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
            },
            socketWaitTick: .milliseconds(1)
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
