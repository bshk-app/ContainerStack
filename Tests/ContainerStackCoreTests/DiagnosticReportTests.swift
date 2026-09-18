import Foundation
import Testing

@testable import ContainerStackCore

@Suite("What a diagnostic report carries")
struct DiagnosticReportTests {
    private func check(
        id: CheckID = .appRoot,
        verdict: Verdict = .indeterminate,
        summary: String = "s",
        detail: String? = nil,
        remedy: Remedy? = .manual("m"),
        duration: Duration = .seconds(1)
    ) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id, verdict: verdict, summary: summary,
            detail: detail, remedy: remedy, duration: duration
        )
    }

    private func roundTrip(_ report: DiagnosticReport) throws -> DiagnosticReport {
        try JSONDecoder().decode(DiagnosticReport.self, from: JSONEncoder().encode(report))
    }

    @Test("a report survives the trip through JSON unchanged")
    func reportRoundTripsThroughJSON() throws {
        let report = DiagnosticReport(checks: [check()], ranAt: Date(timeIntervalSince1970: 0))
        #expect(try roundTrip(report) == report)
        let decoded = try #require(try roundTrip(report).checks.first)
        #expect(decoded.duration == .seconds(1))
        #expect(decoded.duration != .zero)
    }

    /// A wedged runtime reads as healthy if "could not measure" decodes as "did
    /// not run", so the two verdicts must never compare equal.
    @Test("a verdict that could not be measured is not one that was skipped")
    func indeterminateIsNotSkipped() throws {
        #expect(Verdict.indeterminate != Verdict.skipped)
        let report = DiagnosticReport(
            checks: [check(verdict: .indeterminate), check(id: .routes, verdict: .skipped)],
            ranAt: Date(timeIntervalSince1970: 0)
        )
        let decoded = try roundTrip(report)
        #expect(decoded.checks.map(\.verdict) == [.indeterminate, .skipped])
    }

    /// The memory-commitment check prints five lines plus two conditional ones.
    @Test("detail keeps every line it was given")
    func detailCarriesMultipleLines() throws {
        let detail = (1...7).map { "line \($0)" }.joined(separator: "\n")
        let report = DiagnosticReport(
            checks: [check(detail: detail)], ranAt: Date(timeIntervalSince1970: 0)
        )
        let decoded = try #require(try roundTrip(report).checks.first)
        #expect(decoded.detail == detail)
        #expect(decoded.detail?.split(separator: "\n").count == 7)
    }

    @Test("a remedy keeps the text it was built with")
    func manualRemedyRoundTripsItsMessage() throws {
        let report = DiagnosticReport(
            checks: [check(remedy: .manual("run cstack doctor"))],
            ranAt: Date(timeIntervalSince1970: 0)
        )
        let decoded = try #require(try roundTrip(report).checks.first)
        #expect(decoded.remedy == .manual("run cstack doctor"))
        #expect(decoded.remedy != .restartRuntime)
    }

    @Test("an ok check needs no remedy")
    func okCheckCarriesNoRemedy() throws {
        let report = DiagnosticReport(
            checks: [check(verdict: .ok, remedy: nil)], ranAt: Date(timeIntervalSince1970: 0)
        )
        #expect(try roundTrip(report).checks.first?.remedy == nil)
    }

    @Test("every check the design names is addressable")
    func checkIDCoversTheDesignedChecks() {
        #expect(
            Set(CheckID.allCases) == [
                .appRoot, .socket, .versions, .routes, .foreignBridge, .dockerContext, .memoryCommitment,
            ]
        )
    }

    @Test("a check is addressable by id, and an unrequested one is absent")
    func lookupFindsACheckByIDAndReportsAnAbsentOne() {
        let report = DiagnosticReport(
            checks: [check(id: .appRoot, verdict: .skipped), check(id: .routes, verdict: .ok)],
            ranAt: Date(timeIntervalSince1970: 0)
        )
        #expect(report.check(.appRoot)?.verdict == .skipped)
        #expect(report.check(.routes)?.verdict == .ok)
        #expect(report.check(.memoryCommitment) == nil)
    }

    @Test("a probe failure is not an empty output")
    func probeFailureIsDistinctFromEmptyOutput() {
        #expect(ProbeResult.failed(reason: "no such file") == .failed(reason: "no such file"))
        #expect(ProbeResult.failed(reason: "no such file") != .output(""))
        #expect(ProbeResult.output("") != .output("no such file"))
    }
}
