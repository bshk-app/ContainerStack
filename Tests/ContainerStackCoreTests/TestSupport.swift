import Foundation

@testable import ContainerStackCore

actor StubDockerTransport: DockerAPITransport {
    private var responses: [Data]
    private(set) var paths: [String] = []
    private(set) var requests: [String] = []
    private(set) var timeouts: [Duration?] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func send(request: Data) throws -> Data {
        try send(request: request, timeout: .seconds(5))
    }

    func send(request: Data, timeout: Duration?) throws -> Data {
        let requestText = String(decoding: request, as: UTF8.self)
        requests.append(requestText)
        paths.append(String(requestText.split(separator: " ")[1]))
        timeouts.append(timeout)
        return responses.removeFirst()
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
