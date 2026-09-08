import Testing

@testable import ContainerStackApp

/// These four behaviours were previously spread across four private methods on RuntimeViewModel
/// with no coverage of their own: the caching was only ever exercised through a view model that
/// needs a live runtime. Pinning them here is the point of giving the pair its own type.
@Suite("A cached advisory re-probes on its cadence, not on every read")
@MainActor
struct CachedAdvisoryTests {
    @Test("the first throttled read probes")
    func firstThrottledReadProbes() {
        let advisory = CachedAdvisory(interval: .seconds(30))
        var probes = 0

        let answer = advisory.throttled {
            probes += 1
            return "banner"
        }

        #expect(answer == "banner")
        #expect(probes == 1)
    }

    @Test("a second read inside the interval serves the cache instead of probing again")
    func secondReadServesCache() {
        let advisory = CachedAdvisory(interval: .seconds(30))
        var probes = 0
        let probe = {
            probes += 1
            return "banner"
        }

        _ = advisory.throttled(probe)
        let second = advisory.throttled(probe)

        #expect(second == "banner")
        #expect(probes == 1)
    }

    /// The failure this guards against is the one the old comments called out: a refresh that
    /// probed without feeding the cache would raise a banner, and the next poll -- still holding
    /// the pre-refresh answer -- would clear it again.
    @Test("a fresh probe feeds the same cache the throttled read serves")
    func freshProbeFeedsTheCache() {
        let advisory = CachedAdvisory(interval: .seconds(30))

        _ = advisory.throttled { nil }
        let fresh = advisory.fresh { "bridge held elsewhere" }
        let afterFresh = advisory.throttled { "should not be asked" }

        #expect(fresh == "bridge held elsewhere")
        #expect(afterFresh == "bridge held elsewhere")
    }

    @Test("a fresh probe resets the cadence, so the next read does not immediately re-probe")
    func freshProbeResetsTheCadence() {
        let advisory = CachedAdvisory(interval: .seconds(30))
        var probes = 0

        _ = advisory.fresh {
            probes += 1
            return "banner"
        }
        _ = advisory.throttled {
            probes += 1
            return "re-probed"
        }

        #expect(probes == 1)
    }

    @Test("the async pair caches on the same terms as the sync one")
    func asyncPairCachesTheSameWay() async {
        let advisory = CachedAdvisory(interval: .seconds(30))
        var probes = 0
        let probe: () async -> String? = {
            probes += 1
            return "app root gone"
        }

        _ = await advisory.throttledAsync(probe)
        let second = await advisory.throttledAsync(probe)

        #expect(second == "app root gone")
        #expect(probes == 1)
    }
}
