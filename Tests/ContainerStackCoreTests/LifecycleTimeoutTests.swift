import Foundation
import Testing

@testable import ContainerStackCore

/// Starting or restarting a container here boots a virtual machine: a restart measured 6.4s and 6.3s
/// against an idle runtime, and a stop waits out the container's grace period first. On the 5 second
/// default these calls report a failure while the operation is quietly succeeding — the person
/// retries, and the retry fights the first attempt. The recovery for an unroutable network restarts
/// several containers in a row, which is where a wrong answer per container adds up.
@Suite("Lifecycle calls get a timeout that matches the runtime")
struct LifecycleTimeoutTests {

    @Test("restart, start, stop and remove all wait longer than a plain request")
    func lifecycleCallsUseTheLongTimeout() async throws {
        let transport = TimeoutRecordingTransport()
        let client = DockerAPIClient(transport: transport)

        try await client.restartContainer(id: "web")
        try await client.startContainer(id: "web")
        try await client.stopContainer(id: "web")
        try await client.removeContainer(id: "web", force: true)

        let seen = await transport.timeouts
        #expect(seen.count == 4)
        for timeout in seen {
            #expect(timeout == DockerAPIClient.lifecycleRequestTimeout)
            #expect(timeout != .seconds(5), "a lifecycle call is on the plain-request default again")
        }
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
        #expect((seen.first ?? nil).map { $0 > bridgeBound } == true, "the client gives up before the bridge can answer")
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
