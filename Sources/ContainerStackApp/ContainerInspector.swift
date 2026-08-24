import AppKit
import ContainerStackCore
import SwiftUI

struct ContainerInspector: View {
    @State private var isConfirmingDelete = false
    enum Tab: String, CaseIterable, Identifiable {
        case stats = "Stats"
        case logs = "Logs"
        case ports = "Ports"
        var id: Self { self }
    }

    let container: DockerContainerSummary?
    let model: RuntimeViewModel
    @Binding var tab: Tab
    @Environment(\.appTheme) private var theme

    var body: some View {
        Group {
            if let container {
                populated(container)
                    .id(container.id)
            } else {
                Text("No Selection")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.windowBackground)
    }

    private func populated(_ container: DockerContainerSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(container)
            tabBar
            Group {
                switch tab {
                case .stats:
                    statsList(container)
                case .logs:
                    InspectorLogsView(container: container, model: model)
                case .ports:
                    portsList(container)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ container: DockerContainerSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(container.composeService ?? container.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(pillTitle(container))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(pillForeground(container))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        pillBackground(container),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
            }
            Text(container.name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .padding(.top, 5)
            HStack(spacing: 6) {
                actionButton(
                    container.isRunning ? "Stop" : "Start",
                    prominent: !container.isRunning
                ) {
                    Task { await model.toggle(container: container) }
                }
                actionButton("Restart") {
                    Task { await model.restart(container: container) }
                }
                actionButton("Delete", destructive: true) {
                    isConfirmingDelete = true
                }
            }
            .padding(.top, 12)
            .disabled(model.isBusy(container) || !model.isHealthy)
            .confirmDestructive(
                $isConfirmingDelete,
                title: "Delete container \(container.name)?",
                confirmTitle: "Delete Container",
                message: "A running container is stopped first. Its writable layer is deleted; named volumes are kept."
            ) {
                Task { await model.remove(container: container) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12))
                        .foregroundStyle(tab == item ? theme.textPrimary : theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 21)
                        .background(
                            tab == item ? theme.searchFill : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.sidebarBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.hairline, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 4)
    }

    private func statsList(_ container: DockerContainerSummary) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                statRow("Status", container.status ?? container.state ?? "—")
                statRow("Container ID", String(container.id.prefix(12)), mono: true)
                statRow("Image", container.image ?? "—", mono: true)
                statRow("Command", container.command ?? "—", mono: true)
                statRow("Stack", container.composeProject ?? "—")
                statRow(
                    "Network",
                    container.networkNames.isEmpty ? "—" : container.networkNames.joined(separator: ", ")
                )
            }
            .background(theme.sidebarBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            )
            .padding(16)
        }
    }

    private func statRow(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
    }

    private func portsList(_ container: DockerContainerSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ports")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                if let ports = container.ports, !ports.isEmpty {
                    ForEach(Array(ports.enumerated()), id: \.offset) { _, port in
                        portRow(port)
                    }
                } else {
                    Text("No published ports")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.vertical, 8)
                }
            }
            .padding(16)
        }
    }

    private func portRow(_ port: DockerPort) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(port.publicPort == nil ? theme.textTertiary : Color.green)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(port.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                Text(port.publicPort == nil ? "container only" : "published")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 8)
            if let publicPort = port.publicPort {
                Button("Open") {
                    if let url = URL(string: "http://127.0.0.1:\(publicPort)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(theme.sidebarBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.hairline, lineWidth: 0.5)
        )
    }

    private func actionButton(
        _ title: String,
        prominent: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(destructive ? theme.destructive : Color.white)
                .padding(.horizontal, 12)
                .frame(height: 22)
                .background(
                    prominent
                        ? theme.accent
                        : theme.sidebarBackground,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(theme.hairline, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func pillTitle(_ container: DockerContainerSummary) -> String {
        let status = container.status?.lowercased() ?? ""
        if status.contains("unhealthy") { return "unhealthy" }
        if status.contains("healthy") { return "healthy" }
        return container.isRunning ? "running" : "stopped"
    }

    private func pillForeground(_ container: DockerContainerSummary) -> Color {
        switch pillTitle(container) {
        case "healthy", "running":
            return Color(uiHex: 0x86EFAC)
        case "unhealthy":
            return theme.destructive
        default:
            return theme.textSecondary
        }
    }

    private func pillBackground(_ container: DockerContainerSummary) -> Color {
        switch pillTitle(container) {
        case "healthy", "running":
            return Color.green.opacity(0.18)
        case "unhealthy":
            return theme.destructive.opacity(0.16)
        default:
            return Color.white.opacity(0.08)
        }
    }
}

/// Isolated so `@State` cannot leak across container selections even if the parent is reused.
private struct InspectorLogsView: View {
    let container: DockerContainerSummary
    let model: RuntimeViewModel
    @Environment(\.appTheme) private var theme
    @State private var text: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading && text == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(text ?? "No log output.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(16)
            }
        }
        .task(id: container.id) {
            isLoading = true
            text = await model.inlineLogs(for: container)
            isLoading = false
        }
    }
}
