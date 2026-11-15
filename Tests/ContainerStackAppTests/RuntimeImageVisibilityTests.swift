import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@Suite("Runtime image visibility")
@MainActor
struct RuntimeImageVisibilityTests {
    @Test(
        "Runtime repositories are absent from the shared image list",
        arguments: [
            ["ghcr.io/apple/containerization/vminit:0.40.1"],
            ["ghcr.io/apple/containerization/vminit:0.52.1"],
            ["ghcr.io/apple/containerization/vminit@sha256:abc"],
            ["ghcr.io/apple/container-builder-shim/builder:0.13.1"],
            ["ghcr.io/apple/container-builder-shim/builder@sha256:abc"],
            ["socktainer-dns:embedded"],
            ["user-alias:latest", "socktainer-dns:embedded"],
        ])
    func hidesRuntimeImages(tags: [String]) async throws {
        let model = try makeModel(tags: tags)

        await model.refreshImages()

        #expect(model.images.isEmpty)
        #expect(model.imagesErrorMessage == nil)
    }

    @Test(
        "Similar user repositories and untagged images stay visible",
        arguments: [
            ["vminit:latest"],
            ["example.com/apple/containerization/vminit:0.52.1"],
            ["ghcr.io/user/containerization/vminit:latest"],
            ["ghcr.io/apple/containerization/vminit-tools:latest"],
            ["ghcr.io/apple/container-builder-shim/builder-tools:latest"],
            ["container-builder-shim:latest"],
            ["user/socktainer-dns:embedded"],
            ["socktainer-dns-tools:latest"],
            ["localhost:5000/socktainer-dns:embedded"],
            ["alpine:3.20", "local-alpine:latest"],
            ["<none>:<none>"],
            [],
        ])
    func keepsUserImages(tags: [String]) async throws {
        let model = try makeModel(tags: tags)

        await model.refreshImages()

        #expect(model.images.map(\.id) == ["image"])
        #expect(model.images.first?.repositoryTags == tags)
    }

    private func makeModel(tags: [String]) throws -> RuntimeViewModel {
        let body = try JSONSerialization.data(withJSONObject: [["Id": "image", "RepoTags": tags]])
        let transport = GatedDockerTransport(answers: ["/images/json": String(decoding: body, as: UTF8.self)])
        return RuntimeViewModel(client: DockerAPIClient(transport: transport))
    }
}
