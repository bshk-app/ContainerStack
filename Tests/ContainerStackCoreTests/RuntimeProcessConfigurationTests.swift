import Foundation
import Testing

@testable import ContainerStackCore

struct RuntimeProcessConfigurationTests {
    @Test
    func usesTheAppOwnedSocketByDefault() {
        #expect(
            RuntimeProcessConfiguration.defaultSocketPath
                == FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".containerstack/docker.sock")
                .path
        )
    }

    @Test
    func forwardsTheConfiguredSocketToSocktainer() {
        let configuration = RuntimeProcessConfiguration(
            containerPath: "/usr/local/bin/container",
            socktainerPath: "/Applications/ContainerStack.app/Contents/Helpers/socktainer",
            socketPath: "/tmp/custom.sock"
        )

        #expect(
            configuration.socktainerArguments
                == [
                    "--no-check-compatibility", "--no-docker-context", "--socket", "/tmp/custom.sock",
                    "--startup-housekeeping",
                ]
        )
    }

    @Test
    func keepsCompatibilityAndDockerContextUnderAppControl() {
        let configuration = RuntimeProcessConfiguration(
            containerPath: "/usr/local/bin/container",
            socktainerPath: "/Applications/ContainerStack.app/Contents/Helpers/socktainer"
        )

        #expect(configuration.containerStartArguments == ["system", "start"])
        #expect(
            configuration.socktainerArguments
                == [
                    "--no-check-compatibility", "--no-docker-context", "--socket",
                    RuntimeProcessConfiguration.defaultSocketPath, "--startup-housekeeping",
                ]
        )
        #expect(configuration.socktainerPath.hasSuffix("/Contents/Helpers/socktainer"))
        #expect(configuration.expectedContainerVersion == "1.2.2")
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
