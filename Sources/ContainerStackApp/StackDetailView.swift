import AppKit
import ContainerStackCore
import SwiftUI

struct StackDetailView: View {
    let stack: ComposeStack
    let model: RuntimeViewModel

    @State private var composeText: String?
    @State private var isApplyingEdit = false

    private var projectModel: ComposeProjectModel? {
        model.stackModels[stack.id]
    }

    private var statuses: [ComposeServiceStatus] {
        model.stackStatuses[stack.id] ?? []
    }

    private var runningCount: Int {
        statuses.filter(\.isRunning).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let message = model.stackMessage {
                    MessageCard(title: message, icon: .info, tint: .secondary)
                }

                headerCard

                if let projectModel {
                    if projectModel.services.isEmpty {
                        Text("This stack defines no services.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    ForEach(projectModel.services) { service in
                        serviceCard(service)
                    }
                } else {
                    MessageCard(
                        title: "Compose config for \(stack.name) is not available yet.",
                        icon: .fileQuestion,
                        tint: .secondary
                    )
                }

                composeFileCard
            }
            .padding(20)
        }
        .navigationTitle(stack.name)
        .task {
            await model.refreshStackConfig(stack)
            await reloadComposeText()
        }
        .onChange(of: model.stackModels[stack.id]) { _, _ in
            reloadComposeText()
        }
    }

    // MARK: Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stack.name)
                        .font(.title3.weight(.semibold))
                    Text(stack.fileURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(aggregateState)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(runningCount > 0 ? .green : .secondary)
                    if !statuses.isEmpty {
                        Text("\(runningCount)/\(statuses.count) running")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    Task { await model.upStack(stack) }
                } label: {
                    LucideLabel(title: "Up", icon: .play)
                }
                .help("Start the stack, recreating any service whose compose file changed")
                Button {
                    Task { await model.downStack(stack, removeVolumes: false) }
                } label: {
                    LucideLabel(title: "Down", icon: .square)
                }
                .help("Stop and remove the stack's containers, keeping its volumes")
                Button {
                    Task { await model.restartStack(stack) }
                } label: {
                    LucideLabel(title: "Restart", icon: .rotateCw)
                }
                // Compose's restart reuses each container's existing configuration, so an edit made
                // in the forms above is applied by Up, not by this button.
                .help("Restart the existing containers — use Up to apply compose file changes")
            }
            .disabled(model.busyStackID == stack.id || !model.isHealthy)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }

    private var aggregateState: String {
        guard !statuses.isEmpty else { return "Not inspected" }
        if runningCount == statuses.count { return "Running" }
        if runningCount == 0 { return "Stopped" }
        return "Partial"
    }

    // MARK: Service

    private func serviceCard(_ service: ComposeService) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(service.name)
                    .font(.headline)
                Spacer()
                if let image = service.image {
                    Text(image)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let restart = service.restart {
                Text("restart: \(restart)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PortsEditor(stack: stack, service: service, model: model, isApplyingEdit: $isApplyingEdit)
            VolumesEditor(stack: stack, service: service, model: model, isApplyingEdit: $isApplyingEdit)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }

    // MARK: Compose file disclosure

    private var composeFileCard: some View {
        DisclosureGroup("Compose file") {
            if let composeText {
                ScrollView {
                    Text(composeText)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(minHeight: 180, maxHeight: 400)
                .background(.black.opacity(0.88), in: .rect(cornerRadius: 10))
                .foregroundStyle(.white)
            } else {
                Text("The compose file could not be read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }

    private func reloadComposeText() {
        composeText = try? String(contentsOf: stack.fileURL, encoding: .utf8)
    }
}

// MARK: - Ports editor

private struct PortsEditor: View {
    let stack: ComposeStack
    let service: ComposeService
    let model: RuntimeViewModel
    @Binding var isApplyingEdit: Bool

    @State private var hostPort = ""
    @State private var containerPort = ""
    @State private var bindAddress = ""
    @State private var transport = "tcp"

    private var ports: [ComposePortMapping] {
        model.ports(for: stack, service: service.name)
    }

    /// The submit rules live in `ComposePortDraft` so they are covered by tests instead of only
    /// by clicking through the form.
    private var draft: ComposePortDraft {
        ComposePortDraft(
            host: hostPort, container: containerPort, bindAddress: bindAddress, transport: transport)
    }

    private var canAdd: Bool { draft.isValid }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ports")
                .font(.subheadline.weight(.semibold))

            if ports.isEmpty {
                Text("No published ports")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(ports) { port in
                        portRow(port)
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("host", text: $hostPort)
                    .frame(width: 54)
                Text("\u{2192}").foregroundStyle(.secondary)
                TextField("container", text: $containerPort)
                    .frame(width: 66)
                TextField("bind", text: $bindAddress)
                    .frame(width: 110)
                Picker("Transport", selection: $transport) {
                    Text("tcp").tag("tcp")
                    Text("udp").tag("udp")
                }
                .frame(width: 64)
                .labelsHidden()
                Button {
                    Task { await add() }
                } label: {
                    LucideLabel(title: "Add", icon: .plus)
                }
                .disabled(!canAdd || isApplyingEdit)
            }
            .font(.caption)
        }
    }

    private func portRow(_ port: ComposePortMapping) -> some View {
        HStack(spacing: 8) {
            Text(label(for: port))
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                Task { await remove(port) }
            } label: {
                LucideIcon(.circleMinus)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(isApplyingEdit)
        }
    }

    private func label(for port: ComposePortMapping) -> String {
        var hostParts: [String] = []
        if let ip = port.hostIP { hostParts.append(ip) }
        if let host = port.hostPort { hostParts.append(String(host)) }
        let hostLabel = hostParts.isEmpty ? "(auto)" : hostParts.joined(separator: ":")
        var text = "\(hostLabel) \u{2192} \(port.containerPort)"
        if let transport = port.transport { text += "/\(transport)" }
        return text
    }

    private func add() async {
        guard let mapping = draft.mapping else { return }
        isApplyingEdit = true
        defer { isApplyingEdit = false }
        await model.addPort(mapping, to: service.name, in: stack)
        hostPort = ""
        containerPort = ""
        bindAddress = ""
        transport = "tcp"
    }

    private func remove(_ mapping: ComposePortMapping) async {
        isApplyingEdit = true
        defer { isApplyingEdit = false }
        await model.removePort(mapping, from: service.name, in: stack)
    }
}

// MARK: - Volumes editor

private struct VolumesEditor: View {
    let stack: ComposeStack
    let service: ComposeService
    let model: RuntimeViewModel
    @Binding var isApplyingEdit: Bool

    @State private var source = ""
    @State private var target = ""
    @State private var isReadOnly = false

    private var volumes: [ComposeVolumeMount] {
        model.volumes(for: stack, service: service.name)
    }

    /// Same as the ports editor: the submit rules are `ComposeVolumeDraft`'s, so a relative
    /// target or a half-filled row is refused by logic that tests cover.
    private var draft: ComposeVolumeDraft {
        ComposeVolumeDraft(source: source, target: target, isReadOnly: isReadOnly)
    }

    private var canAdd: Bool { draft.isValid }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Volumes")
                .font(.subheadline.weight(.semibold))

            if volumes.isEmpty {
                Text("No volume mounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(volumes) { volume in
                        volumeRow(volume)
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("source", text: $source)
                    .frame(width: 150)
                Button("Choose\u{2026}") { choosePath() }
                    .buttonStyle(.bordered)
                TextField("target", text: $target)
                    .frame(width: 120)
                Toggle("ro", isOn: $isReadOnly)
                    .toggleStyle(.checkbox)
                Button {
                    Task { await add() }
                } label: {
                    LucideLabel(title: "Add", icon: .plus)
                }
                .disabled(!canAdd || isApplyingEdit)
            }
            .font(.caption)
        }
    }

    private func volumeRow(_ volume: ComposeVolumeMount) -> some View {
        HStack(spacing: 8) {
            Text(displaySource(volume))
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            LucideIcon(.arrowRight)
                .frame(width: 10, height: 10)
                .foregroundStyle(.secondary)
            Text(volume.target)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            if volume.isReadOnly {
                Text("ro")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15), in: Capsule())
            }
            Spacer(minLength: 8)
            Button {
                Task { await remove(volume) }
            } label: {
                LucideIcon(.circleMinus)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .disabled(isApplyingEdit)
        }
    }

    /// Compose resolves bind sources to absolute paths in its config output. For display only we
    /// fold them back to a ./relative form when they live under the project directory, so the user
    /// sees what they wrote. Removal still works because the editor matches by container target.
    private func displaySource(_ volume: ComposeVolumeMount) -> String {
        guard volume.isBindMount else { return volume.source }
        let project = stack.projectDirectory.standardizedFileURL.path
        if volume.source == project { return "./" }
        if volume.source.hasPrefix(project + "/") {
            return "./" + String(volume.source.dropFirst(project.count + 1))
        }
        return volume.source
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose a file or directory to mount."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = ComposeVolumeDraft.relativeSource(for: url, projectDirectory: stack.projectDirectory)
    }

    private func add() async {
        guard let mount = draft.mount else { return }
        isApplyingEdit = true
        defer { isApplyingEdit = false }
        await model.addVolume(mount, to: service.name, in: stack)
        source = ""
        target = ""
        isReadOnly = false
    }

    private func remove(_ mount: ComposeVolumeMount) async {
        isApplyingEdit = true
        defer { isApplyingEdit = false }
        await model.removeVolume(mount, from: service.name, in: stack)
    }
}
