import Foundation
import Testing

@testable import ContainerStackCore

/// Fixed so `ranAt` is assertable: a report must never stamp itself from `Date()`.
let diagnosticClockDate = Date(timeIntervalSince1970: 1_700_000_000)

func makeRunner(
    probe: any SystemProbe,
    transport: StubDockerTransport = StubDockerTransport(byPath: [:]),
    now: Date = diagnosticClockDate
) -> DiagnosticRunner {
    DiagnosticRunner(
        client: DockerAPIClient(transport: transport),
        probe: probe,
        now: { now }
    )
}

/// Probe results default to empty output rather than to nothing: an unconfigured
/// `RecordingSystemProbe` method records an issue, which no caller here wants.
func makeRunner(
    runtimeStatus: ProbeResult = .output(""),
    routingTable: ProbeResult = .output(""),
    socketHolder: ProbeResult = .output(""),
    processTable: ProbeResult = .output(""),
    transport: StubDockerTransport = StubDockerTransport(byPath: [:]),
    now: Date = diagnosticClockDate
) -> DiagnosticRunner {
    makeRunner(
        probe: RecordingSystemProbe(
            runtimeStatus: runtimeStatus,
            routingTable: routingTable,
            socketHolder: socketHolder,
            processTable: processTable
        ),
        transport: transport,
        now: now
    )
}

@Suite("A run answers every requested check and nothing else")
struct DiagnosticRunnerTests {
    @Test("one check per requested id, in a fixed order")
    func everyRequestedCheckAppearsExactlyOnce() async {
        let report = await makeRunner().run(checks: [.appRoot, .routes])
        #expect(Set(report.checks.map(\.id)) == [.appRoot, .routes])
        #expect(report.checks.count == 2)
        #expect(report.checks.map(\.id) == [.appRoot, .routes])
    }

    // Spelled out rather than derived from `allCases`: reordering `CheckID` into
    // F-004 precedence must fail here, not pass against a moving target.
    @Test("the emitted order is the declared order, pinned literally")
    func theReportEmitsChecksInTheDeclaredOrder() async {
        let report = await makeRunner().run(checks: Set(CheckID.allCases))
        #expect(
            report.checks.map(\.id) == [
                .appRoot, .socket, .versions, .routes, .foreignBridge, .dockerContext,
                .memoryCommitment,
            ]
        )
    }

    // The producer owns what `DiagnosticCheck` cannot: a check that was not run
    // names no repair.
    @Test("a skipped check carries no remedy")
    func theSkeletonSkipsEveryCheckWithoutNamingARemedy() async {
        let report = await makeRunner().run(checks: Set(CheckID.allCases))
        #expect(report.checks.count == CheckID.allCases.count)
        #expect(report.checks.allSatisfy { $0.verdict == .skipped })
        #expect(report.checks.allSatisfy { $0.remedy == nil })
        #expect(report.checks.allSatisfy { !$0.summary.isEmpty })
    }

    @Test("the stamp is the injected clock's, not the wall clock's")
    func theReportIsStampedByTheInjectedClock() async {
        let report = await makeRunner(now: diagnosticClockDate).run(checks: [.socket])
        #expect(report.ranAt == diagnosticClockDate)
    }

    @Test("an empty request is an empty report, not an error")
    func anEmptyCheckSetStillProducesAStampedReport() async {
        let report = await makeRunner().run(checks: [])
        #expect(report.checks.isEmpty)
        #expect(report.ranAt == diagnosticClockDate)
    }
}
