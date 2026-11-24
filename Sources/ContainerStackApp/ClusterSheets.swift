import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ClusterCreateSheet: View {
    let existing: Set<String>
    var canCreate = true
    var initialDraft = ClusterCreateDraft()
    let create: (ClusterCreateDraft) -> Void

    var body: some View {
        ClusterCreateForm(draft: initialDraft, existing: existing, canCreate: canCreate, create: create)
    }
}

private struct ClusterCreateForm: View {
    @State var draft: ClusterCreateDraft
    let existing: Set<String>
    let canCreate: Bool
    let create: (ClusterCreateDraft) -> Void
    @State private var choosesManifest = false
    @State private var manifestError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Create Cluster").font(.title3.weight(.semibold))
                .padding(16)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Name") {
                                TextField("Name", text: $draft.name, prompt: Text("dev")).labelsHidden()
                            }
                            if !draft.name.isEmpty, let error = draft.nameError(existing: existing) {
                                Text(error).font(.caption).foregroundStyle(theme.destructive)
                            }
                        }
                    }
                    SettingsRow { resources(cpus: $draft.cpus, memory: $draft.memory) }
                    workers
                    SettingsRow {
                        LabeledContent("Node image") {
                            TextField("Node image", text: $draft.nodeImage, prompt: Text("kindest/node:v1.35.5"))
                                .labelsHidden()
                        }
                    }
                    network
                    imageSharing
                    Text(
                        "Keep the total node limits within \(hostMemory) of host memory. "
                            + "An idle node with a 6 GB limit uses about 2.2 GB."
                    )
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.vertical, 10)
                    if let error = draft.optionsError ?? manifestError {
                        Text(error).font(.caption).foregroundStyle(theme.destructive)
                    }
                }
                .padding(.horizontal, 16)
            }
            Hairline()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    create(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate || draft.nameError(existing: existing) != nil || draft.optionsError != nil)
            }
            .padding(16)
        }
        .frame(width: 520, height: 540)
        .background(theme.windowBackground)
        .fileImporter(isPresented: $choosesManifest, allowedContentTypes: [.yaml, .plainText]) { result in
            switch result {
            case .success(let url):
                draft.manifestPath = url.path
                manifestError = nil
            case .failure(let error):
                manifestError = error.localizedDescription
            }
        }
    }

    private var workers: some View {
        Group {
            SettingsRow {
                HStack {
                    Text("Worker groups").fontWeight(.medium)
                    Spacer()
                    Button("Add Group", systemImage: "plus") { draft.workers.append(.init()) }
                        .disabled(draft.workers.count >= 1024)
                }
            }
            ForEach($draft.workers) { $worker in
                SettingsRow {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            LabeledContent("Count") {
                                TextField("Count", value: $worker.count, format: .number.grouping(.never))
                                    .labelsHidden()
                                    .frame(maxWidth: 100)
                            }
                            Spacer()
                            Button("Remove Worker Group", systemImage: "minus.circle") {
                                draft.workers.removeAll { $0.id == worker.id }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                        resources(cpus: $worker.cpus, memory: $worker.memory)
                    }
                }
            }
        }
    }

    private func resources(cpus: Binding<String>, memory: Binding<String>) -> some View {
        HStack(spacing: 12) {
            LabeledContent("CPUs") {
                TextField("CPUs", text: cpus, prompt: Text(String(max(ProcessInfo.processInfo.processorCount / 4, 2))))
                    .labelsHidden()
            }
            LabeledContent("Memory") {
                TextField(
                    "Memory", text: memory,
                    prompt: Text("\(max(Int(ProcessInfo.processInfo.physicalMemory >> 32), 2))g")
                )
                .labelsHidden()
            }
        }
    }

    private var network: some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Network plugin", selection: $draft.network) {
                    ForEach(ClusterCreateDraft.Network.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                if draft.network == .manifest {
                    HStack {
                        Text(draft.manifestPath.isEmpty ? "No file chosen" : draft.manifestPath)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(theme.textSecondary)
                        Spacer()
                        Button("Choose File…") { choosesManifest = true }
                    }
                }
            }
        }
    }

    private var imageSharing: some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Share my local images with the cluster", isOn: $draft.sharedImageStore)
                if draft.sharedImageStore {
                    Group {
                        Text(
                            "• Root on a node, including privileged pods and pods with a hostPath mount, can read every local image, including private images."
                        )
                        Text(
                            "• Local images take priority over registry images of the same name, for every pull policy and without pod pull secrets."
                        )
                        Text("• Nodes cannot add, change, or delete local images.")
                    }
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private var hostMemory: String {
        ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
    }
}

struct ClusterDeletion: Identifiable {
    let name: String
    let cleanup: [String]
    var id: String { name }
}

struct ClusterDeleteSheet: View {
    let deletion: ClusterDeletion
    var canDelete = true
    let delete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete cluster \(deletion.name)?").font(.headline)
            Text("Its nodes, Kubernetes objects and volumes are lost.")
            if !deletion.cleanup.isEmpty {
                Hairline()
                Text("~/.kube/config still has context \(deletion.name). Remove it with:")
                ForEach(deletion.cleanup, id: \.self) { command in
                    Text(command).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    delete()
                    dismiss()
                }
                .foregroundStyle(theme.destructive)
                .disabled(!canDelete)
            }
        }
        .padding(18)
        .frame(width: 520, alignment: .leading)
        .background(theme.windowBackground)
    }
}
