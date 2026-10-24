import ContainerStackCore
import SwiftUI

extension DockerImageSummary {
    var displayName: String {
        repositoryTags?.first ?? ResourceIdentifier.short(id)
    }

    /// Most local images share the `docker.io/library/` prefix, so initials taken from the
    /// full reference read "do" on every row.
    var avatarInitials: String {
        ResourceAvatar.initials(from: Self.repositoryName(of: displayName))
    }

    /// `docker.io/library/redis:7-alpine` → `redis`: the last path component, without a tag or digest.
    private static func repositoryName(of reference: String) -> String {
        let withoutDigest = reference.split(separator: "@").first.map(String.init) ?? reference
        let lastComponent = withoutDigest.split(separator: "/").last.map(String.init) ?? withoutDigest
        return lastComponent.split(separator: ":").first.map(String.init) ?? lastComponent
    }
}

struct RunImage: Identifiable, Equatable {
    let image: String
    var id: String { image }
}

struct ImagesView: View {
    let model: RuntimeViewModel
    let resourceSettings: ContainerResourceSettings
    var searchText: String = ""
    @Binding var selectedImageID: String?
    @Binding var runImage: RunImage?
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ResourceCreateBar(
                placeholder: "Image reference, for example alpine:3.20",
                actionTitle: "Pull",
                icon: .download,
                isBusy: model.busyResource != nil,
                isEnabled: model.canMutate
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
                List(selection: $selectedImageID) {
                    ForEach(filteredImages, id: \.id) { image in
                        ImageRow(
                            image: image,
                            model: model,
                            onRun: { runImage = RunImage(image: image.displayName) }
                        )
                        .tag(image.id)
                    }
                }
                .listStyle(.inset)
                .focusesOnClick()
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
        .sheet(item: $runImage) { request in
            RunContainerSheet(images: [request.image], settings: resourceSettings) { image, limits in
                Task { await model.run(image: image, resourceLimits: limits) }
            }
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

}

struct ImageRow: View {
    @State private var isConfirmingDelete = false
    let image: DockerImageSummary
    let model: RuntimeViewModel
    var onRun: () -> Void = {}

    var body: some View {
        ResourceRow {
            HStack(spacing: 9) {
                ResourceAvatar(text: image.avatarInitials, tint: Color(uiHex: 0x8B5CF6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(image.displayName)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } actions: {
            HStack(spacing: 2) {
                RowActionButton(
                    icon: .play,
                    help: "Run",
                    accessibilityLabel: "Run \(image.displayName)"
                ) {
                    onRun()
                }
                RowActionButton(
                    icon: .trash,
                    help: "Delete",
                    accessibilityLabel: "Delete \(image.displayName)",
                    destructive: true
                ) {
                    isConfirmingDelete = true
                }
            }
            .disabled(model.busyResource != nil || model.isRunningContainer || !model.canMutate)
            .confirmDestructive(
                $isConfirmingDelete,
                title: "Delete image \(image.displayName)?",
                confirmTitle: "Delete Image",
                message: "The image is deleted locally and must be pulled again to be used."
            ) {
                Task { await model.remove(image: image) }
            }
        }
    }

    private var subtitle: String {
        // The platform used to be asserted here from /images/json, which never carries it,
        // so every row read "unknown/unknown". It lives in the inspector now.
        ByteSize.formatted(image.size)
    }
}

struct ImageInspector: View {
    @State private var isConfirmingDelete = false
    let image: DockerImageSummary?
    let model: RuntimeViewModel
    let onRun: (String) -> Void

    private var detail: DockerImageDetail? {
        image.flatMap { model.imageDetail(for: $0) }
    }

    var body: some View {
        content
            .task(id: image?.id) {
                if let image {
                    await model.loadImageDetail(for: image)
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let image {
            let name = image.displayName
            let used = ResourceUsage.containers(usingImage: image, from: model.containers)
            VStack(alignment: .leading, spacing: 0) {
                InspectorHeader(title: name, subtitle: ResourceIdentifier.short(image.id)) {
                    InspectorAction(title: "Run", prominent: true) {
                        onRun(name)
                    }
                    InspectorAction(title: "Delete", destructive: true) {
                        isConfirmingDelete = true
                    }
                }
                .disabled(model.busyResource != nil || model.isRunningContainer || !model.canMutate)
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
                        ("Arch", detail?.architecture ?? "—", true),
                        ("OS", detail?.operatingSystem ?? "—", false),
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
        ImageCreatedLabel.text(for: created)
    }
}

enum ImageCreatedLabel {
    /// `Created` is absent for some images — Apple's `vminit` reports it in neither
    /// `/images/json` nor image inspect, and `/images/json` sends `0` rather than omitting
    /// the key. Rendering the epoch claimed "56 years ago", so non-positive means unknown.
    static func text(for created: Int64?) -> String {
        guard let created, created > 0 else { return "—" }
        return Date(timeIntervalSince1970: TimeInterval(created))
            .formatted(.relative(presentation: .named))
    }
}
