import Foundation

/// One advisory the poll shows the user, with the rate limit that decides how often it is worth
/// re-asking. `DiagnosticCadence` holds the timing rule; this holds the answer the rule gates.
///
/// A reference type, not a struct: the probes are `async`, and a `mutating` method that awaits
/// while holding exclusive access to a stored property is exactly the shape Swift's exclusivity
/// rules reject. Nothing here retains the view model — the probes arrive as non-escaping closures.
@MainActor
final class CachedAdvisory {
    private var cadence: DiagnosticCadence
    private var last: String?

    init(interval: Duration) {
        cadence = DiagnosticCadence(interval: interval)
    }

    /// The cached answer, re-probing at most once per interval.
    func throttled(_ probe: () -> String?) -> String? {
        if cadence.shouldRun() {
            last = probe()
        }
        return last
    }

    /// Probes now and feeds the same cache, so the next throttled read does not revert to a stale
    /// answer: a refresh that raised a banner would otherwise have the following poll clear it.
    func fresh(_ probe: () -> String?) -> String? {
        last = probe()
        cadence.recordRun()
        return last
    }

    // Async twins of the two above, named apart rather than overloaded: swift-format rejects a
    // sync/async pair that a trailing closure cannot tell apart. Both shapes have to exist --
    // `throttledForeignBridge` is read inline in an `applyState(...)` argument list that sits
    // directly after an inventory-epoch guard, so making it async would open a suspension point
    // between the guard and the publish, which is the stale-state race #70 is about.
    func throttledAsync(_ probe: () async -> String?) async -> String? {
        if cadence.shouldRun() {
            last = await probe()
        }
        return last
    }

    func freshAsync(_ probe: () async -> String?) async -> String? {
        last = await probe()
        cadence.recordRun()
        return last
    }
}
