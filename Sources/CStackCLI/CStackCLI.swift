import ContainerStackCore
import Darwin
import Foundation

@main
struct CStackCLI {
    static func main() async {
        let invocation = CStackInvocation(arguments: Array(CommandLine.arguments.dropFirst()))
        let client = DockerAPIClient(socketPath: invocation.socketPath ?? defaultSocketPath())

        do {
            try await run(invocation, client: client)
        } catch {
            fputs("cstack \(invocation.command): \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func run(_ invocation: CStackInvocation, client: DockerAPIClient) async throws {
        if invocation.command == "compose" {
            runCompose(invocation)
        }
        if try await runtimeCommand(invocation, client: client) { return }
        if try await containerCommand(invocation, client: client) { return }
        if try await imageCommand(invocation, client: client) { return }
        if try await resourceCommand(invocation, client: client) { return }

        fputs("Unknown command: \(invocation.command)\n\n", stderr)
        printUsage()
        exit(64)
    }

    /// Compose speaks the Docker API, so it runs unchanged against the ContainerStack socket.
    private static func runCompose(_ invocation: CStackInvocation) -> Never {
        let plan = ComposeCommand.plan(
            socketPath: invocation.socketPath ?? defaultSocketPath(),
            arguments: invocation.passthrough
        )

        guard let executablePath = plan.executablePath else {
            fputs(
                "cstack compose: docker CLI not found in \(ComposeCommand.searchPaths.joined(separator: ", "))\n",
                stderr
            )
            exit(69)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = plan.arguments
        process.environment = plan.environment

        do {
            try process.run()
        } catch {
            fputs("cstack compose: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }

        process.waitUntilExit()
        exit(process.terminationStatus)
    }

    private static func runtimeCommand(
        _ invocation: CStackInvocation,
        client: DockerAPIClient
    ) async throws -> Bool {
        switch invocation.command {
        case "doctor":
            try await doctor(client)
        case "ping":
            print(try await client.health().pingOK ? "OK" : "FAILED")
        case "version":
            print(try await client.health().version.version ?? "unknown")
        case "df":
            try await diskUsage(client)
        case "prune":
            try await prune(invocation, client: client)
        case "context":
            try context(invocation)
        case "runtime":
            try runtimeControl(invocation)
        case "help":
            printUsage()
        default:
            return false
        }
        return true
    }

    private static func containerCommand(
        _ invocation: CStackInvocation,
        client: DockerAPIClient
    ) async throws -> Bool {
        switch invocation.command {
        case "ps":
            try await listContainers(client, all: !invocation.isSet("running"))
        case "inspect":
            try await inspect(client, id: requireArgument(invocation, name: "container"))
        case "logs":
            let id = requireArgument(invocation, name: "container")
            let logs = try await client.containerLogs(id: id, tail: invocation.intValue("tail"))
            print(logs, terminator: logs.hasSuffix("\n") ? "" : "\n")
        case "start":
            try await client.startContainer(id: requireArgument(invocation, name: "container"))
        case "stop":
            try await client.stopContainer(id: requireArgument(invocation, name: "container"))
        case "restart":
            try await client.restartContainer(id: requireArgument(invocation, name: "container"))
        case "rm":
            try await client.removeContainer(
                id: requireArgument(invocation, name: "container"),
                force: invocation.isSet("force")
            )
        default:
            return false
        }
        return true
    }

    private static func imageCommand(
        _ invocation: CStackInvocation,
        client: DockerAPIClient
    ) async throws -> Bool {
        switch invocation.command {
        case "run":
            try await runImage(invocation, client: client)
        case "images":
            try await listImages(client)
        case "pull":
            try await pull(client, reference: requireArgument(invocation, name: "image"))
        case "rmi":
            try await client.removeImage(
                reference: requireArgument(invocation, name: "image"),
                force: invocation.isSet("force")
            )
        default:
            return false
        }
        return true
    }

    private static func resourceCommand(
        _ invocation: CStackInvocation,
        client: DockerAPIClient
    ) async throws -> Bool {
        switch invocation.command {
        case "volume", "volumes":
            try await volumes(invocation, client: client)
        case "network", "networks":
            try await networks(invocation, client: client)
        default:
            return false
        }
        return true
    }
}
