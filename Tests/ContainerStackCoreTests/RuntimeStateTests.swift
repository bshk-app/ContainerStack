import Foundation
import Testing

@testable import ContainerStackCore

struct RuntimeStateTests {
    @Test
    func healthySocketWinsOverExitedHelper() {
        let state = RuntimeState.resolve(
            socketResponds: true,
            helperRunning: false,
            isStarting: false,
            failure: "Runtime helper exited."
        )

        #expect(state == .running)
        #expect(state.isHealthy)
        #expect(state.title == "Runtime ready")
    }

    @Test
    func reportsDegradedWhenNetworksInUseAreUnroutable() {
        let state = RuntimeState.resolve(
            socketResponds: true,
            helperRunning: true,
            isStarting: false,
            failure: nil,
            unroutableNetworks: [UnroutableNetwork(networkName: "default", subnet: "192.168.64.0/24")]
        )

        #expect(
            state
                == .degraded(networks: [
                    UnroutableNetwork(networkName: "default", subnet: "192.168.64.0/24")
                ]))
        #expect(state.isHealthy, "the Docker API still works, so container actions stay enabled")
        #expect(state.isDegraded)
        #expect(state.title == "Runtime degraded")
    }

    @Test
    func degradedDetailNamesTheAffectedNetworkAndSubnet() {
        let state = RuntimeState.resolve(
            socketResponds: true,
            helperRunning: true,
            isStarting: false,
            failure: nil,
            unroutableNetworks: [
                UnroutableNetwork(networkName: "demo_default", subnet: "192.168.253.0/24")
            ]
        )

        // Two corrections live in this string. The ports do not stop working: they accept and then
        // hang, which reads as a hung application. And the repair is the runtime restart, not the
        // container restart offered for a while on the strength of one measurement — four arms on a
        // scratch runtime showed the container restart failing on every network this bridge creates.
        #expect(
            state.detail == "No route to demo_default (192.168.253.0/24). "
                + "Published ports still accept connections and then hang; "
                + "restarting the containers will not fix it — restart the runtime.")
    }

    @Test
    func plainRunningStateIsNotDegraded() {
        let state = RuntimeState.resolve(
            socketResponds: true,
            helperRunning: true,
            isStarting: false,
            failure: nil
        )

        #expect(state == .running)
        #expect(state.isDegraded == false)
    }

    @Test
    func reportsStartingWhileHelperBoots() {
        let state = RuntimeState.resolve(
            socketResponds: false,
            helperRunning: true,
            isStarting: true,
            failure: nil
        )

        #expect(state == .starting)
        #expect(state.isHealthy == false)
    }

    @Test
    func reportsFailureReasonWhenSocketIsDown() {
        let state = RuntimeState.resolve(
            socketResponds: false,
            helperRunning: false,
            isStarting: false,
            failure: "Runtime helper exited."
        )

        #expect(state == .offline("Runtime helper exited."))
        #expect(state.detail == "Runtime helper exited.")
    }

    /// #44: the socket-wait loop only exits while the helper is still running, so `helperRunning`
    /// is true at the moment it gives up. Reporting `.starting` then shows progress forever, and
    /// because `.starting` is what disables the manual restart, it offers no way out.
    @Test
    func anExplicitFailureOutranksStarting() {
        let state = RuntimeState.resolve(
            socketResponds: false,
            helperRunning: true,
            isStarting: true,
            failure: "Docker socket did not become ready within 60 seconds."
        )

        #expect(state == .offline("Docker socket did not become ready within 60 seconds."))
        #expect(state.isHealthy == false)
    }
    @Test
    func fallsBackToGenericOfflineReason() {
        let state = RuntimeState.resolve(
            socketResponds: false,
            helperRunning: false,
            isStarting: false,
            failure: nil
        )

        #expect(state == .offline("Docker socket is not responding."))
    }

    /// Reads work through a foreign bridge, so this stays "healthy" like the other
    /// answering-but-wrong states - and degraded, so the banner keeps saying it
    /// for as long as it is true.
    @Test
    func reportsAForeignBridgeWhileTheSocketAnswers() {
        let state = RuntimeState.resolve(
            socketResponds: true,
            helperRunning: true,
            isStarting: false,
            failure: nil,
            foreignBridge: ForeignBridge(socketPath: "/Users/someone/.socktainer/container.sock")
        )

        #expect(state == .foreignBridge(ForeignBridge(socketPath: "/Users/someone/.socktainer/container.sock")))
        #expect(state.isHealthy)
        #expect(state.isDegraded)
        #expect(state.detail?.contains("can hang") == true)
    }

    /// A foreign bridge outranks missing storage: it makes every mutation hang, and
    /// the app-root probe describes the local runtime rather than who serves this
    /// socket, so leading with storage would print the wrong remedy.
    @Test
    func aForeignBridgeOutranksMissingStorage() {
        let state = RuntimeState.resolve(
            socketResponds: true,
            helperRunning: true,
            isStarting: false,
            failure: nil,
            missingAppRoot: "/tmp/gone",
            foreignBridge: ForeignBridge(socketPath: "/tmp/socket")
        )

        #expect(state == .foreignBridge(ForeignBridge(socketPath: "/tmp/socket")))
        #expect(state.allowsMutations == false)
    }

    /// F-014: a sibling is named by the copy it came from, and the remedy is the restart that
    /// now replaces it.
    @Test
    func aSiblingNamesItsCopyAndTheRestart() {
        let state = RuntimeState.foreignBridge(
            ForeignBridge(
                socketPath: "/tmp/socket",
                pid: 63819,
                command: "/Applications/ContainerStack.app/Contents/Helpers/socktainer --socket /tmp/socket",
                siblingBundlePath: "/Applications/ContainerStack.app"
            ))

        #expect(state.title == "Another ContainerStack bridge is in use")
        #expect(state.detail?.contains("/Applications/ContainerStack.app (process 63819)") == true)
        #expect(state.detail?.contains("Restart the runtime") == true)
        #expect(state.allowsMutations == false)
    }

    /// NFR-004: someone else's bridge is named by its process, not only by the socket.
    @Test
    func aForeignHolderIsNamedByItsProcess() {
        let state = RuntimeState.foreignBridge(
            ForeignBridge(
                socketPath: "/tmp/socket",
                pid: 4242,
                command: "/opt/homebrew/bin/socktainer",
                siblingBundlePath: nil
            ))

        #expect(state.title == "Another Docker bridge is in use")
        #expect(state.detail?.contains("Process 4242 (/opt/homebrew/bin/socktainer) holds /tmp/socket") == true)
        #expect(state.detail?.hasSuffix("Stop process 4242, then start the runtime again.") == true)
    }

    @Test
    func aSilentSocketIsOfflineRatherThanForeign() {
        let state = RuntimeState.resolve(
            socketResponds: false,
            helperRunning: false,
            isStarting: false,
            failure: nil,
            foreignBridge: ForeignBridge(socketPath: "/tmp/socket")
        )

        #expect(state == .offline("Docker socket is not responding."))
    }
}

struct RuntimeStartupPlannerTests {
    @Test
    func adoptsOurOwnRunningBridge() {
        #expect(
            RuntimeStartupPlanner.decide(
                socketFileExists: true,
                bridgeResponds: true,
                bridgeIsOurs: true
            ) == .bridgeAlreadyRunning
        )
    }

    /// The reported failure: a socktainer from somewhere else answered every
    /// request while `start` never returned, and adopting it hid that entirely.
    @Test
    func refusesABridgeItDoesNotOwn() {
        #expect(
            RuntimeStartupPlanner.decide(
                socketFileExists: true,
                bridgeResponds: true,
                bridgeIsOurs: false
            ) == .foreignBridge
        )
    }

    @Test
    func clearsStaleSocketBeforeStarting() {
        #expect(
            RuntimeStartupPlanner.decide(
                socketFileExists: true,
                bridgeResponds: false,
                bridgeIsOurs: false
            ) == .removeStaleSocket
        )
    }

    @Test
    func startsBridgeOnCleanHost() {
        #expect(
            RuntimeStartupPlanner.decide(
                socketFileExists: false,
                bridgeResponds: false,
                bridgeIsOurs: false
            ) == .startBridge
        )
    }
}
