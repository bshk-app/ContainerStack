import Foundation
import Testing

@testable import ContainerStackCore

actor StubDockerTransport: DockerAPITransport {
    struct Exhausted: Error {}

    private var results: [Result<Data, any Error>]
    private(set) var paths: [String] = []
    private(set) var requests: [String] = []
    private(set) var timeouts: [Duration?] = []

    init(results: [Result<Data, any Error>]) {
        self.results = results
    }

    init(responses: [Data]) {
        self.results = responses.map { .success($0) }
    }

    func send(request: Data) throws -> Data {
        try send(request: request, timeout: .seconds(5))
    }

    func send(request: Data, timeout: Duration?) throws -> Data {
        let requestText = String(decoding: request, as: UTF8.self)
        requests.append(requestText)
        paths.append(Self.path(ofRequestText: requestText))
        timeouts.append(timeout)
        guard !results.isEmpty else { throw Exhausted() }
        return try results.removeFirst().get()
    }

    // A request without a path token is recorded, not fatal: the exhaustion guard below
    // has to be the thing that reports an over-consumed queue, and `paths` has to keep
    // describing every attempt for the call-count assertions that read it.
    private static func path(ofRequestText requestText: String) -> String {
        let fields = requestText.split(separator: " ")
        guard fields.count > 1 else { return "<malformed>" }
        return String(fields[1])
    }
}

@Suite("A stub transport can model a failed Docker call")
struct StubDockerTransportTests {
    private let ping = Data("GET /_ping HTTP/1.1\r\n\r\n".utf8)

    @Test("a queued failure is thrown, not swallowed")
    func stubTransportThrowsTheQueuedError() async throws {
        let stub = StubDockerTransport(results: [.failure(UnixSocketError.timedOut)])
        await #expect(throws: UnixSocketError.timedOut) { try await stub.send(request: Data()) }
    }

    @Test("a request past the end of the queue throws instead of trapping")
    func stubTransportThrowsWhenExhausted() async throws {
        let stub = StubDockerTransport(results: [])
        await #expect(throws: StubDockerTransport.Exhausted.self) { try await stub.send(request: Data()) }
    }

    @Test("an unparseable request is still recorded as an attempt")
    func stubTransportRecordsAMalformedRequest() async throws {
        let stub = StubDockerTransport(results: [])
        await #expect(throws: StubDockerTransport.Exhausted.self) { try await stub.send(request: Data()) }
        #expect(await stub.paths == ["<malformed>"])
        #expect(await stub.requests == [""])
    }

    @Test("an exhausted call still reports which endpoint it tried")
    func stubTransportRecordsThePathOfAnExhaustedCall() async throws {
        let stub = StubDockerTransport(responses: [jsonResponse("[]")])
        _ = try await stub.send(request: ping)
        await #expect(throws: StubDockerTransport.Exhausted.self) { try await stub.send(request: ping) }
        #expect(await stub.paths == ["/_ping", "/_ping"])
    }

    @Test("the response-taking initialiser still answers in order")
    func stubTransportKeepsTheResponsesLabel() async throws {
        let stub = StubDockerTransport(responses: [jsonResponse("[]"), jsonResponse("{}")])
        #expect(try await stub.send(request: ping) == jsonResponse("[]"))
        #expect(try await stub.send(request: ping) == jsonResponse("{}"))
    }
}

func httpResponse(status: Int, body: Data) -> Data {
    Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
}

func chunkedHTTPResponse(body: Data) -> Data {
    let size = String(body.count, radix: 16)
    return Data(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n\(size)\r\n"
            .utf8
    ) + body + Data("\r\n0\r\n\r\n".utf8)
}

func jsonResponse(_ json: String, status: Int = 200) -> Data {
    httpResponse(status: status, body: Data(json.utf8))
}
