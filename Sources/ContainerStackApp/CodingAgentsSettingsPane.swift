import SwiftUI

/// Kept separate so command-line onboarding can extend this pane.
struct CodingAgentsSettingsPane: View {
    let settings: AgentSkillSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsRow {
                HStack {
                    Text("Link the ContainerStack skill for coding agents")
                    Spacer()
                    Toggle(
                        "Link the ContainerStack skill for coding agents",
                        isOn: Binding(get: { settings.isEnabled }, set: { settings.isEnabled = $0 })
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!settings.isAvailable)
                }
            }
            if !settings.isAvailable {
                Text("This build of ContainerStack has no skill to link.").foregroundStyle(.secondary)
            }
            ForEach(settings.results, id: \.agent) { result in
                Text(AgentSkillSettings.describe(result))
                    .foregroundStyle(result.outcome.isFailure ? .red : .secondary)
                    .textSelection(.enabled)
            }
            Text("The skill tells Codex and Claude Code to use docker and cstack through ContainerStack.")
                .font(.callout).foregroundStyle(.secondary)
            SettingsHelp(
                title: "How the skill updates",
                text:
                    "The skill uses ContainerStack instead of the container CLI. It links to this app and changes when the app updates."
            )
        }
    }
}
