import ContainerStackCore
import SwiftUI

struct KubernetesView: View {
    let model: ClusterSectionModel
    let searchText: String
    @Binding var selection: String?
    @State private var createsCluster = false
    @State private var deletion: ClusterDeletion?
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.availability {
            case .noClusterStart:
                status(ClusterCapability.noClusterStart.description)
                Spacer()
            case .runtimeNotRunning:
                status(ClusterCapability.runtimeNotRunning.description)
                list(allowsActions: false)
                    .opacity(0.48)
                    .allowsHitTesting(false)
            default:
                if let error = model.inventoryError {
                    status(error)
                    Spacer()
                } else if model.availability == .capable {
                    createBar
                    if let error = model.actionError { status(error) }
                    list(allowsActions: model.canAct)
                } else {
                    ProgressView("Loading clusters…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.windowBackground)
        .sheet(isPresented: $createsCluster) {
            ClusterCreateSheet(existing: model.names, canCreate: model.canAct) { draft in
                selection = draft.name
                Task { await model.create(draft) }
            }
        }
        .sheet(item: $deletion) { deletion in
            ClusterDeleteSheet(deletion: deletion, canDelete: model.canAct) {
                Task { await model.perform(.delete, name: deletion.name) }
            }
        }
    }

    private var createBar: some View {
        HStack {
            Spacer()
            Button {
                createsCluster = true
            } label: {
                LucideLabel(title: "Create Cluster…", icon: .plus)
            }
            .disabled(!model.canAct)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Hairline() }
    }

    @ViewBuilder
    private func list(allowsActions: Bool) -> some View {
        let rows = model.rows.filter {
            ResourceSearch.matches(
                searchText, $0.id, $0.cluster.kubernetesVersion, $0.cluster.apiEndpoint?.absoluteString)
        }
        let pending = model.activity.flatMap { activity in
            !model.names.contains(activity.name) && ResourceSearch.matches(searchText, activity.name) ? activity : nil
        }
        if rows.isEmpty && pending == nil {
            if model.availability == .capable {
                EmptyResourceView(
                    title: model.names.isEmpty ? "No clusters" : "No matching clusters",
                    description: model.names.isEmpty ? "Create a local Kubernetes cluster." : "Try a different search.",
                    icon: .network
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List(selection: $selection) {
                ForEach(rows) { row in
                    KubernetesRow(row: row, allowsActions: allowsActions) { action in
                        if action == .delete {
                            deletion = ClusterDeletion(name: row.id, cleanup: model.cleanupCommands(for: row))
                        } else {
                            Task { await model.perform(action, name: row.id) }
                        }
                    } write: {
                        Task { await model.write(name: row.id, target: .managed) }
                    }
                    .tag(row.id)
                    .listRowInsets(.horizontal, 8)
                }
                if let pending {
                    HStack {
                        Text(pending.name).fontWeight(.medium)
                        Spacer()
                        ProgressView().controlSize(.small)
                        Text("\(pending.operation.rawValue)…").foregroundStyle(.secondary)
                    }
                    .padding(4)
                }
            }
            .resourceListStyle()
            .focusesOnClick()
        }
    }

    private func status(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(theme.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .overlay(alignment: .bottom) { Hairline() }
    }
}

struct KubernetesRow: View {
    let row: ClusterRow
    let allowsActions: Bool
    let perform: (ClusterAction) -> Void
    let write: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        ResourceRow {
            HStack(alignment: .top, spacing: 9) {
                ResourceAvatar(
                    text: ResourceAvatar.initials(from: row.id), tint: ResourceAvatar.tint(for: row.id),
                    isOn: row.cluster.state == .running)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(row.id).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(row.state.label).font(.caption).foregroundStyle(stateColor)
                    }
                    Text(summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let error = row.error {
                        Text(error).font(.caption).foregroundStyle(theme.destructive)
                            .textSelection(.enabled)
                    }
                    if row.localNetworkHint {
                        Text(ClusterAPIReady.localNetworkHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !row.hasContext {
                        Text("No kubeconfig context").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } actions: {
            if allowsActions {
                HStack(spacing: 3) {
                    if !row.hasContext && row.canWriteKubeconfig && !row.state.actions.isEmpty {
                        Button("Write Kubeconfig", action: write).controlSize(.small)
                    }
                    ForEach(row.state.actions, id: \.self) { action in
                        RowActionButton(
                            icon: actionIcon(action), help: action.rawValue,
                            accessibilityLabel: "\(action.rawValue) cluster \(row.id)",
                            destructive: action == .delete
                        ) { perform(action) }
                    }
                }
            }
        }
    }

    private var summary: String {
        let count = row.cluster.nodes.count
        let nodes = count == 1 ? "1 node" : "\(count) nodes"
        return
            "\(row.cluster.kubernetesVersion) · \(nodes) · \(row.cluster.apiEndpoint?.absoluteString ?? "No API endpoint")"
    }

    private var stateColor: Color {
        switch row.state {
        case .running: theme.success
        case .missing, .startFailed: theme.destructive
        default: .secondary
        }
    }

    private func actionIcon(_ action: ClusterAction) -> Lucide {
        switch action {
        case .start: .play
        case .stop: .square
        case .restart: .rotateCw
        case .delete: .trash
        }
    }
}
