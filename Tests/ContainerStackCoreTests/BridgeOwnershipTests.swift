import Foundation
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

/// F-014: measured on 2026-10-03, the installed app's orphaned bridge held the socket for 25 days
/// and every other copy of ContainerStack could only call it foreign.
@Suite("Whose bridge holds the socket")
struct BridgeClassificationTests {
    private let socket = "/Users/me/.containerstack/docker.sock"
    private let ours = "/Users/me/dev/build/ContainerStack.app/Contents/Helpers/socktainer"
    private let installed = "/Applications/ContainerStack.app"
    private let spaced = "/Users/me/My Apps/ContainerStack.app"

    /// Never the disk: `/Applications/ContainerStack.app` exists on a developer's machine.
    private func identifiers(_ bundles: [String: String]) -> (String) -> String? {
        { bundles[$0] }
    }

    private func bridge(_ bundle: String) -> String {
        "\(bundle)/Contents/Helpers/socktainer --no-check-compatibility --no-docker-context --socket \(socket)"
    }

    private func classify(
        holder: pid_t?,
        listing: String,
        bundles: [String: String] = [:]
    ) -> ForeignBridge? {
        BridgeOwnership.foreignBridge(
            socketPath: socket,
            holder: holder,
            ourBridgePath: ours,
            listing: listing,
            bundleIdentifier: identifiers(bundles)
        )
    }

    @Test("this build's own bridge is not foreign")
    func ourBridgeIsNotForeign() {
        #expect(classify(holder: 101, listing: "  101 \(ours) --socket \(socket)") == nil)
    }

    @Test("another ContainerStack copy's bridge is a sibling, named by bundle and pid")
    func anotherCopysBridgeIsASibling() {
        let found = classify(
            holder: 63819,
            listing: "    1 /sbin/launchd\n63819 \(bridge(installed))",
            bundles: [installed: BridgeOwnership.containerStackBundleIdentifier]
        )
        #expect(
            found
                == ForeignBridge(
                    socketPath: socket,
                    pid: 63819,
                    command: bridge(installed),
                    siblingBundlePath: installed
                ))
    }

    @Test("a bundle path with a space still resolves to its bundle")
    func aSpacedBundlePathResolves() {
        let found = classify(
            holder: 5,
            listing: "5 \(bridge(spaced))",
            bundles: [spaced: BridgeOwnership.containerStackBundleIdentifier]
        )
        #expect(found?.siblingBundlePath == spaced)
    }

    @Test("a bundle with another identifier is foreign")
    func anotherIdentifierIsForeign() {
        let found = classify(
            holder: 63819,
            listing: "63819 \(bridge(installed))",
            bundles: [installed: "com.example.other"]
        )
        #expect(found?.pid == 63819)
        #expect(found?.siblingBundlePath == nil)
    }

    @Test("another helper in a ContainerStack bundle is not its bridge")
    func anotherHelperIsNotTheBridge() {
        let found = classify(
            holder: 63819,
            listing: "63819 \(installed)/Contents/Helpers/socktainer-debug --socket \(socket)",
            bundles: [installed: BridgeOwnership.containerStackBundleIdentifier]
        )
        #expect(found?.pid == 63819)
        #expect(found?.siblingBundlePath == nil)
    }

    @Test("a bridge started with no arguments still resolves to its bundle")
    func aBareBridgeResolves() {
        let found = classify(
            holder: 63819,
            listing: "63819 \(installed)/Contents/Helpers/socktainer",
            bundles: [installed: BridgeOwnership.containerStackBundleIdentifier]
        )
        #expect(found?.siblingBundlePath == installed)
    }

    @Test("a socktainer outside any bundle is foreign")
    func anUnbundledSocktainerIsForeign() {
        let command = "/opt/homebrew/bin/socktainer --socket \(socket)"
        let found = classify(holder: 4242, listing: "4242 \(command)")
        #expect(found == ForeignBridge(socketPath: socket, pid: 4242, command: command, siblingBundlePath: nil))
    }

    @Test("a holder lsof could not name is foreign, with nothing to name")
    func anUnnamedHolderIsForeign() {
        #expect(classify(holder: nil, listing: "101 \(ours)") == ForeignBridge(socketPath: socket))
    }

    @Test("a holder the process table no longer lists is foreign, with no command")
    func anUnlistedHolderIsForeign() {
        let found = classify(holder: 77, listing: "101 \(ours)")
        #expect(found == ForeignBridge(socketPath: socket, pid: 77, command: "", siblingBundlePath: nil))
    }
}

/// F-014: the restart's bridge stop reaches a sibling, and never anyone else's process.
@Suite("What the restart's bridge stop signals")
struct BridgeStopTests {
    private let ours = "/Users/me/dev/build/ContainerStack.app/Contents/Helpers/socktainer"
    private let installed = "/Applications/ContainerStack.app"

    private func pidsToStop(holder: pid_t, listing: String) -> [pid_t] {
        BridgeOwnership.pidsToStop(
            bridgePath: ours,
            lsofOutput: "p\(holder)\ncsocktainer\nn/x.sock",
            listing: listing,
            bundleIdentifier: { $0 == installed ? BridgeOwnership.containerStackBundleIdentifier : nil }
        )
    }

    @Test("this build's bridge and a sibling holder are both signalled")
    func ourBridgeAndASiblingAreSignalled() {
        let listing = """
              101 \(ours) --socket /elsewhere.sock
            63819 \(installed)/Contents/Helpers/socktainer --socket /x.sock
            """
        #expect(pidsToStop(holder: 63819, listing: listing) == [101, 63819])
    }

    @Test("a foreign holder is never signalled")
    func aForeignHolderIsLeftAlone() {
        let listing = """
             101 \(ours) --socket /elsewhere.sock
            4242 /opt/homebrew/bin/socktainer --socket /x.sock
            """
        #expect(pidsToStop(holder: 4242, listing: listing) == [101])
    }

    /// A wedged bridge whose socket file was replaced still lists under the path, ahead of
    /// the one that now serves it.
    @Test("a sibling listed after an older holder is still signalled")
    func everyListedHolderIsConsidered() {
        let listing = """
              101 \(ours) --socket /x.sock
            63819 \(installed)/Contents/Helpers/socktainer --socket /x.sock
            """
        let pids = BridgeOwnership.pidsToStop(
            bridgePath: ours,
            lsofOutput: "p101\ncsocktainer\nn/x.sock\np63819\ncsocktainer\nn/x.sock",
            listing: listing,
            bundleIdentifier: { $0 == installed ? BridgeOwnership.containerStackBundleIdentifier : nil }
        )
        #expect(pids == [101, 63819])
    }

    @Test("no socket to look at leaves only this build's bridge")
    func noSocketLeavesOnlyOurBridge() {
        let listing = """
              101 \(ours) --socket /x.sock
            63819 \(installed)/Contents/Helpers/socktainer --socket /x.sock
            """
        #expect(
            BridgeOwnership.pidsToStop(
                bridgePath: ours,
                lsofOutput: "",
                listing: listing,
                bundleIdentifier: { _ in BridgeOwnership.containerStackBundleIdentifier }
            ) == [101])
    }

    @Test("our own holder is signalled once")
    func ourHolderIsSignalledOnce() {
        #expect(pidsToStop(holder: 101, listing: "101 \(ours) --socket /x.sock") == [101])
    }
}
