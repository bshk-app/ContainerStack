import Foundation
import Testing
@testable import ContainerStackCore

struct ByteSizeTests {
    @Test
    func formatsDecimalUnits() {
        #expect(ByteSize.formatted(0) == "0 B")
        #expect(ByteSize.formatted(512) == "512 B")
        #expect(ByteSize.formatted(4768) == "4.8 kB")
        #expect(ByteSize.formatted(172_513_945) == "172.5 MB")
        #expect(ByteSize.formatted(2_627_125_248) == "2.6 GB")
    }

    @Test
    func formatsUnknownAndNegativeSizes() {
        #expect(ByteSize.formatted(nil) == "—")
        #expect(ByteSize.formatted(-1) == "—")
    }
}
