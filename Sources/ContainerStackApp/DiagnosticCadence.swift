import Foundation

/// Rate limit for a check that costs a child process, kept separate from the poll interval that
/// drives it.
///
/// The monitor loop wants a 3s cadence because everything it normally asks goes over the Docker
/// socket and is cheap. One of its checks is not: `container system status` spawns the CLI and
/// waits on an XPC round trip, and it ran on every tick — about 1200 spawns an hour — to watch
/// for a condition that requires someone to delete the runtime's data directory.
///
/// A value type with an injected `now` so the cadence is testable without sleeping.
struct DiagnosticCadence: Sendable {
    let interval: Duration
    private var lastRun: ContinuousClock.Instant?

    init(interval: Duration) {
        self.interval = interval
    }

    /// True on the first call and once per `interval` after that. Records the run itself, so
    /// callers must not ask unless they intend to act on the answer.
    mutating func shouldRun(now: ContinuousClock.Instant = .now) -> Bool {
        if let lastRun, now - lastRun < interval {
            return false
        }
        lastRun = now
        return true
    }

    /// Marks the check as just having run without asking permission — for the paths that probe
    /// unconditionally, so the next poll does not immediately repeat the work.
    mutating func recordRun(now: ContinuousClock.Instant = .now) {
        lastRun = now
    }
}
