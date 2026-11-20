import Foundation

/// One advisory the poll shows the user, with the rate limit that decides how often it is worth
/// re-asking. `DiagnosticCadence` holds the timing rule; this holds the answer the rule gates.
///
/// A reference type, not a struct: the probes are `async`, and a `mutating` method that awaits
/// while holding exclusive access to a stored property is exactly the shape Swift's exclusivity
/// rules reject. Nothing here retains the view model — the probes arrive as non-escaping closures.
@MainActor
final class CachedAdvisory<Value> {
    private var cadence: DiagnosticCadence
    private var last: Value?
    private var generation = 0

    init(interval: Duration) {
        cadence = DiagnosticCadence(interval: interval)
    }

    /// The cached answer, re-probing at most once per interval.
    func throttled(_ probe: () async -> Value?) async -> Value? {
        guard cadence.shouldRun() else { return last }
        return await update(probe)
    }

    /// Probes now and feeds the same cache, so the next throttled read does not revert to a stale
    /// answer: a refresh that raised a banner would otherwise have the following poll clear it.
    func fresh(_ probe: () async -> Value?) async -> Value? {
        cadence.recordRun()
        return await update(probe)
    }

    private func update(_ probe: () async -> Value?) async -> Value? {
        generation &+= 1
        let started = generation
        let value = await probe()
        if started == generation {
            last = value
        }
        return last
    }
}
