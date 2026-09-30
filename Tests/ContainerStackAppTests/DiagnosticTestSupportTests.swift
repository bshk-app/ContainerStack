import ContainerStackCore
import DiagnosticTestSupport
import Testing

// T-020's single-flight proof suspends a run inside `GatedSystemProbe`, so the app's test target
// has to see the same fakes the core's does; SwiftPM lets no test target import another.
@Suite("The probe fakes reach the app's tests")
struct DiagnosticTestSupportTests {
    @Test("a gated probe parks a call until opened")
    func aGatedProbeIsUsableHere() async {
        let probe = GatedSystemProbe(result: .output("status"))
        let run = Task { await probe.runtimeStatus() }
        await probe.waitUntilCalled()
        #expect(await probe.completedCallCount == 0)
        await probe.open()
        #expect(await run.value == .output("status"))
    }

    @Test("a recording probe counts calls")
    func aRecordingProbeIsUsableHere() async {
        let probe = RecordingSystemProbe(processTable: .output("1 /sbin/launchd"))
        #expect(await probe.processTable() == .output("1 /sbin/launchd"))
        #expect(await probe.calls == [.processTable])
    }
}
