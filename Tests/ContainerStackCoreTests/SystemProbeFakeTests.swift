import ContainerStackCore
import DiagnosticTestSupport
import Testing
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

    @Test("a second caller arriving while the first is parked is awaitable")
    func gatedProbeAwaitsASecondConcurrentCaller() async {
        let probe = GatedSystemProbe(result: .output("status"))
        let first = Task { await probe.runtimeStatus() }
        await probe.waitUntilCalled()
        let second = Task { await probe.routingTable() }
        await probe.waitUntilCalled(count: 2)
        #expect(await probe.callCount == 2)
        #expect(await probe.completedCallCount == 0)
        await probe.open()
        #expect(await first.value == .output("status"))
        #expect(await second.value == .output("status"))
        #expect(await probe.completedCallCount == 2)
    }

    @Test("a departure is awaitable too, so an abandoned run can be let finish")
    func gatedProbeAwaitsCallsLeavingTheGate() async {
        let probe = GatedSystemProbe(result: .output("status"))
        let first = Task { await probe.runtimeStatus() }
        let second = Task { await probe.processTable() }
        await probe.waitUntilCalled(count: 2)
        await probe.open()
        await probe.waitUntilCompleted(count: 2)
        #expect(await probe.completedCallCount == 2)
        #expect(await first.value == .output("status"))
        #expect(await second.value == .output("status"))
    }
}
