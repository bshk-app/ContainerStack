import DiagnosticTestSupport
import Foundation
import Testing

@testable import ContainerStackCore

/// Ownership is the one check with no CLI line to reproduce, so these fixtures pin
/// wording this feature invents rather than wording F-003 requires it to copy.
@Suite("Bridge ownership is measured, and an unmeasured bridge is never ours")
struct DiagnosticRunnerForeignBridgeTests {
    private let foreignLsofOutput = "p4242\ncsocktainer\nn\(diagnosticSocketPath)"
    private let lsofFailure = "/usr/sbin/lsof exited with status 1"
    private let processTableFailure = "/bin/ps could not be run: spawn failed"

    private func ownershipCheck(
        socketHolder: ProbeResult,
        processTable: ProbeResult
    ) async -> DiagnosticCheck? {
        await ownershipReport(socketHolder: socketHolder, processTable: processTable).check(.foreignBridge)
    }

    private func ownershipReport(
        socketHolder: ProbeResult,
        processTable: ProbeResult
    ) async -> DiagnosticReport {
        await makeRunner(
            socketHolder: socketHolder,
            processTable: processTable,
            transport: idleRuntime()
        ).run(checks: CheckID.uiSet)
    }

    /// Answers every call the other checks make, so the aggregate below turns on
    /// ownership alone.
    private func idleRuntime() -> StubDockerTransport {
        StubDockerTransport(byPath: [
            "/_ping": .success(jsonResponse("OK")),
            "/version": .success(jsonResponse(#"{"Version":"1.7.0","ApiVersion":"1.43"}"#)),
            "/info": .success(jsonResponse(#"{"Containers":0,"Images":0}"#)),
            "/containers/json": .success(jsonResponse("[]")),
            "/networks": .success(jsonResponse("[]")),
        ])
    }

    @Test("the bridge this build ships holding the socket is a passing check")
    func ourOwnBridgePassesTheOwnershipCheck() async {
        let check = await ownershipCheck(
            socketHolder: .output(ourBridgeLsofOutput),
            processTable: .output(ourBridgeProcessTable)
        )
        #expect(check?.verdict == .ok)
        #expect(check?.summary == "Docker bridge: ours")
        #expect(check?.remedy == nil)
    }

    // F-005: restarting our runtime does not evict a process it did not start, so the
    // only honest repair is one the person performs.
    @Test("a foreign holder fails with a manual remedy, never a local restart")
    func aForeignHolderCarriesAManualRemedy() async {
        let check = await ownershipCheck(
            socketHolder: .output(foreignLsofOutput),
            processTable: .output(ourBridgeProcessTable)
        )
        let expected =
            "Stop the other Docker bridge holding \(diagnosticSocketPath), then start the runtime again."
        #expect(check?.verdict == .failure)
        #expect(check?.remedy == .manual(expected))
        #expect(check?.remedy != .restartRuntime)
    }

    @Test("an lsof that could not run leaves ownership unknown, not ours")
    func aFailedSocketHolderProbeIsIndeterminate() async {
        let check = await ownershipCheck(
            socketHolder: .failed(reason: lsofFailure),
            processTable: .output(ourBridgeProcessTable)
        )
        #expect(check?.verdict == .indeterminate)
        #expect(check?.verdict != .ok)
        #expect(check?.summary == "Docker bridge: UNKNOWN — the process holding the socket could not be identified.")
        #expect(check?.detail == lsofFailure)
        #expect(check?.remedy == nil)
    }

    @Test("a process table that could not run leaves ownership unknown, not ours")
    func aFailedProcessTableProbeIsIndeterminate() async {
        let check = await ownershipCheck(
            socketHolder: .output(ourBridgeLsofOutput),
            processTable: .failed(reason: processTableFailure)
        )
        #expect(check?.verdict == .indeterminate)
        #expect(check?.verdict != .ok)
        #expect(check?.detail == processTableFailure)
        #expect(check?.remedy == nil)
    }

    // A responding socket is held by something; lsof naming nobody means the holder
    // was not visible to us, which is unknown ownership rather than our own.
    @Test("a holder nobody could see is not read as ours")
    func anUnseenHolderIsNotReadAsOurs() async {
        let check = await ownershipCheck(
            socketHolder: .output(""),
            processTable: .output(ourBridgeProcessTable)
        )
        #expect(check?.verdict == .indeterminate)
        #expect(check?.verdict != .ok)
    }

    // The aggregate is where a laundered probe would do its damage: a clean bill of
    // health on the machine whose ownership probe just died.
    @Test("a dead ownership probe keeps the whole report off ok")
    func anUnmeasuredBridgeKeepsTheReportOffOk() async {
        let healthy = await ownershipReport(
            socketHolder: .output(ourBridgeLsofOutput),
            processTable: .output(ourBridgeProcessTable)
        )
        let unmeasured = await ownershipReport(
            socketHolder: .failed(reason: lsofFailure),
            processTable: .output(ourBridgeProcessTable)
        )
        #expect(healthy.verdict == .ok)
        #expect(unmeasured.verdict == .indeterminate)
    }
}
