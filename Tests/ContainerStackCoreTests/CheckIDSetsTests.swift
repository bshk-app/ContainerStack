import Testing

@testable import ContainerStackCore

@Suite("Neither caller's check set is 'all'")
struct CheckIDSetsTests {
    // Spelled out rather than derived: later tasks depend on the exact difference,
    // so a set built from `allCases` minus something would pin nothing.
    @Test("both sets are pinned literally, per F-002")
    func theTwoCheckSetsAreExactlyThese() {
        #expect(
            CheckID.cliSet == [.appRoot, .socket, .versions, .routes, .foreignBridge, .memoryCommitment]
        )
        #expect(
            CheckID.uiSet == [.appRoot, .socket, .versions, .routes, .foreignBridge, .dockerContext]
        )
    }

    // `memoryCommitment` costs one `inspectContainer` per running container, so the
    // UI omits it (NFR-001); `dockerContext` is the app's own staleness concern.
    @Test("the sets differ by exactly one check each, and share foreignBridge")
    func theTwoCheckSetsDifferOnlyWhereTheCostDoes() {
        #expect(CheckID.cliSet.subtracting(CheckID.uiSet) == [.memoryCommitment])
        #expect(CheckID.uiSet.subtracting(CheckID.cliSet) == [.dockerContext])
        #expect(CheckID.cliSet.contains(.foreignBridge))
        #expect(CheckID.uiSet.contains(.foreignBridge))
    }

    // Adding a `CheckID` case without placing it in a caller's set leaves a check
    // no surface ever runs; this is the one line that catches that.
    @Test("no check belongs to neither set")
    func everyCheckIDIsClaimedByAtLeastOneSet() {
        #expect(CheckID.cliSet.union(CheckID.uiSet) == Set(CheckID.allCases))
    }
}
