import ContainerStackCore
import SwiftUI

struct SystemSettingsView: View {
    let settings: ContainerResourceSettings
    let builderSettings: ContainerResourceSettings
    let agentSkill: AgentSkillSettings
    let sharedRuntimeSettings: SharedRuntimeSettings
    let model: RuntimeViewModel
    var navigation: SettingsNavigation = .shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { .resolve(colorScheme) }
    @State private var restartProblem: String?
    @State private var builderTab = BuilderTab.resources
    @AppStorage(BuilderIdleStop.minutesKey) private var builderIdleMinutes = BuilderIdleStop.defaultMinutes

    enum BuilderTab: String, CaseIterable {
        case resources = "Resources"
        case idleStop = "Idle Stop"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 210)
                theme.hairline.frame(width: 1)
                VStack(alignment: .leading, spacing: 16) {
                    Text(navigation.selection.title).font(.title2.weight(.semibold))
                    pane
                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if Self.showsRestartBar(awaitsRestart: awaitsBridgeRestart, problem: restartProblem) {
                theme.hairline.frame(height: 1)
                restartBar
            }
        }
        .background(theme.windowBackground)
        .frame(width: 780, height: 560)
        .modifier(AppThemeInjector())
        .onAppear { reload() }
        .onChange(of: model.snapshot) { _, snapshot in
            sharedRuntimeSettings.bridgeStatus = snapshot.map { SharedRuntimesStatus.parse(info: $0.info) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
        .onChange(of: model.isRestarting) { _, restarting in
            if !restarting { reload() }
        }
    }

    private var sidebar: some View {
        List(
            selection: Binding<SettingsPane?>(
                get: { navigation.selection }, set: { if let pane = $0 { navigation.selection = pane } })
        ) {
            ForEach(SettingsPane.allCases) { pane in
                Label {
                    Text(pane.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    LucideIcon(pane.icon).frame(width: 15, height: 15)
                }
                .tag(pane)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.windowBackground)
        .focusesOnClick()
        .accessibilityLabel("Settings panes")
    }

    @ViewBuilder private var pane: some View {
        switch navigation.selection {
        case .containers:
            Text("Default Container Resources").font(.headline)
            SettingsResourceFields(settings: settings)
            note("Used by Run Container, Docker API clients and the container CLI when no limit is set.")
            SettingsHelp(
                title: "Memory and config file",
                text: settings.memoryNote + "\n\nSaved immediately in \(settings.filePath).")
        case .imageBuilder:
            builderPane
        case .sharedRuntimes:
            SharedRuntimeSettingsSection(settings: sharedRuntimeSettings)
        case .codingAgents:
            CodingAgentsSettingsPane(settings: agentSkill)
        }
    }

    private var builderPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Image Builder", selection: $builderTab) {
                ForEach(BuilderTab.allCases, id: \.self) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch builderTab {
            case .resources:
                SettingsResourceFields(settings: builderSettings)
                note("Used by container build and Docker API builds. New values apply when the builder next starts.")
                SettingsHelp(
                    title: "Buildx and config file",
                    text:
                        "Buildx uses a builder container. It gets the default container resources when buildx creates it."
                        + "\n\nSaved immediately in \(builderSettings.filePath).")
            case .idleStop:
                SettingsRow {
                    HStack {
                        Text("Stop when idle for")
                        Spacer()
                        Picker("Stop when idle for", selection: $builderIdleMinutes) {
                            ForEach(BuilderIdleStop.choices, id: \.self) { minutes in
                                Text(minutes == 0 ? "Never" : "\(minutes) minutes").tag(minutes)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                note(
                    "Stops the image builder and buildx builder containers after this time without work. The next build starts them again."
                )
                SettingsHelp(
                    title: "Why stop the builder?",
                    text: "A builder VM keeps the memory it has used until it stops. A running builder keeps its size.")
            }
        }
    }

    private var restartBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(
                Self.restartMessages(
                    resourcesAwaitRestart: settings.awaitsBridgeRestart || builderSettings.awaitsBridgeRestart,
                    sharedRuntimesAwaitRestart: sharedRuntimeSettings.awaitsBridgeRestart), id: \.self
            ) { Text($0) }
            note(
                "Restarting interrupts open builds, exec sessions and runner jobs. Running containers keep their size and continue running."
            )
            HStack {
                if let restartProblem {
                    Text(restartProblem).foregroundStyle(.red).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button("Restart Docker Bridge") {
                    Task {
                        restartProblem = nil
                        sharedRuntimeSettings.beginBridgeRestart()
                        if await model.restartBridge() {
                            reload()
                        } else {
                            restartProblem = model.runtimeFailure ?? "Docker bridge restart did not complete."
                        }
                    }
                }
                .disabled(!model.canRestartRuntime || settings.problem != nil || builderSettings.problem != nil)
            }
        }
        .font(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    static func showsRestartBar(awaitsRestart: Bool, problem: String?) -> Bool {
        awaitsRestart || problem != nil
    }

    static func restartMessages(resourcesAwaitRestart: Bool, sharedRuntimesAwaitRestart: Bool) -> [String] {
        var messages: [String] = []
        if sharedRuntimesAwaitRestart { messages.append("Shared runtimes start after a Docker bridge restart.") }
        if resourcesAwaitRestart {
            messages.append(
                "Saved. New Docker API containers and builds use these values after a Docker bridge restart.")
        }
        return messages
    }

    private var awaitsBridgeRestart: Bool {
        settings.awaitsBridgeRestart || builderSettings.awaitsBridgeRestart || sharedRuntimeSettings.awaitsBridgeRestart
    }

    private func reload() {
        settings.reload()
        builderSettings.reload()
        sharedRuntimeSettings.reload()
        sharedRuntimeSettings.bridgeStatus = model.snapshot.map { SharedRuntimesStatus.parse(info: $0.info) }
        agentSkill.apply()
    }
}

extension SettingsPane {
    fileprivate var icon: Lucide {
        switch self {
        case .containers: .container
        case .imageBuilder: .package
        case .sharedRuntimes: .layers
        case .codingAgents: .scrollText
        }
    }
}
