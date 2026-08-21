import ContainerStackCore
import SwiftUI

struct AppTheme: Equatable {
    let windowBackground: Color
    let sidebarBackground: Color
    let headerBackground: Color
    let searchFill: Color
    let hairline: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let accent: Color
    let accentTop: Color
    let accentBottom: Color
    let rowHover: Color
    let destructive: Color

    static let dark = AppTheme(
        windowBackground: Color(uiHex: 0x1E1E1E),
        sidebarBackground: Color(uiHex: 0x262628),
        headerBackground: Color(uiHex: 0x1E1E1E),
        searchFill: Color(uiHex: 0x1A1A1C),
        hairline: Color.white.opacity(0.07),
        textPrimary: Color(uiHex: 0xEBEBF5),
        textSecondary: Color(uiHex: 0xEBEBF5).opacity(0.60),
        textTertiary: Color(uiHex: 0xEBEBF5).opacity(0.35),
        accent: Color(uiHex: 0x0A84FF),
        accentTop: Color(uiHex: 0x0A8CFF),
        accentBottom: Color(uiHex: 0x0A72E0),
        rowHover: Color.white.opacity(0.06),
        destructive: Color(uiHex: 0xFF8F88)
    )

    static let light = AppTheme(
        windowBackground: Color(uiHex: 0xF5F5F7),
        sidebarBackground: Color(uiHex: 0xECECEE),
        headerBackground: Color(uiHex: 0xF5F5F7),
        searchFill: Color.white,
        hairline: Color.black.opacity(0.08),
        textPrimary: Color(uiHex: 0x1D1D1F),
        textSecondary: Color(uiHex: 0x1D1D1F).opacity(0.55),
        textTertiary: Color(uiHex: 0x1D1D1F).opacity(0.35),
        accent: Color(uiHex: 0x0A84FF),
        accentTop: Color(uiHex: 0x0A8CFF),
        accentBottom: Color(uiHex: 0x0A72E0),
        rowHover: Color.black.opacity(0.05),
        destructive: Color(uiHex: 0xD70015)
    )

    static func resolve(_ scheme: ColorScheme) -> AppTheme {
        scheme == .dark ? .dark : .light
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.dark
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

struct AppThemeInjector: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.environment(\.appTheme, .resolve(colorScheme))
    }
}

extension Color {
    init(uiHex hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension DashboardDestination {
    var sidebarTitle: String {
        switch self {
        case .overview: "Activity Monitor"
        default: title
        }
    }

    static let dockerItems: [DashboardDestination] = [
        .containers, .stacks, .images, .volumes, .networks,
    ]

    static let generalItems: [DashboardDestination] = [.overview]
}

struct DashboardSidebar: View {
    @Binding var selection: DashboardDestination
    let model: RuntimeViewModel
    @Environment(\.appTheme) private var theme
    @State private var hovered: DashboardDestination?
    // ponytail: comma-joined raw values; a Set<String> in defaults would need a Codable box for no gain
    @AppStorage("sidebarHiddenItems") private var hiddenRaw = ""

    private var hidden: Set<DashboardDestination> {
        Set(hiddenRaw.split(separator: ",").compactMap { DashboardDestination(rawValue: String($0)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Docker")
            ForEach(DashboardDestination.dockerItems.filter { !hidden.contains($0) }) { item in
                sidebarRow(item)
            }
            sectionLabel("General")
                .padding(.top, 8)
            ForEach(DashboardDestination.generalItems) { item in
                sidebarRow(item)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.sidebarBackground)
        .contextMenu {
            Section("Show in Sidebar") {
                ForEach(DashboardDestination.dockerItems) { item in
                    Toggle(item.sidebarTitle, isOn: visibility(of: item))
                }
            }
        }
    }

    private func visibility(of item: DashboardDestination) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(item) },
            set: { show in
                var next = hidden
                if show { next.remove(item) } else { next.insert(item) }
                hiddenRaw = next.map(\.rawValue).sorted().joined(separator: ",")
                if !show, selection == item { selection = .overview }
            }
        )
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 5)
    }

    private func sidebarRow(_ item: DashboardDestination) -> some View {
        let isSelected = selection == item
        let badge = badge(for: item)
        return Button {
            selection = item
        } label: {
            HStack(spacing: 8) {
                LucideIcon(item.lucide)
                    .frame(width: 14, height: 14)
                Text(item.sidebarTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(
                            isSelected ? Color.white.opacity(0.78) : theme.textTertiary
                        )
                }
            }
            .foregroundStyle(isSelected ? Color.white : theme.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                rowBackground(item, isSelected: isSelected),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hovered = hovering ? item : (hovered == item ? nil : hovered)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func rowBackground(_ item: DashboardDestination, isSelected: Bool) -> Color {
        if isSelected { return theme.accent }
        if hovered == item { return theme.rowHover }
        return .clear
    }

    private func badge(for item: DashboardDestination) -> String {
        switch item {
        case .containers:
            "\(model.containers.filter(\.isRunning).count)/\(model.containers.count)"
        case .stacks:
            "\(model.allStacks.count)"
        case .images:
            "\(model.images.count)"
        case .volumes:
            "\(model.volumes.count)"
        case .networks:
            "\(model.networks.count)"
        case .overview:
            ""
        }
    }
}

enum ResourceSearch {
    static func matches(_ query: String, _ fields: String?...) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return fields.contains { field in
            guard let field, !field.isEmpty else { return false }
            return field.localizedCaseInsensitiveContains(needle)
        }
    }

    static func containerGroups(
        _ groups: [ContainerGroup],
        query: String
    ) -> [ContainerGroup] {
        groups.compactMap { group in
            let items = group.containers.filter { container in
                matches(
                    query,
                    container.name,
                    container.image,
                    container.id,
                    container.composeService,
                    container.composeProject
                )
            }
            guard !items.isEmpty else { return nil }
            return ContainerGroup(project: group.project, containers: items)
        }
    }
}
