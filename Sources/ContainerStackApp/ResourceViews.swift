import ContainerStackCore
import SwiftUI

struct VolumesView: View {
    let model: RuntimeViewModel
    var searchText: String = ""
    @Binding var selectedVolumeName: String?
    @State private var isConfirmingPrune = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ResourceCreateBar(
                placeholder: "Volume name",
                actionTitle: "Create",
                icon: .plus,
                isBusy: model.busyResource != nil,
                isEnabled: model.canMutate
            ) { name in
                Task { await model.createVolume(named: name) }
            }

            if let error = model.volumesErrorMessage {
                MessageCard(title: error, icon: .triangleAlert, tint: .orange)
                    .padding(.horizontal, 24)
            } else if filteredVolumes.isEmpty {
                EmptyResourceView(
                    title: model.volumes.isEmpty ? "No volumes" : "No matching volumes",
                    description: model.volumes.isEmpty
                        ? "Create a volume above to persist container data between runs."
                        : "Nothing matches “\(searchText)”.",
                    icon: .hardDrive
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedVolumeName) {
                    ForEach(filteredVolumes) { volume in
                        VolumeRow(volume: volume, model: model)
                            .tag(volume.name)
                    }
                }
                .listStyle(.inset)
            }

            ResourceStatus(model: model)
        }
        .background(theme.windowBackground)
        .toolbar {
            ToolbarItem {
                Button {
                    isConfirmingPrune = true
                } label: {
                    LucideLabel(title: "Remove Unused", icon: .trash)
                }
                .disabled(!model.canMutate || model.busyResource != nil || model.volumes.isEmpty)
            }
        }
        .confirmationDialog(
            "Remove volumes that no container uses?",
            isPresented: $isConfirmingPrune,
            titleVisibility: .visible
        ) {
            Button("Remove Unused Volumes", role: .destructive) {
                Task { await model.pruneUnusedVolumes() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Volume data is deleted permanently and cannot be restored.")
        }
    }

    private var filteredVolumes: [DockerVolumeSummary] {
        model.volumes.filter { volume in
            ResourceSearch.matches(searchText, volume.name, volume.mountpoint, volume.driver)
        }
    }

}

struct NetworksView: View {
    let model: RuntimeViewModel
    var searchText: String = ""
    @Binding var selectedNetworkID: String?
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ResourceCreateBar(
                placeholder: "Network name",
                actionTitle: "Create",
                icon: .plus,
                isBusy: model.busyResource != nil,
                isEnabled: model.canMutate
            ) { name in
                Task { await model.createNetwork(named: name) }
            }

            if let error = model.networksErrorMessage {
                MessageCard(title: error, icon: .triangleAlert, tint: .orange)
                    .padding(.horizontal, 24)
            } else if filteredNetworks.isEmpty {
                EmptyResourceView(
                    title: model.networks.isEmpty ? "No networks" : "No matching networks",
                    description: model.networks.isEmpty
                        ? "Create a network above to give containers their own subnet."
                        : "Nothing matches “\(searchText)”.",
                    icon: .network
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedNetworkID) {
                    ForEach(filteredNetworks) { network in
                        NetworkRow(network: network, model: model)
                            .tag(network.id)
                    }
                }
                .listStyle(.inset)
            }

            ResourceStatus(model: model)
        }
        .background(theme.windowBackground)
    }

    private var filteredNetworks: [DockerNetworkSummary] {
        model.networks.filter { network in
            ResourceSearch.matches(searchText, network.name, network.subnet, network.driver)
        }
    }
}

private struct VolumeRow: View {
    let volume: DockerVolumeSummary
    let model: RuntimeViewModel
    @State private var isConfirmingDelete = false

    var body: some View {
        ResourceRow {
            HStack(spacing: 9) {
                ResourceAvatar(
                    text: ResourceAvatar.initials(from: volume.name),
                    tint: Color(uiHex: 0x14B8A6)
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    Text(volume.mountpoint ?? "No mountpoint")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } actions: {
            RowActionButton(
                icon: .trash,
                help: "Delete",
                accessibilityLabel: "Delete volume \(volume.name)",
                destructive: true
            ) {
                isConfirmingDelete = true
            }
            .disabled(model.busyResource != nil || !model.canMutate)
            .confirmDestructive(
                $isConfirmingDelete,
                title: "Delete volume \(volume.name)?",
                confirmTitle: "Delete Volume",
                message: "Volume data is deleted permanently and cannot be restored."
            ) {
                Task { await model.remove(volume: volume) }
            }
        }
    }
}

private struct NetworkRow: View {
    let network: DockerNetworkSummary
    let model: RuntimeViewModel
    @State private var isConfirmingDelete = false

    var body: some View {
        ResourceRow {
            HStack(spacing: 9) {
                ResourceAvatar(
                    text: ResourceAvatar.initials(from: network.name),
                    tint: Color(uiHex: 0x3B82F6)
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(network.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    Text(network.subnet ?? "No subnet")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(network.driver ?? "nat")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } actions: {
            RowActionButton(
                icon: .trash,
                help: "Delete",
                accessibilityLabel: "Delete network \(network.name)",
                destructive: true
            ) {
                isConfirmingDelete = true
            }
            .disabled(model.busyResource != nil || !model.canMutate)
            .confirmDestructive(
                $isConfirmingDelete,
                title: "Delete network \(network.name)?",
                confirmTitle: "Delete Network",
                message: "Containers attached to this network lose it until they are recreated."
            ) {
                Task { await model.remove(network: network) }
            }
        }
    }
}

struct VolumeInspector: View {
    let volume: DockerVolumeSummary?
    let model: RuntimeViewModel
    @State private var isConfirmingDelete = false

    var body: some View {
        if let volume {
            VStack(alignment: .leading, spacing: 0) {
                InspectorHeader(
                    title: volume.name,
                    subtitle: volume.mountpoint ?? "No mountpoint"
                ) {
                    InspectorAction(title: "Delete", destructive: true) {
                        isConfirmingDelete = true
                    }
                }
                .disabled(model.busyResource != nil || !model.canMutate)
                .confirmDestructive(
                    $isConfirmingDelete,
                    title: "Delete volume \(volume.name)?",
                    confirmTitle: "Delete Volume",
                    message: "Volume data is deleted permanently and cannot be restored."
                ) {
                    Task { await model.remove(volume: volume) }
                }

                // No "Used by" row: the container list carries no mounts, so it could only read "—".
                InspectorStatBlock(
                    rows: [
                        ("Driver", volume.driver ?? "local", false),
                        ("Mount", volume.mountpoint ?? "—", true),
                        ("Created", volume.createdAt ?? "—", false),
                    ]
                )
            }
        } else {
            EmptyInspector()
        }
    }
}

struct NetworkInspector: View {
    let network: DockerNetworkSummary?
    let model: RuntimeViewModel
    @State private var isConfirmingDelete = false

    var body: some View {
        if let network {
            let attached = ResourceUsage.containers(onNetwork: network.name, from: model.containers)
            VStack(alignment: .leading, spacing: 0) {
                InspectorHeader(
                    title: network.name,
                    subtitle: network.subnet ?? "No subnet",
                    pill: network.driver
                ) {
                    InspectorAction(title: "Delete", destructive: true) {
                        isConfirmingDelete = true
                    }
                }
                .disabled(model.busyResource != nil || !model.canMutate)
                .confirmDestructive(
                    $isConfirmingDelete,
                    title: "Delete network \(network.name)?",
                    confirmTitle: "Delete Network",
                    message: "Containers attached to this network lose it until they are recreated."
                ) {
                    Task { await model.remove(network: network) }
                }

                InspectorStatBlock(
                    rows: [
                        ("Driver", network.driver ?? "nat", false),
                        ("Subnet", network.subnet ?? "—", true),
                        ("Gateway", network.gateway ?? "—", true),
                        (
                            "Attached",
                            attached.isEmpty ? "—" : attached.map(\.name).joined(separator: ", "),
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

private struct ResourceStatus: View {
    let model: RuntimeViewModel

    var body: some View {
        if let resourceMessage = model.resourceMessage {
            MessageCard(title: resourceMessage, icon: .info, tint: .secondary)
                .padding(.horizontal, 24)
                .padding(.top, 8)
        }
    }
}
