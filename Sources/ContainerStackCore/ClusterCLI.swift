import Foundation

public struct ClusterCLI: Sendable {
    public static let usage = """
        Usage: cstack cluster <command>
          ls [--json]                 List clusters
          create NAME [--cpus N] [--memory SIZE] [--workers SPEC]... [--node-image REF]
                      [--cni PATH|NONE] [--shared-image-store]
                                      Create a cluster
          start NAME                  Start a cluster
          stop NAME                   Stop a cluster
          rm NAME                     Delete a cluster (no prompt)
          kubeconfig NAME             Write the context to ~/.containerstack/kubeconfig
        """

    enum Command: Equatable {
        case list(json: Bool)
        case create(name: String, options: [String])
        case start(String)
        case stop(String)
        case remove(String)
        case kubeconfig(String)
    }

    public struct ReadyWait: Sendable {
        let interval: Duration
        let probe: Duration
        let limit: Duration
    }

    struct ReadinessClock: Sendable {
        let now: @Sendable () -> ContinuousClock.Instant
        let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void

        init<C: Clock>(_ clock: C) where C.Instant == ContinuousClock.Instant {
            now = { clock.now }
            sleep = { try await clock.sleep(until: $0, tolerance: nil) }
        }
    }

    struct UsageError: Error {
        let message: String
    }

    private static let createValueOptions: Set<String> = ["--cpus", "--memory", "--workers", "--node-image", "--cni"]

    let commands: ClusterCommands
    let write: @Sendable (String) -> Void
    let writeError: @Sendable (String) -> Void
    let apiObservation: @Sendable (KubernetesCluster, Duration) async -> ClusterAPIReady.Result
    let readyWait: ReadyWait
    private let clock: ReadinessClock

    public init(
        commands: ClusterCommands,
        write: @escaping @Sendable (String) -> Void,
        writeError: @escaping @Sendable (String) -> Void
    ) {
        let kubeconfig = commands.managedKubeconfig
        self.init(
            commands: commands, write: write, writeError: writeError,
            apiObservation: { cluster, limit in
                await ClusterAPIReady.check(
                    endpoint: cluster.apiEndpoint, context: cluster.name, kubeconfig: kubeconfig, timeout: limit)
            },
            readyWait: ReadyWait(interval: .seconds(5), probe: .seconds(3), limit: .seconds(30)))
    }

    init(
        commands: ClusterCommands,
        write: @escaping @Sendable (String) -> Void,
        writeError: @escaping @Sendable (String) -> Void,
        apiObservation: @escaping @Sendable (KubernetesCluster, Duration) async -> ClusterAPIReady.Result,
        readyWait: ReadyWait,
        clock: ReadinessClock = ReadinessClock(ContinuousClock())
    ) {
        self.commands = commands
        self.write = write
        self.writeError = writeError
        self.apiObservation = apiObservation
        self.readyWait = readyWait
        self.clock = clock
    }

    private func print(_ line: String) {
        write(line + "\n")
    }

    private func printError(_ line: String) {
        writeError(line + "\n")
    }

    public func run(_ arguments: [String]) async -> Int32 {
        let command: Command
        do {
            command = try Self.parse(arguments)
        } catch {
            printError("cstack cluster: \(error.message)\n\n\(Self.usage)")
            return 64
        }
        do {
            let capability = try await commands.capability()
            guard capability == .capable else {
                printError("cstack cluster: \(capability)")
                return 69
            }
            return try await execute(command)
        } catch {
            printError("cstack cluster: \(error)")
            return 1
        }
    }

    private func execute(_ command: Command) async throws -> Int32 {
        switch command {
        case .list(let json):
            let output = try await commands.list()
            if json {
                write(output)
            } else {
                try await printTable(KubernetesCluster.decodeList(Data(output.utf8)))
            }
        case .create(let name, let options):
            try await commands.create(name: name, options: options)
            return try await apiReadyAfterStart(name) ? 0 : 1
        case .start(let name):
            try await commands.start(name: name)
            return try await apiReadyAfterStart(name) ? 0 : 1
        case .stop(let name):
            try await commands.stop(name: name)
        case .remove(let name):
            try await commands.delete(name: name)
        case .kubeconfig(let name):
            try await commands.writeConfig(name: name)
            print("kubectl --kubeconfig ~/.containerstack/kubeconfig --context \(name) get nodes")
            print("export KUBECONFIG=~/.containerstack/kubeconfig")
        }
        return 0
    }

    private func apiReadyAfterStart(_ name: String) async throws -> Bool {
        let cluster = try await KubernetesCluster.decodeList(Data(commands.list().utf8)).first { $0.name == name }
        let recovery = "To recover, run 'cstack cluster stop \(name)', then 'cstack cluster start \(name)'."
        guard let cluster else {
            printError("cstack cluster: cluster \(name) started, but it is not in the cluster list. \(recovery)")
            return false
        }
        if cluster.apiEndpoint == nil {
            printError(
                "cstack cluster: cluster \(name) has no published API port and no FQDN; the API check is skipped.")
            return true
        }
        var tick = clock.now()
        let deadline = tick + readyWait.limit
        var observation: ClusterAPIReady.Result = .notReady
        while tick < deadline {
            try await clock.sleep(tick)
            let left = clock.now().duration(to: deadline)
            guard left > .zero else { break }
            observation = await apiObservation(cluster, min(readyWait.probe, left))
            if observation == .ready { return true }
            tick += readyWait.interval
        }
        let limit = Double(readyWait.limit.components.seconds) + Double(readyWait.limit.components.attoseconds) / 1e18
        let seconds = limit == limit.rounded() ? String(Int(limit)) : String(limit)
        if observation == .connectionFailed, cluster.allNodesRunning {
            printError(ClusterAPIReady.localNetworkHint)
        }
        printError(
            "cstack cluster: cluster \(name) started, but its API is not ready after \(seconds) s. \(recovery)")
        return false
    }

    private func printTable(_ clusters: [KubernetesCluster]) async {
        print(["NAME", "STATE", "API-READY", "VERSION", "NODES", "API"].joined(separator: "\t"))
        for cluster in clusters {
            var ready = "-"
            if cluster.state == .running {
                let isReady = await ClusterAPIReady.isReady(
                    endpoint: cluster.apiEndpoint, context: cluster.name, kubeconfig: commands.managedKubeconfig)
                ready = isReady ? "yes" : "no"
            }
            let row = [
                cluster.name, cluster.state.rawValue, ready, cluster.kubernetesVersion, String(cluster.nodes.count),
                cluster.apiEndpoint?.absoluteString ?? "-",
            ]
            print(row.joined(separator: "\t"))
        }
    }

    static func parse(_ arguments: [String]) throws(UsageError) -> Command {
        guard let subcommand = arguments.first else { throw UsageError(message: "a subcommand is required") }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "ls":
            guard rest.isEmpty || rest == ["--json"] else { throw UsageError(message: "ls takes only --json") }
            return .list(json: rest == ["--json"])
        case "create":
            return try parseCreate(rest)
        case "start": return .start(try name(rest, subcommand))
        case "stop": return .stop(try name(rest, subcommand))
        case "rm": return .remove(try name(rest, subcommand))
        case "kubeconfig": return .kubeconfig(try name(rest, subcommand))
        default: throw UsageError(message: "unknown subcommand '\(subcommand)'")
        }
    }

    private static func name(_ arguments: [String], _ subcommand: String) throws(UsageError) -> String {
        guard arguments.count == 1, let name = arguments.first, !name.hasPrefix("-") else {
            throw UsageError(message: "\(subcommand) takes one cluster name")
        }
        return name
    }

    private static func parseCreate(_ arguments: [String]) throws(UsageError) -> Command {
        var name: String?
        var options: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if createValueOptions.contains(argument) {
                guard index < arguments.count, !arguments[index].hasPrefix("-") else {
                    throw UsageError(message: "\(argument) needs a value")
                }
                options += [argument, arguments[index]]
                index += 1
            } else if argument == "--shared-image-store" {
                options.append(argument)
            } else if argument.hasPrefix("-") {
                throw UsageError(message: "unknown option '\(argument)' for create")
            } else if name == nil {
                name = argument
            } else {
                throw UsageError(message: "create takes one cluster name")
            }
        }
        guard let name else { throw UsageError(message: "create takes one cluster name") }
        return .create(name: name, options: options)
    }
}
