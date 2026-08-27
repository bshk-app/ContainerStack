import Foundation
import Testing

@testable import ContainerStackCore

struct ResourceIdentifierTests {
    @Test
    func shortensDigests() {
        #expect(ResourceIdentifier.short("sha256:6839bd6e230281df328571bd15929f81") == "6839bd6e2302")
        #expect(
            ResourceIdentifier.short("4c43be8c849339405db6b70ac5500371cea31e9cfa911a58806df68c5e39f78e")
                == "4c43be8c8493"
        )
    }

    @Test
    func keepsHumanReadableIdentifiers() {
        #expect(ResourceIdentifier.short("cstack-cli-net") == "cstack-cli-net")
        #expect(ResourceIdentifier.short("default") == "default")
    }
}
