import ContainerStackCore
import Foundation
import SwiftUI
import Testing

@testable import ContainerStackApp

/// F-006: `CaseIterable` alone renders nothing. The sidebar draws `dockerItems` and filters only
/// that list by the hidden set, so membership there is what makes the row visible and hideable.
@MainActor
@Suite("Doctor is a sidebar destination that can be hidden like the others")
struct DoctorDestinationTests {
    @Test("the Doctor row is one of the Docker items")
    func doctorIsADockerItem() {
        #expect(DashboardDestination.dockerItems.contains(.doctor))
        #expect(!DashboardDestination.generalItems.contains(.doctor))
    }

    @Test("hiding Doctor removes its row and leaves the others")
    func hidingDoctorRemovesItsRow() {
        let visible = DashboardDestination.visibleDockerItems(hiding: [.doctor])

        #expect(!visible.contains(.doctor))
        #expect(visible == DashboardDestination.dockerItems.filter { $0 != .doctor })
    }

    @Test("the hidden set survives a fresh read of the stored preference")
    func theHiddenSetPersists() throws {
        let suite = "DoctorDestinationTests-\(UUID().uuidString)"
        let writer = try #require(UserDefaults(suiteName: suite))
        defer { writer.removePersistentDomain(forName: suite) }

        writer.set(
            DashboardDestination.storedValue(hiding: [.doctor, .images]),
            forKey: DashboardDestination.hiddenItemsKey
        )
        let reader = try #require(UserDefaults(suiteName: suite))
        let hidden = DashboardDestination.hiddenItems(
            from: reader.string(forKey: DashboardDestination.hiddenItemsKey) ?? ""
        )

        #expect(hidden == [.doctor, .images])
        #expect(!DashboardDestination.visibleDockerItems(hiding: hidden).contains(.doctor))
    }

    @Test("a stored value naming no known row hides nothing")
    func unknownStoredNamesAreIgnored() {
        #expect(DashboardDestination.hiddenItems(from: "") == [])
        #expect(DashboardDestination.hiddenItems(from: "retired,doctor") == [.doctor])
    }
}

/// G-03: a wedged runtime cannot be told from a stopped one at the socket, so "could not measure"
/// must never look like "not applicable".
@Suite("Each verdict has its own icon, and unknown is amber, never grey")
struct DoctorVerdictStyleTests {
    private static let verdicts: [Verdict] = [.ok, .warning, .failure, .skipped, .indeterminate]

    @Test("an unmeasured check is amber, not the grey of a skipped one")
    func indeterminateIsAmber() {
        #expect(Verdict.indeterminate.tint == .orange)
        #expect(Verdict.indeterminate.tint != Verdict.skipped.tint)
    }

    @Test("no two verdicts share an icon")
    func iconsAreDistinct() {
        #expect(Set(Self.verdicts.map(\.lucide)).count == Self.verdicts.count)
    }

    @Test("only a passing check is green and only a failing one red")
    func passAndFailHaveTheirOwnColours() {
        #expect(Verdict.ok.tint == .green)
        #expect(Verdict.failure.tint == .red)
        #expect(Self.verdicts.filter { $0.tint == .green } == [.ok])
        #expect(Self.verdicts.filter { $0.tint == .red } == [.failure])
    }
}

/// F-011: inside the window the section shows the cached report with its stamp, so the header
/// has to say which of "never run", "running" and "measured at" it is showing.
@MainActor
@Suite("The Doctor header says what the rows are")
struct DoctorStatusLineTests {
    @Test("before any run, while running, and after")
    func statusLineFollowsTheRun() async {
        let ranAt = Date(timeIntervalSince1970: 1_800_000_000)
        let doctor = DoctorViewModel(run: { DiagnosticReport(checks: [], ranAt: ranAt) })
        #expect(doctor.statusLine == "Not checked yet")

        doctor.appeared()
        #expect(doctor.statusLine == "Checking…")
        await doctor.inFlight?.value

        #expect(doctor.statusLine == "Checked at \(ranAt.formatted(date: .omitted, time: .standard))")
    }
}
