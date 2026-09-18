import Foundation

public enum CheckID: String, CaseIterable, Codable, Sendable {
    case appRoot, socket, versions, routes, foreignBridge, dockerContext, memoryCommitment
}

public enum Verdict: Codable, Equatable, Sendable {
    case ok, warning, failure

    /// Deliberately not run: the runtime is stopped, or a higher-precedence
    /// check made this one meaningless. Rendered grey.
    case skipped

    /// Attempted and unmeasurable: a probe or the deadline expired. Never equal
    /// to `.skipped` - a wedged runtime must not render as a stopped one.
    case indeterminate
}

public enum Remedy: Codable, Equatable, Sendable {
    case restartRuntime
    case repairDockerContext
    case manual(String)
}

public struct DiagnosticCheck: Codable, Equatable, Sendable {
    public let id: CheckID
    public let verdict: Verdict
    /// `summary` is non-empty; `remedy` is nil exactly when `verdict` is `.ok`.
    public let summary: String
    /// Carries newlines: the memory-commitment report is seven lines wide.
    public let detail: String?
    public let remedy: Remedy?
    /// NFR-005: which probe ate the budget.
    public let duration: Duration

    public init(
        id: CheckID,
        verdict: Verdict,
        summary: String,
        detail: String?,
        remedy: Remedy?,
        duration: Duration
    ) {
        self.id = id
        self.verdict = verdict
        self.summary = summary
        self.detail = detail
        self.remedy = remedy
        self.duration = duration
    }
}

public struct DiagnosticReport: Codable, Equatable, Sendable {
    /// Precedence-ordered, one entry per requested `CheckID`; a check is never
    /// dropped, not-run is `.skipped`.
    public let checks: [DiagnosticCheck]
    /// From an injected clock, never `Date()`.
    public let ranAt: Date

    public init(checks: [DiagnosticCheck], ranAt: Date) {
        self.checks = checks
        self.ranAt = ranAt
    }
}

public enum ProbeResult: Sendable {
    case output(String)
    /// A non-zero exit, a spawn failure or a timeout lands here, never in
    /// `.output("")`.
    case failed(reason: String)
}
