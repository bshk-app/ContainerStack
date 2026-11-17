import ContainerStackCore
import SwiftUI

struct SharedRuntimeSettingsSection: View {
    let settings: SharedRuntimeSettings
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controls.disabled(settings.document == nil)
            if let problem = settings.problem {
                Text(problem).foregroundStyle(.red).textSelection(.enabled)
            }
            if settings.document == nil {
                Button("Reset to Defaults") { confirmingReset = true }
                    .confirmDestructive(
                        $confirmingReset, title: "Reset shared runtimes?", confirmTitle: "Reset to Defaults",
                        message: "This replaces the file and removes your hand edits."
                    ) { settings.resetToDefaults() }
            }
            if let cause = settings.bridgeProblem {
                Text(cause).foregroundStyle(.red).textSelection(.enabled)
            }
            Text(
                "Matching sessions use one shared VM per group. Sessions in a group share one container and one trust domain."
            )
            .font(.callout).foregroundStyle(.secondary)
            SettingsHelp(
                title: "Session rules and config file",
                text:
                    "A matching docker run -i --rm uses the shared VM. A run with a TTY, mounts, ports or limits gets its own VM."
                    + "\n\nSaved immediately in \(settings.fileURL.path).")
        }
    }

    var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupToggle("mcp-catalog", subtitle: "Images mcp/*")
            groupToggle("stdio-sessions", subtitle: "Plain docker run -i --rm sessions")
            SettingsRow {
                HStack {
                    Text("Stop when idle for")
                    Spacer()
                    Picker(
                        "Stop when idle for",
                        selection: Binding(
                            get: { settings.idleMinutes ?? -1 }, set: { settings.setIdleMinutes($0) })
                    ) {
                        if settings.idleMinutes == nil {
                            Text(settings.hasEditableGroups ? "Mixed" : "No groups").tag(-1)
                        }
                        ForEach([0, 5, 10, 30, 60], id: \.self) { minutes in
                            Text(minutes == 0 ? "Never" : "\(minutes) minutes").tag(minutes)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(!settings.hasEditableGroups)
                }
            }
        }
    }

    private func groupToggle(_ name: String, subtitle: String) -> some View {
        SettingsRow {
            HStack {
                VStack(alignment: .leading) {
                    Text(name)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    name,
                    isOn: Binding(
                        get: { settings.document?.group(named: name)?.enabled ?? false },
                        set: { settings.setEnabled($0, group: name) })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(settings.document?.group(named: name) == nil)
            }
        }
    }
}
