import ContainerStackCore
import SwiftUI

struct ImagesView: View {
    let model: RuntimeViewModel
    var searchText: String = ""
    var focusPull: Bool = false
    var onFocusConsumed: () -> Void = {}
    @FocusState private var pullFocused: Bool
    @State private var selectedImageID: String?
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ResourceCreateBar(
                placeholder: "Image reference, for example alpine:3.20",
                actionTitle: "Pull",
                icon: .download,
                isBusy: model.busyResource != nil,
                isEnabled: model.isHealthy,
                focused: $pullFocused
            ) { reference in
                Task { await model.pull(reference: reference) }
            }

            if let error = model.imagesErrorMessage {
                MessageCard(title: error, icon: .triangleAlert, tint: .orange)
                    .padding(.horizontal, 24)
            } else if filteredImages.isEmpty {
                EmptyResourceView(
                    title: model.images.isEmpty ? "No images" : "No matching images",
                    description: model.images.isEmpty
                        ? "Pull an image above, or use the Docker CLI against the ContainerStack socket."
                        : "Nothing matches “\(searchText)”.",
                    icon: .package
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ResourceSplitPane {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredImages, id: \.id) { image in
                                ImageRow(
                                    image: image,
                                    model: model,
                                    isSelected: selectedImageID == image.id
                                ) {
                                    selectedImageID = image.id
                                }
                            }
                        }
                    }
                } inspector: {
                    ImageInspector(image: selectedImage, model: model)
                }
            }

            if let resourceMessage = model.resourceMessage {
                MessageCard(title: resourceMessage, icon: .info, tint: .secondary)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }

            if let containerMessage = model.containerMessage {
                MessageCard(title: containerMessage, icon: .info, tint: .secondary)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }

            if let containerOutput = model.containerOutput {
                OutputCard(output: containerOutput)
                    .padding(24)
            }
        }
        .background(theme.windowBackground)
        .onChange(of: focusPull) { _, want in
            guard want else { return }
            pullFocused = true
            onFocusConsumed()
        }
        .onAppear {
            guard focusPull else { return }
            pullFocused = true
            onFocusConsumed()
        }
    }

    private var filteredImages: [DockerImageSummary] {
        model.images.filter { image in
            ResourceSearch.matches(
                searchText,
                image.repositoryTags?.joined(separator: " "),
                image.id,
                image.architecture
            )
        }
    }

    private var selectedImage: DockerImageSummary? {
        guard let selectedImageID else { return nil }
        return model.images.first { $0.id == selectedImageID }
    }
}

struct ImageRow: View {
    @State private var isConfirmingDelete = false
    let image: DockerImageSummary
    let model: RuntimeViewModel
    var isSelected: Bool = false
    var onSelect: () -> Void = {}
    @Environment(\.appTheme) private var theme

    private var imageName: String {
        image.repositoryTags?.first ?? ResourceIdentifier.short(image.id)
    }

    var body: some View {
        SelectableResourceRow(
            isSelected: isSelected,
            accessibilityLabel: imageName,
            action: onSelect
        ) {
            HStack(spacing: 9) {
                ResourceAvatar(
                    text: ResourceAvatar.initials(from: imageName),
                    tint: Color(uiHex: 0x8B5CF6),
                    isOn: true
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(imageName)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white : theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.78) : theme.textSecondary)
                        .lineLimit(1)
                }
            }
        } actions: {
            HStack(spacing: 2) {
                RowActionButton(
                    icon: .play,
                    help: "Run",
                    isSelected: isSelected
                ) {
                    Task { await model.run(image: imageName) }
                }
                RowActionButton(
                    icon: .trash,
                    help: "Delete",
                    destructive: true,
                    isSelected: isSelected
                ) {
                    isConfirmingDelete = true
                }
            }
            .disabled(model.busyResource != nil || model.isRunningContainer || !model.isHealthy)
            .confirmDestructive(
                $isConfirmingDelete,
                title: "Delete image \(imageName)?",
                confirmTitle: "Delete Image",
                message: "The image is deleted locally and must be pulled again to be used."
            ) {
                Task { await model.remove(image: image) }
            }
        }
    }

    private var subtitle: String {
        let platform = "\(image.operatingSystem ?? "unknown")/\(image.architecture ?? "unknown")"
        return "\(platform) · \(ByteSize.formatted(image.size))"
    }
}

private struct ImageInspector: View {
    @State private var isConfirmingDelete = false
    let image: DockerImageSummary?
    let model: RuntimeViewModel

    var body: some View {
        if let image {
            let name = image.repositoryTags?.first ?? ResourceIdentifier.short(image.id)
            let used = ResourceUsage.containers(usingImage: image, from: model.containers)
            VStack(alignment: .leading, spacing: 0) {
                InspectorHeader(title: name, subtitle: ResourceIdentifier.short(image.id)) {
                    InspectorAction(title: "Run", prominent: true) {
                        Task { await model.run(image: name) }
                    }
                    InspectorAction(title: "Delete", destructive: true) {
                        isConfirmingDelete = true
                    }
                }
                .disabled(model.busyResource != nil || model.isRunningContainer || !model.isHealthy)
                .confirmDestructive(
                    $isConfirmingDelete,
                    title: "Delete image \(name)?",
                    confirmTitle: "Delete Image",
                    message: "The image is deleted locally and must be pulled again to be used."
                ) {
                    Task { await model.remove(image: image) }
                }

                InspectorStatBlock(
                    rows: [
                        ("ID", ResourceIdentifier.short(image.id), true),
                        ("Arch", image.architecture ?? "—", true),
                        ("OS", image.operatingSystem ?? "—", false),
                        ("Size", ByteSize.formatted(image.size), false),
                        ("Created", formattedCreated(image.created), false),
                        (
                            "Used by",
                            used.isEmpty ? "—" : used.map(\.name).joined(separator: ", "),
                            false
                        ),
                    ]
                )
            }
        } else {
            EmptyInspector()
        }
    }

    private func formattedCreated(_ created: Int64?) -> String {
        guard let created else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(created))
        return date.formatted(.relative(presentation: .named))
    }
}
