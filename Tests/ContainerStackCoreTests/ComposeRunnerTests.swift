import Foundation
import Testing

@testable import ContainerStackCore

struct ComposeRunnerTests {
    // A stack named "demo" living in /tmp/demo. `--project-directory` must resolve to /tmp/demo.
    private let stack = ComposeStack(name: "demo", fileURL: URL(fileURLWithPath: "/tmp/demo/compose.yaml"))

    /// Wraps the internal argument builder in `ComposeCommand.plan` and returns the full argument
    /// array docker would receive (including the leading `compose`), without spawning anything.
    private func planArgs(_ verb: String, _ extra: [String] = []) -> [String] {
        let args = ComposeRunner.composeArguments(for: stack, verb: verb, extra: extra)
        return ComposeCommand.plan(
            socketPath: "/tmp/c.sock",
            arguments: args,
            environment: [:],
            executableExists: { _ in true }
        ).arguments
    }

    private var prefix: [String] {
        ["compose", "--project-name", "demo", "--file", "/tmp/demo/compose.yaml", "--project-directory", "/tmp/demo"]
    }

    // MARK: - argument construction

    @Test
    func upUsesDetachAndRemovesOrphans() {
        #expect(planArgs("up", ["--detach", "--remove-orphans"]) == prefix + ["up", "--detach", "--remove-orphans"])
    }

    @Test
    func downAddsVolumesWhenRequested() {
        #expect(planArgs("down", ["--volumes"]) == prefix + ["down", "--volumes"])
    }

    @Test
    func downOmitsVolumesByDefault() {
        #expect(planArgs("down") == prefix + ["down"])
    }

    @Test
    func configEmitsFormatJson() {
        #expect(planArgs("config", ["--format", "json"]) == prefix + ["config", "--format", "json"])
    }

    @Test
    func psEmitsFormatJsonAll() {
        #expect(planArgs("ps", ["--format", "json", "--all"]) == prefix + ["ps", "--format", "json", "--all"])
    }

    @Test
    func restartIsBare() {
        #expect(planArgs("restart") == prefix + ["restart"])
    }

    @Test
    func logsForAllServices() {
        #expect(planArgs("logs", ["--no-color", "--tail", "100"]) == prefix + ["logs", "--no-color", "--tail", "100"])
    }

    @Test
    func logsForNamedService() {
        #expect(
            planArgs("logs", ["--no-color", "--tail", "50", "webserver"]) == prefix + [
                "logs", "--no-color", "--tail", "50", "webserver",
            ])
    }

    @Test
    func globalFlagsPrecedeTheVerb() {
        // project-name -> file -> project-directory must stay in this order before the verb.
        let args = planArgs("ps", ["--format", "json", "--all"])
        let names = args.firstIndex(of: "--project-name")
        let file = args.firstIndex(of: "--file")
        let dir = args.firstIndex(of: "--project-directory")
        let verb = args.firstIndex(of: "ps")

        #expect(names != nil && file != nil && dir != nil && verb != nil)
        #expect(names! < file! && file! < dir! && dir! < verb!)
    }

    // MARK: - ps parsing

    @Test
    func parsesJSONLines() {
        let output = """
            {"Name":"demo-web-1","Service":"web","State":"running","Health":"healthy","Publishers":[{"URL":"0.0.0.0","TargetPort":3000,"PublishedPort":3000,"Protocol":"tcp"}]}
            {"Name":"demo-db-1","Service":"db","State":"exited","Health":"","Publishers":[]}
            """

        let statuses = ComposeRunner.parseStatus(output)

        #expect(
            statuses == [
                ComposeServiceStatus(
                    name: "web", state: "running", health: "healthy", publishedPorts: ["0.0.0.0:3000->3000/tcp"],
                    isRunning: true),
                ComposeServiceStatus(name: "db", state: "exited", health: nil, publishedPorts: [], isRunning: false),
            ])
    }

    @Test
    func parsesSingleArray() {
        let output = """
            [{"Name":"demo-web-1","Service":"web","State":"running","Health":"healthy","Publishers":[
              {"URL":"0.0.0.0","TargetPort":3000,"PublishedPort":3000,"Protocol":"tcp"}]},{"Name":"demo-db-1","Service":"db","State":"exited","Health":"","Publishers":[
              ]}]
            """

        let statuses = ComposeRunner.parseStatus(output)

        #expect(statuses.count == 2)
        #expect(
            statuses[0]
                == ComposeServiceStatus(
                    name: "web", state: "running", health: "healthy", publishedPorts: ["0.0.0.0:3000->3000/tcp"],
                    isRunning: true))
        #expect(
            statuses[1]
                == ComposeServiceStatus(name: "db", state: "exited", health: nil, publishedPorts: [], isRunning: false))
    }

    @Test
    func skipsUnpublishedPortsAndMissingHealth() {
        let output = """
            {"Name":"demo-db-1","Service":"db","State":"running","Publishers":[{"URL":"0.0.0.0","TargetPort":5432,"PublishedPort":0,"Protocol":"tcp"}]}
            """

        let statuses = ComposeRunner.parseStatus(output)

        // No Health key -> nil; PublishedPort 0 -> dropped, leaving no published ports.
        #expect(
            statuses == [
                ComposeServiceStatus(name: "db", state: "running", health: nil, publishedPorts: [], isRunning: true)
            ])
    }

    @Test
    func defaultsMissingUrlToWildcard() {
        let output = """
            {"Name":"demo-web-1","Service":"web","State":"running","Publishers":[{"TargetPort":80,"PublishedPort":8080,"Protocol":"tcp"}]}
            """

        let statuses = ComposeRunner.parseStatus(output)

        #expect(
            statuses == [
                ComposeServiceStatus(
                    name: "web", state: "running", health: nil, publishedPorts: ["0.0.0.0:8080->80/tcp"],
                    isRunning: true)
            ])
    }

    @Test
    func treatsEmptyHealthAsNone() {
        let output = """
            {"Name":"demo-web-1","Service":"web","State":"running","Health":"","Publishers":[]}
            """

        let statuses = ComposeRunner.parseStatus(output)

        #expect(
            statuses == [
                ComposeServiceStatus(name: "web", state: "running", health: nil, publishedPorts: [], isRunning: true)
            ])
    }

    @Test
    func mapsRunningState() {
        // isRunning is true only when state == "running".
        let output = """
            {"Name":"a-1","Service":"a","State":"running","Publishers":[]}
            {"Name":"b-1","Service":"b","State":"exited","Publishers":[]}
            {"Name":"c-1","Service":"c","State":"restarting","Publishers":[]}
            """

        let statuses = ComposeRunner.parseStatus(output)

        #expect(statuses.map(\.isRunning) == [true, false, false])
    }

    @Test
    func skipsStrayNonJsonLines() {
        // Combined stdout/stderr may interleave a Compose warning before the JSON Lines objects.
        let output = """
            WARN[0000] /tmp/demo/compose.yaml: `version` is obsolete
            {"Name":"demo-web-1","Service":"web","State":"running","Health":"healthy","Publishers":[]}
            """

        let statuses = ComposeRunner.parseStatus(output)

        #expect(
            statuses == [
                ComposeServiceStatus(
                    name: "web", state: "running", health: "healthy", publishedPorts: [], isRunning: true)
            ])
    }

    @Test
    func emptyOutputYieldsNoStatuses() {
        #expect(ComposeRunner.parseStatus("") == [])
        #expect(ComposeRunner.parseStatus("   \n  ") == [])
    }

    // MARK: - validation temp file

    @Test
    func validationTempNameIsUniquePerCall() {
        let first = ComposeRunner.validationTempName()
        let second = ComposeRunner.validationTempName()

        #expect(first != second)
    }

    @Test
    func validationTempNameIsHiddenYaml() {
        let name = ComposeRunner.validationTempName()

        #expect(name.hasPrefix(".containerstack-validate."))
        #expect(name.hasSuffix(".yaml"))
        // The compose file itself must never be the target of the validation write.
        #expect(name != stack.fileURL.lastPathComponent)
    }

    /// A project name is unbounded, so carrying it here would let a long one breach the 255-byte
    /// filename limit and fail a save that used to work.
    @Test
    func validationTempNameLengthDoesNotDependOnTheProjectName() {
        #expect(ComposeRunner.validationTempName().utf8.count < 255)
    }
}
