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
}

struct RuntimeStartupPlannerTests {
    @Test
    func adoptsRunningBridge() {
        #expect(
            RuntimeStartupPlanner.decide(socketFileExists: true, bridgeResponds: true)
                == .bridgeAlreadyRunning
        )
    }

    @Test
    func clearsStaleSocketBeforeStarting() {
        #expect(
            RuntimeStartupPlanner.decide(socketFileExists: true, bridgeResponds: false)
                == .removeStaleSocket
        )
    }

    @Test
    func startsBridgeOnCleanHost() {
        #expect(
            RuntimeStartupPlanner.decide(socketFileExists: false, bridgeResponds: false)
                == .startBridge
        )
    }
}
