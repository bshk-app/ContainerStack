import ContainerStackCore
import Foundation

@MainActor
extension RuntimeViewModel {
    func run(image: String, resourceLimits: ContainerResourceLimits) async {
        guard canMutate else {
            containerMessage = "Start the runtime before launching a container."
            return
        }

        isRunningContainer = true
        containerMessage = "Running \(image)…"
        containerOutput = nil
        defer { isRunningContainer = false }

        do {
            let result = try await client.run(
                image: image,
                command: [],
                resourceLimits: resourceLimits
            )
            containerOutput = result.output
            containerMessage = "\(image) exited with status \(result.exitCode)."
            await refreshContainers()
        } catch {
            containerMessage = "Container failed: \(error)"
        }
    }

    /// Whether this container - not any container - is mid-action. Both the row
    /// and the inspector ask, so neither can drift back to a global flag.
    func isBusy(_ container: DockerContainerSummary) -> Bool {
        busyContainerIDs.contains(container.id)
    }

    func toggle(container: DockerContainerSummary) async {
        // Only a stop escalates to runtime recovery: it is the call measured hanging when Apple
        // Container loses its XPC service, and widening it would relabel an ordinary start or
        // remove failure as a runtime fault.
        await withContainer(
            container,
            action: container.isRunning ? "Stopping" : "Starting",
            recoversRuntime: container.isRunning
        ) { [client] in
            if container.isRunning {
                try await client.stopContainer(id: container.id)
            } else {
                try await client.startContainer(id: container.id)
            }
        }
    }

    func remove(container: DockerContainerSummary) async {
        await withContainer(
            container,
            action: "Removing",
            completion: "Removed \(container.name)."
        ) { [client] in
            try await client.removeContainer(id: container.id, force: true)
        }
    }

    func refreshImages() async {
        do {
            images = try await client.listImages()
            imagesErrorMessage = nil
        } catch {
            imagesErrorMessage = "Images could not be listed: \(error)"
        }
    }

    func refreshContainers() async {
        do {
            containers = try await client.listContainers(all: true)
            // The Stacks list is built from these: Compose labels every container it creates with its
            // project, working directory and config files, so a project started outside the app is
            // discoverable without a registry entry.

            discoveredProjects = ComposeProjectDiscovery.discover(from: containers)
            containersErrorMessage = nil
            if let selectedContainerID,
                !containers.contains(where: { $0.id == selectedContainerID })
            {
                self.selectedContainerID = nil
            }
        } catch {
            containersErrorMessage = "Containers could not be listed: \(error)"
        }
    }
}

enum RuntimeConnectionRecovery {
    static func shouldCheckSystemStatus(
        after error: Error?,
        recoveryRequested: Bool
    ) -> Bool {
        recoveryRequested || error.map(isHTTPServerFailure) == true
    }

    /// `isStarting` is deliberately unused: an absent API server must remain recoverable while
    /// the runtime is coming up, which is the state that previously stayed stuck forever.
    static func shouldAttemptRestart(
        apiserverRunning: Bool?,
        isStarting _: Bool,
        isRestarting: Bool,
        hasRuntimeFailure: Bool
    ) -> Bool {
        guard !isRestarting, !hasRuntimeFailure else { return false }
        return apiserverRunning == false
    }

    static func isStopRecoveryError(_ error: Error) -> Bool {
        (error as? UnixSocketError) == .timedOut || isDeadXPC(error)
    }

    private static func isHTTPServerFailure(_ error: Error) -> Bool {
        guard let apiError = error as? DockerAPIError,
            case .httpStatus(500, message: _) = apiError
        else {
            return false
        }
        return true
    }

    private static func isDeadXPC(_ error: Error) -> Bool {
        guard let apiError = error as? DockerAPIError,
            case .httpStatus(500, message: let message?) = apiError
        else {
            return false
        }
        let normalized = message.lowercased()
        return normalized.contains("xpc connection error")
            && (normalized.contains("connection interrupted")
                || normalized.contains("connection invalid"))
    }
}
