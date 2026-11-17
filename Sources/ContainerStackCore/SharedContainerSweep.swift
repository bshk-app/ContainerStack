import Foundation

public enum SharedContainerSweep {
    public static func leftovers(
        in containers: [DockerContainerSummary], socketPath: String, status: SharedRuntimesStatus
    ) -> [DockerContainerSummary] {
        guard status == .notRunning else { return [] }
        return containers.filter { $0.sharedSocket == socketPath }
    }

    public static func run(
        client: DockerAPIClient, socketPath: String, log: @Sendable (String) -> Void
    ) async {
        do {
            try Task.checkCancellation()
            let info = try await client.decode(DockerInfo.self, response: client.request(path: "/info"))
            try Task.checkCancellation()
            let status = SharedRuntimesStatus.parse(info: info)
            guard status == .notRunning else { return }
            let containers = try await client.listContainers(all: true)
            for container in leftovers(in: containers, socketPath: socketPath, status: status) {
                guard !Task.isCancelled else { return }
                do {
                    try await client.removeContainer(id: container.id, force: true)
                    log("Removed shared container \(container.name) left by an earlier bridge.")
                } catch is CancellationError {
                    return
                } catch {
                    log("Could not remove shared container \(container.name) left by an earlier bridge: \(error)")
                }
            }
        } catch is CancellationError {
            return
        } catch {
            log("Could not check for shared containers left by an earlier bridge: \(error)")
        }
    }

    /// A time budget includes the ping itself, so a silent socket cannot extend the 60 s wait.
    public static func waitAndRun(
        client: DockerAPIClient, socketPath: String, timeout: Duration = .seconds(60),
        log: @Sendable (String) -> Void
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            while clock.now < deadline {
                try Task.checkCancellation()
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { break }
                if let response = try? await client.request(
                    method: "GET", path: "/_ping", timeout: min(.seconds(1), remaining)),
                    String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        == "OK"
                {
                    try Task.checkCancellation()
                    await run(client: client, socketPath: socketPath, log: log)
                    return
                }
                try await Task.sleep(for: min(.seconds(1), max(.zero, clock.now.duration(to: deadline))))
            }
            log("Could not check for shared containers: the Docker socket did not answer within 60 seconds.")
        } catch {
            // The supervising bridge exited; a cancelled sweep must admit no further request.
        }
    }
}
