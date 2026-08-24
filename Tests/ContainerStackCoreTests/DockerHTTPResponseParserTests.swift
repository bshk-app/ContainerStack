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

extension DockerHTTPResponseParserTests {
    /// A chunk-size line parses as hex up to `Int.max`, so `offset + size` can overflow.
    /// Swift traps on overflow, so before the guard this crashed the process instead of
    /// reporting a malformed body.
    @Test
    func oversizedChunkSizeThrowsInsteadOfTrapping() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\nabc\r\n0\r\n\r\n"
        #expect(throws: DockerHTTPParseError.invalidChunkedBody) {
            try DockerHTTPResponseParser.parse(Data(raw.utf8))
        }
    }

    /// `Int(_:radix:)` accepts a leading minus. A size of `-2` moves `chunkEnd`
    /// back onto the size line's CRLF, so the terminator checks pass and the
    /// subsequent `offset..<chunkEnd` constructs a reversed range that traps.
    @Test
    func negativeChunkSizeThrowsInsteadOfTrapping() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-2\r\nabc\r\n0\r\n\r\n"
        #expect(throws: DockerHTTPParseError.invalidChunkedBody) {
            try DockerHTTPResponseParser.parse(Data(raw.utf8))
        }
    }
}
