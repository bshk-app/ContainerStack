import ContainerStackCore
import SwiftUI

private struct ResourceLimitFields: View {
    @Binding var cpus: Int
    @Binding var memoryGiB: Int
    let memoryDescription: String
    let maximumCPUs: Int
    let maximumMemoryGiB: Int

    var body: some View {
        Stepper(value: $cpus, in: 1...maximumCPUs) {
            LabeledContent("CPUs", value: cpus.formatted())
        }
        Stepper(value: $memoryGiB, in: 1...maximumMemoryGiB) {
            LabeledContent("Memory", value: memoryDescription)
        }
    }
}

struct SystemSettingsView: View {
    let settings: ContainerResourceSettings
    let builderSettings: ContainerResourceSettings
    let agentSkill: AgentSkillSettings
    let model: RuntimeViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var restartProblem: String?
    @AppStorage(BuilderIdleStop.minutesKey) private var builderIdleMinutes = BuilderIdleStop.defaultMinutes

    var body: some View {
        Form {
            Section {
                ResourceLimitFields(
                    cpus: cpus,
                    memoryGiB: memoryGiB,
                    memoryDescription: settings.memoryDescription,
                    maximumCPUs: settings.maximumCPUs,
                    maximumMemoryGiB: settings.maximumMemoryGiB
                )
                .disabled(settings.problem != nil)
                if let problem = settings.problem {
                    Text(problem)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Default Container Resources")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Used by Run Container, Docker API clients and the container CLI when no limit is specified.")
                    Text(settings.memoryNote)
                    Text("Saved immediately in \(settings.filePath).")
                        .textSelection(.enabled)
                }
            }
            Section {
                ResourceLimitFields(
                    cpus: builderCPUs,
                    memoryGiB: builderMemoryGiB,
                    memoryDescription: builderSettings.memoryDescription,
                    maximumCPUs: builderSettings.maximumCPUs,
                    maximumMemoryGiB: builderSettings.maximumMemoryGiB
                )
                .disabled(builderSettings.problem != nil)
                Picker("Stop when idle for", selection: $builderIdleMinutes) {
                    ForEach(BuilderIdleStop.choices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Never" : "\(minutes) minutes").tag(minutes)
                    }
                }
                if let problem = builderSettings.problem {
                    Text(problem)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Image Builder")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "CPUs and memory are for the image builder that container build and Docker API builds"
                            + " use. A docker build through buildx runs in a builder container, which gets the"
                            + " default container resources when buildx makes it.")
                    Text("A running builder keeps its size. New values apply the next time it starts.")
                    Text(
                        "A builder VM keeps the memory it has used until it stops. ContainerStack stops the image"
                            + " builder and buildx builder containers that do no work for the time above. The"
                            + " next build starts them again.")
                }
            }
            Section {
                Toggle("Link the ContainerStack skill for coding agents", isOn: agentSkillEnabled)
                    .disabled(!agentSkill.isAvailable)
                if !agentSkill.isAvailable {
                    Text("This build of ContainerStack has no skill to link.")
                        .foregroundStyle(.secondary)
                }
                ForEach(agentSkill.results, id: \.agent) { result in
                    Text(AgentSkillSettings.describe(result))
                        .foregroundStyle(result.outcome.isFailure ? .red : .secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Coding Agents")
            } footer: {
                Text(
                    "The skill tells Codex and Claude Code to build and run containers with docker and cstack"
                        + " through ContainerStack, not with the container CLI. It links to this app, so it"
                        + " changes when the app updates.")
            }
            if awaitsBridgeRestart {
                Section {
                    Text("Saved. New Docker API containers and builds use these values after a Docker bridge restart.")
                    Text(
                        "Restarting interrupts open builds, exec sessions and runner jobs."
                            + " Running containers keep their size and continue running.")
                    Button("Restart Docker Bridge") {
                        Task {
                            restartProblem = nil
                            if await model.restartBridge() {
                                reload()
                            } else {
                                restartProblem = model.runtimeFailure ?? "Docker bridge restart did not complete."
                            }
                        }
                    }
                    .disabled(!model.canRestartRuntime || settings.problem != nil || builderSettings.problem != nil)
                    if let restartProblem {
                        Text(restartProblem)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 700)
        .onAppear { reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
        .onChange(of: model.isRestarting) { _, restarting in
            if !restarting { reload() }
        }
        .onChange(of: awaitsBridgeRestart) { _, awaitsRestart in
            if !awaitsRestart { restartProblem = nil }
        }
    }

    private var awaitsBridgeRestart: Bool {
        settings.awaitsBridgeRestart || builderSettings.awaitsBridgeRestart
    }

    private func reload() {
        settings.reload()
        builderSettings.reload()
        agentSkill.apply()
    }

    private var cpus: Binding<Int> {
        Binding(get: { settings.cpus }, set: { settings.setCPUs($0) })
    }

    private var memoryGiB: Binding<Int> {
        Binding(get: { settings.memoryGiB }, set: { settings.setMemoryGiB($0) })
    }

    private var agentSkillEnabled: Binding<Bool> {
        Binding(get: { agentSkill.isEnabled }, set: { agentSkill.isEnabled = $0 })
    }

    private var builderCPUs: Binding<Int> {
        Binding(get: { builderSettings.cpus }, set: { builderSettings.setCPUs($0) })
    }

    private var builderMemoryGiB: Binding<Int> {
        Binding(get: { builderSettings.memoryGiB }, set: { builderSettings.setMemoryGiB($0) })
    }
}

struct RunContainerSheet: View {
    /// The images to choose from. With one image the caller already chose it, so no picker shows.
    let images: [String]
    let settings: ContainerResourceSettings
    let onRun: (String, ContainerResourceLimits) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: String
    @State private var resources: ContainerResourceSelection

    init(
        images: [String],
        settings: ContainerResourceSettings,
        onRun: @escaping (String, ContainerResourceLimits) -> Void
    ) {
        self.images = images
        self.settings = settings
        self.onRun = onRun
        _image = State(initialValue: images.first ?? "")
        _resources = State(initialValue: ContainerResourceSelection(settings: settings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Run Container")
                    .font(.title2.weight(.semibold))
                if images.count == 1 {
                    Text(image)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Form {
                if images.count > 1 {
                    Section {
                        Picker("Image", selection: $image) {
                            ForEach(images, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                    }
                }
                Section("Resources") {
                    ResourceLimitFields(
                        cpus: $resources.cpus,
                        memoryGiB: $resources.memoryGiB,
                        memoryDescription: resources.memoryDescription,
                        maximumCPUs: settings.maximumCPUs,
                        maximumMemoryGiB: settings.maximumMemoryGiB
                    )
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") {
                    onRun(image, resources.limits)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!Self.canRun(image, from: images))
            }
        }
        .padding(24)
        .frame(width: 460, height: images.count > 1 ? 400 : 340)
        .onAppear { resources = ContainerResourceSelection.load(settings: settings) }
    }

    nonisolated static func canRun(_ image: String, from images: [String]) -> Bool {
        images.contains(image)
    }
}
