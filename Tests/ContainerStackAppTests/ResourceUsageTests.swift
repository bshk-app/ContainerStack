import XCTest

@testable import ContainerStackApp
@testable import ContainerStackCore

final class ResourceUsageTests: XCTestCase {
    func testImageMatchUsesRepoTag() {
        let image = DockerImageSummary(
            id: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            repositoryTags: ["nginx:latest"],
            size: 1,
            created: nil,
            architecture: "arm64",
            operatingSystem: "linux"
        )
        let hit = container(id: "1", name: "web", image: "nginx:latest", imageID: nil, networks: [])
        let miss = container(id: "2", name: "db", image: "postgres:16", imageID: nil, networks: [])
        let used = ResourceUsage.containers(usingImage: image, from: [hit, miss])
        XCTAssertEqual(used.map(\.name), ["web"])
    }

    func testImageMatchNormalizesAnUnprefixedFullDigest() {
        let digest = "1234567890ab" + String(repeating: "c", count: 52)
        let image = DockerImageSummary(
            id: "sha256:\(digest)",
            repositoryTags: nil,
            size: 1,
            created: nil,
            architecture: "arm64",
            operatingSystem: "linux"
        )
        let hit = container(id: "1", name: "web", image: "<none>:<none>", imageID: digest, networks: [])

        XCTAssertEqual(ResourceUsage.containers(usingImage: image, from: [hit]).map(\.name), ["web"])
    }

    func testImageIDWinsWhenAMutableTagNowNamesAnotherDigest() {
        let currentDigest = String(repeating: "2", count: 64)
        let previousDigest = String(repeating: "1", count: 64)
        let image = DockerImageSummary(
            id: "sha256:\(currentDigest)",
            repositoryTags: ["app:latest"],
            size: 1,
            created: nil,
            architecture: "arm64",
            operatingSystem: "linux"
        )
        let staleTag = container(
            id: "1",
            name: "old",
            image: "app:latest",
            imageID: "sha256:\(previousDigest)",
            networks: []
        )

        XCTAssertTrue(ResourceUsage.containers(usingImage: image, from: [staleTag]).isEmpty)
    }

    func testFullDigestsSharingATwelveCharacterPrefixDoNotMatch() {
        let prefix = "1234567890ab"
        let imageDigest = prefix + String(repeating: "c", count: 52)
        let otherDigest = prefix + String(repeating: "d", count: 52)
        let image = DockerImageSummary(
            id: "sha256:\(imageDigest)",
            repositoryTags: nil,
            size: 1,
            created: nil,
            architecture: "arm64",
            operatingSystem: "linux"
        )
        let collision = container(
            id: "1",
            name: "other",
            image: "<none>:<none>",
            imageID: otherDigest,
            networks: []
        )
        let abbreviated = container(
            id: "2",
            name: "short",
            image: "<none>:<none>",
            imageID: prefix,
            networks: []
        )

        XCTAssertEqual(ResourceUsage.containers(usingImage: image, from: [collision, abbreviated]).map(\.name), ["short"])
    }

    func testNetworkMatchUsesAttachedName() {
        let api = container(
            id: "1",
            name: "api",
            image: "app:dev",
            imageID: nil,
            networks: ["shop-api_default"]
        )
        let other = container(
            id: "2",
            name: "ollama",
            image: "ollama",
            imageID: nil,
            networks: ["bridge"]
        )
        let used = ResourceUsage.containers(onNetwork: "shop-api_default", from: [api, other])
        XCTAssertEqual(used.map(\.name), ["api"])
    }

    private func container(
        id: String,
        name: String,
        image: String,
        imageID: String?,
        networks: [String]
    ) -> DockerContainerSummary {
        DockerContainerSummary(
            id: id,
            names: ["/\(name)"],
            image: image,
            imageID: imageID,
            command: nil,
            created: nil,
            state: "running",
            status: "Up",
            labels: nil,
            ports: nil,
            networkSettings: DockerNetworkSettings(
                networks: Dictionary(uniqueKeysWithValues: networks.map { ($0, DockerNetworkEndpoint()) })
            )
        )
    }
}
