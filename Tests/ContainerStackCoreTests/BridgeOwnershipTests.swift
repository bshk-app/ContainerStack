import Testing

@testable import ContainerStackCore

@Suite("Who holds the Docker socket")
struct BridgeOwnershipTests {
    /// Real `lsof -Fpcn -- <socket>` output: one field per line, type-prefixed.
    private let lsof = """
        p55650
        csocktainer
        f14
        n/Users/akira/.socktainer/container.sock
        """

    @Test("the holder is read from the pid field, not the command or name")
    func readsHolderPID() {
        #expect(BridgeOwnership.holder(lsofOutput: lsof) == 55650)
    }

    @Test("an unheld socket has no holder")
    func noHolderWhenNothingListens() {
        #expect(BridgeOwnership.holder(lsofOutput: "") == nil)
    }

    @Test("the holder is ours only when it is one of our processes")
    func comparesHolderAgainstOurProcesses() {
        #expect(BridgeOwnership.isOurs(holder: 55650, ourPIDs: [55650]) == true)
        #expect(BridgeOwnership.isOurs(holder: 55650, ourPIDs: [42, 4242]) == false)
    }

    /// The case process-existence alone gets wrong: our bridge is running, but on
    /// another socket, while something else serves this one.
    @Test("our bridge running elsewhere does not make a foreign holder ours")
    func ourProcessOnAnotherSocketIsNotOwnership() {
        #expect(BridgeOwnership.isOurs(holder: 999, ourPIDs: [55650]) == false)
    }

    @Test("nobody holding it is not ownership either")
    func absentHolderIsNotOurs() {
        #expect(BridgeOwnership.isOurs(holder: nil, ourPIDs: [55650]) == false)
    }
}
