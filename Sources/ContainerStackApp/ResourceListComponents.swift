import ContainerStackCore
import SwiftUI

/// The state the screens share with the inspector column, which is outside them on the split view.
struct ResourceSelection: Equatable {
    var containerTab = ContainerInspector.Tab.info
    var imageID: String?
    var volumeName: String?
    var networkID: String?
    var stackID: UUID?
    /// The inspector's Run sets it, and Images shows the sheet.
    var runImage: RunImage?
    var isInspectorShown = true

    mutating func showContainerLogs() {
        containerTab = .logs
        isInspectorShown = true
    }
}

extension View {
    /// Content with a minimum width wider than its split view column makes the split view loop and throw.
    func fitsSplitColumn() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ResourceInspector: View {
    let destination: DashboardDestination
    let model: RuntimeViewModel
    @Binding var selection: ResourceSelection
    @Binding var openedStackID: UUID?
    @Environment(\.appTheme) private var theme

    var body: some View {
        content
            .fitsSplitColumn()
            .background(theme.windowBackground)
    }

    @ViewBuilder private var content: some View {
        switch destination {
        case .containers:
            ContainerInspector(
                container: model.containers.first { $0.id == model.selectedContainerID },
                model: model,
                tab: $selection.containerTab
            )
        case .images:
            ImageInspector(image: model.images.first { $0.id == selection.imageID }, model: model) { image in
                selection.runImage = RunImage(image: image)
            }
        case .volumes:
            VolumeInspector(volume: model.volumes.first { $0.name == selection.volumeName }, model: model)
        case .networks:
            NetworkInspector(network: model.networks.first { $0.id == selection.networkID }, model: model)
        case .stacks:
            let stack = model.allStacks.first { $0.id == selection.stackID }
            StackInspector(stack: stack, model: model) { openedStackID = stack?.id }
        case .overview, .doctor:
            EmptyInspector()
        }
    }
}

/// A click selects a row of a SwiftUI `List` but, unlike `NSTableView`, gives the list no keyboard focus.
private struct FocusOnClick: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .simultaneousGesture(TapGesture().onEnded { isFocused = true })
    }
}

extension View {
    func focusesOnClick() -> some View {
        modifier(FocusOnClick())
    }
}

/// A resource row: the content takes the free width and the actions sit at the trailing edge.
/// Inside `List(selection:)` the list selects the row; `onSelect` serves a row outside a list.
struct ResourceRow<Content: View, Actions: View>: View {
    var onSelect: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 9) {
            if let onSelect {
                Button(action: onSelect) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
            actions()
        }
        .padding(.vertical, 3)
    }

    private var label: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

struct EmptyInspector: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        Text("No Selection")
            .font(.system(size: 13))
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.windowBackground)
    }
}

struct InspectorHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    var pill: String?
    /// Colors the pill's text and fill; `nil` draws it neutral.
    var pillTint: Color?
    @ViewBuilder var actions: () -> Actions
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if let pill {
                    Text(pill)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(pillTint ?? theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            pillTint?.opacity(0.16) ?? theme.subtleFill,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
            }
            Text(subtitle)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 5)
            HStack(spacing: 6) {
                actions()
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 8)
    }
}

struct InspectorStatBlock: View {
    let rows: [(key: String, value: String, mono: Bool)]
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.key)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 96, alignment: .leading)
                        Text(row.value)
                            .font(row.mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
                            .foregroundStyle(theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(theme.hairline).frame(height: 0.5)
                    }
                }
            }
            .background(theme.sidebarBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            )
            .padding(16)
        }
        .background(theme.windowBackground)
    }
}

struct InspectorAction: View {
    let title: String
    var prominent: Bool = false
    var destructive: Bool = false
    let action: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        let button = Button(title, role: destructive ? .destructive : nil, action: action)
            .controlSize(.small)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else if destructive {
            // macOS draws a bordered destructive button like any other, so the red title is the cue.
            button.buttonStyle(.bordered).foregroundStyle(theme.destructive)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

struct RowActionButton: View {
    let icon: Lucide
    let help: String
    let accessibilityLabel: String
    var destructive: Bool = false
    let action: () -> Void
    @Environment(\.appTheme) private var theme
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Button(action: action) {
            LucideIcon(icon)
                .frame(width: 11, height: 11)
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Red is close to invisible on the selection fill, so a selected row draws every glyph white.
    private var color: Color {
        if prominence == .increased { return Color.white.opacity(0.9) }
        return destructive ? theme.destructive.opacity(0.8) : theme.textSecondary
    }
}

struct ResourceAvatar: View {
    let text: String
    let tint: Color
    var isOn: Bool = true
    @Environment(\.appTheme) private var theme
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(foreground)
            .frame(width: 27, height: 27)
            .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            // The initials repeat the row's name, so VoiceOver would read "we, demo-webserver-1".
            .accessibilityHidden(true)
    }

    /// A tinted tile loses its letters on the selection fill, so a selected row draws it white.
    private var foreground: Color {
        if prominence == .increased { return .white }
        return isOn ? tint : theme.textSecondary
    }

    private var background: Color {
        if prominence == .increased { return Color.white.opacity(0.22) }
        return (isOn ? tint : Color.gray).opacity(0.22)
    }

    nonisolated static func initials(from source: String) -> String {
        let letters = source.filter(\.isLetter)
        let seed = letters.count >= 2 ? String(letters.prefix(2)) : String(source.prefix(2))
        return seed.lowercased()
    }

    private static let palette: [Color] = [
        Color(uiHex: 0x3B82F6),
        Color(uiHex: 0x8B5CF6),
        Color(uiHex: 0x06B6D4),
        Color(uiHex: 0xEF4444),
        Color(uiHex: 0xF59E0B),
        Color(uiHex: 0x22C55E),
    ]

    static func tint(for name: String) -> Color {
        palette[paletteIndex(for: name, count: palette.count)]
    }

    /// `String.hashValue` is seeded per process, so a tint taken from it would change on every launch.
    nonisolated static func paletteIndex(for name: String, count: Int) -> Int {
        let sum = name.unicodeScalars.reduce(UInt(0)) { $0 &+ UInt($1.value) }
        return Int(sum % UInt(count))
    }
}

enum ResourceUsage {
    static func containers(
        usingImage image: DockerImageSummary,
        from containers: [DockerContainerSummary]
    ) -> [DockerContainerSummary] {
        let tags = Set(image.repositoryTags ?? [])
        let digest = normalizedDigest(image.id)
        return containers.filter { container in
            if let imageID = container.imageID, !imageID.isEmpty {
                let candidate = normalizedDigest(imageID)
                return candidate == digest || (candidate.count == 12 && digest.hasPrefix(candidate))
            }
            if let name = container.image {
                return tags.contains(name) || normalizedDigest(name) == digest
            }
            return false
        }
    }

    private static func normalizedDigest(_ identifier: String) -> String {
        identifier.hasPrefix("sha256:")
            ? String(identifier.dropFirst("sha256:".count))
            : identifier
    }

    static func containers(
        onNetwork name: String,
        from containers: [DockerContainerSummary]
    ) -> [DockerContainerSummary] {
        containers.filter { $0.networkNames.contains(name) }
    }
}

extension View {
    /// Single-item deletes are irreversible and used to fire on one click. The bulk prune
    /// actions already gate on `confirmationDialog`; this applies the same gate per item.
    func confirmDestructive(
        _ isPresented: Binding<Bool>,
        title: String,
        confirmTitle: String,
        message: String,
        action: @escaping () -> Void
    ) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(confirmTitle, role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}
