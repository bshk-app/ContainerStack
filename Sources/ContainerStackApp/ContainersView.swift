import ContainerStackCore
import SwiftUI

struct ContainersView: View {
    let model: RuntimeViewModel
    var searchText: String = ""
    @Binding var resources: ResourceSelection
    @Environment(\.appTheme) private var theme
    @State private var collapsed = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.containersErrorMessage {
                MessageCard(title: error, icon: .triangleAlert, tint: .orange)
                    .padding(24)
            } else if filteredGroups.isEmpty {
                EmptyResourceView(
                    title: model.containers.isEmpty ? "No containers" : "No matching containers",
                    description: model.containers.isEmpty
                        ? "Run an image to see its container here. "
                            + "Stopped containers stay visible so you can restart or remove them."
                        : "Nothing matches “\(searchText)”.",
                    icon: .container
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let groups = filteredGroups
                List(selection: selection) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        ContainerGroupHeader(
                            group: group,
                            model: model,
                            isCollapsed: collapsed.contains(group.id),
                            showsTopLine: Self.showsTopLine(
                                after: index > 0 ? groups[index - 1] : nil, collapsed: collapsed)
                        ) {
                            if collapsed.contains(group.id) {
                                collapsed.remove(group.id)
                            } else {
                                collapsed.insert(group.id)
                            }
                        }
                        .listRowInsets(.horizontal, 8)
                        if !collapsed.contains(group.id) {
                            ForEach(group.containers) { container in
                                ContainerRow(
                                    container: container,
                                    model: model,
                                    onShowLogs: {
                                        model.selectedContainerID = container.id
                                        resources.showContainerLogs()
                                    }
                                )
                                .listRowInsets(.horizontal, 8)
                                .tag(container.id)
                            }
                        }
                    }
                }
                .resourceListStyle()
                .focusesOnClick()
            }

            if let containerMessage = model.containerMessage {
                MessageCard(title: containerMessage, icon: .info, tint: .secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
        }
        .background(theme.windowBackground)
    }

    static func showsTopLine(after previous: ContainerGroup?, collapsed: Set<String>) -> Bool {
        // The toolbar divider borders the first header.
        previous.map { !$0.containers.isEmpty && !collapsed.contains($0.id) } ?? false
    }

    private var filteredGroups: [ContainerGroup] {
        ResourceSearch.containerGroups(model.containerGroups, query: searchText)
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedContainerID },
            set: { model.selectedContainerID = $0 }
        )
    }
}

struct ContainerGroupHeader: View {
    let group: ContainerGroup
    let model: RuntimeViewModel
    let isCollapsed: Bool
    let showsTopLine: Bool
    let toggle: () -> Void
    @Environment(\.appTheme) private var theme

    @State private var confirmingStop = false

    var actionGroup: ContainerGroup {
        model.containerGroups.first { $0.id == group.id } ?? group
    }

    private var runningCount: Int {
        group.containers.filter(\.isRunning).count
    }

    private var title: String {
        group.sharedContainer?.sharedGroup ?? group.project ?? "Not in a stack"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    LucideIcon(isCollapsed ? .chevronRight : .chevronDown)
                        .frame(width: 8, height: 8)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 15, height: 15)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(
                        group.sharedContainer == nil
                            ? "\(runningCount)/\(group.containers.count) running" : "\(group.containers.count) sessions"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    if let parent = group.sharedContainer {
                        Text(parent.name).font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand group" : "Collapse group")
            .accessibilityLabel(isCollapsed ? "Expand group \(title)" : "Collapse group \(title)")
            .accessibilityValue("\(runningCount) of \(group.containers.count) running")
            if let parent = actionGroup.sharedContainer, actionGroup.headerActions.contains(.stop) {
                Button("Stop") { confirmingStop = true }
                    .disabled(model.busyResource != nil || !model.canMutate || !parent.isRunning)
                    .confirmDestructive(
                        $confirmingStop, title: actionGroup.stopConfirmation, confirmTitle: "Stop Group",
                        message: "The shared container stops."
                    ) { Task { await model.stopSharedContainer(parent) } }
            } else if actionGroup.headerActions.contains(.start) {

                Button {
                    Task {
                        if runningCount > 0 {
                            await model.stop(group: group)
                        } else {
                            await model.start(group: group)
                        }
                    }
                } label: {
                    LucideIcon(runningCount > 0 ? .square : .play)
                        .frame(width: 10, height: 10)
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 23, height: 21)
                }
                .buttonStyle(.plain)
                .help(runningCount > 0 ? "Stop the stack" : "Start the stack")
                .accessibilityLabel(runningCount > 0 ? "Stop stack \(title)" : "Start stack \(title)")
                .disabled(model.busyResource != nil || !model.canMutate)
            }
        }
        .frame(minHeight: 28)
        // A row, not a section header: a pinned header gets a system background
        // that also fills the area under the toolbar.
        .listRowSeparator(.hidden)
        .listRowBackground(background)
        .selectionDisabled()
        .accessibilityAddTraits(.isHeader)
    }

    private var background: some View {
        theme.groupHeaderBackground
            .overlay(alignment: .top) {
                if showsTopLine { Hairline() }
            }
            .overlay(alignment: .bottom) { Hairline() }
    }
}

extension DockerContainerSummary {
    /// The row's column fits one mapping, so it shows the first published one and a count.
    /// Docker reports the IPv4 and the IPv6 binding of a mapping separately; they fold into one.
    var rowPortLabel: String? {
        var mappings: [(label: String, type: String?)] = []
        for port in ports ?? [] {
            guard let host = port.publicPort, host != 0 else { continue }
            let label = "\(host)→\(port.privatePort.map(String.init) ?? "?")"
            if !mappings.contains(where: { $0.label == label && $0.type == port.type }) {
                mappings.append((label, port.type))
            }
        }
        guard let first = mappings.first else { return nil }
        return mappings.count > 1 ? "\(first.label) +\(mappings.count - 1)" : first.label
    }
}

struct ContainerRow: View {
    @State private var isConfirmingDelete = false
    @State private var confirmingStop = false
    let container: DockerContainerSummary
    let model: RuntimeViewModel
    var onShowLogs: () -> Void = {}
    /// For a row outside a `List`, which has no selection of its own: runs after the row
    /// selects its container.
    var onSelect: (() -> Void)?

    @Environment(\.backgroundProminence) private var prominence

    private var isBusy: Bool {
        model.isBusy(container)
    }

    var body: some View {
        ResourceRow(onSelect: selectAction) {
            HStack(spacing: 9) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(container.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(container.image ?? "unknown")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(container.rowPortLabel ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 96, alignment: .trailing)
                    .help(container.portSummary ?? "")
            }
        } actions: {
            HStack(spacing: 2) {
                RowActionButton(
                    icon: container.rowActions.contains(.stop) ? .square : .play,
                    help: container.rowActions.contains(.stop) ? "Stop" : "Start",
                    accessibilityLabel: "\(container.rowActions.contains(.stop) ? "Stop" : "Start") \(container.name)"
                ) {
                    if container.isSharedContainer {
                        confirmingStop = true
                    } else {
                        Task { await model.toggle(container: container) }
                    }
                }
                .disabled(
                    isBusy || !model.canMutate
                        || !container.allowsLifecycleAction)
                // Reading, so it survives a bridge that cannot be changed through -
                // which is when someone most wants to see why.
                RowActionButton(
                    icon: .scrollText,
                    help: "Logs",
                    accessibilityLabel: "Show logs for \(container.name)"
                ) {
                    onShowLogs()
                }
                .disabled(isBusy || !model.isHealthy)
                if container.rowActions.contains(.delete) {
                    RowActionButton(
                        icon: .trash,
                        help: "Delete",
                        accessibilityLabel: "Delete \(container.name)",
                        destructive: true
                    ) {
                        isConfirmingDelete = true
                    }
                    .disabled(isBusy || !model.canMutate)
                }
            }
            .confirmDestructive(
                $confirmingStop, title: "Stop \(container.name)?", confirmTitle: "Stop Group",
                message:
                    "This ends \(model.containers.filter { $0.isSession && $0.sessionContainerID == container.id }.count) sessions."
            ) { Task { await model.stopSharedContainer(container) } }
            .confirmDestructive(
                $isConfirmingDelete,

                title: "Delete container \(container.name)?",
                confirmTitle: "Delete Container",
                message: "A running container is stopped first. Its writable layer is deleted; named volumes are kept."
            ) {
                Task { await model.remove(container: container) }
            }
        }
    }

    private var selectAction: (() -> Void)? {
        guard let onSelect else { return nil }
        return {
            model.selectedContainerID = container.id
            onSelect()
        }
    }

    private var avatar: some View {
        ResourceAvatar(
            text: ResourceAvatar.initials(from: container.composeService ?? container.name),
            tint: ResourceAvatar.tint(for: container.name),
            isOn: container.isRunning
        )
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(container.isRunning ? Color.green : Color.gray.opacity(0.7))
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(ringColor, lineWidth: 2.5))
                .offset(x: 3, y: 3)
        }
    }

    /// The ring cuts the status dot out of the avatar, so it takes the color behind the row.
    private var ringColor: Color {
        Color(nsColor: prominence == .increased ? .selectedContentBackgroundColor : .controlBackgroundColor)
    }
}
