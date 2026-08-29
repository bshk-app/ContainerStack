import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@Suite("Runtime staleness messages")
@MainActor
struct RuntimeStalenessMessageTests {
    private let shipped = RuntimeHelperIdentity(bundleVersion: "1.0", digest: "aaaa111122223333")
    private let older = RuntimeHelperIdentity(bundleVersion: "0.9", digest: "bbbb444455556666")

    @Test("A successful stale bridge restart replaces the progress message")
    func successfulRestartReportsCompletion() async {
        let model = makeModel()
        model.applyState(socketResponds: true)

        await model.adoptBridgeIfStale(
            recorded: older,
            current: shipped,
            restart: { true },
            recordIdentity: {}
        )

        #expect(model.serviceMessage == "Runtime restarted on the current build.")
    }

    @Test("A restart that did not run neither claims success nor records the shipped bridge")
    func skippedRestartDoesNotClaimSuccess() async {
        let model = makeModel()
        model.applyState(socketResponds: true)
        var recordedIdentity = false

        await model.adoptBridgeIfStale(
            recorded: older,
            current: shipped,
            restart: { false },
            recordIdentity: { recordedIdentity = true }
        )

        #expect(model.serviceMessage == nil)
        #expect(recordedIdentity == false)
    }

    /// A restart stops only the bridge this build ships. When someone else's
    /// socktainer keeps the socket, the restart "succeeds" and nothing has
    /// changed - recording the shipped identity there would mark the mismatch
    /// resolved forever, which is how a wedged foreign bridge survived every
    /// later launch.
    @Test("A foreign bridge still holding the socket is named, not recorded as ours")
    func foreignBridgeIsNotRecorded() async {
        let model = makeModel()
        model.applyState(socketResponds: true)
        var recordedIdentity = false

        await model.adoptBridgeIfStale(
            recorded: older,
            current: shipped,
            restart: { true },
            recordIdentity: { recordedIdentity = true },
            servesOurBridge: { false }
        )

        #expect(recordedIdentity == false)
        #expect(model.serviceMessage?.contains("Another Docker bridge holds") == true)
    }

    /// The reported scenario, and the one the staleness gate could never see: the
    /// build has not changed, so the recorded identity matches, and only asking
    /// who is serving reveals that it is not us.
    @Test("A foreign bridge on an unchanged build is still reported")
    func foreignBridgeOnCurrentBuildIsReported() async {
        let model = makeModel()
        model.applyState(socketResponds: true)
        var restarted = false
        var recordedIdentity = false

        await model.adoptBridgeIfStale(
            recorded: shipped,
            current: shipped,
            restart: {
                restarted = true
                return true
            },
            recordIdentity: { recordedIdentity = true },
            servesOurBridge: { false }
        )

        #expect(restarted == false)
        #expect(recordedIdentity == false)
        #expect(model.serviceMessage == model.foreignBridgeMessage)
    }

    @Test("A message produced while restarting is not erased")
    func concurrentServiceMessageSurvivesRestart() async {
        let model = makeModel()
        model.applyState(socketResponds: true)
        let registrationFailure = "LaunchAgent registration failed."

        await model.adoptBridgeIfStale(
            recorded: older,
            current: shipped,
            restart: {
                model.serviceMessage = registrationFailure
                return false
            },
            recordIdentity: {}
        )

        #expect(model.serviceMessage == registrationFailure)
    }

    @Test("An identity recording failure remains visible after restart")
    func identityFailureReplacesCompletion() async {
        let model = makeModel()
        model.applyState(socketResponds: true)
        let failure = "Runtime started, but its identity could not be recorded."

        await model.adoptBridgeIfStale(
            recorded: older,
            current: shipped,
            restart: { true },
            recordIdentity: { model.serviceMessage = failure }
        )

        #expect(model.serviceMessage == failure)
    }

    @Test("A confirmed restart records the bridge even when its follow-up refresh fails")
    func successfulRestartRecordsIdentityAfterRefreshFailure() async {
        let model = makeModel()
        model.applyState(socketResponds: true)
        var recordedIdentity = false

        await model.adoptBridgeIfStale(
            recorded: older,
            current: shipped,
            restart: {
                model.applyState(socketResponds: false)
                return true
            },
            recordIdentity: { recordedIdentity = true }
        )

        #expect(recordedIdentity)
        #expect(model.serviceMessage == "Runtime restarted on the current build.")
    }

    @Test("A cancelled caller records a confirmed restart without publishing completion")
    func cancellationAfterRestartDoesNotPublishCompletion() async {
        let model = makeModel()
        model.applyState(socketResponds: true)
        var recordedIdentity = false

        let adoption = Task { @MainActor in
            await model.adoptBridgeIfStale(
                recorded: older,
                current: shipped,
                restart: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                },
                recordIdentity: { recordedIdentity = true }
            )
        }
        await adoption.value

        #expect(recordedIdentity)
        #expect(model.serviceMessage == nil)
    }

    @Test("A completed identity check does not reload or rehash bridge identities")
    func repeatedCheckSkipsIdentityReads() async {
        let model = makeModel()
        model.hasCheckedBridgeIdentity = true
        var identityReads = 0

        await model.adoptBridgeIfStale(
            loadRecorded: {
                identityReads += 1
                return older
            },
            loadCurrent: {
                identityReads += 1
                return shipped
            },
            restart: { true },
            recordIdentity: {}
        )

        #expect(identityReads == 0)
    }

    @Test("Cancelling a socket wait stops before probing")
    func cancelledSocketWaitDoesNotSpin() async {
        var probes = 0
        let wait = Task { @MainActor in
            try await RuntimeViewModel.waitForRestartedSocket(
                attempts: 3,
                delay: .seconds(60),
                responds: {
                    probes += 1
                    return false
                }
            )
        }

        wait.cancel()

        var wasCancelled = false
        do {
            _ = try await wait.value
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            Issue.record("Unexpected socket wait error: \(error)")
        }

        #expect(wasCancelled)
        #expect(probes == 0)
    }

    @Test("A cancelled restart wait does not report a timeout")
    func cancelledRestartWaitDoesNotReportFailure() async {
        let model = makeModel()
        model.runtimeMessage = "Waiting for Docker socket…"

        let restarted = await model.completeRuntimeRestart(waitForSocket: {
            throw CancellationError()
        })

        #expect(restarted == false)
        #expect(model.runtimeFailure == nil)
        #expect(model.runtimeMessage == "Waiting for Docker socket…")
    }

    @Test("A cancelled refresh preserves the last observed runtime state")
    func cancelledRefreshDoesNotPublishFailure() async {
        let model = makeModel()
        model.applyState(socketResponds: true)

        await model.refresh(health: {
            throw CancellationError()
        })

        #expect(model.runtimeState.isHealthy)
        #expect(model.runtimeFailure == nil)
        #expect(model.errorMessage == nil)
        #expect(model.isLoading == false)
    }

    @Test("A failed automatic recovery clears stale inventory and leaves a state the user can act on")
    func failedAutomaticRecoveryClearsInventory() async throws {
        let model = makeModel()
        model.containers = try JSONDecoder().decode(
            [DockerContainerSummary].self,
            from: Data(#"[{"Id":"web","State":"running"}]"#.utf8)
        )
        // The recovery can fire while the runtime is still coming up, and `.starting` is exactly
        // the state that disables the manual restart — staying there is the stuck-on-Starting trap.
        model.isStarting = true

        await model.completeAutomaticRuntimeRecovery(restart: { false })

        #expect(model.containers.isEmpty)
        #expect(model.runtimeState != .starting)
        #expect(model.canRestartRuntime)
    }

    /// #39: the manual restart had no equivalent of the automatic path's cleanup, so a restart the
    /// user asked for could fail and leave the dead runtime's containers on screen indefinitely.
    @Test("A failed manual restart clears the dead runtime's inventory")
    func failedManualRestartClearsInventory() async throws {
        let model = makeModel()
        model.applyState(socketResponds: true)
        model.containers = try JSONDecoder().decode(
            [DockerContainerSummary].self,
            from: Data(#"[{"Id":"web","State":"running"}]"#.utf8)
        )

        let recovered = await model.completeRuntimeRestart(waitForSocket: { false })

        #expect(recovered == false)
        #expect(model.containers.isEmpty)
    }

    /// The poll cannot repair it afterwards: `failRuntime` already published the offline state, so
    /// the probe's `!responds, wasHealthy` clearing branch never fires on the next tick.
    @Test("Declaring the runtime failed drops the inventory it described")
    func failRuntimeClearsInventory() async throws {
        let model = makeModel()
        model.applyState(socketResponds: true)
        model.containers = try JSONDecoder().decode(
            [DockerContainerSummary].self,
            from: Data(#"[{"Id":"web","State":"running"}]"#.utf8)
        )

        model.failRuntime("Restart failed at Stopping Docker bridge…: boom")

        #expect(model.containers.isEmpty)
        #expect(model.runtimeFailure != nil)
    }

    /// #43: clearing is not durable on its own. A refresh suspended at its await when the runtime
    /// failed used to resume and write the dead runtime's rows back over the cleared state, and
    /// nothing cleaned up after — the model was offline by then, so the poll's clearing branch
    /// never fired again.
    @Test("A refresh in flight when the runtime failed does not write its rows back")
    func inFlightRefreshDoesNotResurrectInventory() async throws {
        let model = makeModel()
        model.applyState(socketResponds: true)
        model.containers = try JSONDecoder().decode(
            [DockerContainerSummary].self,
            from: Data(#"[{"Id":"web","State":"running"}]"#.utf8)
        )
        let healthy = RuntimeHealthSnapshot(
            pingOK: true,
            version: try JSONDecoder().decode(DockerVersion.self, from: Data("{}".utf8)),
            info: try JSONDecoder().decode(DockerInfo.self, from: Data("{}".utf8))
        )

        await model.refresh(health: {
            // The runtime dies while this call is in flight, which is the whole race.
            model.failRuntime("Runtime helper exited.")
            return healthy
        })

        #expect(model.containers.isEmpty)
        #expect(model.snapshot == nil)
        #expect(model.runtimeState.isHealthy == false)
    }

    /// The wiring, not the classifier: this hook was silently lost once when `toggle` was
    /// reconciled with `withContainer`, and nothing else holds it in place.
    @Test("A stop that loses the XPC connection asks the monitor to check the runtime")
    func stopConnectionLossRaisesRecoveryRequest() async throws {
        let model = makeModel()
        model.applyState(socketResponds: true)

        await model.withContainer(try Self.container(), action: "Stopping", recoversRuntime: true) {
            throw DockerAPIError.httpStatus(500, message: "XPC connection error: Connection invalid")
        }

        #expect(model.runtimeRecoveryRequested)
    }

    /// Everything that is not a stop keeps its own failure: widening the hook relabelled an
    /// ordinary start or remove error as a runtime fault and hid the real message.
    @Test("A non-stop failure reports itself and leaves the runtime alone")
    func nonStopFailureDoesNotRaiseRecoveryRequest() async throws {
        let model = makeModel()
        model.applyState(socketResponds: true)

        await model.withContainer(try Self.container(), action: "Removing") {
            throw DockerAPIError.httpStatus(500, message: "XPC connection error: Connection invalid")
        }

        #expect(!model.runtimeRecoveryRequested)
        #expect(model.containerMessage?.contains("Container action failed") == true)
    }

    private static func container() throws -> DockerContainerSummary {
        try JSONDecoder().decode(
            DockerContainerSummary.self,
            from: Data(#"{"Id":"web","Names":["/web"],"State":"running"}"#.utf8)
        )
    }

    @Test("A ready socket is not recovery success when health refresh fails")
    func failedPostRestartHealthDoesNotReportSuccess() async {
        let model = makeModel()

        let restarted = await model.completeRuntimeRestart(
            waitForSocket: { true },
            refreshHealth: { throw RecoveryError.failed }
        )

        #expect(!restarted)
        #expect(!model.runtimeState.isHealthy)
        #expect(model.runtimeFailure != nil)
    }

    private enum RecoveryError: Error {
        case failed
    }

    private func makeModel() -> RuntimeViewModel {
        RuntimeViewModel(
            socketPath: "/tmp/containerstack-staleness-\(UUID().uuidString).sock",
            startsRuntime: false
        )
    }
}
