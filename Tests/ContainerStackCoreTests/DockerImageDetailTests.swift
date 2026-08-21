import Foundation
import Testing

@testable import ContainerStackCore

struct DockerImageDetailTests {
    @Test
    func platformTextIncludesTheVariantWhenThereIsOne() {
        let withVariant = DockerImageDetail(architecture: "arm64", operatingSystem: "linux", variant: "v8")
        #expect(withVariant.platformText == "linux/arm64 v8")

        let withoutVariant = DockerImageDetail(architecture: "arm64", operatingSystem: "linux", variant: nil)
        #expect(withoutVariant.platformText == "linux/arm64")

        let emptyVariant = DockerImageDetail(architecture: "amd64", operatingSystem: "linux", variant: "")
        #expect(emptyVariant.platformText == "linux/amd64")
    }

    /// Missing platform reads as nil rather than as the string "unknown/unknown", which is
    /// what the row subtitle asserted for every image.
    @Test
    func platformTextIsNilWhenTheRuntimeReportsNothing() {
        #expect(DockerImageDetail(architecture: nil, operatingSystem: nil, variant: nil).platformText == nil)
        #expect(DockerImageDetail(architecture: "arm64", operatingSystem: nil, variant: nil).platformText == nil)
        #expect(DockerImageDetail(architecture: nil, operatingSystem: "linux", variant: nil).platformText == nil)
    }
}
