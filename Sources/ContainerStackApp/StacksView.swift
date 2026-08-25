import AppKit
import ContainerStackCore
import SwiftUI
import UniformTypeIdentifiers

struct StacksView: View {
    let model: RuntimeViewModel
    var searchText: String = ""

    @State private var showingNewStack = false
    @State private var newStackName = ""
    @State private var newStackDirectory: URL?
    @State private var selectedStackID: UUID?
    @State private var openedStackID: UUID?
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.stacksErrorMessage {
                MessageCard(title: error, icon: .triangleAlert, tint: .orange)
                    .padding(24)
            } else if filteredStacks.isEmpty {
                EmptyResourceView(
                    title: model.allStacks.isEmpty ? "No stacks" : "No matching stacks",
                    description: model.allStacks.isEmpty
                        ? "A stack is a Docker Compose project you can run and edit from "
                            + "here. Add an existing compose file or start a new one."
                        : "Nothing matches “\(searchText)”.",
                    icon: .layers
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ResourceSplitPane {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredStacks) { stack in
                                StackRow(
                                    stack: stack,
                                    model: model,
                                    isSelected: selectedStackID == stack.id
                                ) {
                                    selectedStackID = stack.id
                                }
                                .contextMenu {
                                    Button("Unregister (keeps the file)") {
                                        model.removeStack(stack)
                                    }
                                }
                            }
                        }
                    }
                } inspector: {
                    StackInspector(
                        stack: selectedStack,
                        model: model,
                        onEdit: { openedStackID = selectedStack?.id }
                    )
                }
            }

            if let stackMessage = model.stackMessage {
                MessageCard(title: stackMessage, icon: .info, tint: .secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
        }
        .background(theme.windowBackground)
        .navigationDestination(item: $openedStackID) { id in
            if let stack = model.allStacks.first(where: { $0.id == id }) {
                StackDetailView(stack: stack, model: model)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Add Existing\u{2026}") { pickExistingFile() }
            }
            ToolbarItem {
                Button("New Stack\u{2026}") { showingNewStack = true }
            }
        }
        .sheet(isPresented: $showingNewStack) {
            NewStackSheet(name: $newStackName, directory: $newStackDirectory) {
                guard let directory = newStackDirectory else { return }
                Task {
                    await model.createStack(named: newStackName, in: directory)
                }
                showingNewStack = false
                newStackName = ""
                newStackDirectory = nil
            }
        }
        .task {
            await model.refreshStacks()
        }
    }

    private var filteredStacks: [ComposeStack] {
        model.allStacks.filter { stack in
            ResourceSearch.matches(searchText, stack.name, stack.fileURL.path)
        }
    }

    private var selectedStack: ComposeStack? {
        guard let selectedStackID else { return nil }
        return model.allStacks.first { $0.id == selectedStackID }
    }

    private func pickExistingFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        let yamlTypes = [
            UTType(filenameExtension: "yml"),
            UTType(filenameExtension: "yaml"),
        ].compactMap { $0 }
        panel.allowedContentTypes = yamlTypes.isEmpty ? [.plainText] : yamlTypes
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addStack(fileURL: url) }
    }
}

private struct StackRow: View {
    let stack: ComposeStack
    let model: RuntimeViewModel
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.appTheme) private var theme

    private var statuses: [ComposeServiceStatus] {
        model.stackStatuses[stack.id] ?? []
    }

    private var runningCount: Int {
        statuses.filter(\.isRunning).count
    }

    private var isBusy: Bool {
        model.busyStackID == stack.id
    }

    var body: some View {
        SelectableResourceRow(
            isSelected: isSelected,
            accessibilityLabel: stack.name,
            action: onSelect
        ) {
            HStack(spacing: 9) {
                LucideIcon(.layers)
                    .frame(width: 13, height: 13)
                    .foregroundStyle(isSelected ? Color.white : Color(uiHex: 0x3B82F6))
                    .frame(width: 27, height: 27)
                    .background(
                        Color(uiHex: 0x3B82F6).opacity(isSelected ? 0.28 : 0.22),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(stack.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : theme.textPrimary)
                        .lineLimit(1)
                    Text(stack.fileURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.78) : theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(statuses.isEmpty ? "—" : "\(runningCount)/\(statuses.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.78) : theme.textSecondary)
            }
        } actions: {
            HStack(spacing: 2) {
                RowActionButton(
                    icon: .play,
                    help: "Start stack",
                    accessibilityLabel: "Start stack \(stack.name)",
                    isSelected: isSelected
                ) {
                    Task { await model.upStack(stack) }
                }
                RowActionButton(
                    icon: .square,
                    help: "Stop stack",
                    accessibilityLabel: "Stop stack \(stack.name)",
                    isSelected: isSelected
                ) {
                    Task { await model.downStack(stack, removeVolumes: false) }
                }
            }
            .disabled(isBusy || !model.canMutate)
        }
    }
}

struct StackActionAvailability: Equatable {
    let canControl: Bool
    let canEdit: Bool

    init(isHealthy: Bool, isBusy: Bool) {
        canControl = isHealthy && !isBusy
        canEdit = !isBusy
    }
}

private struct StackInspector: View {
    let stack: ComposeStack?
    let model: RuntimeViewModel
    let onEdit: () -> Void

    private var statuses: [ComposeServiceStatus] {
        guard let stack else { return [] }
        return model.stackStatuses[stack.id] ?? []
    }

    var body: some View {
        if let stack {
            VStack(alignment: .leading, spacing: 0) {
                InspectorHeader(
                    title: stack.name,
                    subtitle: stack.fileURL.path,
                    pill: statuses.isEmpty
                        ? nil : "\(statuses.filter(\.isRunning).count)/\(statuses.count)"
                ) {
                    let availability = StackActionAvailability(
                        // Control is a mutation; editing the compose file stays
                        // available offline through `canEdit`, which ignores this.
                        isHealthy: model.canMutate,
                        isBusy: model.busyStackID != nil
                    )
                    InspectorAction(title: "Start", prominent: true) {
                        Task { await model.upStack(stack) }
                    }
                    .disabled(!availability.canControl)
                    InspectorAction(title: "Stop") {
                        Task { await model.downStack(stack, removeVolumes: false) }
                    }
                    .disabled(!availability.canControl)
                    InspectorAction(title: "Edit") {
                        onEdit()
                    }
                    .disabled(!availability.canEdit)
                }

                InspectorStatBlock(
                    rows: [
                        ("File", stack.fileURL.lastPathComponent, true),
                        ("Directory", stack.projectDirectory.path, true),
                        (
                            "Services",
                            statuses.isEmpty
                                ? "—"
                                : statuses.map(\.name).joined(separator: ", "),
                            false
                        ),
                        (
                            "Status",
                            statuses.isEmpty
                                ? "—"
                                : statuses.map { "\($0.name) \($0.state)" }.joined(separator: ", "),
                            false
                        ),
                    ]
                )
            }
        } else {
            EmptyInspector()
        }
    }
}

private struct NewStackSheet: View {
    @Binding var name: String
    @Binding var directory: URL?
    let onCreate: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Stack")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("my-stack", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Directory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(directory?.path ?? "No directory chosen")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose\u{2026}") { directory = pickDirectory() }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty || directory == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func submit() {
        guard !trimmedName.isEmpty, directory != nil else { return }
        onCreate()
    }

    private func pickDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
