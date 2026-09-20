import Foundation

/// The CLI half of F-003, as a pure function (F-012): `cstack doctor` is
/// `print(DoctorTextRenderer.render(report))`, so the trailing newline is `print`'s.
public enum DoctorTextRenderer {
    public static func render(_ report: DiagnosticReport) -> String {
        report.checks.flatMap(lines(of:)).joined(separator: "\n")
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
