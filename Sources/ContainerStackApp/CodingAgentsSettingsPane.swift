import SwiftUI

struct CodingAgentsSettingsPane: View {
    let settings: AgentSkillSettings
    let commandLine: CommandLineSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CommandLineAndAgentsView(commandLine: commandLine, agentSkill: settings)
            Text("Install asks for an administrator password. You can change both later in Settings.")
                .font(.callout).foregroundStyle(.secondary)
            SettingsHelp(
                title: "How the command and skill work",
                text:
                    "The cstack command checks and controls ContainerStack from Terminal. The skill tells Codex and"
                    + " Claude Code to build and run containers with docker and cstack through ContainerStack."
                    + " The skill has its own copy of cstack, so agents work without the command.")
        }
    }
}
