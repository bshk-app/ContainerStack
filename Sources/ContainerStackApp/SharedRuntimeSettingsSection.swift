import ContainerStackCore
import SwiftUI

struct SharedRuntimeSettingsSection: View {
    let settings: SharedRuntimeSettings
    @State private var confirmingReset = false

    var body: some View {
        Section {
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
        } header: {
            Text("Shared Runtimes")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "A matching docker run -i --rm runs in one shared VM. Sessions of one group share one container,"
                        + " so they are one trust domain. A run with a TTY, mounts, ports or limits gets its own VM.")
                Text("Saved immediately in \(settings.fileURL.path).")
                    .textSelection(.enabled)
            }
        }
    }

    private var controls: some View {
        Group {
            groupToggle("mcp-catalog", subtitle: "Images mcp/*")
            groupToggle("stdio-sessions", subtitle: "Plain docker run -i --rm sessions")
            Picker(
                "Stop when idle for",
                selection: Binding(
                    get: { settings.idleMinutes ?? -1 }, set: { settings.setIdleMinutes($0) })
            ) {
                if settings.idleMinutes == nil { Text(settings.hasEditableGroups ? "Mixed" : "No groups").tag(-1) }
                ForEach([0, 5, 10, 30, 60], id: \.self) { minutes in
                    Text(minutes == 0 ? "Never" : "\(minutes) minutes").tag(minutes)
                }
            }
            .disabled(!settings.hasEditableGroups)
        }
    }

    private func groupToggle(_ name: String, subtitle: String) -> some View {
        Toggle(
            isOn: Binding(
                get: { settings.document?.group(named: name)?.enabled ?? false },
                set: { settings.setEnabled($0, group: name) })
        ) {
            VStack(alignment: .leading) {
                Text(name)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(settings.document?.group(named: name) == nil)
    }
}
