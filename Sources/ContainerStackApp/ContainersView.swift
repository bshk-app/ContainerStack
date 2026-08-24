import ContainerStackCore
import SwiftUI

struct ContainersView: View {
    let model: RuntimeViewModel
    var searchText: String = ""
    @Environment(\.appTheme) private var theme
    @State private var collapsed = Set<String>()
    @State private var inspectorTab = ContainerInspector.Tab.stats

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
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredGroups) { group in
                                ContainerGroupHeader(
                                    group: group,
                                    model: model,
                                    isCollapsed: collapsed.contains(group.id)
                                ) {
                                    if collapsed.contains(group.id) {
                                        collapsed.remove(group.id)
                                    } else {
                                        collapsed.insert(group.id)
                                    }
                                }
                                if !collapsed.contains(group.id) {
                                    ForEach(group.containers) { container in
                                        ContainerRow(
                                            container: container,
                                            model: model,
                                            onShowLogs: {
                                                model.selectedContainerID = container.id
                                                inspectorTab = .logs
                                            }
                                        )
                                    }
                                }
                            }
                        }
                    }
                    Rectangle()
                        .fill(theme.hairline)
                        .frame(width: 0.5)
                    ContainerInspector(
                        container: selectedContainer,
                        model: model,
                        tab: $inspectorTab
                    )
                    .frame(width: 404)
                }
            }

            if let containerMessage = model.containerMessage {
                MessageCard(title: containerMessage, icon: .info, tint: .secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
        }
        .background(theme.windowBackground)
    }

    private var filteredGroups: [ContainerGroup] {
        ResourceSearch.containerGroups(model.containerGroups, query: searchText)
    }

    private var selectedContainer: DockerContainerSummary? {
        guard let selectedContainerID = model.selectedContainerID else { return nil }
        return model.containers.first { $0.id == selectedContainerID }
    }

}

private struct ContainerGroupHeader: View {
    let group: ContainerGroup
    let model: RuntimeViewModel
    let isCollapsed: Bool
    let toggle: () -> Void
    @Environment(\.appTheme) private var theme

    private var runningCount: Int {
        group.containers.filter(\.isRunning).count
    }

    private var title: String {
        group.project ?? "Not in a stack"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                LucideIcon(isCollapsed ? .chevronRight : .chevronDown)
                    .frame(width: 8, height: 8)
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand group" : "Collapse group")
            .accessibilityLabel(isCollapsed ? "Expand group \(title)" : "Collapse group \(title)")

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("\(runningCount)/\(group.containers.count) running")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 8)
            if group.project != nil {
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
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(theme.sidebarBackground.opacity(0.72))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
    }
}

struct ContainerRow: View {
    @State private var isConfirmingDelete = false
    let container: DockerContainerSummary
    let model: RuntimeViewModel
    var onShowLogs: () -> Void = {}

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    private var isBusy: Bool {
        model.isBusy(container)
    }

    private var isSelected: Bool {
        model.selectedContainerID == container.id
    }

    var body: some View {
        HStack(spacing: 9) {
            Button {
                model.selectedContainerID = container.id
            } label: {
                HStack(spacing: 9) {
                    avatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text(container.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white : theme.textPrimary)
                            .lineLimit(1)
                        Text(container.image ?? "unknown")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(
                                isSelected ? Color.white.opacity(0.78) : theme.textSecondary
                            )
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(container.portSummary ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(
                            isSelected ? Color.white.opacity(0.78) : theme.textSecondary
                        )
                        .lineLimit(1)
                        .frame(width: 96, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(container.name)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            HStack(spacing: 2) {
                rowButton(
                    icon: container.isRunning ? .square : .play,
                    help: container.isRunning ? "Stop" : "Start",
                    accessibilityLabel: "\(container.isRunning ? "Stop" : "Start") \(container.name)"
                ) {
                    Task { await model.toggle(container: container) }
                }
                rowButton(
                    icon: .scrollText,
                    help: "Logs",
                    accessibilityLabel: "Show logs for \(container.name)"
                ) {
                    onShowLogs()
                }
                rowButton(
                    icon: .trash,
                    help: "Delete",
                    accessibilityLabel: "Delete \(container.name)",
                    destructive: true
                ) {
                    isConfirmingDelete = true
                }
            }
            .disabled(isBusy || !model.canMutate)
            .confirmDestructive(
                $isConfirmingDelete,
                title: "Delete container \(container.name)?",
                confirmTitle: "Delete Container",
                message: "A running container is stopped first. Its writable layer is deleted; named volumes are kept."
            ) {
                Task { await model.remove(container: container) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(rowBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
        .onHover { isHovered = $0 }
    }

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(tile)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(tileForeground)
                .frame(width: 27, height: 27)
                .background(tileBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Circle()
                .fill(container.isRunning ? Color.green : Color.gray.opacity(0.7))
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(rowBackground, lineWidth: 2.5))
                .offset(x: 3, y: 3)
        }
    }

    private var tile: String {
        let source = container.composeService ?? container.name
        let letters = source.filter(\.isLetter)
        let seed = letters.count >= 2 ? String(letters.prefix(2)) : String(source.prefix(2))
        return seed.lowercased()
    }

    private var tileTint: Color {
        let palette: [Color] = [
            Color(uiHex: 0x3B82F6),
            Color(uiHex: 0x8B5CF6),
            Color(uiHex: 0x06B6D4),
            Color(uiHex: 0xEF4444),
            Color(uiHex: 0xF59E0B),
            Color(uiHex: 0x22C55E),
        ]
        let index = abs(container.name.hashValue) % palette.count
        return palette[index]
    }

    private var tileBackground: Color {
        container.isRunning ? tileTint.opacity(0.22) : Color.gray.opacity(0.22)
    }

    private var tileForeground: Color {
        container.isRunning ? tileTint : theme.textSecondary
    }

    private var rowBackground: Color {
        if isSelected { return theme.accent }
        if isHovered { return theme.rowHover }
        return .clear
    }

    private func rowButton(
        icon: Lucide,
        help: String,
        accessibilityLabel: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            LucideIcon(icon)
                .frame(width: 11, height: 11)
                .foregroundStyle(glyphColor(destructive: destructive))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    private func glyphColor(destructive: Bool) -> Color {
        if isSelected { return destructive ? theme.destructive : Color.white.opacity(0.9) }
        return destructive ? theme.destructive.opacity(0.8) : theme.textSecondary
    }
}
