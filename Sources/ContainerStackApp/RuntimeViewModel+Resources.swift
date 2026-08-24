import ContainerStackCore
import Foundation

@MainActor
extension RuntimeViewModel {
    var containerGroups: [ContainerGroup] {
        ContainerGroup.grouped(containers)
    }

    func start(group: ContainerGroup) async {
        await withResource(group.id, message: "Starting \(group.title)…") {
            for container in group.containers where !container.isRunning {
                try await self.client.startContainer(id: container.id)
            }
            self.resourceMessage = "Started \(group.title)."
            await self.refreshContainers()
        }
    }

    func stop(group: ContainerGroup) async {
        await withResource(group.id, message: "Stopping \(group.title)…") {
            for container in group.containers where container.isRunning {
                try await self.client.stopContainer(id: container.id)
            }
            self.resourceMessage = "Stopped \(group.title)."
            await self.refreshContainers()
        }
    }

    func remove(group: ContainerGroup) async {
        await withResource(group.id, message: "Removing \(group.title)…") {
            for container in group.containers {
                try await self.client.removeContainer(id: container.id, force: true)
            }
            self.resourceMessage = "Removed \(group.title)."
            await self.refreshContainers()
        }
    }

    var storageSummary: String {
        ByteSize.formatted(diskUsage?.layersSize)
    }

    func refreshVolumes() async {
        do {
            volumes = try await client.listVolumes()
            volumesErrorMessage = nil
        } catch {
            volumesErrorMessage = "Volumes could not be listed: \(error)"
        }
    }

    func refreshNetworks() async {
        do {
            networks = try await client.listNetworks()
            networksErrorMessage = nil
        } catch {
            networksErrorMessage = "Networks could not be listed: \(error)"
        }
    }

    func refreshDiskUsage() async {
        diskUsage = try? await client.diskUsage()
    }

    func restart(container: DockerContainerSummary) async {
        await withContainer(container, action: "Restarting") {
            try await self.client.restartContainer(id: container.id)
        }
    }

    func showLogs(for container: DockerContainerSummary) async {
        await withContainer(container, action: "Reading logs from", refreshList: false) {
            let output = try await self.client.containerLogs(id: container.id, tail: 500)
            self.logsContainerName = container.name
            self.logs = output.isEmpty ? "No log output." : output
        }
    }

    func clearLogs() {
        logs = nil
        logsContainerName = nil
    }

    /// Inspector logs. Must not write `logs` — that binding presents the sheet.
    func inlineLogs(for container: DockerContainerSummary) async -> String {
        do {
            let output = try await client.containerLogs(id: container.id, tail: 500)
            return output.isEmpty ? "No log output." : output
        } catch {
            return "Logs could not be read: \(error)"
        }
    }

    func pull(reference: String) async {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await withResource(trimmed, message: "Pulling \(trimmed)…") {
            let events = try await self.client.pullImage(reference: trimmed)
            let status = events.compactMap(\.status).last ?? "Pull complete"
            self.resourceMessage = "\(trimmed): \(status)"
            await self.refreshImages()
            await self.refreshDiskUsage()
        }
    }

    func remove(image: DockerImageSummary) async {
        let reference = image.repositoryTags?.first ?? image.id
        await withResource(image.id, message: "Removing \(reference)…") {
            try await self.client.removeImage(reference: reference, force: true)
            self.resourceMessage = "Removed \(reference)."
            await self.refreshImages()
            await self.refreshDiskUsage()
        }
    }

    func createVolume(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await withResource(trimmed, message: "Creating volume \(trimmed)…") {
            _ = try await self.client.createVolume(name: trimmed)
            self.resourceMessage = "Created volume \(trimmed)."
            await self.refreshVolumes()
        }
    }

    func remove(volume: DockerVolumeSummary) async {
        await withResource(volume.name, message: "Removing volume \(volume.name)…") {
            try await self.client.removeVolume(name: volume.name, force: false)
            self.resourceMessage = "Removed volume \(volume.name)."
            await self.refreshVolumes()
        }
    }

    func createNetwork(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await withResource(trimmed, message: "Creating network \(trimmed)…") {
            _ = try await self.client.createNetwork(name: trimmed)
            self.resourceMessage = "Created network \(trimmed)."
            await self.refreshNetworks()
        }
    }

    func remove(network: DockerNetworkSummary) async {
        await withResource(network.id, message: "Removing network \(network.name)…") {
            do {
                try await self.client.removeNetwork(id: network.id)
            } catch UnixSocketError.timedOut {
                // The bridge explains this itself when it can answer. When even that answer does not
                // arrive, silence on a network removal still has exactly one meaning here, and
                // "Timed out connecting to Docker socket" sends the person looking at the socket.
                throw NetworkRemovalWedged(network: network.name)
            }
            self.resourceMessage = "Removed network \(network.name)."
            await self.refreshNetworks()
        }
    }

    /// Removes stopped containers and unused images. Volumes are never touched here:
    /// they hold user data and are pruned separately from the Volumes screen.
    func pruneSystem() async {
        await withResource("system", message: "Reclaiming space…") {
            let containers = try await self.client.pruneContainers()
            let images = try await self.client.pruneImages()
            let reclaimed = containers.spaceReclaimed + images.spaceReclaimed
            self.resourceMessage =
                "Removed \(containers.deleted.count) stopped containers, "
                + "reclaimed \(ByteSize.formatted(reclaimed))."
            await self.refreshContainers()
            await self.refreshImages()
            await self.refreshDiskUsage()
        }
    }

    func pruneUnusedVolumes() async {
        await withResource("volumes", message: "Removing unused volumes…") {
            let result = try await self.client.pruneVolumes()
            self.resourceMessage =
                result.deleted.isEmpty
                ? "No unused volumes to remove."
                : "Removed \(result.deleted.joined(separator: ", "))."
            await self.refreshVolumes()
            await self.refreshDiskUsage()
        }
    }

    private func withContainer(
        _ container: DockerContainerSummary,
        action: String,
        refreshList: Bool = true,
        _ body: @escaping () async throws -> Void
    ) async {
        guard isHealthy, busyContainerID == nil else { return }

        busyContainerID = container.id
        containerMessage = "\(action) \(container.name)…"
        defer { busyContainerID = nil }

        do {
            try await body()
            if refreshList {
                containerMessage = "\(container.name) is ready."
                await refreshContainers()
            } else {
                containerMessage = nil
            }
        } catch {
            containerMessage = "Container action failed: \(error)"
        }
    }

    private func withResource(
        _ id: String,
        message: String,
        _ body: @escaping () async throws -> Void
    ) async {
        guard isHealthy, busyResource == nil else { return }

        busyResource = id
        resourceMessage = message
        defer { busyResource = nil }

        do {
            try await body()
        } catch {
            resourceMessage = "Action failed: \(error)"
        }
    }
}

extension RuntimeViewModel {
    /// Fetched per selection rather than for the whole list: it is one request per image and
    /// only the inspector shows it. Cached because an image's platform cannot change.
    func loadImageDetail(for image: DockerImageSummary) async {
        guard imageDetails[image.id] == nil else { return }
        guard let reference = image.repositoryTags?.first, !reference.isEmpty else {
            imageDetails[image.id] = .some(nil)  // untagged: inspect cannot resolve it
            return
        }
        do {
            imageDetails[image.id] = .some(try await client.inspectImage(reference: reference))
        } catch {
            // A socket/runtime failure is transient. Leaving the key absent makes
            // the next selection retry instead of caching `—` for the session.
        }
    }

    func imageDetail(for image: DockerImageSummary) -> DockerImageDetail? {
        imageDetails[image.id] ?? nil
    }
}
