import Foundation

extension DiagnosticRunner {
    static func pingSharedRuntimeSocket(_ path: String) async -> Bool {
        let client = DockerAPIClient(socketPath: path, retryPolicy: DockerRetryPolicy(maxAttempts: 1, delay: .zero))
        guard let response = try? await client.request(method: "GET", path: "/_ping", timeout: .seconds(1)) else {
            return false
        }
        return String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
    }

    func sharedRuntimesMeasurement(
        versions: VersionsMeasurement, containers: ContainersMeasurement
    ) async -> DiagnosticCheck {
        guard case .measured(_, let info) = versions, case .listed(let listed) = containers else {
            return Self.indeterminate(
                .sharedRuntimes, summary: "Shared runtimes: could not check",
                detail: "The Docker API did not answer.", took: .zero)
        }
        var orphans: [DockerContainerSummary] = []
        var sockets: [String: Bool] = [:]
        let status = SharedRuntimesStatus.parse(info: info)
        for container in listed where container.isSharedContainer {
            guard let owner = container.sharedSocket, !owner.isEmpty else {
                orphans.append(container)
                continue
            }
            if owner == sharedRuntimeSocketPath {
                if status == .notRunning { orphans.append(container) }
            } else {
                if sockets[owner] == nil { sockets[owner] = await sharedRuntimeSocketResponds(owner) }
                if sockets[owner] == false { orphans.append(container) }
            }
        }
        if !orphans.isEmpty {
            let names = orphans.map(\.name).sorted()
            // Quoting prevents shell metacharacters in a Docker name from becoming commands.
            let command =
                "docker rm -f "
                + names.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            return Self.warned(
                .sharedRuntimes,
                summary: "\(names.count) shared containers have no bridge: \(names.joined(separator: ", "))",
                detail: nil, remedy: .manual(command), took: .zero)
        }
        switch status {
        case .notRunning: return Self.passed(.sharedRuntimes, summary: "Shared runtimes: off", detail: nil, took: .zero)
        case .on: return Self.passed(.sharedRuntimes, summary: "Shared runtimes: on", detail: nil, took: .zero)
        case .starting:
            return Self.indeterminate(.sharedRuntimes, summary: "Shared runtimes: starting", detail: nil, took: .zero)
        case .off(let cause):
            return Self.warned(
                .sharedRuntimes, summary: "Shared runtimes are off: \(cause)", detail: nil, remedy: nil, took: .zero)
        }
    }
}
