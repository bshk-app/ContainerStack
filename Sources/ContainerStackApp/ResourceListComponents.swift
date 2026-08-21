import ContainerStackCore
import SwiftUI

struct ResourceSplitPane<ListContent: View, Inspector: View>: View {
    @ViewBuilder var list: () -> ListContent
    @ViewBuilder var inspector: () -> Inspector
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            list()
            Rectangle()
                .fill(theme.hairline)
                .frame(width: 0.5)
            inspector()
                .frame(width: 404)
        }
    }
}

struct SelectableResourceRow<Content: View, Actions: View>: View {
    let isSelected: Bool
    let accessibilityLabel: String
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions
    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 9) {
            Button(action: action) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            actions()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(rowBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
        .onHover { isHovered = $0 }
    }

    private var rowBackground: Color {
        if isSelected { return theme.accent }
        if isHovered { return theme.rowHover }
        return .clear
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
    var pill: String? = nil
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
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Color.white.opacity(0.08),
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
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(destructive ? theme.destructive : Color.white)
                .padding(.horizontal, 12)
                .frame(height: 22)
                .background(
                    prominent ? theme.accent : theme.sidebarBackground,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(theme.hairline, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

struct RowActionButton: View {
    let icon: Lucide
    let help: String
    var destructive: Bool = false
    var isSelected: Bool = false
    let action: () -> Void
    @Environment(\.appTheme) private var theme

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
        // The glyph is an Image(nsImage:) with no text, so without this the button
        // announces only as "button" to VoiceOver. `help` is the hint, not the label.
        .accessibilityLabel(help)
    }

    private var color: Color {
        if isSelected { return destructive ? theme.destructive : Color.white.opacity(0.9) }
        return destructive ? theme.destructive.opacity(0.8) : theme.textSecondary
    }
}

struct ResourceAvatar: View {
    let text: String
    let tint: Color
    var isOn: Bool = true
    @Environment(\.appTheme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(isOn ? tint : theme.textSecondary)
            .frame(width: 27, height: 27)
            .background(
                (isOn ? tint : Color.gray).opacity(0.22),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }

    static func initials(from source: String) -> String {
        let letters = source.filter(\.isLetter)
        let seed = letters.count >= 2 ? String(letters.prefix(2)) : String(source.prefix(2))
        return seed.lowercased()
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
