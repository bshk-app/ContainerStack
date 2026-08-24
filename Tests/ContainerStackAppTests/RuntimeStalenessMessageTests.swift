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

    private func makeModel() -> RuntimeViewModel {
        RuntimeViewModel(
            socketPath: "/tmp/containerstack-staleness-\(UUID().uuidString).sock",
            startsRuntime: false
        )
    }
}
