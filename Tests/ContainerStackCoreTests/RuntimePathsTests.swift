import Foundation
import Testing
@testable import ContainerStackCore

struct RuntimePathsTests {
    @Test
    func resolvesSiblingOfAbsoluteExecutable() {
        let path = RuntimePaths.sibling(
            named: "socktainer",
            ofExecutableAt: "/Applications/ContainerStack.app/Contents/Helpers/ContainerStackRuntime",
            workingDirectory: "/"
        )

        #expect(path == "/Applications/ContainerStack.app/Contents/Helpers/socktainer")
    }

    /// launchd starts a `BundleProgram` agent with a bundle-relative argv[0].
    @Test
    func resolvesSiblingOfBundleRelativeExecutable() {
        let path = RuntimePaths.sibling(
            named: "socktainer",
            ofExecutableAt: "Contents/Helpers/ContainerStackRuntime",
            workingDirectory: "/Applications/ContainerStack.app"
        )

        #expect(path == "/Applications/ContainerStack.app/Contents/Helpers/socktainer")
    }

    @Test
    func resolvesSiblingNextToBareExecutableName() {
        let path = RuntimePaths.sibling(
            named: "socktainer",
            ofExecutableAt: "ContainerStackRuntime",
            workingDirectory: "/tmp/stage"
        )

        #expect(path == "/tmp/stage/socktainer")
    }
}
