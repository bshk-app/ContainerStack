import AppKit
import ContainerStackCore
import Observation
import SwiftUI

@MainActor @Observable
final class CommandLineSettings {
    let command: CStackCommand
    private let path: (() -> String)?
    private var loginPath: String?
    private(set) var state: CStackCommand.State = .missing
    private(set) var problem: String?
    private(set) var isWorking = false

    init(
        command: CStackCommand = CStackCommand(
            executable: Bundle.main.bundleURL.appending(path: "Contents/MacOS/cstack")),
        path: (() -> String)? = nil
    ) {
        self.command = command
        self.path = path
        refresh()
    }

    private var searchPath: String {
        path?() ?? loginPath ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }

    func refresh() { state = command.state(path: searchPath) }

    func refreshFromShell() async {
        guard path == nil else {
            refresh()
            return
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = await Task.detached {
            try? ProcessRunner.run(
                executablePath: shell, arguments: ["-lc", "printf '\\n__CSTACK_PATH__%s\\n' \"$PATH\""],
                output: .capture(includingStandardError: false), timeout: .seconds(2))
        }.value
        if let result, result.status == 0,
            let line = result.output.components(separatedBy: .newlines).last(where: { $0.hasPrefix("__CSTACK_PATH__") })
        {
            loginPath = String(line.dropFirst("__CSTACK_PATH__".count))
        }
        refresh()
    }

    func perform(_ operation: CStackCommand.Operation) {
        isWorking = true
        defer {
            isWorking = false
            refresh()
        }
        do {
            if operation == .replace,
                command.resolvedCommand(path: searchPath)?.standardizedFileURL != command.link.standardizedFileURL
            {
                problem =
                    "PATH selects another cstack before /usr/local/bin. Remove that PATH entry before using this app."
                return
            }
            let shell = try command.shellScript(for: operation)
            let literal = shell.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            var error: NSDictionary?
            let script = NSAppleScript(source: "do shell script \"\(literal)\" with administrator privileges")
            guard let script else {
                problem = "Could not prepare the administrator prompt."
                return
            }
            script.executeAndReturnError(&error)
            problem = error.map { $0[NSAppleScript.errorMessage] as? String ?? "The command link was not changed." }
            if problem == nil, operation != .remove, command.state(path: searchPath) == .missing {
                problem = "Installed at /usr/local/bin/cstack. Add /usr/local/bin to your PATH to use it."
            }
        } catch { problem = error.localizedDescription }
    }
}

struct CommandLineAndAgentsView: View {
    let commandLine: CommandLineSettings
    let agentSkill: AgentSkillSettings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(statusColor).frame(width: 7, height: 7).padding(.top, 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text("cstack command").fontWeight(.medium)
                    Text(statusText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                commandButton.disabled(commandLine.isWorking)
            }
            Divider()
            Toggle(
                isOn: Binding(get: { agentSkill.isEnabled }, set: { agentSkill.isEnabled = $0 })
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Link the ContainerStack skill for coding agents")
                    Text("Writes links in ~/.claude/skills and ~/.agents/skills.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!agentSkill.isAvailable)
            if !agentSkill.isAvailable {
                Text("This build of ContainerStack has no skill to link.").font(.caption).foregroundStyle(.secondary)
            }
            if agentSkill.isEnabled {
                ForEach(agentSkill.results, id: \.agent) { result in
                    Text(AgentSkillSettings.describe(result))
                        .font(.caption.monospaced())
                        .foregroundStyle(result.outcome.isFailure ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
            if let problem = commandLine.problem {
                Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .controlSize(.small)
        .task { await commandLine.refreshFromShell() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await commandLine.refreshFromShell() } }
        }
    }

    private var statusColor: Color {
        switch commandLine.state {
        case .missing: .secondary
        case .installed, .homebrew: .green
        case .other: .orange
        }
    }

    private var statusText: String {
        switch commandLine.state {
        case .missing: "Not in PATH. Install links /usr/local/bin/cstack to this app."
        case .installed: "/usr/local/bin/cstack → this app"
        case .homebrew:
            commandLine.command.homebrewLink.resolvingSymlinksInPath()
                == commandLine.command.executable.resolvingSymlinksInPath()
                ? "/opt/homebrew/bin/cstack → this app. Homebrew manages this link."
                : "/opt/homebrew/bin/cstack → another copy. Homebrew manages this link."
        case .other(let path): "cstack in PATH runs another copy: \(path)"
        }
    }

    @ViewBuilder private var commandButton: some View {
        switch commandLine.state {
        case .missing:
            Button("Install…") { commandLine.perform(.install) }.buttonStyle(.borderedProminent)
        case .installed:
            Button("Remove") { commandLine.perform(.remove) }
        case .homebrew:
            EmptyView()
        case .other:
            Button("Use This App…") { commandLine.perform(.replace) }.buttonStyle(.borderedProminent)
        }
    }
}
