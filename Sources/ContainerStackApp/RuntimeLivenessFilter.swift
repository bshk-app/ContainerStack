/// How many consecutive unanswered probes it takes before a healthy runtime is called offline.
///
/// Calling it is destructive: the same branch clears the inventory and bumps `inventoryEpoch`,
/// discarding any refresh in flight. On a single probe, one dropped connection blanked every list.
///
/// Only unexplained silence waits. A stopped API server is restarted first, by
/// `RuntimeConnectionRecovery.shouldAttemptRestart`.
struct RuntimeLivenessFilter: Sendable {
    /// Two, not more: the second answer arrives on the next tick, so the runtime is reported
    /// offline within about six seconds instead of three. Longer buys little and delays the
    /// banner that tells the user to restart.
    static let defaultTolerance = 2

    let tolerance: Int
    private(set) var consecutiveFailures = 0

    init(tolerance: Int = RuntimeLivenessFilter.defaultTolerance) {
        self.tolerance = max(1, tolerance)
    }

    /// Records one probe result and answers whether a runtime currently held healthy has now gone
    /// quiet for long enough to be declared offline. Any answer at all forgives what came before.
    mutating func recordProbe(responds: Bool) -> Bool {
        guard !responds else {
            consecutiveFailures = 0
            return false
        }
        consecutiveFailures += 1
        return consecutiveFailures >= tolerance
    }

    /// Forgets accumulated silence. A healthy verdict reaches the app from paths that never probe
    /// — adopting a socket, a successful refresh, the wait after a start — and silence counted
    /// before one of those is silence about a runtime that is now answering.
    mutating func reset() {
        consecutiveFailures = 0
    }
}
