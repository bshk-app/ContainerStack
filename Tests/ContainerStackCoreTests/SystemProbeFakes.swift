import Foundation
import Testing

@testable import ContainerStackCore

/// One entry per `SystemProbe` method, so a recorded run reports which spawns
/// it made and not merely how many.
enum ProbeCall: String, Sendable {
    case runtimeStatus, routingTable, socketHolder, processTable
}

actor RecordingSystemProbe: SystemProbe {
    private let canned: [ProbeCall: ProbeResult]
    private(set) var calls: [ProbeCall] = []
    private(set) var socketPaths: [String] = []

    var callCount: Int { calls.count }

    init(
        runtimeStatus: ProbeResult? = nil,
        routingTable: ProbeResult? = nil,
        socketHolder: ProbeResult? = nil,
        processTable: ProbeResult? = nil
    ) {
        var canned: [ProbeCall: ProbeResult] = [:]
        canned[.runtimeStatus] = runtimeStatus
        canned[.routingTable] = routingTable
        canned[.socketHolder] = socketHolder
        canned[.processTable] = processTable
        self.canned = canned
    }

    func callCount(of call: ProbeCall) -> Int { calls.count { $0 == call } }

    func runtimeStatus() async -> ProbeResult { answer(.runtimeStatus) }

    func routingTable() async -> ProbeResult { answer(.routingTable) }

    func socketHolder(socketPath: String) async -> ProbeResult {
        socketPaths.append(socketPath)
        return answer(.socketHolder)
    }

    func processTable() async -> ProbeResult { answer(.processTable) }

    // An unconfigured method fails the test: inventing `.output("")` here would
    // rebuild the laundering this protocol exists to prevent.
    private func answer(_ call: ProbeCall) -> ProbeResult {
        calls.append(call)
        guard let result = canned[call] else {
            let reason = "RecordingSystemProbe has no canned result for \(call.rawValue)"
            Issue.record(Comment(rawValue: reason))
            return .failed(reason: reason)
        }
        return result
    }
}

actor GatedSystemProbe: SystemProbe {
    private let result: ProbeResult
    private var isOpen = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0
    private(set) var completedCallCount = 0

    init(result: ProbeResult) { self.result = result }

    /// Releases every parked call and admits later ones; reopening an open gate
    /// is a no-op, so no continuation is ever resumed twice.
    func open() {
        isOpen = true
        let waiting = gateWaiters
        gateWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Returns once a call has entered the probe, so a test can act on a
    /// suspended run without sleeping.
    func waitUntilCalled() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func runtimeStatus() async -> ProbeResult { await gate() }

    func routingTable() async -> ProbeResult { await gate() }

    func socketHolder(socketPath: String) async -> ProbeResult { await gate() }

    func processTable() async -> ProbeResult { await gate() }

    private func gate() async -> ProbeResult {
        callCount += 1
        let entered = entryWaiters
        entryWaiters = []
        for waiter in entered { waiter.resume() }
        if !isOpen {
            await withCheckedContinuation { gateWaiters.append($0) }
        }
        completedCallCount += 1
        return result
    }
}
@Suite("A recording probe makes spawn counts assertable")
struct RecordingSystemProbeTests {
    @Test("every call is counted")
    func recordingProbeCountsCalls() async {
        let probe = RecordingSystemProbe(runtimeStatus: .output("x"))
        _ = await probe.runtimeStatus()
        #expect(await probe.callCount == 1)
    }

    @Test("counts are kept per method, so one set's spawns are identifiable")
    func recordingProbeCountsEachMethodSeparately() async {
        let probe = RecordingSystemProbe(
            runtimeStatus: .output("status"),
            routingTable: .output("routes"),
            socketHolder: .output("holder"),
            processTable: .output("processes")
        )
        _ = await probe.runtimeStatus()
        _ = await probe.runtimeStatus()
        _ = await probe.routingTable()
        _ = await probe.socketHolder(socketPath: "/tmp/x.sock")
        _ = await probe.processTable()
        #expect(await probe.callCount == 5)
        #expect(await probe.callCount(of: .runtimeStatus) == 2)
        #expect(await probe.callCount(of: .routingTable) == 1)
        #expect(await probe.callCount(of: .socketHolder) == 1)
        #expect(await probe.callCount(of: .processTable) == 1)
        #expect(await probe.calls == [.runtimeStatus, .runtimeStatus, .routingTable, .socketHolder, .processTable])
    }

    @Test("the socket path reaching the probe is recorded, not just the call")
    func recordingProbeRecordsTheSocketPathItWasGiven() async {
        let probe = RecordingSystemProbe(socketHolder: .output("p1234"))
        _ = await probe.socketHolder(socketPath: "/var/run/container.sock")
        #expect(await probe.socketPaths == ["/var/run/container.sock"])
    }

    @Test("an unconfigured method fails the test instead of answering empty output")
    func recordingProbeRefusesToInventAResult() async {
        let probe = RecordingSystemProbe()
        var result = ProbeResult.output("unset")
        await withKnownIssue("the missing canned result is the point of this case") {
            result = await probe.runtimeStatus()
        }
        #expect(result == .failed(reason: "RecordingSystemProbe has no canned result for runtimeStatus"))
        #expect(await probe.callCount == 1)
    }
}

@Suite("A gated probe suspends a run without Task.sleep")
struct GatedSystemProbeTests {
    @Test("a call entered before opening has not returned")
    func gatedProbeSuspendsUntilOpened() async {
        let probe = GatedSystemProbe(result: .output("status"))
        let run = Task { await probe.runtimeStatus() }
        await probe.waitUntilCalled()
        #expect(await probe.callCount == 1)
        #expect(await probe.completedCallCount == 0)
        await probe.open()
        #expect(await run.value == .output("status"))
        #expect(await probe.completedCallCount == 1)
    }

    @Test("calls after opening return without suspending, and reopening is harmless")
    func gatedProbeAdmitsEveryCallOnceOpened() async {
        let probe = GatedSystemProbe(result: .failed(reason: "no runtime"))
        await probe.open()
        await probe.open()
        #expect(await probe.routingTable() == .failed(reason: "no runtime"))
        #expect(await probe.processTable() == .failed(reason: "no runtime"))
        #expect(await probe.callCount == 2)
        #expect(await probe.completedCallCount == 2)
    }
}
