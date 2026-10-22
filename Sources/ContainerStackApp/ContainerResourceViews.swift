import ContainerStackCore
import SwiftUI

private struct ResourceLimitFields: View {
    @Binding var cpus: Int
    @Binding var memoryGiB: Int
    let maximumCPUs: Int
    let maximumMemoryGiB: Int

    var body: some View {
        Stepper(value: $cpus, in: 1...maximumCPUs) {
            LabeledContent("CPUs", value: cpus.formatted())
        }
        Stepper(value: $memoryGiB, in: 1...maximumMemoryGiB) {
            LabeledContent("Memory", value: "\(memoryGiB) GiB")
        }
    }
}

struct SystemSettingsView: View {
    let settings: ContainerResourceSettings

    var body: some View {
        Form {
            Section {
                ResourceLimitFields(
                    cpus: cpus,
                    memoryGiB: memoryGiB,
                    maximumCPUs: settings.maximumCPUs,
                    maximumMemoryGiB: settings.maximumMemoryGiB
                )
            } header: {
                Text("Default Container Resources")
            } footer: {
                Text("These defaults prefill the resource limits for new containers.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 210)
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
    @State private var cpus: Int
    @State private var memoryGiB: Int

    init(
        images: [String],
        settings: ContainerResourceSettings,
        onRun: @escaping (String, ContainerResourceLimits) -> Void
    ) {
        self.images = images
        self.settings = settings
        self.onRun = onRun
        _image = State(initialValue: images.first ?? "")
        _cpus = State(initialValue: settings.cpus)
        _memoryGiB = State(initialValue: settings.memoryGiB)
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
                        cpus: $cpus,
                        memoryGiB: $memoryGiB,
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
                    onRun(image, ContainerResourceSettings.limits(cpus: cpus, memoryGiB: memoryGiB))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!Self.canRun(image, from: images))
            }
        }
        .padding(24)
        .frame(width: 460, height: images.count > 1 ? 400 : 340)
    }

    nonisolated static func canRun(_ image: String, from images: [String]) -> Bool {
        images.contains(image)
    }
}
