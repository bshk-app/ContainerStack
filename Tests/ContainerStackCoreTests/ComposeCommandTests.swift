import Foundation
import Testing
@testable import ContainerStackCore

struct ComposeCommandTests {
    @Test
    func buildsDockerComposeInvocation() {
        let plan = ComposeCommand.plan(socketPath: "/tmp/c.sock", arguments: ["up", "-d"])

        #expect(plan.arguments == ["compose", "up", "-d"])
        #expect(plan.environment["DOCKER_HOST"] == "unix:///tmp/c.sock")
    }

    @Test
    func defaultsToHelpWithoutArguments() {
        let plan = ComposeCommand.plan(socketPath: "/tmp/c.sock", arguments: [])

        #expect(plan.arguments == ["compose", "--help"])
    }

    @Test
    func keepsExistingEnvironmentAndOverridesHost() {
        let plan = ComposeCommand.plan(
            socketPath: "/tmp/c.sock",
            arguments: ["ps"],
            environment: ["PATH": "/usr/bin", "DOCKER_HOST": "unix:///var/run/docker.sock"]
        )

        #expect(plan.environment["PATH"] == "/usr/bin")
        #expect(plan.environment["DOCKER_HOST"] == "unix:///tmp/c.sock")
    }

    @Test
    func resolvesDockerFromKnownLocations() {
        let plan = ComposeCommand.plan(
            socketPath: "/tmp/c.sock",
            arguments: ["ps"],
            environment: ["PATH": "/usr/bin"],
            executableExists: { $0 == "/opt/homebrew/bin/docker" }
        )

        #expect(plan.executablePath == "/opt/homebrew/bin/docker")
    }

    @Test
    func reportsMissingDockerBinary() {
        let plan = ComposeCommand.plan(
            socketPath: "/tmp/c.sock",
            arguments: ["ps"],
            executableExists: { _ in false }
        )

        #expect(plan.executablePath == nil)
    }
}
