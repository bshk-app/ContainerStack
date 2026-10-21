import Foundation
import Testing

@testable import ContainerStackCore

struct CStackCommandParserTests {
    @Test(
        "a help flag asks for help instead of running the command",
        arguments: [
            ["--help"],
            ["-h"],
            ["help"],
            ["runtime", "--help"],
            ["runtime", "-h"],
            ["runtime", "restart", "--help"],
            ["prune", "--help"],
        ]
    )
    func helpFlagAsksForHelp(arguments: [String]) {
        #expect(CStackInvocation(arguments: arguments).wantsHelp)
    }

    @Test(
        "a command without a help flag runs",
        arguments: [[], ["runtime"], ["runtime", "restart"], ["ps", "--all"], ["doctor"]]
    )
    func commandWithoutHelpFlagRuns(arguments: [String]) {
        #expect(!CStackInvocation(arguments: arguments).wantsHelp)
    }

    @Test
    func composePassesItsHelpFlagToDockerCompose() {
        let invocation = CStackInvocation(arguments: ["compose", "--help"])

        #expect(!invocation.wantsHelp)
        #expect(invocation.passthrough == ["--help"])
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
