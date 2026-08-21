import Foundation
import Testing
@testable import ContainerStackCore

struct DockerHTTPResponseParserTests {
    @Test
    func parsesStatusHeadersAndBody() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nOK".utf8)

        let response = try DockerHTTPResponseParser.parse(raw)

        #expect(response.statusCode == 200)
        #expect(response.headers["content-type"] == "text/plain")
        #expect(response.body == Data("OK".utf8))
    }

    @Test
    func decodesChunkedResponseBody() throws {
        let rawText =
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                + "5\r\nHello\r\n"
                + "7\r\n world!\r\n"
                + "0\r\n\r\n"
        let raw = Data(rawText.utf8)

        let response = try DockerHTTPResponseParser.parse(raw)

        #expect(response.body == Data("Hello world!".utf8))
    }

    @Test
    func rejectsResponsesWithoutHeaderTerminator() {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 2".utf8)

        #expect(throws: DockerHTTPParseError.self) {
            try DockerHTTPResponseParser.parse(raw)
        }
    }
}
