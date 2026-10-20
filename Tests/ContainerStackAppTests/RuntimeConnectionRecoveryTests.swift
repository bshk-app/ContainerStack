import ContainerStackCore
import Testing

@testable import ContainerStackApp

struct RuntimeConnectionRecoveryTests {
    @Test
    func stopTimeoutRequestsSystemStatusCheck() {
        #expect(RuntimeConnectionRecovery.isStopRecoveryError(UnixSocketError.timedOut))
        #expect(
            RuntimeConnectionRecovery.shouldCheckSystemStatus(
                after: nil,
                recoveryRequested: true
            )
        )
    }

    @Test
    func opaquePing500RequestsSystemStatusCheck() {
        let error = DockerAPIError.httpStatus(500, message: "Something went wrong.")

        #expect(
            RuntimeConnectionRecovery.shouldCheckSystemStatus(
                after: error,
                recoveryRequested: false
            )
        )
    }

    /// Whether something else runs, a Start included, is the lifecycle queue's to weigh (#102).
    @Test
    func absentAPIServerRestarts() {
        #expect(RuntimeConnectionRecovery.shouldAttemptRestart(apiserverRunning: false, hasRuntimeFailure: false))
    }

    @Test
    func runningAPIServerDoesNotRestart() {
        #expect(!RuntimeConnectionRecovery.shouldAttemptRestart(apiserverRunning: true, hasRuntimeFailure: false))
    }

    @Test
    func failedRuntimeIsNotRecoveredAutomatically() {
        #expect(!RuntimeConnectionRecovery.shouldAttemptRestart(apiserverRunning: false, hasRuntimeFailure: true))
    }

    @Test
    func transientPingTimeoutDoesNotCheckSystemStatus() {
        #expect(
            !RuntimeConnectionRecovery.shouldCheckSystemStatus(
                after: UnixSocketError.timedOut,
                recoveryRequested: false
            )
        )
    }

    @Test
    func deadXPCStopResponseRequestsRecovery() {
        let error = DockerAPIError.httpStatus(
            500,
            message: "failed to stop container: XPC connection error: Connection interrupted"
        )

        #expect(RuntimeConnectionRecovery.isStopRecoveryError(error))
    }

    @Test
    func preservesOrdinaryContainerFailures() {
        let error = DockerAPIError.httpStatus(500, message: "guest refused SIGTERM")

        #expect(!RuntimeConnectionRecovery.isStopRecoveryError(error))
    }
}
