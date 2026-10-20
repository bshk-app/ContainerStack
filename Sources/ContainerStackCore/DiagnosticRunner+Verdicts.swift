import Foundation

/// How each verdict is spelled. Separated from the projection so `DiagnosticRunner.swift`
/// carries only what a check decides, never how a `DiagnosticCheck` is assembled.
extension DiagnosticRunner {
    static func passed(_ id: CheckID, summary: String, detail: String?, took duration: Duration) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .ok,
            summary: summary,
            detail: detail,
            remedy: nil,
            duration: duration
        )
    }

    static func failed(
        _ id: CheckID,
        summary: String,
        detail: String?,
        remedy: Remedy?,
        took duration: Duration
    ) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .failure,
            summary: summary,
            detail: detail,
            remedy: remedy,
            duration: duration
        )
    }

    /// A risk on a machine that is working, which is why it keeps a remedy: unlike
    /// `indeterminate`, something was measured and there is something to do about it.
    static func warned(
        _ id: CheckID,
        summary: String,
        detail: String?,
        remedy: Remedy?,
        took duration: Duration
    ) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .warning,
            summary: summary,
            detail: detail,
            remedy: remedy,
            duration: duration
        )
    }

    /// Amber, and the reason the measurement failed travels with it: "could not tell" is
    /// only actionable when the report names what did not answer.
    static func indeterminate(
        _ id: CheckID,
        summary: String,
        detail: String?,
        took duration: Duration
    ) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .indeterminate,
            summary: summary,
            detail: detail,
            // No repair: an unmeasured root gives no grounds to restart anything.
            remedy: nil,
            duration: duration
        )
    }

    /// A reason, never a bare "not applicable": the check below a failure is grey because
    /// something above it already decided, and the report has to say what. F-015: the summary
    /// names the check, because the reason is the same on every row it greys.
    static func skipped(_ id: CheckID, because reason: String, took duration: Duration) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .skipped,
            summary: notChecked(id),
            detail: reason,
            remedy: nil,
            duration: duration
        )
    }

    /// Still timed: a healthy app root reaches here with a probe behind it, and what that
    /// probe cost is the one thing this verdict's wording does not say.
    static func notRun(_ id: CheckID, took duration: Duration) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .skipped,
            summary: notChecked(id),
            detail: nil,
            remedy: nil,
            duration: duration
        )
    }

    private static func notChecked(_ id: CheckID) -> String {
        "\(id.title): not checked"
    }
}
