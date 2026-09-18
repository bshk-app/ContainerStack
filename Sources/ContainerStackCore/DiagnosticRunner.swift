import Foundation

/// Assembles a `DiagnosticReport` over the Docker API and the external commands
/// a Docker call cannot answer. Prints nothing and touches no view state.
public struct DiagnosticRunner: Sendable {
    private let client: DockerAPIClient
    private let probe: any SystemProbe
    /// Injected so `ranAt` is assertable; a report never stamps itself from `Date()`.
    private let now: @Sendable () -> Date

    public init(
        client: DockerAPIClient,
        probe: any SystemProbe,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.probe = probe
        self.now = now
    }

    /// Answers every requested id and only those: a check that was not run is
    /// `.skipped` with no remedy, never dropped from the report.
    public func run(checks: Set<CheckID>) async -> DiagnosticReport {
        let ordered = CheckID.allCases.filter(checks.contains)
        return DiagnosticReport(checks: ordered.map(Self.notRun), ranAt: now())
    }

    private static func notRun(_ id: CheckID) -> DiagnosticCheck {
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
