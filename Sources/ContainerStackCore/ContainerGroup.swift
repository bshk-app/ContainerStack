import Foundation

public struct ContainerGroup: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case compose(project: String)
        case shared(container: DockerContainerSummary)
        case standalone
    }

    public let kind: Kind
    public let containers: [DockerContainerSummary]
    public var project: String? {
        if case .compose(let project) = kind { return project }
        return nil
    }
    public var sharedContainer: DockerContainerSummary? {
        if case .shared(let container) = kind { return container }
        return nil
    }
    public var id: String {
        switch kind {
        case .compose(let project): "compose:\(project)"
        case .shared(let container): "shared:\(container.id)"
        case .standalone: "__standalone"
        }
    }
    public var title: String { sharedContainer?.sharedGroup ?? project ?? "Standalone" }
    public var stopConfirmation: String { "Stop \(title)? This ends \(containers.count) sessions." }
    public var headerActions: [ContainerAction] {
        switch kind {
        case .shared: [.stop]
        case .compose: [.start, .stop]
        case .standalone: []
        }
    }

    public init(project: String?, containers: [DockerContainerSummary]) {
        self.init(kind: project.map { .compose(project: $0) } ?? .standalone, containers: containers)
    }

    public init(kind: Kind, containers: [DockerContainerSummary]) {
        self.kind = kind
        self.containers = containers
    }

    public static func grouped(_ containers: [DockerContainerSummary]) -> [ContainerGroup] {
        let shared = containers.filter(\.isSharedContainer).sorted {
            ($0.sharedGroup ?? "", $0.name, $0.id) < ($1.sharedGroup ?? "", $1.name, $1.id)
        }
        let sharedIDs = Set(shared.map(\.id))
        let ordinary = containers.filter { !$0.isSharedContainer && !$0.isSession }
        let projects = Dictionary(
            grouping: ordinary.filter { $0.composeProject != nil }, by: { $0.composeProject ?? "" })
        var result = projects.keys.sorted().map { ContainerGroup(project: $0, containers: projects[$0] ?? []) }
        result += shared.map { parent in
            ContainerGroup(
                kind: .shared(container: parent),
                containers: containers.filter {
                    $0.isSession && $0.sessionContainerID == parent.id
                })
        }
        let standalone = containers.filter {
            !$0.isSharedContainer
                && ($0.isSession ? !sharedIDs.contains($0.sessionContainerID ?? "") : $0.composeProject == nil)
        }
        if !standalone.isEmpty { result.append(ContainerGroup(project: nil, containers: standalone)) }
        return result
    }
}

public enum ContainerAction: Equatable, Sendable {
    case start, stop, logs, restart, delete
}

extension DockerContainerSummary {
    public var allowsLifecycleAction: Bool { (!isSession && !isSharedContainer) || isRunning }

    public var rowActions: [ContainerAction] {
        if isSession || isSharedContainer { return [.stop, .logs] }
        return [isRunning ? .stop : .start, .logs, .delete]
    }
    public var inspectorActions: [ContainerAction] {
        if isSession || isSharedContainer { return [.stop] }
        return [isRunning ? .stop : .start, .restart, .delete]
    }
}
