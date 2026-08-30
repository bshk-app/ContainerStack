import Foundation
import Testing

@testable import ContainerStackCore

/// `ping` is what the monitor loop asks three times a second to decide whether the runtime is
/// alive, and the answer clears the inventory when it is no. It used to be the one read on that
/// path with no retry at all, while `health` retried the very same `/_ping`.
@Suite("What the liveness probe retries")
struct LivenessProbeRetryTests {
    @Test("a refused connection is asked again rather than reported as a dead runtime")
    func retriesARefusedConnection() async throws {
        let transport = FailingDockerTransport(error: .systemCallFailed(ECONNREFUSED), failures: 1)
        let client = DockerAPIClient(
            transport: transport,
            retryPolicy: DockerRetryPolicy(maxAttempts: 3, delay: .zero)
        )

        #expect(try await client.ping())
        #expect(await transport.attempts == 2)
    }

    @Test("a reset connection is asked again too")
    func retriesAResetConnection() async throws {
        let transport = FailingDockerTransport(error: .systemCallFailed(ECONNRESET), failures: 1)
        let client = DockerAPIClient(
            transport: transport,
            retryPolicy: DockerRetryPolicy(maxAttempts: 3, delay: .zero)
        )

        #expect(try await client.ping())
        #expect(await transport.attempts == 2)
    }

    /// The deliberate exception. A timeout has already spent its budget, so three of them would
    /// cost the poll fifteen seconds to learn what the first one said.
    @Test("a timeout is not retried, so one probe stays one deadline")
    func doesNotRetryATimeout() async {
        let transport = FailingDockerTransport(error: .timedOut, failures: .max)
        let client = DockerAPIClient(
            transport: transport,
            retryPolicy: DockerRetryPolicy(maxAttempts: 3, delay: .zero)
        )

        await #expect(throws: UnixSocketError.timedOut) {
            _ = try await client.ping()
        }
        #expect(await transport.attempts == 1)
    }

    /// The contrast that makes the line above a choice rather than an oversight: `health` runs on
    /// a user-initiated refresh, where waiting out a slow socket is worth more than answering fast.
    @Test("health still retries a timeout, because nothing is waiting on its tick")
    func healthRetriesATimeout() async {
        let transport = FailingDockerTransport(error: .timedOut, failures: .max)
        let client = DockerAPIClient(
            transport: transport,
            retryPolicy: DockerRetryPolicy(maxAttempts: 3, delay: .zero)
        )

        await #expect(throws: UnixSocketError.timedOut) {
            _ = try await client.health()
        }
        #expect(await transport.attempts == 3)
    }

    @Test("a probe that keeps being refused still reports the failure")
    func surfacesASustainedRefusal() async {
        let transport = FailingDockerTransport(error: .systemCallFailed(ECONNREFUSED), failures: .max)
        let client = DockerAPIClient(
            transport: transport,
            retryPolicy: DockerRetryPolicy(maxAttempts: 2, delay: .zero)
        )

        await #expect(throws: UnixSocketError.systemCallFailed(ECONNREFUSED)) {
            _ = try await client.ping()
        }
        #expect(await transport.attempts == 2)
    }
}

/// Fails the first `failures` sends with one socket error, then answers `OK`.
private actor FailingDockerTransport: DockerAPITransport {
    private let error: UnixSocketError
    private let failures: Int
    private(set) var attempts = 0

    init(error: UnixSocketError, failures: Int) {
        self.error = error
        self.failures = failures
    }

    func send(request: Data) throws -> Data {
        try send(request: request, timeout: .seconds(5))
    }

    func send(request _: Data, timeout _: Duration?) throws -> Data {
        attempts += 1
        if attempts <= failures {
            throw error
        }
        return httpResponse(status: 200, body: Data("OK".utf8))
    }
}
