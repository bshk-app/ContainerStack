import Testing

@testable import ContainerStackApp

/// Declaring a healthy runtime offline clears the inventory and bumps the epoch, so the cost of
/// being wrong once is every list in the app going blank and a refresh in flight being thrown away.
@Suite("What it takes to call a runtime offline")
struct RuntimeLivenessFilterTests {
    @Test("one unanswered probe is not enough")
    func singleFailureIsTolerated() {
        var filter = RuntimeLivenessFilter()

        let declared = filter.recordProbe(responds: false)

        #expect(!declared)
        #expect(filter.consecutiveFailures == 1)
    }

    @Test("the second consecutive silence decides")
    func secondFailureDeclaresOffline() {
        var filter = RuntimeLivenessFilter()

        let first = filter.recordProbe(responds: false)
        let second = filter.recordProbe(responds: false)

        #expect(!first)
        #expect(second)
    }

    /// The case the filter exists for: a dropped connection between two answering probes used to
    /// blank the inventory, and the runtime was never actually gone.
    @Test("an answer in between forgives the failure before it")
    func successResetsTheCount() {
        var filter = RuntimeLivenessFilter()

        _ = filter.recordProbe(responds: false)
        let answered = filter.recordProbe(responds: true)
        let afterRecovery = filter.recordProbe(responds: false)

        #expect(!answered)
        #expect(!afterRecovery)
        #expect(filter.consecutiveFailures == 1)
    }

    @Test("silence keeps reporting once it has been declared")
    func staysOfflineWhileQuiet() {
        var filter = RuntimeLivenessFilter()

        _ = filter.recordProbe(responds: false)
        let second = filter.recordProbe(responds: false)
        let third = filter.recordProbe(responds: false)

        #expect(second)
        #expect(third)
        #expect(filter.consecutiveFailures == 3)
    }

    @Test("a tolerance of one keeps the old single-probe behaviour")
    func toleranceOfOneDeclaresImmediately() {
        var filter = RuntimeLivenessFilter(tolerance: 1)

        let declared = filter.recordProbe(responds: false)

        #expect(declared)
    }

    /// A zero or negative tolerance would declare the runtime offline on a probe that answered.
    @Test("a tolerance below one is clamped rather than honoured")
    func toleranceIsClampedToOne() {
        var filter = RuntimeLivenessFilter(tolerance: 0)

        let answered = filter.recordProbe(responds: true)
        let declared = filter.recordProbe(responds: false)

        #expect(filter.tolerance == 1)
        #expect(!answered)
        #expect(declared)
    }

    @Test("a reset forgives silence the filter never saw answered")
    func resetClearsAccumulatedSilence() {
        var filter = RuntimeLivenessFilter()

        _ = filter.recordProbe(responds: false)
        _ = filter.recordProbe(responds: false)
        filter.reset()

        #expect(filter.consecutiveFailures == 0)
        let declaredOnFirstFailure = filter.recordProbe(responds: false)
        #expect(!declaredOnFirstFailure)
    }
}

/// The filter only helps if every healthy verdict clears it. Most of them never probe: adopting a
/// socket, a successful refresh and the wait after a start all publish health directly.
@Suite("A healthy verdict clears accumulated silence")
@MainActor
struct RuntimeLivenessWiringTests {
    @Test("the silence a stopped runtime accumulated does not outlive its restart")
    func healthyStateResetsTheFilter() {
        let model = RuntimeViewModel(socketPath: "/dev/null", startsRuntime: false)
        // What the monitor records while the runtime is down: the probes keep failing and nothing
        // takes the offline branch, because the state is already offline.
        _ = model.livenessFilter.recordProbe(responds: false)
        _ = model.livenessFilter.recordProbe(responds: false)
        #expect(model.livenessFilter.consecutiveFailures == 2)

        // The restart publishes health without ever probing.
        model.applyState(socketResponds: true)

        #expect(model.livenessFilter.consecutiveFailures == 0)
        // The point of the reset: the next dropped connection is a first failure again, so it
        // cannot clear the inventory on its own.
        let declaredOnFirstFailure = model.livenessFilter.recordProbe(responds: false)
        #expect(!declaredOnFirstFailure)
    }
}
