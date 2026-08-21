import Foundation
import Testing
@testable import ContainerStackCore

struct RuntimeProcessConfigurationTests {
    @Test
    func keepsCompatibilityAndDockerContextUnderAppControl() {
        let configuration = RuntimeProcessConfiguration(
            containerPath: "/usr/local/bin/container",
            socktainerPath: "/Applications/ContainerStack.app/Contents/Helpers/socktainer"
        )

        #expect(configuration.containerStartArguments == ["system", "start"])
        #expect(configuration.socktainerArguments == ["--no-check-compatibility", "--no-docker-context"])
        #expect(configuration.socktainerPath.hasSuffix("/Contents/Helpers/socktainer"))
        #expect(configuration.expectedContainerVersion == "1.2.2")
    }

    /// The vendored runtime (Apple Container shipped inside the bundle).
    ///
    /// Homebrew cannot pin a dependency's version, so relying on a system-wide
    /// install means an unrelated `brew upgrade` can move Apple Container's API
    /// out from under us on a machine we never touched. Shipping our own is the
    /// only way the pin reaches a user, and `container system start` takes
    /// `--install-root` precisely so a copy can live somewhere else.
    @Test
    func prefersTheVendoredRuntimeOverAnySystemInstall() {
        let bundled = "/Applications/ContainerStack.app/Contents/Resources/container"

        let resolved = RuntimeProcessConfiguration.resolvedContainerPath(
            bundledInstallRoot: bundled,
            exists: { _ in true }   // every system path present; the bundled one still wins
        )

        #expect(resolved == "\(bundled)/bin/container")
    }

    @Test
    func fallsBackToSystemPathsWhenNothingIsVendored() {
        let resolved = RuntimeProcessConfiguration.resolvedContainerPath(
            bundledInstallRoot: nil,
            exists: { $0 == "/opt/homebrew/bin/container" }
        )

        #expect(resolved == "/opt/homebrew/bin/container")
    }

    @Test
    func pointsTheDaemonAtTheVendoredInstallRoot() {
        let root = "/Applications/ContainerStack.app/Contents/Resources/container"
        let configuration = RuntimeProcessConfiguration(
            containerPath: "\(root)/bin/container",
            socktainerPath: "/Applications/ContainerStack.app/Contents/Helpers/socktainer",
            containerInstallRoot: root
        )

        #expect(configuration.containerStartArguments == ["system", "start", "--install-root", root])
    }

    /// Without a vendored copy the flag must be absent rather than empty: a
    /// system install already knows its own root, and passing a wrong one would
    /// send the daemon looking for plugins that are not there.
    @Test
    func omitsTheInstallRootForASystemInstall() {
        let configuration = RuntimeProcessConfiguration(
            containerPath: "/usr/local/bin/container",
            socktainerPath: "/Applications/ContainerStack.app/Contents/Helpers/socktainer"
        )

        #expect(configuration.containerStartArguments == ["system", "start"])
    }

    @Test
    func resolvesBundledRuntimeHelperPath() {
        let plan = RuntimeLaunchPlan(
            appBundleURL: URL(fileURLWithPath: "/Applications/ContainerStack.app")
        )

        #expect(plan.executablePath == "/Applications/ContainerStack.app/Contents/Helpers/ContainerStackRuntime")
        #expect(plan.arguments.isEmpty)
    }

    @Test
    func recognizesTabularContainerStatus() {
        let status = """
        FIELD              VALUE
        status             running
        appRoot            /Users/example/Library/Application Support/com.apple.container/
        """

        #expect(RuntimeStatusParser.isRunning(status))
        #expect(!RuntimeStatusParser.isRunning("apiserver is not running and not registered with launchd"))
    }
}
