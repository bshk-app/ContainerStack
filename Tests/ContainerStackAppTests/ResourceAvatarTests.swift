import XCTest

@testable import ContainerStackApp
@testable import ContainerStackCore

final class ResourceAvatarTests: XCTestCase {
    /// Most local images share the `docker.io/library/` prefix, so initials taken from the
    /// registry host read "do" on every row.
    func testImageInitialsComeFromTheRepositoryName() {
        XCTAssertEqual(image(tag: "docker.io/library/redis:7-alpine").avatarInitials, "re")
        XCTAssertEqual(image(tag: "localhost:5000/team/app:1.2").avatarInitials, "ap")
        XCTAssertEqual(image(tag: "ghcr.io/bshk-app/socktainer@sha256:abc").avatarInitials, "so")
        XCTAssertEqual(image(tag: "alpine").avatarInitials, "al")
    }

    private func image(tag: String) -> DockerImageSummary {
        DockerImageSummary(
            id: "sha256:" + String(repeating: "a", count: 64),
            repositoryTags: [tag],
            size: 1,
            created: nil,
            architecture: nil,
            operatingSystem: nil
        )
    }
}
