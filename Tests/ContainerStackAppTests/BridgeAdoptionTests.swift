import ContainerStackCore
import Testing

@testable import ContainerStackApp

@Suite("Bridge adoption")
@MainActor
struct BridgeAdoptionTests {
    private let shipped = RuntimeHelperIdentity(bundleVersion: "1.0", digest: "aaaa111122223333")
    private let older = RuntimeHelperIdentity(bundleVersion: "0.9", digest: "bbbb222233334444")

    @Test("An answering socket with no named holder is reported as foreign")
    func unnamedHolderIsReportedAsForeign() async {
        let model = RuntimeViewModel()
        model.applyState(socketResponds: true)
        var restarted = false

        await model.adoptBridgeIfStale(
            recorded: older,
            current: shipped,
            restart: {
                restarted = true
                return .completed(false)
            },
            recordIdentity: {},
            foreignBridge: { await model.currentForeignBridge() }
        )

        #expect(model.serviceMessage == RuntimeState.foreignBridge(ForeignBridge(socketPath: model.socketPath)).detail)
        #expect(!restarted)
    }

    @Test("Start retries an ownership check whose probe restart was dropped")
    func startRetriesDroppedProbeCheck() async {
        let model = RuntimeViewModel()
        let gates = StepGates()
        let turn = model.admit(.start, origin: .user)
        guard case .run(let token) = turn else {
            Issue.record("Start was not admitted")
            return
        }
        defer { _ = model.lifecycle.finish(token) }
        let observed = model.lifecycle.generation
        model.applyState(socketResponds: true)
        await gates.hold("probe ownership")
        var probeRestartWasDropped = false
        let probe = Task {
            await model.adoptBridgeIfStale(
                recorded: older,
                current: shipped,
                restart: {
                    let outcome = await model.run(
                        .restart(replacingSibling: false), origin: .staleBridge,
                        observed: observed)
                    #expect(outcome == .dropped)
                    probeRestartWasDropped = outcome == .dropped
                    return outcome
                },
                recordIdentity: { Issue.record("The dropped restart recorded an identity") },
                foreignBridge: {
                    await gates.pass("probe ownership")
                    return nil
                }
            )
            return true
        }
        await gates.waitUntilEntered("probe ownership", within: .seconds(5))

        // The release cannot run on MainActor until Start enters the check below.
        let release = Task { @MainActor in await gates.release("probe ownership") }
        var startRestarts = 0
        await model.adoptBridgeIfStale(
            recorded: older,
            current: shipped,
            restart: {
                #expect(probeRestartWasDropped)
                #expect(model.lifecycle.isCurrent(token))
                startRestarts += 1
                return .completed(true)
            },
            recordIdentity: {}
        )
        await release.value
        #expect(await settled(probe, within: .seconds(5)) == true)
        #expect(startRestarts == 1)
    }
}
