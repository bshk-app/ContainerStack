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

    // MARK: - helper log destinations

    @Test
    func prefersTheOwnedLogFileOverTheFallback() {
        let candidates = RuntimePaths.runtimeLogCandidates(
            home: URL(fileURLWithPath: "/Users/tester"),
            temporaryDirectory: URL(fileURLWithPath: "/tmp/scratch")
        )

        #expect(
            candidates.map(\.path) == [
                "/Users/tester/Library/Logs/ContainerStack/runtime.log",
                "/tmp/scratch/containerstack-runtime.log",
            ])
    }

    /// A helper that cannot open its own log must still have somewhere to be heard.
    @Test
    func alwaysOffersAFallbackOutsideTheHomeDirectory() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let candidates = RuntimePaths.runtimeLogCandidates(
            home: home,
            temporaryDirectory: URL(fileURLWithPath: "/tmp/scratch")
        )

        #expect(candidates.count > 1)
        #expect(candidates.dropFirst().allSatisfy { !$0.path.hasPrefix(home.path) })
    }
}
