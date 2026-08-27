import Darwin
import Foundation
import Testing

@testable import ContainerStackCore

/// Starting, restarting or removing a container boots or tears down a virtual machine and can take
/// longer than a plain API request. Stop is different: Docker grants a short graceful period before
/// forcing termination, and the client must preserve that bound when Apple Container's XPC stop
/// call wedges.
@Suite("Lifecycle calls get a timeout that matches the runtime")
struct LifecycleTimeoutTests {

    @Test("lifecycle calls use operation-specific timeouts")
    func lifecycleCallsUseOperationTimeouts() async throws {
        let transport = TimeoutRecordingTransport()
        let client = DockerAPIClient(transport: transport)

        try await client.restartContainer(id: "web")
        try await client.startContainer(id: "web")
        try await client.stopContainer(id: "web")
        try await client.removeContainer(id: "web", force: true)

        #expect(
            await transport.timeouts == [
                DockerAPIClient.lifecycleRequestTimeout,
                DockerAPIClient.lifecycleRequestTimeout,
                DockerAPIClient.gracefulStopRequestTimeout,
                DockerAPIClient.lifecycleRequestTimeout,
            ])
    }

    @Test("a wedged graceful stop times out without issuing another request")
    func wedgedStopPropagatesTimeout() async {
        let transport = WedgedStopTransport()
        let client = DockerAPIClient(transport: transport)

        await #expect(throws: UnixSocketError.timedOut) {
            try await client.stopContainer(id: "web")
        }
        #expect(await transport.paths == ["/containers/web/stop?t=5"])
        #expect(await transport.timeouts == [.seconds(30)])
    }

    @Test("stopping an already-stopped container succeeds")
    func alreadyStoppedContainerSucceeds() async throws {
        let transport = AlreadyStoppedTransport()
        let client = DockerAPIClient(transport: transport)

        try await client.stopContainer(id: "web")

        #expect(await transport.paths == ["/containers/web/stop?t=5"])
    }

    @Test("a socket failure propagates without issuing another request")
    func nonTimeoutStopFailurePropagates() async {
        let transport = WedgedStopTransport(
            stopError: .systemCallFailed(ECONNRESET)
        )
        let client = DockerAPIClient(transport: transport)

        await #expect(throws: UnixSocketError.systemCallFailed(ECONNRESET)) {
            try await client.stopContainer(id: "web")
        }
        #expect(await transport.paths == ["/containers/web/stop?t=5"])
    }

    /// Removing a network tears down a vmnet helper, and when that helper is already dead the bridge
    /// bounds the removal at 60s so it can explain itself. On the 5s read default the socket gave up
    /// first and the explanation never arrived — the timeout here has to outlast that bound.
    @Test("removing a network outlasts the bridge's own bound on a wedged removal")
    func networkRemovalUsesTheLongTimeout() async throws {
        let transport = TimeoutRecordingTransport()
        let client = DockerAPIClient(transport: transport)

        try await client.removeNetwork(id: "app_default")

        let seen = await transport.timeouts
        #expect(seen == [DockerAPIClient.lifecycleRequestTimeout])
        #expect(seen.first != .seconds(5), "network removal is back on the plain-request default")
        let bridgeBound = Duration.seconds(60)
        let timeout = try #require(seen.first ?? nil)
        #expect(timeout > bridgeBound, "the client gives up before the bridge can answer")
    }

    /// The reads stay short: a listing that hangs should give up quickly, and nothing about it boots
    /// a machine.
    @Test("a plain read keeps the short default")
    func readsKeepTheShortTimeout() async throws {
        let transport = TimeoutRecordingTransport(body: "[]")
        let client = DockerAPIClient(transport: transport)

        _ = try await client.listContainers(all: true)

        let seen = await transport.timeouts
        #expect(seen.first == .seconds(5))
    }
}

private actor TimeoutRecordingTransport: DockerAPITransport {
    private(set) var timeouts: [Duration?] = []
    private let body: String

    init(body: String = "{}") {
        self.body = body
    }

    func send(request: Data) throws -> Data {
        try send(request: request, timeout: .seconds(5))
    }

    func send(request: Data, timeout: Duration?) throws -> Data {
        timeouts.append(timeout)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        return Data((head + body).utf8)
    }
}

private actor WedgedStopTransport: DockerAPITransport {
    private(set) var paths: [String] = []
    private(set) var timeouts: [Duration?] = []
    private let stopError: UnixSocketError

    init(stopError: UnixSocketError = .timedOut) {
        self.stopError = stopError
    }

    func send(request: Data) throws -> Data {
        try send(request: request, timeout: .seconds(5))
    }

    func send(request: Data, timeout: Duration?) throws -> Data {
        let requestText = String(decoding: request, as: UTF8.self)
        let path = String(requestText.split(separator: " ")[1])
        paths.append(path)
        timeouts.append(timeout)

        throw stopError
    }
}

private actor AlreadyStoppedTransport: DockerAPITransport {
    private(set) var paths: [String] = []

    func send(request: Data) throws -> Data {
        try send(request: request, timeout: .seconds(5))
    }

    func send(request: Data, timeout: Duration?) throws -> Data {
        let requestText = String(decoding: request, as: UTF8.self)
        paths.append(String(requestText.split(separator: " ")[1]))
        return httpResponse(status: 304, body: Data())
    }
}
