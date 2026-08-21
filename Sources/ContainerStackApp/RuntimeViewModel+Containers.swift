import ContainerStackCore
import Foundation

@MainActor
extension RuntimeViewModel {
    func run(image: String) async {
        guard isHealthy else {
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

    func toggle(container: DockerContainerSummary) async {
        guard isHealthy, busyContainerID == nil else { return }

        busyContainerID = container.id
        let action = container.isRunning ? "Stopping" : "Starting"
        containerMessage = "\(action) \(container.name)…"
        defer { busyContainerID = nil }

        do {
            if container.isRunning {
                try await client.stopContainer(id: container.id)
            } else {
                try await client.startContainer(id: container.id)
            }
            containerMessage = "\(container.name) is ready."
            await refreshContainers()
        } catch {
            containerMessage = "Container action failed: \(error)"
        }
    }

    func remove(container: DockerContainerSummary) async {
        guard isHealthy, busyContainerID == nil else { return }

        busyContainerID = container.id
        defer { busyContainerID = nil }

        do {
            try await client.removeContainer(id: container.id, force: true)
            containerMessage = "Removed \(container.name)."
            await refreshContainers()
        } catch {
            containerMessage = "Container removal failed: \(error)"
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
