import ContainerStackCore
import Foundation

@MainActor
extension RuntimeViewModel {
    func run(image: String) async {
        guard canMutate else {
            containerMessage = "Start the runtime before launching a container."
            return
        }

        isRunningContainer = true
        containerMessage = "Running \(image)…"
        containerOutput = nil
        defer { isRunningContainer = false }

        do {
            let result = try await client.run(image: image, command: [])
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
        await withContainer(
            container,
            action: container.isRunning ? "Stopping" : "Starting"
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
