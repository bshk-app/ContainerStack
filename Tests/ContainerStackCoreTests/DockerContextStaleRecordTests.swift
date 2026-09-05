import Foundation
import Testing

@testable import ContainerStackCore

/// Covers the stale-record repair: rewriting a mismatched record without ever running
/// `context use`, kept separate from `DockerContextTests`'s `shouldAdopt` coverage.
struct DockerContextStaleRecordTests {
    @Test
    func splitsTheRecordFromTheSwitchInInstallCommands() {
        #expect(
            DockerContext.recordCommand(socketPath: "/tmp/c.sock", exists: true) == [
                "context", "update", "containerstack",
                "--description", "ContainerStack",
                "--docker", "host=unix:///tmp/c.sock",
            ])
        #expect(
            DockerContext.installCommands(socketPath: "/tmp/c.sock", exists: true) == [
                DockerContext.recordCommand(socketPath: "/tmp/c.sock", exists: true),
                ["context", "use", "containerstack"],
            ])
    }

    @Test
    func repairsAMismatchedRecordWithoutActivatingIt() {
        #expect(
            DockerContext.shouldRepairStaleRecord(
                activeContext: "desktop-linux",
                installed: true,
                takeoverEnabled: true,
                recordedSocketPath: "/Users/me/.socktainer/container.sock",
                currentSocketPath: "/Users/me/.containerstack/docker.sock"
            ))
    }

    @Test
    func doesNotRepairARecordThatAlreadyMatches() {
        #expect(
            !DockerContext.shouldRepairStaleRecord(
                activeContext: "desktop-linux",
                installed: true,
                takeoverEnabled: true,
                recordedSocketPath: "/Users/me/.containerstack/docker.sock",
                currentSocketPath: "/Users/me/.containerstack/docker.sock"
            ))
    }

    @Test
    func doesNotRepairAContextThatIsCurrentlyActive() {
        // shouldAdopt already handles this shape -- it activates, which repairs the record as a
        // side effect of installContext. Repair must not also fire and double-run the update.
        #expect(
            !DockerContext.shouldRepairStaleRecord(
                activeContext: DockerContext.name,
                installed: true,
                takeoverEnabled: true,
                recordedSocketPath: "/Users/me/.socktainer/container.sock",
                currentSocketPath: "/Users/me/.containerstack/docker.sock"
            ))
    }

    @Test
    func doesNotRepairWhenTakeoverIsDisabled() {
        #expect(
            !DockerContext.shouldRepairStaleRecord(
                activeContext: "desktop-linux",
                installed: true,
                takeoverEnabled: false,
                recordedSocketPath: "/Users/me/.socktainer/container.sock",
                currentSocketPath: "/Users/me/.containerstack/docker.sock"
            ))
    }

    @Test
    func doesNotRepairAnUninstalledOrUnresolvedContext() {
        #expect(
            !DockerContext.shouldRepairStaleRecord(
                activeContext: "desktop-linux",
                installed: false,
                takeoverEnabled: true,
                recordedSocketPath: "/Users/me/.socktainer/container.sock",
                currentSocketPath: "/Users/me/.containerstack/docker.sock"
            ))
        #expect(
            !DockerContext.shouldRepairStaleRecord(
                activeContext: "desktop-linux",
                installed: true,
                takeoverEnabled: true,
                recordedSocketPath: nil,
                currentSocketPath: "/Users/me/.containerstack/docker.sock"
            ))
    }

    @Test
    func readsTheRecordedEndpointForANamedContextAmongOthers() {
        let output = """
            containerstack\tunix:///Users/me/.socktainer/container.sock
            default\tunix:///var/run/docker.sock
            desktop-linux\tunix:///Users/me/.docker/run/docker.sock
            """
        #expect(
            DockerContext.recordedSocketPath(for: "containerstack", in: output)
                == "/Users/me/.socktainer/container.sock")
        #expect(
            DockerContext.recordedSocketPath(for: "desktop-linux", in: output)
                == "/Users/me/.docker/run/docker.sock")
        #expect(DockerContext.recordedSocketPath(for: "orbstack", in: output) == nil)
    }

    @Test
    func ignoresAWarningLineAheadOfTheEndpointTable() {
        let output = """
            WARNING: Error parsing config file
            containerstack\tunix:///Users/me/.containerstack/docker.sock
            """
        #expect(
            DockerContext.recordedSocketPath(for: "containerstack", in: output)
                == "/Users/me/.containerstack/docker.sock")
    }

    @Test
    func returnsNilForANonUnixEndpoint() {
        #expect(
            DockerContext.recordedSocketPath(
                for: "remote", in: "remote\ttcp://192.0.2.1:2376"
            ) == nil)
    }

    @Test
    func fetchesTheRecordedEndpointThroughTheNameEndpointFormat() throws {
        var receivedCommand: [String]?
        let recorded = try DockerCLI.recordedSocketPath(for: "containerstack") { arguments in
            receivedCommand = arguments
            return "containerstack\tunix:///tmp/containerstack.sock\ndefault\tunix:///var/run/docker.sock"
        }
        #expect(receivedCommand == ["context", "ls", "--format", "{{.Name}}\t{{.DockerEndpoint}}"])
        #expect(recorded == "/tmp/containerstack.sock")
    }

    @Test
    func repairsTheRecordWithoutSwitchingToIt() throws {
        var commands: [[String]] = []
        try DockerCLI.repairRecord(socketPath: "/tmp/containerstack.sock") { arguments in
            commands.append(arguments)
            return ""
        }
        #expect(
            commands == [
                [
                    "context", "update", "containerstack",
                    "--description", "ContainerStack",
                    "--docker", "host=unix:///tmp/containerstack.sock",
                ]
            ])
        #expect(!commands.contains(where: { $0.first == "context" && $0.dropFirst().first == "use" }))
    }
}
