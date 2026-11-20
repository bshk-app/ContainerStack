import Foundation
import Testing

@testable import ContainerStackCore

private final class CStackTestBundleToken {}

struct CStackCommandParserTests {
    @Test(
        "help flags bypass commands with default actions",
        arguments: [
            [], ["doctor"], ["ping"], ["version"], ["df"], ["prune"], ["context"], ["runtime"],
            ["ps"], ["images"], ["volume"], ["volumes"], ["network"], ["networks"], ["runtime", "restart"],
        ],
        ["-h", "--help"]
    )
    func helpFlagAsksForHelp(arguments: [String], flag: String) {
        #expect(CStackInvocation(arguments: arguments + [flag]).wantsHelp)
    }

    @Test
    func helpCommandAsksForHelp() {
        #expect(CStackInvocation(arguments: ["help"]).wantsHelp)
    }

    @Test(arguments: [
        ["-h", "compose", "up", "-d"],
        ["--help", "compose", "down", "-v"],
        ["-h", "compose", "up", "--help"],
        ["--help", "compose", "run", "service", "--", "--help"],
    ])
    func helpBeforeComposeAsksForCStackHelp(arguments: [String]) {
        #expect(CStackInvocation(arguments: arguments).wantsHelp)
    }

    @Test(
        "a command without a help flag runs",
        arguments: [
            [], ["runtime"], ["runtime", "restart"], ["ps", "--all"], ["doctor"], ["run", "alpine", "--", "--help"],
        ]
    )
    func commandWithoutHelpFlagRuns(arguments: [String]) {
        #expect(!CStackInvocation(arguments: arguments).wantsHelp)
    }

    @Test(arguments: [[], ["up"]], ["-h", "--help"])
    func composePassesItsHelpFlagToDockerCompose(arguments: [String], flag: String) {
        let invocation = CStackInvocation(arguments: ["compose"] + arguments + [flag])

        #expect(!invocation.wantsHelp)
        #expect(invocation.passthrough == arguments + [flag])
    }

    @Test
    func composeKeepsHelpAfterArgumentSeparator() {
        let invocation = CStackInvocation(arguments: ["compose", "run", "service", "--", "--help"])

        #expect(!invocation.wantsHelp)
        #expect(!invocation.isSet("help"))
        #expect(invocation.trailing == ["--help"])
        #expect(invocation.passthrough == ["run", "service", "--help"])
    }

    @Test(arguments: ["-h", "--help"])
    func pruneHelpPrintsUsageWithoutContactingDocker(flag: String) throws {
        let testBundle = Bundle(for: CStackTestBundleToken.self)
        let executable = testBundle.bundleURL.deletingLastPathComponent().appending(path: "cstack")
        let result = try ProcessRunner.run(
            executablePath: executable.path,
            arguments: ["--socket", "/dev/null", "prune", flag],
            output: .capture(includingStandardError: true),
            timeout: .seconds(10)
        )

        #expect(result.status == 0)
        #expect(result.output.hasPrefix("Usage: cstack"))
    }

    @Test
    func defaultsToDoctorWithoutArguments() {
        let invocation = CStackInvocation(arguments: [])

        #expect(invocation.command == "doctor")
        #expect(invocation.socketPath == nil)
        #expect(invocation.positional.isEmpty)
    }

    @Test
    func readsGlobalSocketBeforeCommand() {
        let invocation = CStackInvocation(arguments: ["--socket", "/tmp/x.sock", "ps", "--all"])

        #expect(invocation.socketPath == "/tmp/x.sock")
        #expect(invocation.command == "ps")
        #expect(invocation.isSet("all"))
    }

    @Test
    func readsGlobalSocketAfterCommand() {
        let invocation = CStackInvocation(arguments: ["images", "--socket", "/tmp/x.sock"])

        #expect(invocation.socketPath == "/tmp/x.sock")
        #expect(invocation.command == "images")
        #expect(invocation.positional.isEmpty)
    }

    @Test
    func splitsTrailingCommandArguments() {
        let invocation = CStackInvocation(arguments: ["run", "alpine:3.20", "--", "/bin/sh", "-c", "echo hi"])

        #expect(invocation.command == "run")
        #expect(invocation.positional == ["alpine:3.20"])
        #expect(invocation.trailing == ["/bin/sh", "-c", "echo hi"])
    }

    @Test
    func readsValueOptions() {
        let invocation = CStackInvocation(arguments: ["logs", "c1", "--tail", "50"])

        #expect(invocation.command == "logs")
        #expect(invocation.positional == ["c1"])
        #expect(invocation.value("tail") == "50")
        #expect(invocation.intValue("tail") == 50)
    }

    @Test
    func keepsSubcommandPositionals() {
        let invocation = CStackInvocation(arguments: ["volume", "create", "data", "--force"])

        #expect(invocation.command == "volume")
        #expect(invocation.positional == ["create", "data"])
        #expect(invocation.isSet("force"))
        #expect(invocation.isSet("f") == false)
    }

    @Test
    func treatsShortFlagAliasesAsFlags() {
        let invocation = CStackInvocation(arguments: ["rm", "c1", "-f"])

        #expect(invocation.command == "rm")
        #expect(invocation.positional == ["c1"])
        #expect(invocation.isSet("force"))
    }

    @Test
    func keepsRawArgumentsForPassthroughCommands() {
        let invocation = CStackInvocation(
            arguments: ["--socket", "/tmp/x.sock", "compose", "up", "-d", "--build"]
        )

        #expect(invocation.command == "compose")
        #expect(invocation.socketPath == "/tmp/x.sock")
        #expect(invocation.passthrough == ["up", "-d", "--build"])
    }

    @Test
    func stripsGlobalSocketFromPassthrough() {
        let invocation = CStackInvocation(arguments: ["compose", "ps", "--socket", "/tmp/x.sock"])

        #expect(invocation.passthrough == ["ps"])
    }
}
