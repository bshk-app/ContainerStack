import AppKit
import ContainerStackCore
import SwiftUI

struct ClusterInspector: View {
    let model: ClusterSectionModel
    let name: String?
    @State private var addsContext = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        if let name, model.availability == .capable, model.inventoryError == nil,
            let row = model.rows.first(where: { $0.id == name })
        {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    InspectorHeader(
                        title: row.id, subtitle: row.cluster.apiEndpoint?.absoluteString ?? "No API endpoint"
                    ) {}
                    sectionTitle("Nodes")
                    ForEach(row.cluster.nodes, id: \.name) { node in
                        let status = row.cluster.nodeStatuses.first { $0.name == node.name }
                        ClusterNodeView(
                            node: node, status: status, missing: row.missing.contains(node.name), model: model)
                    }
                    Text("Reach a NodePort Service at http://<node IP>:<node port>")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.vertical, 10)
                    Hairline()
                    sectionTitle("Kubeconfig")
                    ForEach(ClusterKubeconfig.copyLines(name: name), id: \.self) { line in
                        ClusterCopyLine(line: line)
                    }
                    InspectorAction(title: "Add to ~/.kube/config…") {
                        addsContext = model.preflightAdd(name: name)
                    }
                    .disabled(!model.canWrite(name: name))
                    .padding(.top, 10)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .background(theme.windowBackground)
            .alert("Add context \(name)?", isPresented: $addsContext) {
                Button("Cancel", role: .cancel) {}
                Button("Add Context") { Task { await model.write(name: name, target: .userDefault) } }
            } message: {
                Text(
                    "container rewrites the whole file ~/.kube/config. Keys it does not know are lost, "
                        + "and it changes the layout. Make a backup first.")
            }
            .id(row.cluster.creationDate)
        } else {
            EmptyInspector()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline).padding(.vertical, 8)
    }
}

private struct ClusterNodeView: View {
    let node: KubernetesCluster.Node
    let status: KubernetesCluster.NodeStatus?
    let missing: Bool
    let model: ClusterSectionModel
    @State private var detail: DockerContainerDetail?
    @Environment(\.appTheme) private var theme

    var body: some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(node.name).fontWeight(.medium)
                    Spacer()
                    Text(missing ? "Missing" : status?.status.capitalized ?? "Unknown")
                        .foregroundStyle(missing ? theme.destructive : theme.textSecondary)
                }
                Text(node.roles.joined(separator: ", ")).foregroundStyle(theme.textSecondary)
                LabeledContent("IP", value: status?.addresses?.joined(separator: ", ") ?? "—")
                LabeledContent("CPUs", value: detail?.cpuLimit?.formatted() ?? "—")
                LabeledContent(
                    "Memory",
                    value: detail?.memoryLimitBytes.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory)
                    } ?? "—")
            }
            .font(.caption)
        }
        .task(id: missing) {
            detail = missing ? nil : await model.nodeDetails(name: node.name)
        }
    }
}

private struct ClusterCopyLine: View {
    let line: String

    var body: some View {
        SettingsRow {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(line, forType: .string)
                } label: {
                    Image(systemName: "document.on.document")
                }
                .buttonStyle(.borderless)
                .help("Copy command")
                .accessibilityLabel("Copy \(line)")
            }
        }
    }
}
