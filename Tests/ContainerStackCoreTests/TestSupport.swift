import Foundation
import Testing

@testable import ContainerStackCore

actor StubDockerTransport: DockerAPITransport {
    struct Exhausted: Error {}

    private var results: [Result<Data, any Error>]
    private let byPath: [String: Result<Data, any Error>]
    private(set) var paths: [String] = []
    private(set) var requests: [String] = []
    private(set) var timeouts: [Duration?] = []

    init(results: [Result<Data, any Error>]) {
        self.results = results
        self.byPath = [:]
    }

    init(responses: [Data]) {
        self.results = responses.map { .success($0) }
        self.byPath = [:]
    }

    // Keyed responses are never consumed: a path answers the same way however often it is called.
    init(byPath: [String: Result<Data, any Error>]) {
        self.results = []
        self.byPath = byPath
    }

    func send(request: Data) throws -> Data {
        try send(request: request, timeout: .seconds(5))
    }

    func send(request: Data, timeout: Duration?) throws -> Data {
        let requestText = String(decoding: request, as: UTF8.self)
        let path = Self.path(ofRequestText: requestText)
        requests.append(requestText)
        paths.append(path)
        timeouts.append(timeout)
        if !byPath.isEmpty {
            guard let keyed = byPath[path] else { throw Exhausted() }
            return try keyed.get()
        }
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

@Suite("A stub transport can answer by request path")
struct StubDockerTransportByPathTests {
    private let networks = Data("GET /networks HTTP/1.1\r\n\r\n".utf8)
    private let containers = Data("GET /containers/json?all=0 HTTP/1.1\r\n\r\n".utf8)

    @Test("a keyed response is chosen by path, not by call order")
    func keyedStubAnswersByPathNotByOrder() async throws {
        let stub = StubDockerTransport(byPath: [
            "/networks": .success(jsonResponse("[]")),
            "/containers/json?all=0": .success(jsonResponse("{}")),
        ])
        #expect(try await stub.send(request: containers) == jsonResponse("{}"))
        #expect(try await stub.send(request: networks) == jsonResponse("[]"))
        #expect(await stub.paths == ["/containers/json?all=0", "/networks"])
    }

    @Test("a keyed path answers every time it is called")
    func keyedStubRepeatsTheSameResponse() async throws {
        let stub = StubDockerTransport(byPath: ["/networks": .success(jsonResponse("[]"))])
        #expect(try await stub.send(request: networks) == jsonResponse("[]"))
        #expect(try await stub.send(request: networks) == jsonResponse("[]"))
    }

    @Test("an unkeyed path throws and is still recorded as an attempt")
    func keyedStubRecordsThePathItCouldNotAnswer() async throws {
        let stub = StubDockerTransport(byPath: ["/networks": .success(jsonResponse("[]"))])
        await #expect(throws: StubDockerTransport.Exhausted.self) {
            try await stub.send(request: containers)
        }
        #expect(await stub.paths == ["/containers/json?all=0"])
    }

    @Test("a keyed failure is thrown, not swallowed")
    func keyedStubThrowsTheKeyedError() async throws {
        let stub = StubDockerTransport(byPath: ["/networks": .failure(UnixSocketError.timedOut)])
        await #expect(throws: UnixSocketError.timedOut) { try await stub.send(request: networks) }
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
