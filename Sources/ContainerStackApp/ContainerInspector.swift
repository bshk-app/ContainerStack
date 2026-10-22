import AppKit
import ContainerStackCore
import SwiftUI

struct ContainerInspector: View {
    @State private var isConfirmingDelete = false
    /// "Info", not "Stats": the first tab lists the container's details and no resource usage.
    enum Tab: String, CaseIterable, Identifiable {
        case info = "Info"
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
            tabPicker
            Group {
                switch tab {
                case .info:
                    InspectorStatBlock(rows: infoRows(container))
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
        InspectorHeader(
            title: container.composeService ?? container.name,
            subtitle: container.name,
            pill: pillTitle(container),
            pillTint: pillTint(container)
        ) {
            InspectorAction(
                title: container.isRunning ? "Stop" : "Start",
                prominent: !container.isRunning
            ) {
                Task { await model.toggle(container: container) }
            }
            InspectorAction(title: "Restart") {
                Task { await model.restart(container: container) }
            }
            InspectorAction(title: "Delete", destructive: true) {
                isConfirmingDelete = true
            }
        }
        .disabled(model.isBusy(container) || !model.canMutate)
        .confirmDestructive(
            $isConfirmingDelete,
            title: "Delete container \(container.name)?",
            confirmTitle: "Delete Container",
            message: "A running container is stopped first. Its writable layer is deleted; named volumes are kept."
        ) {
            Task { await model.remove(container: container) }
        }
    }

    private var tabPicker: some View {
        Picker("Inspector section", selection: $tab) {
            ForEach(Tab.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 5)
        .padding(.bottom, 4)
    }

    private func infoRows(_ container: DockerContainerSummary) -> [(key: String, value: String, mono: Bool)] {
        [
            ("Status", container.status ?? container.state ?? "—", false),
            ("Container ID", String(container.id.prefix(12)), true),
            ("Image", container.image ?? "—", true),
            ("Command", container.command ?? "—", true),
            ("Stack", container.composeProject ?? "—", false),
            (
                "Network",
                container.networkNames.isEmpty ? "—" : container.networkNames.joined(separator: ", "),
                false
            ),
        ]
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

    private func pillTitle(_ container: DockerContainerSummary) -> String {
        let status = container.status?.lowercased() ?? ""
        if status.contains("unhealthy") { return "unhealthy" }
        if status.contains("healthy") { return "healthy" }
        return container.isRunning ? "running" : "stopped"
    }

    private func pillTint(_ container: DockerContainerSummary) -> Color? {
        switch pillTitle(container) {
        case "healthy", "running": theme.success
        case "unhealthy": theme.destructive
        default: nil
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
