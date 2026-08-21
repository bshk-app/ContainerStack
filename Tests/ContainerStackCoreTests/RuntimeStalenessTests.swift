import Foundation
import Testing

@testable import ContainerStackCore

/// Replacing the app bundle leaves the LaunchAgent's old helper process running from the old
/// executable image, under the same path — so the app keeps talking to a bridge whose code it no
/// longer ships, and every check made against it is silently about the wrong build.
@Suite("RuntimeStaleness")
struct RuntimeStalenessTests {
    private static let shipped = RuntimeHelperIdentity(bundleVersion: "1.0", digest: "aaaa111122223333")
    private static let older = RuntimeHelperIdentity(bundleVersion: "0.9", digest: "bbbb444455556666")

    @Test("A serving helper from a different build must be restarted")
    func differentBuildIsStale() {
        #expect(RuntimeStaleness.needsRestart(isServing: true, recorded: Self.older, current: Self.shipped))
    }

    @Test("A downgrade counts, which a timestamp comparison would miss")
    func downgradeIsStale() {
        #expect(RuntimeStaleness.needsRestart(isServing: true, recorded: Self.shipped, current: Self.older))
    }

    @Test("The same build is left alone")
    func sameBuildIsFresh() {
        #expect(RuntimeStaleness.needsRestart(isServing: true, recorded: Self.shipped, current: Self.shipped) == false)
    }

    @Test("A rebuild at the same version is still a different helper")
    func sameVersionDifferentBinaryIsStale() {
        let rebuilt = RuntimeHelperIdentity(bundleVersion: "1.0", digest: "cccc777788889999")
        #expect(RuntimeStaleness.needsRestart(isServing: true, recorded: Self.shipped, current: rebuilt))
    }

    @Test("Nothing serving is not a staleness decision")
    func notServingIsNotStale() {
        #expect(RuntimeStaleness.needsRestart(isServing: false, recorded: Self.older, current: Self.shipped) == false)
    }

    @Test("A helper the app cannot account for is adopted by restarting it")
    func unknownRecordIsStale() {
        // What the first launch of a build containing this check sees: a helper already serving,
        // started by the previous build, with nothing recorded. Treating it as fresh would mean the
        // guard never applies on its own rollout.
        #expect(RuntimeStaleness.needsRestart(isServing: true, recorded: nil, current: Self.shipped))
    }

    @Test("A missing helper binary is an install problem, not a restart loop")
    func missingHelperIsNotStale() {
        #expect(RuntimeStaleness.needsRestart(isServing: true, recorded: Self.older, current: nil) == false)
        #expect(
            RuntimeHelperIdentity.read(
                helperURL: URL(fileURLWithPath: "/nonexistent/socktainer"),
                bundleVersion: "1.0"
            ) == nil
        )
    }

    @Test("The digest distinguishes two helper binaries and is stable for one")
    func digestReflectsContents() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cstack-staleness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appending(path: "a")
        let second = directory.appending(path: "b")
        try Data("bridge-build-one".utf8).write(to: first)
        try Data("bridge-build-two".utf8).write(to: second)

        let one = RuntimeHelperIdentity.read(helperURL: first, bundleVersion: "1.0")
        let again = RuntimeHelperIdentity.read(helperURL: first, bundleVersion: "1.0")
        let two = RuntimeHelperIdentity.read(helperURL: second, bundleVersion: "1.0")

        #expect(one == again)
        #expect(one != two)
        #expect(one?.digest.count == 16)
    }

    @Test("The recorded identity round-trips, and an absent record reads as unknown")
    func storeRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cstack-staleness-\(UUID().uuidString)/runtime-helper.json")
        let store = RuntimeHelperIdentityStore(url: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(store.load() == nil)
        try store.save(Self.shipped)
        #expect(store.load() == Self.shipped)
    }
}
