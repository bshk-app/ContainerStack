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
    let model: RuntimeViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var restartProblem: String?

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
            if settings.awaitsBridgeRestart {
                Section {
                    Text("Saved. New Docker API containers use these defaults after a Docker bridge restart.")
                    Text(
                        "Restarting interrupts open builds, exec sessions and runner jobs."
                            + " Running containers keep their size and continue running.")
                    Button("Restart Docker Bridge") {
                        Task {
                            restartProblem = nil
                            if await model.restartBridge() {
                                settings.reload()
                            } else {
                                restartProblem = model.runtimeFailure ?? "Docker bridge restart did not complete."
                            }
                        }
                    }
                    .disabled(!model.canRestartRuntime || settings.problem != nil)
                    if let restartProblem {
                        Text(restartProblem)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 500)
        .onAppear { settings.reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { settings.reload() }
        }
        .onChange(of: model.isRestarting) { _, restarting in
            if !restarting { settings.reload() }
        }
        .onChange(of: settings.awaitsBridgeRestart) { _, awaitsRestart in
            if !awaitsRestart { restartProblem = nil }
        }
    }

    private var cpus: Binding<Int> {
        Binding(get: { settings.cpus }, set: { settings.setCPUs($0) })
    }

    private var memoryGiB: Binding<Int> {
        Binding(get: { settings.memoryGiB }, set: { settings.setMemoryGiB($0) })
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
