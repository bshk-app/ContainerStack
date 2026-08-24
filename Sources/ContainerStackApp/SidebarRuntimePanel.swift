import ContainerStackCore
import SwiftUI

/// Compact runtime footer. Full controls live in the overflow menu so the sidebar
/// can stay a single status line.
struct SidebarRuntimePanel: View {
    let model: RuntimeViewModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
            HStack(spacing: 8) {
                indicator
                Text(footerLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(footerColor)
                    .lineLimit(1)
                    .help(footerHelp)
                Spacer(minLength: 0)
                if model.runtimeState.isDegraded {
                    Button("Restart") {
                        Task { await model.restartRuntime() }
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRestartRuntime)
                } else if !model.isHealthy {
                    Button("Start") {
                        model.startRuntime()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.runtimeState == .starting || model.isRestarting)
                }
                runtimeMenu
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
        }
        .background(theme.sidebarBackground)
    }

    private var footerLabel: String {
        if let serviceMessage = model.serviceMessage, !serviceMessage.isEmpty {
            return serviceMessage
        }
        switch model.runtimeState {
        case .running:
            return "Engine running · \(RuntimeProcessConfiguration.pinnedContainerVersion)"
        case .starting:
            return "Starting…"
        default:
            return model.statusTitle
        }
    }

    private var footerColor: Color {
        if let serviceMessage = model.serviceMessage,
            serviceMessage.localizedCaseInsensitiveContains("fail")
        {
            return .orange
        }
        if model.serviceMessage != nil {
            return theme.textPrimary
        }
        if model.conflictingDockerContext != nil || model.dockerContextEnvironmentConflict != nil {
            return .orange
        }
        return theme.textSecondary
    }

    private var footerHelp: String {
        var parts: [String] = []
        if let serviceMessage = model.serviceMessage {
            parts.append(serviceMessage)
        }
        parts.append(model.socketPath)
        if let detail = model.statusDetail ?? unhealthyMessage {
            parts.append(detail)
        }
        if let context = model.activeDockerContext {
            parts.append("Docker context: \(context)")
        }
        parts.append("LaunchAgent: \(model.launchAgentStatus)")
        return parts.joined(separator: "\n")
    }

    private var runtimeMenu: some View {
        Menu {
            Button("Refresh Now") {
                Task { await model.refresh() }
            }
            Button("Restart Runtime") {
                Task { await model.restartRuntime() }
            }
            .disabled(!model.canRestartRuntime)
            Button("Stop Runtime") {
                Task { await model.stopRuntime() }
            }
            .disabled(model.isRestarting)
            Divider()
            Toggle("Use as Docker Context", isOn: dockerContextBinding)
            if model.conflictingDockerContext != nil
                && model.dockerContextEnvironmentConflict == nil
            {
                Button("Use ContainerStack Context") {
                    Task { await model.useDockerContext() }
                }
            }
            Button("Reveal Runtime Log") {
                model.revealRuntimeLog()
            }
            Divider()
            Button("Enable at Login") {
                model.registerRuntime()
            }
            Button("Disable at Login") {
                model.unregisterRuntime()
            }
        } label: {
            LucideIcon(.ellipsis)
                .frame(width: 12, height: 12)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Runtime actions")
        .accessibilityLabel("Runtime actions")
    }

    private var unhealthyMessage: String? {
        model.isHealthy ? nil : model.runtimeMessage
    }

    private var dockerContextBinding: Binding<Bool> {
        Binding(
            get: { model.takesOverDockerContext },
            set: { model.takesOverDockerContext = $0 }
        )
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.runtimeState {
        case .starting:
            ProgressView()
                .controlSize(.small)
                .frame(width: 10, height: 10)
        case .running:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .degraded, .detached:
            Circle().fill(.yellow).frame(width: 8, height: 8)
        case .offline:
            Circle().fill(.orange).frame(width: 8, height: 8)
        case .unknown:
            Circle().fill(.secondary).frame(width: 8, height: 8)
        }
    }
}
