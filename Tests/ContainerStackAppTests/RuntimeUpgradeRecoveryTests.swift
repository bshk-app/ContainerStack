import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@Suite("Runtime upgrade recovery")
@MainActor
struct RuntimeUpgradeRecoveryTests {
    @Test("An automatic restart starts the helper when launchd has no agent")
    func absentAgentStartsHelperAutomatically() async {
        let (model, runtime) = makeModel(
            client: DockerAPIClient(
                transport: GatedDockerTransport(answers: [
                    "/_ping": "OK", "/version": "{}", "/info": "{}",
                ])))
        runtime.onPing = { [unowned runtime] in runtime.socketAnswers = !runtime.spawned.isEmpty }

        model.applyState(socketResponds: true)
        var recorded = false
        await model.adoptBridgeIfStale(
            recorded: RuntimeHelperIdentity(bundleVersion: "447", digest: "old"),
            current: RuntimeHelperIdentity(bundleVersion: "448", digest: "new"),
            restart: { await model.run(.restart(replacingSibling: false), origin: .staleBridge) },
            recordIdentity: { recorded = true }
        )
        #expect(recorded)

        #expect(await runtime.gates.count("agentRegistered") == 1)
        #expect(runtime.spawned.count == 1)
        #expect(!runtime.performed.contains(.kickstartAgent(label: RuntimeRestartPlan.agentLabel)))
        #expect(model.runtimeState.isHealthy)
    }

    @Test("A registered launchd agent is kickstarted instead of spawning a helper")
    func presentAgentIsKickstarted() async {
        let (model, runtime) = makeModel()
        runtime.agentIsRegistered = true
        runtime.socketAnswers = true

        _ = await model.run(.restart(replacingSibling: false), origin: .staleBridge)

        #expect(runtime.performed.contains(.kickstartAgent(label: RuntimeRestartPlan.agentLabel)))
        #expect(runtime.spawned.isEmpty)
    }

    @Test("A nonzero command exit is an error")
    func nonzeroCommandExitIsReported() {
        #expect(throws: (any Error).self) {
            try RuntimeShell.run(executablePath: "/bin/launchctl", arguments: ["kickstart", "-k", "gui/501/test"]) {
                _, _, _ in ProcessRunner.Result(status: 113, output: "")
            }
        }
    }

    @Test("Opening the app starts a dead socket without a click")
    func launchStartsDeadSocket() async {
        let model = RuntimeViewModel(startsRuntime: true, client: healthyClient())
        let runtime = FakeRuntime()
        runtime.onPing = { [unowned runtime] in runtime.socketAnswers = !runtime.spawned.isEmpty }
        model.steps = runtime.steps()
        await runtime.gates.hold("ping")
        await runtime.gates.waitUntilEntered("ping")
        await runtime.gates.release("ping")
        for _ in 0..<500 where model.lifecycle.latest != nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(runtime.spawned.count == 1)
        #expect(model.runtimeState.isHealthy)
        #expect(!model.isStarting)
    }

    @Test("Stop supersedes a restart waiting on launchd")
    func stopDuringAgentQueryDoesNotRestart() async {
        let (model, runtime) = makeModel()
        await runtime.gates.hold("agentRegistered")
        let restart = Task { await model.restartRuntime() }
        await runtime.gates.waitUntilEntered("agentRegistered")
        let stop = model.admit(.stop(replacingSibling: false), origin: .user)
        await runtime.gates.release("agentRegistered")
        #expect(await settled(restart) == false)
        #expect(runtime.performed.isEmpty)
        #expect(await settled(Task { await model.execute(.stop(replacingSibling: false), stop) }) == .completed(true))
        #expect(runtime.spawned.isEmpty)
    }

    @Test("A failed kickstart reports the command and exit status in the restart error")
    func failedKickstartReportsRestartStep() async {
        let (model, runtime) = makeModel()
        runtime.agentIsRegistered = true
        let control = model.steps.control
        model.steps.control = { step in
            if case .kickstartAgent = step {
                try RuntimeShell.run(executablePath: "/bin/launchctl", arguments: ["kickstart", "-k", "gui/501/test"]) {
                    _, _, _ in ProcessRunner.Result(status: 113, output: "")
                }
            } else {
                try await control(step)
            }
        }
        #expect(await model.restartRuntime() == false)
        #expect(model.runtimeFailure?.contains("Restart failed at Restarting the runtime LaunchAgent") == true)
        #expect(model.runtimeFailure?.contains("launchctl kickstart -k gui/501/test exited with status 113") == true)
        #expect(!model.isRestarting)
    }

    @Test("Agent registration comes from launchd's stdout")
    func registrationUsesLaunchd() {
        for registered in [false, true] {
            let actual = RuntimeShell.agentRegistered { path, arguments in
                #expect(path == "/bin/launchctl")
                #expect(arguments == ["print", "gui/\(getuid())/\(RuntimeRestartPlan.agentLabel)"])
                return registered ? "gui/501/\(RuntimeRestartPlan.agentLabel) = {}" : ""
            }
            #expect(actual == registered)
        }
    }

    private func healthyClient() -> DockerAPIClient {
        DockerAPIClient(
            transport: GatedDockerTransport(answers: [
                "/_ping": "OK", "/version": "{}", "/info": "{}",
            ]))
    }

    private func makeModel(client: DockerAPIClient? = nil) -> (RuntimeViewModel, FakeRuntime) {
        let model = RuntimeViewModel(startsRuntime: false, client: client)
        let runtime = FakeRuntime()
        model.steps = runtime.steps()
        return (model, runtime)
    }
}
