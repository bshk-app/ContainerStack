import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

/// The acceptance scenarios of docs/specs/2026-10-07-runtime-lifecycle-queue.md, one per
/// requirement, on the substituted steps of `FakeRuntime` (#102). Requests a scenario must order
/// are admitted directly, and every await on an operation is bounded by `settled`.
@Suite("Runtime lifecycle acceptance")
@MainActor
struct RuntimeLifecycleAcceptanceTests {
    @Test("F-001: a Start clicked while Restart is in system stop begins only after it returned")
    func startWaitsForRestartsSystemStop() async {
        let (model, runtime) = makeModel(client: Self.healthyClient())
        runtime.onPing = { [unowned runtime] in runtime.socketAnswers = !runtime.spawned.isEmpty }
        await runtime.gates.hold("system stop")
        let restart = Task { await model.restartRuntime() }
        await runtime.gates.waitUntilEntered("system stop")

        let turn = model.admit(.start, origin: .user)
        let start = Task { await model.execute(.start, turn) }
        // Time for a Start that did not wait to reach its ping.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await runtime.gates.count("ping") == 0)
        await runtime.gates.release("system stop")
        #expect(await settled(restart) == false)
        #expect(await settled(start) == .completed(true))
        #expect(!runtime.performed.contains { FakeRuntime.name(of: $0) == "system start" })
        #expect(runtime.spawned.count == 1)
    }

    @Test("F-002a: a Stop clicked while Restart is in system stop leaves the runtime stopped")
    func stopDuringRestartLeavesRuntimeStopped() async {
        let (model, runtime) = makeModel()
        await runtime.gates.hold("system stop")
        let restart = Task { await model.restartRuntime() }
        await runtime.gates.waitUntilEntered("system stop")

        let stop = Task { await model.stopRuntime() }
        await runtime.gates.release("system stop")

        #expect(await settled(restart) == false)
        #expect(await settled(stop) != nil)
        #expect(!runtime.performed.contains { FakeRuntime.name(of: $0) == "system start" })
        #expect(runtime.spawned.isEmpty)
        #expect(model.runtimeMessage == "Docker bridge stopped.")
        #expect(!model.isRestarting)
    }

    @Test("F-002b: a Restart superseded while its refresh collects health publishes nothing")
    func restartSupersededDuringHealthPublishesNothing() async {
        let transport = GatedDockerTransport(answers: Self.healthyAPI, holding: ["/_ping"])
        await supersedeRestartDuringRefresh(transport: transport, heldPath: "/_ping") { model in
            #expect(model.snapshot == nil)
        }
    }

    @Test("F-002c: a Restart superseded while its refresh lists images publishes no list or error")
    func restartSupersededDuringInventoryPublishesNothing() async {
        var answers = Self.healthyAPI
        answers["/images/json"] = #"[{"Id":"sha256:1","RepoTags":["nginx:latest"]}]"#
        // No answer: the containers fetch after the supersede fails.
        answers["/containers/json"] = nil
        answers["/volumes"] = #"{"Volumes":[{"Name":"data","Driver":"local"}]}"#
        answers["/networks"] = #"[{"Id":"n1","Name":"bridge"}]"#
        let transport = GatedDockerTransport(answers: answers, holding: ["/images/json"])
        await supersedeRestartDuringRefresh(transport: transport, heldPath: "/images/json") { model in
            #expect(model.images.isEmpty)
            #expect(model.containers.isEmpty)
            #expect(model.containersErrorMessage == nil)
            #expect(model.volumes.isEmpty)
            #expect(model.networks.isEmpty)
        }
    }

    /// The interleaving Codex reproduced on #105: a probe began while a Stop ran, and its
    /// "not running" arrived once the Stop was over.
    @Test("F-003: a probe begun during a Stop cannot restart the runtime after it")
    func probeDuringStopCannotRecoverAfterIt() async {
        let (model, runtime) = makeModel()
        runtime.status = "apiserver is not running"
        await runtime.gates.hold("stopBridge")
        let stop = Task { await model.stopRuntime() }
        await runtime.gates.waitUntilEntered("stopBridge")
        runtime.pingError = Self.lostConnection
        await runtime.gates.hold("systemStatus")
        let probe = Task { await model.probeRuntime() }
        await runtime.gates.waitUntilEntered("systemStatus")
        // Only this probe lost the connection, or the Stop's closing probe would ask too.
        runtime.pingError = nil

        await runtime.gates.release("stopBridge")
        #expect(await settled(stop) != nil)
        let stopped = runtime.performed
        await runtime.gates.release("systemStatus")
        #expect(await settled(probe) != nil)

        #expect(runtime.performed == stopped)
        #expect(model.runtimeMessage == "Docker bridge stopped.")
    }

    @Test("F-004: recovery supersedes a Start whose API server is gone, and the Start publishes nothing")
    func recoverySupersedesStart() async throws {
        let (model, runtime) = makeModel(client: Self.healthyClient())
        runtime.status = "apiserver is not running"
        // Only the restart's helper brings the socket up; the Start's waits in vain, slowly enough
        // that the probe's verdict arrives before the wait gives up.
        runtime.onPing = { [unowned runtime] in runtime.socketAnswers = runtime.spawned.count >= 2 }
        model.steps.socketWaitTick = .milliseconds(50)
        let start = Task { await model.run(.start, origin: .user) }
        for _ in 0..<200 where runtime.spawned.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(runtime.spawned.count == 1)

        runtime.pingError = Self.lostConnection
        await runtime.gates.hold("systemStatus")
        let probe = Task { await model.probeRuntime() }
        await runtime.gates.waitUntilEntered("systemStatus")
        runtime.pingError = nil
        // The restart's first step: the Start has drained by then, and the restart has written
        // nothing over what the Start left but its own progress message.
        await runtime.gates.hold("stopBridge")
        await runtime.gates.release("systemStatus")

        #expect(await settled(start) == .superseded)
        await runtime.gates.waitUntilEntered("stopBridge")
        #expect(model.errorMessage == nil)
        await runtime.gates.release("stopBridge")
        #expect(await settled(probe) != nil)
        #expect(runtime.spawned.count == 2)
        #expect(!runtime.spawned[0].isRunning)
        #expect(model.runtimeState.isHealthy)
        #expect(!model.isStarting)
        #expect(!model.isRestarting)
    }

    @Test("F-006: the Doctor's Restart, replaced by a Stop while it waits, settles and ends its repair")
    func replacedDoctorRestartEndsItsRepair() async {
        let transport = GatedDockerTransport(answers: Self.healthyAPI, holding: ["/_ping"])
        let (model, runtime) = makeModel(client: Self.client(transport))
        runtime.socketAnswers = true
        let start = Task { await model.run(.start, origin: .user) }
        // Adopted and refreshing: the runtime reads healthy, so the Doctor offers its restart, and
        // that request waits behind the Start.
        await transport.waitUntilRequested("/_ping")
        let doctor = DoctorViewModel(
            run: { DiagnosticReport(checks: [], ranAt: Date()) },
            repairs: DoctorRepairs(runtime: model)
        )
        let repair = Task { await doctor.perform(.restartRuntime) }
        for _ in 0..<200 where model.lifecycle.latest != .restart(replacingSibling: true) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(doctor.repairing == .restartRuntime)

        let stop = model.admit(.stop(replacingSibling: false), origin: .user)

        // Settled while the Start still holds the queue: the Doctor is not left waiting on it.
        #expect(await settled(repair) != nil)
        #expect(doctor.repairing == nil)
        await transport.release("/_ping")
        #expect(await settled(start) == .superseded)
        let stopped = Task { await model.execute(.stop(replacingSibling: false), stop) }
        #expect(await settled(stopped) == .completed(true))
    }

    @Test("F-007: a recovery dropped while a Start runs leaves the Start's state alone")
    func droppedRecoveryLeavesStartAlone() async throws {
        let (model, runtime) = makeModel()
        model.containers = try JSONDecoder().decode(
            [DockerContainerSummary].self, from: Data(#"[{"Id":"web","State":"running"}]"#.utf8))
        runtime.status = "apiserver is not running"
        runtime.pingError = Self.lostConnection
        await runtime.gates.hold("systemStatus")
        let probe = Task { await model.probeRuntime() }
        await runtime.gates.waitUntilEntered("systemStatus")
        runtime.pingError = nil
        await runtime.gates.hold("ping")
        let start = Task { await model.run(.start, origin: .user) }
        await runtime.gates.waitUntilEntered("ping", count: 2)

        await runtime.gates.release("systemStatus")
        #expect(await settled(probe) != nil)

        #expect(model.isStarting)
        #expect(model.containers.count == 1)
        #expect(model.runtimeMessage != RuntimeViewModel.recoveringRuntimeMessage)
        #expect(runtime.performed.isEmpty)
        await runtime.gates.release("ping")
        #expect(await settled(start) != nil)
    }

    @Test("F-008: Stop is disabled only while a Stop runs or waits")
    func stopIsDisabledOnlyForAStop() async {
        let (model, runtime) = makeModel()
        await runtime.gates.hold("ping")
        let start = Task { await model.run(.start, origin: .user) }
        await runtime.gates.waitUntilEntered("ping")
        #expect(!model.isStopping, "a Start runs")

        let replacedStop = model.admit(.stop(replacingSibling: false), origin: .user)
        #expect(model.isStopping, "a Stop waits")

        await runtime.gates.hold("system stop")
        let restartTurn = model.admit(.restart(replacingSibling: false), origin: .user)
        #expect(!model.isStopping, "the waiting Stop was replaced by a Restart")
        let replaced = Task { await model.execute(.stop(replacingSibling: false), replacedStop) }
        #expect(await settled(replaced) == .superseded)
        let restart = Task { await model.execute(.restart(replacingSibling: false), restartTurn) }
        await runtime.gates.release("ping")
        #expect(await settled(start) == .superseded)
        await runtime.gates.waitUntilEntered("system stop")
        #expect(!model.isStopping, "a Restart runs")

        // The restart passed stopBridge before this hold, so the Stop's is the second.
        await runtime.gates.hold("stopBridge")
        let stopTurn = model.admit(.stop(replacingSibling: false), origin: .user)
        let stop = Task { await model.execute(.stop(replacingSibling: false), stopTurn) }
        await runtime.gates.release("system stop")
        #expect(await settled(restart) == .superseded)
        await runtime.gates.waitUntilEntered("stopBridge", count: 2)
        #expect(model.isStopping, "a Stop runs")

        await runtime.gates.release("stopBridge")
        #expect(await settled(stop) == .completed(true))
        #expect(!model.isStopping)
    }

    /// Restart launches a helper whose socket answers, then refreshes against `transport`, which
    /// holds `heldPath`. A Stop admitted there supersedes it, and is itself held at its first step,
    /// so `check` sees what the superseded refresh left with nothing written over it.
    private func supersedeRestartDuringRefresh(
        transport: GatedDockerTransport,
        heldPath: String,
        check: (RuntimeViewModel) -> Void
    ) async {
        let (model, runtime) = makeModel(client: Self.client(transport))
        runtime.onPing = { [unowned runtime] in runtime.socketAnswers = !runtime.spawned.isEmpty }
        let restart = Task { await model.restartRuntime() }
        await transport.waitUntilRequested(heldPath)

        // The restart passed stopBridge long ago, so the Stop's is the second.
        await runtime.gates.hold("stopBridge")
        let stopTurn = model.admit(.stop(replacingSibling: false), origin: .user)
        let stop = Task { await model.execute(.stop(replacingSibling: false), stopTurn) }
        await transport.release(heldPath)
        #expect(await settled(restart) == false)
        await runtime.gates.waitUntilEntered("stopBridge", count: 2)

        check(model)
        #expect(model.imagesErrorMessage == nil)
        #expect(model.runtimeFailure == nil)
        await runtime.gates.release("stopBridge")
        #expect(await settled(stop) == .completed(true))
    }

    private static let lostConnection = DockerAPIError.httpStatus(
        500, message: "XPC connection error: Connection invalid")

    private static let healthyAPI: [String: String] = [
        "/_ping": "OK",
        "/version": "{}",
        "/info": "{}",
        "/images/json": "[]",
        "/containers/json": "[]",
        "/volumes": #"{"Volumes":[]}"#,
        "/networks": "[]",
    ]

    private static func client(_ transport: GatedDockerTransport) -> DockerAPIClient {
        DockerAPIClient(transport: transport, retryPolicy: DockerRetryPolicy(maxAttempts: 1, delay: .zero))
    }

    private static func healthyClient() -> DockerAPIClient {
        client(GatedDockerTransport(answers: healthyAPI))
    }

    private func makeModel(client: DockerAPIClient? = nil) -> (RuntimeViewModel, FakeRuntime) {
        let model = RuntimeViewModel(
            socketPath: "/tmp/containerstack-acceptance-\(UUID().uuidString).sock",
            startsRuntime: false,
            client: client
        )
        let runtime = FakeRuntime()
        model.steps = runtime.steps()
        return (model, runtime)
    }
}
