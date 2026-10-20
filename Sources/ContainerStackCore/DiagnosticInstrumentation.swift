import Foundation
import os

/// How long a check took, read from a clock that cannot step backwards. `Date` can, whenever
/// the wall clock is adjusted, and a negative measurement is worse than none.
public enum MonotonicTicks {
    private static let origin = ContinuousClock.now

    /// Counted from the first read, never from an epoch: only differences are meaningful.
    public static func sinceStart() -> Duration { ContinuousClock.now - origin }
}

/// Where NFR-005's line goes when a caller wires up nothing. The unified log, not stdout:
/// a report prints nothing, and a CLI renders the same facts itself.
public enum DiagnosticLog {
    private static let logger = Logger(subsystem: "com.containerstack.core", category: "diagnostics")

    public static func line(_ message: String) { logger.log("\(message, privacy: .public)") }
}
