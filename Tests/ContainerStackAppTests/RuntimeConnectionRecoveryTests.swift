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

    @Test
    func startingStateRestartsWhenAPIServerIsDown() {
        #expect(
            RuntimeConnectionRecovery.shouldAttemptRestart(
                apiserverRunning: false,
                isStarting: true,
                isRestarting: false,
                hasRuntimeFailure: false
            )
        )
    }

    @Test
    func runningAPIServerDoesNotRestart() {
        #expect(
            !RuntimeConnectionRecovery.shouldAttemptRestart(
                apiserverRunning: true,
                isStarting: false,
                isRestarting: false,
                hasRuntimeFailure: false
            )
        )
    }

    @Test
    func restartGuardsPreventDuplicateAttempts() {
        #expect(
            !RuntimeConnectionRecovery.shouldAttemptRestart(
                apiserverRunning: false,
                isStarting: false,
                isRestarting: true,
                hasRuntimeFailure: false
            )
        )
        #expect(
            !RuntimeConnectionRecovery.shouldAttemptRestart(
                apiserverRunning: false,
                isStarting: false,
                isRestarting: false,
                hasRuntimeFailure: true
            )
        )
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
