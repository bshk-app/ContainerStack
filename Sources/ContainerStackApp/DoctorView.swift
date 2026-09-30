import ContainerStackCore
import SwiftUI

/// The Doctor section: the last report the section was shown, one row per check in the order the
/// runner ranked them, so whatever decided the others comes first.
struct DoctorView: View {
    let doctor: DoctorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                content
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { doctor.appeared() }
        .onDisappear { doctor.disappeared() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if doctor.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Text(doctor.statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button {
                doctor.checkAgain()
            } label: {
                LucideLabel(title: "Check again", icon: .rotateCw)
            }
            .disabled(doctor.isRunning)
        }
    }

    @ViewBuilder private var content: some View {
        if let report = doctor.report {
            VStack(spacing: 0) {
                ForEach(Array(report.checks.enumerated()), id: \.element.id) { index, check in
                    if index > 0 {
                        Divider()
                    }
                    DoctorCheckRow(check: check)
                }
            }
            .padding(.horizontal, 16)
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
        } else if !doctor.isRunning {
            EmptyResourceView(
                title: "No report yet",
                description: "Check the runtime's storage, the Docker socket, container routes, "
                    + "who holds the socket and the Docker context.",
                icon: .stethoscope
            )
            .frame(maxWidth: .infinity)
        }
    }
}

private struct DoctorCheckRow: View {
    let check: DiagnosticCheck

    /// The CLI's rule (`DoctorTextRenderer`): advice already quoted in the detail is not repeated.
    private var advice: String? {
        guard case .manual(let advice) = check.remedy, check.detail?.contains(advice) != true else {
            return nil
        }
        return advice
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LucideIcon(check.verdict.lucide)
                .frame(width: 15, height: 15)
                .foregroundStyle(check.verdict.tint)
                .padding(.top, 1)
                .accessibilityLabel(check.verdict.spokenName)
            VStack(alignment: .leading, spacing: 4) {
                Text(check.summary)
                    .font(.callout.weight(.medium))
                if let detail = check.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let advice {
                    Text(advice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .opacity(check.verdict == .skipped ? 0.6 : 1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

extension DoctorViewModel {
    /// F-011: a cached report is shown with the time it was measured, never as if it were live.
    var statusLine: String {
        if isRunning { return "Checking…" }
        guard let report else { return "Not checked yet" }
        return "Checked at \(report.ranAt.formatted(date: .omitted, time: .standard))"
    }
}

extension Verdict {
    var lucide: Lucide {
        switch self {
        case .ok: .circleCheck
        case .warning: .triangleAlert
        case .failure: .circleX
        case .indeterminate: .circleQuestion
        case .skipped: .circleMinus
        }
    }

    /// G-03: "could not measure" is amber, never the grey of "not applicable": a wedged runtime
    /// is indistinguishable from a stopped one at the socket, and all-grey reads as healthy.
    var tint: Color {
        switch self {
        case .ok: .green
        case .warning: .yellow
        case .failure: .red
        case .indeterminate: .orange
        case .skipped: .secondary
        }
    }

    var spokenName: String {
        switch self {
        case .ok: "Passed"
        case .warning: "Warning"
        case .failure: "Failed"
        case .indeterminate: "Could not check"
        case .skipped: "Skipped"
        }
    }
}
