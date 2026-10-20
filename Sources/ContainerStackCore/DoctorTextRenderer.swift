import Foundation

/// The CLI half of F-003, as a pure function (F-012): `cstack doctor` is
/// `print(DoctorTextRenderer.render(report))`, so the trailing newline is `print`'s.
public enum DoctorTextRenderer {
    public static func render(_ report: DiagnosticReport) -> String {
        let text = inPrintOrder(report.checks).flatMap(lines(of:)).joined(separator: "\n")
        // A stopped runtime deliberately skips its checks, but silence is not a useful
        // CLI diagnosis. Keep the stopped verdict grey while preserving the socket line.
        if text.isEmpty, report.check(.socket)?.verdict == .skipped {
            return "Docker socket: not responding"
        }
        return text
    }

    /// The order `cstack doctor` prints (`CStackCommands.swift:24-84`), which is not `CheckID`'s
    /// F-004 precedence order: precedence ranks checks, this only decides what a person reads first.
    public static let printOrder: [CheckID] = [
        .foreignBridge, .socket, .versions, .appRoot, .routes, .dockerContext, .memoryCommitment,
    ]

    /// Stable, and a check whose id `printOrder` does not name keeps its place at the end rather
    /// than disappearing: a report never loses a check it was asked for.
    private static func inPrintOrder(_ checks: [DiagnosticCheck]) -> [DiagnosticCheck] {
        let rank = Dictionary(uniqueKeysWithValues: printOrder.enumerated().map { ($1, $0) })
        return checks.enumerated()
            .sorted { left, right in
                (rank[left.element.id] ?? printOrder.count, left.offset)
                    < (rank[right.element.id] ?? printOrder.count, right.offset)
            }
            .map(\.element)
    }

    /// A skipped check is silence: F-003 has the foreign bridge skip what it makes meaningless,
    /// and the reason a check was skipped describes whichever check decided, not this one.
    private static func lines(of check: DiagnosticCheck) -> [String] {
        guard check.verdict != .skipped else { return [] }
        let detail = check.detail
        var lines = [check.summary]
        if let detail { lines.append(contentsOf: detail.components(separatedBy: "\n")) }
        // The advice can be both a `detail` line and the remedy, and a trailing line can follow
        // it, so anywhere in `detail` is the match that keeps the CLI from printing it twice.
        if case .manual(let advice) = check.remedy, detail?.contains(advice) != true {
            lines.append(advice)
        }
        return lines
    }
}
