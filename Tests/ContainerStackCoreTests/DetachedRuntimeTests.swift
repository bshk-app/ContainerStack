import Foundation
import Testing

@testable import ContainerStackCore

/// A runtime whose app root has been deleted keeps answering: `_ping` returns 200 and
/// `container system status` still reports `status running` next to the path that is gone. Every check
/// the app had was therefore satisfied while nothing it stored could be found. Measured twice on a
/// disposable runtime, `scripts/verify-stage0-remedies.sh erased-root`.
@Suite("A runtime storing into a directory that is gone")
struct DetachedRuntimeTests {
    private let status = """
        FIELD              VALUE
        status             running
        appRoot            /tmp/scratch-runtime.EsqerE/root/
        installRoot        /usr/local/
        apiserver.version  container-apiserver version 1.2.2
        """

    @Test("the root survives having spaces in it")
    func parsesARootWithSpaces() {
        // `Library/Application Support` is the default. Splitting the row on whitespace truncates it
        // at the space, which is how a restore once pointed a runtime at `Library/Application`.
        let spaced = """
            status             running
            appRoot            /Users/a/Library/Application Support/com.apple.container/
            """
        #expect(RuntimeStatusParser.appRoot(spaced) == "/Users/a/Library/Application Support/com.apple.container")
    }

    @Test("the trailing slash the CLI prints does not become part of the path")
    func dropsTheTrailingSlash() {
        #expect(RuntimeStatusParser.appRoot(status) == "/tmp/scratch-runtime.EsqerE/root")
    }

    @Test("a row that merely starts with the field name is not the field")
    func doesNotMatchALongerFieldName() {
        #expect(RuntimeStatusParser.appRoot("appRootUsage       17") == nil)
        #expect(RuntimeStatusParser.appRoot("installRoot        /usr/local/") == nil)
    }

    @Test("a reported root that is gone is named; one that exists is not")
    func recognisesTheMissingRoot() {
        let missing = RuntimeStatusParser.missingAppRoot(status, exists: { _ in false })
        #expect(missing == "/tmp/scratch-runtime.EsqerE/root")
        #expect(RuntimeStatusParser.missingAppRoot(status, exists: { _ in true }) == nil)
    }

    @Test("a runtime that is not running is not diagnosed as detached")
    func staysQuietWhenTheRuntimeIsDown() {
        // Nothing is stored anywhere while the apiserver is down, and "storage is missing" would
        // send a person after the wrong thing.
        let stopped = "apiserver is not running\nappRoot            /tmp/gone"
        #expect(RuntimeStatusParser.missingAppRoot(stopped, exists: { _ in false }) == nil)
    }

    @Test("the state is reached even though the socket answers")
    func resolvesAheadOfHealthy() {
        let state = RuntimeState.resolve(
            socketResponds: true,
            helperRunning: true,
            isStarting: false,
            failure: nil,
            missingAppRoot: "/tmp/gone/root"
        )
        #expect(state == .detached(appRoot: "/tmp/gone/root"))
        #expect(state != .running, "a responding socket is not enough to call this healthy")
    }

    /// The state the app's full refresh actually meets: `health()` fails — measured, `/info` answers
    /// "Failed to generate system information" — while `_ping` still succeeds. Resolving this as
    /// offline says "Docker socket is not responding", which is untrue and points nowhere.
    @Test("it is reached on the path where the API call failed, not only where the ping succeeded")
    func resolvesWhenHealthFailed() {
        let state = RuntimeState.resolve(
            socketResponds: false,
            helperRunning: true,
            isStarting: false,
            failure: "Failed to generate system information",
            missingAppRoot: "/tmp/gone/root"
        )
        #expect(state == .detached(appRoot: "/tmp/gone/root"))
    }

    @Test("a stopped runtime is still offline, not detached")
    func stoppedRuntimeStaysOffline() {
        // The parser only reports a missing root for a runtime that says it is running, so nil arrives
        // here and this stays the honest answer.
        let state = RuntimeState.resolve(
            socketResponds: false,
            helperRunning: false,
            isStarting: false,
            failure: nil,
            missingAppRoot: nil
        )
        #expect(state == .offline(RuntimeState.genericFailure))
    }

    @Test("it outranks the route check, which cannot explain as much")
    func outranksUnroutableNetworks() {
        let state = RuntimeState.resolve(
            socketResponds: true,
            helperRunning: true,
            isStarting: false,
            failure: nil,
            unroutableNetworks: [UnroutableNetwork(networkName: "app_default", subnet: "192.168.254.0/24")],
            missingAppRoot: "/tmp/gone/root"
        )
        #expect(state == .detached(appRoot: "/tmp/gone/root"))
    }

    @Test("the detail names the directory and the one step that recovers it")
    func detailCarriesTheRemedy() {
        let detail = RuntimeState.detached(appRoot: "/tmp/gone/root").detail ?? ""
        #expect(detail.contains("/tmp/gone/root"))
        #expect(detail.contains("no longer exists"))
        // The measured remedy is the restart the app already performs: a bare `container system start`
        // came back on the default root both times. Nothing here asks anyone about launchd.
        #expect(detail.contains("Restart the runtime"))
        #expect(!detail.lowercased().contains("launchctl"))
        #expect(!detail.lowercased().contains("bootout"))
    }

    @Test("it is offered the restart, and it is not called ready")
    func presentsAsRecoverable() {
        let state = RuntimeState.detached(appRoot: "/tmp/gone/root")
        #expect(state.isDegraded, "the restart is gated on this")
        #expect(state.isHealthy, "the Docker API does answer, so container actions stay usable")
        #expect(state.title != RuntimeState.running.title)
    }
}
