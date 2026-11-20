import Testing

@testable import ContainerStackApp

/// These four behaviours were previously spread across four private methods on RuntimeViewModel
/// with no coverage of their own: the caching was only ever exercised through a view model that
/// needs a live runtime. Pinning them here is the point of giving the pair its own type.
@Suite("A cached advisory re-probes on its cadence, not on every read")
@MainActor
struct CachedAdvisoryTests {
    @Test("the first throttled read probes")
    func firstThrottledReadProbes() async {
        let advisory = CachedAdvisory<String>(interval: .seconds(30))
        var probes = 0

        let answer = await advisory.throttled {
            probes += 1
            return "banner"
        }

        #expect(answer == "banner")
        #expect(probes == 1)
    }

    @Test("a second read inside the interval serves the cache instead of probing again")
    func secondReadServesCache() async {
        let advisory = CachedAdvisory<String>(interval: .seconds(30))
        var probes = 0
        let probe: () async -> String? = {
            probes += 1
            return "banner"
        }

        _ = await advisory.throttled(probe)
        let second = await advisory.throttled(probe)

        #expect(second == "banner")
        #expect(probes == 1)
    }

    /// The failure this guards against is the one the old comments called out: a refresh that
    /// probed without feeding the cache would raise a banner, and the next poll -- still holding
    /// the pre-refresh answer -- would clear it again.
    @Test("a fresh probe feeds the same cache the throttled read serves")
    func freshProbeFeedsTheCache() async {
        let advisory = CachedAdvisory<String>(interval: .seconds(30))

        _ = await advisory.throttled { nil }
        let fresh = await advisory.fresh { "bridge held elsewhere" }
        let afterFresh = await advisory.throttled { "should not be asked" }

        #expect(fresh == "bridge held elsewhere")
        #expect(afterFresh == "bridge held elsewhere")
    }

    @Test("a fresh probe resets the cadence, so the next read does not immediately re-probe")
    func freshProbeResetsTheCadence() async {
        let advisory = CachedAdvisory<String>(interval: .seconds(30))
        var probes = 0

        _ = await advisory.fresh {
            probes += 1
            return "banner"
        }
        _ = await advisory.throttled {
            probes += 1
            return "re-probed"
        }

        #expect(probes == 1)
    }

    @Test("a slow probe cannot replace the result of a newer refresh")
    func overtakenProbeDoesNotReplaceCache() async {
        let advisory = CachedAdvisory<String>(interval: .seconds(30))
        let answer = await advisory.throttled {
            _ = await advisory.fresh { "new owner" }
            return "old owner"
        }
        let cached = await advisory.throttled { "unexpected probe" }

        #expect(answer == "new owner")
        #expect(cached == "new owner")
    }
}
