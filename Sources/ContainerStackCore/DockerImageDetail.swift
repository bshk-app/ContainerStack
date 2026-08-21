import Foundation

/// Architecture and OS live on image inspect, not on `GET /images/json`.
public struct DockerImageDetail: Equatable, Sendable {
    public let architecture: String?
    public let operatingSystem: String?
    public let variant: String?

    public init(architecture: String?, operatingSystem: String?, variant: String?) {
        self.architecture = architecture
        self.operatingSystem = operatingSystem
        self.variant = variant
    }

    /// "linux/arm64 v8", or nil when the runtime reports nothing.
    public var platformText: String? {
        guard let operatingSystem, let architecture else { return nil }
        guard let variant, !variant.isEmpty else { return "\(operatingSystem)/\(architecture)" }
        return "\(operatingSystem)/\(architecture) \(variant)"
    }
}

private struct ImageDetailPayload: Decodable {
    let architecture: String?
    let os: String?
    let variant: String?

    enum CodingKeys: String, CodingKey {
        case architecture = "Architecture"
        case os = "Os"
        case variant = "Variant"
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
            operatingSystem: payload.os,
            variant: payload.variant
        )
    }
}
