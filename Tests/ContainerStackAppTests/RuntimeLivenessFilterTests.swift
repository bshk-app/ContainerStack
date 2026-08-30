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
}
