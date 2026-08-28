import ContainerStackCore
import Darwin
import Foundation

extension CStackCLI {
    // MARK: - Commands

    static func doctor(_ client: DockerAPIClient) async throws {
        // This leads, because it is the one state where every other check misleads. With the app root
        // deleted the socket still answers `_ping` with 200 while `/info` fails — measured on a
        // disposable runtime, `cstack doctor` printed "Failed to generate system information" and
        // stopped, which names neither the cause nor the way out.
        let systemStatus = CommandShell.output(
            executablePath: RuntimeProcessConfiguration.make(
                socktainerPath: "",
                bundledInstallRoot: RuntimeProcessConfiguration.bundledInstallRoot(
                    forExecutableAt: Bundle.main.executableURL
                )
            ).containerPath,
            arguments: ["system", "status"]
        )
        if let missing = RuntimeStatusParser.missingAppRoot(systemStatus) {
            let responds = (try? await client.ping()) ?? false
            print("Docker socket: \(responds ? "healthy" : "not responding")")
            print("Runtime storage: MISSING — storing into \(missing), which no longer exists.")
            print("Images, volumes and containers kept there cannot be found.")
            print("The restart moves it back to the default location. Run: cstack runtime restart")
            return
        }

        let health = try await client.health()
        print("Docker socket: healthy")
        print("API version: \(health.version.apiVersion ?? "unknown")")
        print("Engine: \(health.version.version ?? "unknown")")
        print("Containers: \(health.info.containers.map(String.init) ?? "unknown")")
        print("Images: \(health.info.images.map(String.init) ?? "unknown")")
        if let root = RuntimeStatusParser.appRoot(systemStatus) {
            print("Runtime storage: \(root)")
        }

        // A healthy API says nothing about reachability: without a host route to the container
        // subnet every published port fails while every API call still succeeds.
        let containers = try await client.listContainers(all: false)
        guard containers.contains(where: \.isRunning) else {
            print("Container routes: no running containers to check")
            return
        }

        // Only networks a running container publishes on can break a published port. Judging every
        // network condemned the runtime for an idle `default` nobody was using (#36).
        let networks = try await client.listNetworks()
        let publishing = NetworkRouteHealth.publishingNetworks(containers: containers, networks: networks)
        if publishing.isEmpty {
            print("Container routes: no running container publishes ports")
        } else {
            let routes = CommandShell.output(
                executablePath: "/usr/sbin/netstat",
                arguments: ["-rn", "-f", "inet"]
            )
            let unroutable = NetworkRouteHealth.unroutableNetworks(publishing, routes: routes)
            if unroutable.isEmpty {
                print("Container routes: reachable (\(publishing.map(\.label).joined(separator: ", ")))")
            } else {
                print("Container routes: NO ROUTE to \(unroutable.map(\.label).joined(separator: ", "))")
                // The ports do not refuse — they accept and then nothing answers, which is why this
                // gets mistaken for an application bug. The container restart that looks like the
                // cheaper repair was measured failing on every network this bridge creates; the runtime
                // restart recovered the same case in 17s and kept the container addresses.
                print("Published ports accept connections and then hang.")
                print("Restarting the containers does not fix it. Run: cstack runtime restart")
            }
        }

        await reportMemoryCommitment(client, running: containers.filter(\.isRunning))
    }

    /// Every container here runs in its own micro-VM. The inspect value is the
    /// configured limit, not current RSS, but host use can grow toward it as the
    /// guest fills caches. Report that capacity without pretending it is already
    /// resident.
    private static func reportMemoryCommitment(
        _ client: DockerAPIClient,
        running: [DockerContainerSummary]
    ) async {
        var limits: [Int64?] = []
        var inspectFailures = 0
        for container in running {
            do {
                limits.append(try await client.inspectContainer(id: container.id).memoryLimitBytes)
            } catch {
                inspectFailures += 1
            }
        }

        guard !limits.isEmpty else {
            print(
                "Container memory limits: unavailable — \(inspectFailures) running container(s) could not be inspected."
            )
            return
        }

        let hostBytes = HostMemory.totalBytes() ?? 0
        let commitment = MemoryCommitment.measure(limits: limits, hostBytes: hostBytes)

        if hostBytes > 0 {
            let summary =
                "\(ByteSize.formatted(commitment.configuredBytes)) in explicit container limits vs \(ByteSize.formatted(hostBytes)) host memory"
            switch commitment.verdict {
            case .within:
                print("Container memory limits: \(summary)")
            case .approaching:
                print(
                    "Container memory limits: \(summary) — guests approaching their limits may pressure other applications"
                )
            case .exceeding:
                print("Container memory limits: HIGH — \(summary)")
                print("Guests do not reserve every byte immediately, but host use can grow toward these limits.")
                print("Stop a container or recreate it with a smaller --memory.")
            }
        } else {
            print(
                "Container memory limits: \(ByteSize.formatted(commitment.configuredBytes)) configured (host memory unknown)"
            )
        }

        if commitment.containersWithoutLimit > 0 {
            print(
                "\(commitment.containersWithoutLimit) running container(s) have no explicit memory limit and are excluded from that total."
            )
        }
        if inspectFailures > 0 {
            print(
                "\(inspectFailures) running container(s) could not be inspected, so the total is incomplete."
            )
        }
    }

    static func listContainers(_ client: DockerAPIClient, all: Bool) async throws {
        let containers = try await client.listContainers(all: all)
        printRow("CONTAINER ID", "IMAGE", "STATE", "NAME", "STATUS")
        for container in containers {
            printRow(
                shortID(container.id),
                container.image ?? "—",
                container.state ?? "—",
                container.name,
                container.status ?? "—"
            )
        }
    }

    static func inspect(_ client: DockerAPIClient, id: String) async throws {
        let detail = try await client.inspectContainer(id: id)
        print("ID:        \(detail.id)")
        print("Name:      \(detail.name)")
        print("Image:     \(detail.image ?? "—")")
        print("State:     \(detail.status ?? "—")")
        print("Running:   \(detail.isRunning)")
        print("Exit code: \(detail.exitCode.map(String.init) ?? "—")")
        print("Command:   \(detail.command ?? "—")")
        print("Memory:    \(detail.memoryLimitBytes.map(ByteSize.formatted) ?? "no limit reported")")
        if let project = detail.composeProject {
            print("Compose:   \(project)/\(detail.composeService ?? "—")")
        }
    }

    static func runImage(_ invocation: CStackInvocation, client: DockerAPIClient) async throws {
        let image = requireArgument(invocation, name: "image")
        let result = try await client.run(
            image: image,
            command: invocation.trailing,
            resourceLimits: nil
        )
        print(result.output, terminator: "")
        if result.exitCode != 0 {
            exit(Int32(result.exitCode))
        }
    }

    static func listImages(_ client: DockerAPIClient) async throws {
        let images = try await client.listImages()
        printRow("REPOSITORY:TAG", "IMAGE ID", "SIZE")
        for image in images {
            printRow(
                image.repositoryTags?.joined(separator: ",") ?? "<untagged>",
                shortID(image.id),
                ByteSize.formatted(image.size)
            )
        }
    }

    static func pull(_ client: DockerAPIClient, reference: String) async throws {
        let events = try await client.pullImage(reference: reference)
        for event in events {
            let status = event.status ?? ""
            guard !status.isEmpty else { continue }
            if let progress = event.progress {
                print("\(status) \(progress)")
            } else {
                print(status)
            }
        }
    }

    static func volumes(_ invocation: CStackInvocation, client: DockerAPIClient) async throws {
        switch invocation.positional.first {
        case "create":
            let name = requireArgument(invocation, name: "volume", at: 1)
            let volume = try await client.createVolume(name: name)
            print(volume.name)
        case "rm", "remove":
            let name = requireArgument(invocation, name: "volume", at: 1)
            try await client.removeVolume(name: name, force: invocation.isSet("force"))
        case "prune":
            let result = try await client.pruneVolumes()
            printPrune(result)
        default:
            let volumes = try await client.listVolumes()
            printRow("VOLUME NAME", "DRIVER", "MOUNTPOINT")
            for volume in volumes {
                printRow(volume.name, volume.driver ?? "—", volume.mountpoint ?? "—")
            }
        }
    }

    static func networks(_ invocation: CStackInvocation, client: DockerAPIClient) async throws {
        switch invocation.positional.first {
        case "create":
            let name = requireArgument(invocation, name: "network", at: 1)
            print(try await client.createNetwork(name: name))
        case "rm", "remove":
            try await client.removeNetwork(id: requireArgument(invocation, name: "network", at: 1))
        default:
            let networks = try await client.listNetworks()
            printRow("NETWORK ID", "NAME", "DRIVER", "SUBNET")
            for network in networks {
                printRow(shortID(network.id), network.name, network.driver ?? "—", network.subnet ?? "—")
            }
        }
    }

    static func diskUsage(_ client: DockerAPIClient) async throws {
        let usage = try await client.diskUsage()
        printRow("TYPE", "TOTAL", "SIZE")
        printRow("Images", "\(usage.images.count)", ByteSize.formatted(usage.layersSize))
        printRow("Containers", "\(usage.containers.count)", "—")
        printRow("Volumes", "\(usage.volumes.count)", "—")
    }

    /// Mirrors `docker system prune`: volumes hold user data and are only removed with `--volumes`.
    static func prune(_ invocation: CStackInvocation, client: DockerAPIClient) async throws {
        let containers = try await client.pruneContainers()
        let images = try await client.pruneImages()
        var reclaimed = containers.spaceReclaimed + images.spaceReclaimed
        print("Containers removed: \(containers.deleted.count)")

        if invocation.isSet("volumes") {
            let volumes = try await client.pruneVolumes()
            reclaimed += volumes.spaceReclaimed
            print("Volumes removed: \(volumes.deleted.count)")
        } else {
            print("Volumes kept. Pass --volumes to remove unused volumes.")
        }

        print("Total reclaimed space: \(ByteSize.formatted(reclaimed))")
    }

    /// Points the Docker client at this runtime so plain `docker` and Compose need no flags.
    static func context(_ invocation: CStackInvocation) throws {
        let socketPath = invocation.socketPath ?? RuntimeProcessConfiguration.defaultSocketPath

        switch invocation.positional.first {
        case "install", "use", .none:
            try DockerCLI.installContext(socketPath: socketPath)
            print("Docker context '\(DockerContext.name)' -> unix://\(socketPath)")
        case "uninstall", "rm":
            let removed = try DockerCLI.uninstallContext()
            print(
                removed
                    ? "Docker context '\(DockerContext.name)' removed"
                    : "Docker context takeover disabled"
            )
        case "status":
            break
        case let other?:
            fputs("cstack context: unknown action '\(other)'\n", stderr)
            exit(64)
        }

        let activeContext = DockerCLI.activeContext()
        let isInstalled = try? DockerCLI.installedContexts().contains(DockerContext.name)
        if let environmentOverride = DockerCLI.contextEnvironmentConflict(
            activeContext: activeContext,
            isContextInstalled: isInstalled
        ) {
            print(
                "Docker environment override: \(environmentOverride). Unset \(environmentOverride) to use the configured context."
            )
        }

        print("Docker context: \(activeContext ?? "unknown")")
    }

    // MARK: - Helpers

    static func printPrune(_ result: DockerPruneResult) {
        print("Removed: \(result.deleted.isEmpty ? "none" : result.deleted.joined(separator: ", "))")
        print("Reclaimed space: \(ByteSize.formatted(result.spaceReclaimed))")
    }

    static func requireArgument(
        _ invocation: CStackInvocation,
        name: String,
        at index: Int = 0
    ) -> String {
        guard invocation.positional.indices.contains(index) else {
            fputs("cstack \(invocation.command): \(name) is required\n\n", stderr)
            printUsage()
            exit(64)
        }
        return invocation.positional[index]
    }

    static func shortID(_ id: String) -> String {
        ResourceIdentifier.short(id)
    }

    static func printRow(_ columns: String...) {
        print(columns.joined(separator: "\t"))
    }

    static func printUsage() {
        print(
            """
            Usage: cstack [--socket PATH] <command>

            Runtime:
              doctor                 Check the Docker API health gate (default)
              ping                   Check that the Docker socket responds
              version                Print the Docker engine version
              df                     Show image, container and volume disk usage
              prune [--volumes]      Remove stopped containers and unused images

            Containers:
              ps [--running]         List containers (all by default)
              inspect ID             Show container detail
              logs ID [--tail N]     Print container logs
              start|stop|restart ID  Change container state
              rm ID [--force]        Remove a container
              run IMAGE [-- CMD...]  Run an image and print its output

            Images:
              images                 List images
              pull REFERENCE         Pull an image from a registry
              rmi REFERENCE [--force]  Remove an image

            Volumes and networks:
              volumes                List volumes
              volume create NAME     Create a volume
              volume rm NAME         Remove a volume
              volume prune           Remove unused volumes
              networks               List networks
              network create NAME    Create a network
              network rm ID          Remove a network
              context [status|install|uninstall]
                                     Point the docker CLI at this runtime

            Runtime:
              runtime [restart|stop|start]
                                     Recover the runtime when ports stop working

            Compose:
              compose ARGS...        Run docker compose against the ContainerStack socket
            """)
    }
}
