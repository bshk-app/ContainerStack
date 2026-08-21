import ContainerStackCore
import SwiftUI

enum DashboardDestination: String, CaseIterable, Hashable, Identifiable {
    case overview
    case containers
    case images
    case volumes
    case networks
    case stacks

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .containers: "Containers"
        case .images: "Images"
        case .volumes: "Volumes"
        case .networks: "Networks"
        case .stacks: "Stacks"
        }
    }

}

struct DashboardView: View {
    let model: RuntimeViewModel
    @State private var selection: DashboardDestination = .containers
    @State private var isConfirmingPrune = false
    @State private var searchText = ""
    @State private var focusImagePull = false

    var body: some View {
        NavigationSplitView {
            DashboardSidebar(selection: $selection, model: model)
                .navigationSplitViewColumnWidth(min: 196, ideal: 210, max: 248)
                .navigationTitle("")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    SidebarRuntimePanel(model: model)
                }
        } detail: {
            NavigationStack {
                Group {
                    switch selection {
                    case .overview:
                        OverviewView(model: model)
                    case .containers:
                        ContainersView(model: model, searchText: searchText)
                    case .images:
                        ImagesView(
                            model: model,
                            searchText: searchText,
                            focusPull: focusImagePull,
                            onFocusConsumed: { focusImagePull = false }
                        )
                    case .volumes:
                        VolumesView(model: model, searchText: searchText)
                    case .networks:
                        NetworksView(model: model, searchText: searchText)
                    case .stacks:
                        StacksView(model: model, searchText: searchText)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(selection.title)
                .navigationSubtitle(headerSubtitle)
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
                .toolbar {
                    ToolbarItem {
                        Button("Run image") {
                            selection = .images
                            focusImagePull = true
                        }
                        .disabled(!model.isHealthy)
                    }
                    ToolbarItem {
                        Menu {
                            Button("Reclaim Space") { isConfirmingPrune = true }
                                .disabled(!model.isHealthy || model.busyResource != nil)
                            Button("Refresh") {
                                Task { await model.refresh() }
                            }
                            .disabled(model.isLoading || model.isStarting)
                        } label: {
                            LucideLabel(title: "More", icon: .ellipsis)
                        }
                    }
                }
            }
        }
        .modifier(AppThemeInjector())
        .confirmationDialog(
            "Remove stopped containers and unused images?",
            isPresented: $isConfirmingPrune,
            titleVisibility: .visible
        ) {
            Button("Reclaim Space", role: .destructive) {
                Task { await model.pruneSystem() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Volumes are not touched. Remove unused volumes from the Volumes screen.")
        }
        .task {
            await model.refresh()
            model.loadStacks()
            await model.refreshStacks()
            await model.adoptDockerContextIfEnabled()
            model.startMonitoring()
        }
        .onDisappear {
            model.stopMonitoring()
        }
        .sheet(isPresented: logsBinding) {
            ContainerLogsSheet(model: model)
        }
        .frame(minWidth: 1040, minHeight: 680)
    }

    private var headerSubtitle: String {
        switch selection {
        case .containers:
            let running = model.containers.filter(\.isRunning).count
            return "\(running) of \(model.containers.count) running"
        case .stacks:
            return "\(model.allStacks.count) stacks"
        case .images:
            return "\(model.images.count) images"
        case .volumes:
            return "\(model.volumes.count) volumes"
        case .networks:
            return "\(model.networks.count) networks"
        case .overview:
            return model.statusTitle
        }
    }

    private var logsBinding: Binding<Bool> {
        Binding(
            get: { model.logs != nil },
            set: { isPresented in
                if !isPresented {
                    model.clearLogs()
                }
            }
        )
    }
}

private struct ContainerLogsSheet: View {
    let model: RuntimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.logsContainerName.map { "Logs · \($0)" } ?? "Logs")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    model.clearLogs()
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(model.logs ?? "")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.black.opacity(0.88), in: .rect(cornerRadius: 10))
            .foregroundStyle(.white)
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 460)
    }
}

private struct OverviewView: View {
    let model: RuntimeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RuntimeHero(model: model)
                ResourceSummary(model: model)

                if let containerMessage = model.containerMessage {
                    MessageCard(title: containerMessage, icon: .info, tint: .secondary)
                }

                if let resourceMessage = model.resourceMessage {
                    MessageCard(title: resourceMessage, icon: .sparkles, tint: .secondary)
                }

                if let containerOutput = model.containerOutput {
                    OutputCard(output: containerOutput)
                }

                RecentContainers(model: model)
                RuntimeDetails(model: model)
            }
            .padding(28)
        }
    }
}

private struct RuntimeHero: View {
    let model: RuntimeViewModel

    private var tint: Color {
        switch model.runtimeState {
        case .running: .green
        case .degraded: .yellow
        case .detached: .yellow
        case .starting: .blue
        case .offline: .orange
        case .unknown: .secondary
        }
    }

    private var detail: String {
        if let statusDetail = model.statusDetail {
            return statusDetail
        }
        guard let snapshot = model.snapshot else {
            return "Apple Container with a Docker-compatible socket."
        }
        let api = snapshot.version.apiVersion ?? "unknown"
        let architecture = snapshot.info.architecture ?? "unknown"
        return "Docker API \(api) · \(architecture) · \(model.socketPath)"
    }

    var body: some View {
        HStack(spacing: 18) {
            LucideIcon(model.runtimeState.lucide)
                .frame(width: 28, height: 28)
                .foregroundStyle(tint)
                .frame(width: 56, height: 56)
                .background(tint.opacity(0.12), in: .rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 6) {
                Text(model.statusTitle)
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)
        }
        .padding(22)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }
}

private struct ResourceSummary: View {
    let model: RuntimeViewModel

    var body: some View {
        HStack(spacing: 12) {
            MetricCard(
                title: "Containers",
                value: model.containers.count,
                icon: .container,
                tint: .blue
            )
            MetricCard(
                title: "Running",
                value: model.containers.filter(\.isRunning).count,
                icon: .circlePlay,
                tint: .green
            )
            MetricCard(
                title: "Images",
                value: model.images.count,
                icon: .package,
                tint: .purple
            )
            MetricCard(
                title: "Volumes",
                value: model.volumes.count,
                icon: .hardDrive,
                tint: .teal
            )
            MetricCard(
                title: "Image storage",
                value: model.storageSummary,
                icon: .database,
                tint: .orange
            )
        }
    }
}

private struct RecentContainers: View {
    let model: RuntimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent containers")
                    .font(.headline)
                Spacer()
                Text("\(model.containers.count) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.containers.isEmpty {
                EmptyResourceView(
                    title: "No containers yet",
                    description: "Run an image from the Images section to create a container.",
                    icon: .container
                )
            } else {
                ForEach(model.containers.prefix(5)) { container in
                    ContainerRow(
                        container: container,
                        model: model,
                        onShowLogs: {
                            Task { await model.showLogs(for: container) }
                        }
                    )
                }
            }
        }
    }
}

private struct RuntimeDetails: View {
    let model: RuntimeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Engine")
                .font(.headline)

            if let snapshot = model.snapshot {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Text("Docker API").foregroundStyle(.secondary)
                        Text(snapshot.version.apiVersion ?? "Unknown")
                    }
                    GridRow {
                        Text("Engine").foregroundStyle(.secondary)
                        Text(snapshot.version.version ?? "Unknown")
                    }
                    GridRow {
                        Text("Architecture").foregroundStyle(.secondary)
                        Text(snapshot.info.architecture ?? "Unknown")
                    }
                    GridRow {
                        Text("Docker socket").foregroundStyle(.secondary)
                        Text(model.socketPath)
                            .textSelection(.enabled)
                    }
                }
                .font(.callout.monospaced())
            } else {
                Text("Start the runtime from the sidebar to inspect engine details.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
    }
}
