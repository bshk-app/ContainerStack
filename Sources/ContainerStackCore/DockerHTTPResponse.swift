import Foundation

public struct DockerHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public enum DockerHTTPParseError: Error, Equatable, Sendable {
    case missingHeaderTerminator
    case invalidHeaderEncoding
    case invalidStatusLine
    case invalidStatusCode
    case invalidHeader
    case invalidChunkedBody
}

public enum DockerHTTPResponseParser {
    public static func parse(_ data: Data) throws -> DockerHTTPResponse {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let separator = data.range(of: delimiter) else {
            throw DockerHTTPParseError.missingHeaderTerminator
        }

        let headerData = data[..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw DockerHTTPParseError.invalidHeaderEncoding
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw DockerHTTPParseError.invalidStatusLine
        }

        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2 else {
            throw DockerHTTPParseError.invalidStatusLine
        }
        guard let statusCode = Int(statusParts[1]) else {
            throw DockerHTTPParseError.invalidStatusCode
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw DockerHTTPParseError.invalidHeader
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw DockerHTTPParseError.invalidHeader
            }
            headers[name] = value
        }
        let rawBody = Data(data[separator.upperBound...])
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunkedBody(rawBody)
        } else {
            body = rawBody
        }

        return DockerHTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: body
        )
    }
    private static func decodeChunkedBody(_ data: Data) throws -> Data {
        var offset = 0
        var decoded = Data()

        while true {
            var lineEnd: Int?
            if data.count >= 2, offset <= data.count - 2 {
                for index in offset...(data.count - 2) where data[index] == 13 && data[index + 1] == 10 {
                    lineEnd = index
                    break
                }
            }
            guard let lineEnd else {
                throw DockerHTTPParseError.invalidChunkedBody
            }

            let sizeData = data[offset..<lineEnd]
            guard let sizeLine = String(data: sizeData, encoding: .ascii) else {
                throw DockerHTTPParseError.invalidChunkedBody
            }
            guard let sizeToken = sizeLine.split(
                separator: ";",
                maxSplits: 1,
                omittingEmptySubsequences: true
            ).first,
            let size = Int(sizeToken, radix: 16)
            else {
                throw DockerHTTPParseError.invalidChunkedBody
            }
            offset = lineEnd + 2

            if size == 0 {
                return decoded
            }

            let chunkEnd = offset + size
            guard chunkEnd + 2 <= data.count,
                  data[chunkEnd] == 13,
                  data[chunkEnd + 1] == 10
            else {
                throw DockerHTTPParseError.invalidChunkedBody
            }
            decoded.append(data[offset..<chunkEnd])
            offset = chunkEnd + 2
        }
    }
}
