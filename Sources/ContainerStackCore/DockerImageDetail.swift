import Foundation

/// Architecture and OS live on image inspect, not on `GET /images/json`.
public struct DockerImageDetail: Equatable, Sendable {
    public let architecture: String?
    public let operatingSystem: String?

    public init(architecture: String?, operatingSystem: String?) {
        self.architecture = architecture
        self.operatingSystem = operatingSystem
    }
}

private struct ImageDetailPayload: Decodable {
    let architecture: String?
    let os: String?

    enum CodingKeys: String, CodingKey {
        case architecture = "Architecture"
        case os = "Os"
    }
}

extension DockerAPIClient {
    /// Resolves **by repository tag**, not by id: socktainer answers 404 for
    /// `/images/{id}/json` while `/images/{repo:tag}/json` returns 200, so an untagged image
    /// has no platform to report.
    public func inspectImage(reference: String) async throws -> DockerImageDetail {
        let response = try await request(path: "/images/\(Self.pathEncoded(reference))/json")
        let payload = try await decode(ImageDetailPayload.self, response: response)
        return DockerImageDetail(
            architecture: payload.architecture,
            operatingSystem: payload.os
        )
    }
}
