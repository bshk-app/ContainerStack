import Testing

@testable import ContainerStackApp

/// The app-root probe spawns the `container` CLI and waits on an XPC round trip. It ran on every
/// 3s monitor tick — roughly 1200 spawns an hour — so the cadence below is what keeps the poll
/// cheap without giving up the check.
///
/// `shouldRun` is `mutating`, and `#expect` captures its expression in a closure, so every call
/// is made first and the returned value is what gets asserted.
@Suite("The process-spawning diagnostic runs on its own cadence")
struct DiagnosticCadenceTests {
    private let start = ContinuousClock.now

    @Test("the first ask always runs")
    func firstAskRuns() {
        var cadence = DiagnosticCadence(interval: .seconds(30))
        let first = cadence.shouldRun(now: start)

        #expect(first)
    }

    @Test("asks inside the interval are refused")
    func refusesInsideTheInterval() {
        var cadence = DiagnosticCadence(interval: .seconds(30))
        _ = cadence.shouldRun(now: start)

        // The 3s monitor ticks that fall strictly inside a 30s window: 3s through 27s. The
        // tenth tick lands exactly on 30s, where running again is correct.
        var granted = 0
        for tick in 1...9 where cadence.shouldRun(now: start + .seconds(3 * tick)) {
            granted += 1
        }
        let tenthTick = cadence.shouldRun(now: start + .seconds(30))

        #expect(granted == 0)
        #expect(tenthTick)
    }

    @Test("the next ask at or past the interval runs")
    func runsAgainAfterTheInterval() {
        var cadence = DiagnosticCadence(interval: .seconds(30))
        _ = cadence.shouldRun(now: start)
        let justBefore = cadence.shouldRun(now: start + .seconds(29))
        let atTheBoundary = cadence.shouldRun(now: start + .seconds(30))

        #expect(!justBefore)
        #expect(atTheBoundary)
    }

    /// The window restarts from the run, not from a fixed grid — otherwise a check that landed
    /// late would be followed immediately by another one.
    @Test("the interval is measured from the last run")
    func intervalIsMeasuredFromTheLastRun() {
        var cadence = DiagnosticCadence(interval: .seconds(30))
        _ = cadence.shouldRun(now: start)
        let late = cadence.shouldRun(now: start + .seconds(40))
        let tooSoonAfterLate = cadence.shouldRun(now: start + .seconds(50))
        let dueAgain = cadence.shouldRun(now: start + .seconds(70))

        #expect(late)
        #expect(!tooSoonAfterLate)
        #expect(dueAgain)
    }

    /// An explicit refresh probes unconditionally. Recording that run is what stops the very
    /// next poll tick from spawning the CLI again for an answer it was just handed.
    @Test("recording a run holds off the following ask")
    func recordingARunHoldsOffTheNextAsk() {
        var cadence = DiagnosticCadence(interval: .seconds(30))
        cadence.recordRun(now: start)
        let nextTick = cadence.shouldRun(now: start + .seconds(3))
        let afterInterval = cadence.shouldRun(now: start + .seconds(30))

        #expect(!nextTick)
        #expect(afterInterval)
    }
}
