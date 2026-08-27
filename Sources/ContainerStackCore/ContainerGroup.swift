import Foundation

/// Containers grouped by Compose project, with standalone containers last.
public struct ContainerGroup: Identifiable, Equatable, Sendable {
    public let project: String?
    public let containers: [DockerContainerSummary]

    public var id: String { project ?? "__standalone" }
    public var title: String { project ?? "Standalone" }

    public init(project: String?, containers: [DockerContainerSummary]) {
        self.project = project
        self.containers = containers
    }

    public static func grouped(_ containers: [DockerContainerSummary]) -> [ContainerGroup] {
        var order: [String] = []
        var buckets: [String: [DockerContainerSummary]] = [:]

        for container in containers {
            let key = container.composeProject ?? ""
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(container)
        }

        return
            order
            .sorted { lhs, rhs in
                switch (lhs.isEmpty, rhs.isEmpty) {
                case (false, true): true
                case (true, false): false
                default: lhs < rhs
                }
            }
            .map { key in
                ContainerGroup(project: key.isEmpty ? nil : key, containers: buckets[key] ?? [])
            }
    }
}
