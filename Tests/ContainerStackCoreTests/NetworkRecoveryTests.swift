import Foundation
import Testing

@testable import ContainerStackCore

/// A network can lose its host bridge while the containers on it keep running: the bridge dies with
/// the network's vmnet helper and nothing re-establishes it, so published ports go on accepting
/// connections that nothing answers (#1, #47). Measured by killing the helper — the container stayed
/// up, `connect()` succeeded, a request timed out — and by restarting that container, which brought
/// the helper, the bridge and forwarding back.
@Suite("Recovering an unroutable network")
struct NetworkRecoveryTests {

    /// What the banner says decides where a person looks. "Ports will not work" sends them to the
    /// runtime; the truth is that the connection is accepted and then hangs, which they will
    /// otherwise read as a bug in their own application.
    @Test("the degraded detail names the hang and the way out")
    func detailNamesTheSymptomAndTheFix() {
        let state = RuntimeState.degraded(networks: [
            UnroutableNetwork(networkName: "app_default", subnet: "192.168.254.0/24")
        ])
        let detail = state.detail ?? ""

        #expect(detail.contains("app_default (192.168.254.0/24)"))
        #expect(detail.contains("accept"))
        #expect(detail.contains("hang"))
        #expect(detail.contains("restart the runtime"))
    }

    /// Measured on a scratch runtime, four arms, each on its own throwaway daemon so one wedged
    /// network could not poison the next. The workload's PID 1 handles TERM — a plain `sh` loop is
    /// SIGKILLed on every stop and ends 137 whatever the network did, which is a harness reading
    /// itself rather than the product:
    ///
    ///     helper alive,  bridge-created   restart container   ok in 1s, address changed
    ///     helper killed, bridge-created   restart container   FAILED: 243s, container stopped
    ///     helper killed, CLI-created      restart container   ok, address changed
    ///     helper killed, bridge-created   restart runtime     ok in 17s, address kept
    ///
    /// `NetworkCreateRoute.createPinned` pins a subnet on every network this bridge creates, so the
    /// arm that fails is the only shape a user ever has. That is why the app no longer offers to
    /// restart containers as a repair, and why the banner names the runtime restart instead.
    @Test("the detail does not offer a repair that was measured not to work")
    func detailDoesNotPromiseTheContainerRestart() {
        let broken = UnroutableNetwork(networkName: "app_default", subnet: "192.168.254.0/24")
        let detail = RuntimeState.degraded(networks: [broken]).detail ?? ""

        #expect(detail.contains("restart the runtime"))
        #expect(detail.contains("will not fix it"))
    }
}

/// The remedy has to survive the case where nothing answers at all. The bridge bounds a wedged removal
/// and replies (measured live: 63s, with the sentence); the app says the same thing when even that
/// reply does not arrive, because on this one operation silence has a single meaning.
@Suite("A network removal that goes silent")
struct NetworkRemovalWedgedTests {
    @Test("the failure names the network and the one step that clears it")
    func namesTheRemedy() {
        let failure = NetworkRemovalWedged(network: "app_default")
        #expect(failure.description.contains("app_default"))
        #expect(failure.description.contains("stopped answering"))
        #expect(failure.description.contains("restart the runtime"))
    }

    @Test("it reads as itself through the paths the app reports with")
    func survivesInterpolation() {
        let failure = NetworkRemovalWedged(network: "app_default")
        // The resource banner is "Action failed: \(error)"; a bare struct would print its type name.
        #expect(String(describing: failure) == failure.description)
        #expect(failure.localizedDescription == failure.description)
    }
}
