import Foundation

@MainActor
extension RuntimeViewModel {
    /// The poll's view of the app root. Asks the CLI at most once per cadence and reuses the
    /// last answer in between, so a 3s socket poll no longer implies a 3s process spawn.
    ///
    /// Latency is the whole trade: a deleted app root now surfaces within 30s rather than 3s.
    /// Nothing else can see it — with its app root gone the runtime still answers `_ping` with
    /// 200 — but reaching that state takes deliberate damage to the runtime's data directory,
    /// and every user-initiated refresh still asks immediately.
    func throttledMissingAppRoot() async -> String? {
        await appRootAdvisory.throttledAsync { await self.missingAppRoot() }
    }

    /// The socket path when a bridge that is not ours holds it, otherwise nil.
    /// Re-asked on the cadence so the banner clears by itself once the other
    /// bridge is gone - the reported case sat there for hours with nothing to see.
    func throttledForeignBridge() -> String? {
        bridgeOwnerAdvisory.throttled { self.servesOurBridge() ? nil : self.socketPath }
    }

    /// Probes now and feeds the same cache, for the same reason `freshMissingAppRoot`
    /// does: a refresh that answered from nothing would clear the banner the poll
    /// had just raised.
    func freshForeignBridge() -> String? {
        bridgeOwnerAdvisory.fresh { self.servesOurBridge() ? nil : self.socketPath }
    }

    /// Probes now and feeds the cache, so the next poll does not revert to a stale answer.
    /// Without sharing the cache, a refresh that raised the banner would have it cleared again
    /// on the following tick — the failure the comment in `refresh(health:)` already warns of.
    func freshMissingAppRoot() async -> String? {
        await appRootAdvisory.freshAsync { await self.missingAppRoot() }
    }
}
