import Foundation

/// How each verdict is spelled. Separated from the projection so `DiagnosticRunner.swift`
/// carries only what a check decides, never how a `DiagnosticCheck` is assembled.
extension DiagnosticRunner {
    static func passed(_ id: CheckID, summary: String, detail: String?) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .ok,
            summary: summary,
            detail: detail,
            remedy: nil,
            duration: .zero
        )
    }

    static func failed(
        _ id: CheckID,
        summary: String,
        detail: String?,
        remedy: Remedy?
    ) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .failure,
            summary: summary,
            detail: detail,
            remedy: remedy,
            duration: .zero
        )
    }

    /// A risk on a machine that is working, which is why it keeps a remedy: unlike
    /// `indeterminate`, something was measured and there is something to do about it.
    static func warned(
        _ id: CheckID,
        summary: String,
        detail: String?,
        remedy: Remedy?
    ) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .warning,
            summary: summary,
            detail: detail,
            remedy: remedy,
            duration: .zero
        )
    }

    /// Amber, and the reason the measurement failed travels with it: "could not tell" is
    /// only actionable when the report names what did not answer.
    static func indeterminate(_ id: CheckID, summary: String, detail: String?) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .indeterminate,
            summary: summary,
            detail: detail,
            // No repair: an unmeasured root gives no grounds to restart anything.
            remedy: nil,
            duration: .zero
        )
    }

    /// A reason, never a bare "not applicable": the check below a failure is grey because
    /// something above it already decided, and the report has to say what.
    static func skipped(_ id: CheckID, because reason: String) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .skipped,
            summary: reason,
            detail: nil,
            remedy: nil,
            duration: .zero
        )
    }

    static func notRun(_ id: CheckID) -> DiagnosticCheck {
        DiagnosticCheck(
            id: id,
            verdict: .skipped,
            summary: "Not run.",
            detail: nil,
            remedy: nil,
            duration: .zero
        )
    }
}
