import AppKit
import ContainerStackCore
import Observation
import SwiftUI

@MainActor @Observable
final class WelcomeSidebarNavigation {
    static let shared = WelcomeSidebarNavigation()
    var destination: String?
}

struct OnboardingLaunch: ViewModifier {
    let session: WelcomeSession
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            guard !session.attemptedAutomaticPresentation else { return }
            session.attemptedAutomaticPresentation = true
            if session.policy.mode != nil { openWindow(id: "welcome") }
        }
    }
}

struct OnboardingCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Welcome to ContainerStack") { openWindow(id: "welcome") }
            Button("What's New in ContainerStack") { openWindow(id: "whats-new") }
        }
    }
}

struct WelcomeWindowContent: View {
    let session: WelcomeSession
    let model: RuntimeViewModel
    let resources: ContainerResourceSettings
    let builder: ContainerResourceSettings
    let shared: SharedRuntimeSettings
    let commandLine: CommandLineSettings
    let skill: AgentSkillSettings
    @State private var doctor: DoctorViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow

    init(
        session: WelcomeSession, model: RuntimeViewModel, resources: ContainerResourceSettings,
        builder: ContainerResourceSettings, shared: SharedRuntimeSettings,
        commandLine: CommandLineSettings, skill: AgentSkillSettings
    ) {
        self.session = session
        self.model = model
        self.resources = resources
        self.builder = builder
        self.shared = shared
        self.commandLine = commandLine
        self.skill = skill
        _doctor = State(initialValue: DoctorViewModel(runtime: model))
    }

    var body: some View {
        WelcomeView(session: session) { step in
            WelcomeControls(
                step: step, model: model, resources: resources, builder: builder, shared: shared,
                commandLine: commandLine, skill: skill, doctor: doctor)
        } openLocation: { step in
            switch step.id {
            case "resources": openSettings(pane: .containers)
            case "builder": openSettings(pane: .imageBuilder)
            case "shared": openSettings(pane: .sharedRuntimes)
            case "cli": openSettings(pane: .codingAgents)
            default:
                WelcomeSidebarNavigation.shared.destination = step.id
                openWindow(id: "dashboard")
            }
        } close: {
            dismissWindow(id: "welcome")
        }
        .onAppear {
            resources.reload()
            builder.reload()
            shared.reload()
            shared.bridgeStatus = model.snapshot.map { SharedRuntimesStatus.parse(info: $0.info) }
            skill.apply()
        }
        .onDisappear { session.windowClosed() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            session.windowClosed()
        }
        .onChange(of: model.snapshot) { _, snapshot in
            shared.bridgeStatus = snapshot.map { SharedRuntimesStatus.parse(info: $0.info) }
        }
        .onChange(of: model.isRestarting) { _, restarting in
            if !restarting {
                resources.reload()
                builder.reload()
                shared.reload()
            }
        }
    }
}

struct WhatsNewWindowContent: View {
    let session: WelcomeSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        WhatsNewView(session: session) { id in
            session.select(id)
            openWindow(id: "welcome")
        }
    }
}
