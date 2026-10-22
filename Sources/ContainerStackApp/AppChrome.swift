import ContainerStackCore
import SwiftUI

struct AppTheme: Equatable {
    let windowBackground: Color
    let sidebarBackground: Color
    let hairline: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let subtleFill: Color
    let success: Color
    let destructive: Color

    static let dark = AppTheme(
        windowBackground: Color(uiHex: 0x1E1E1E),
        sidebarBackground: Color(uiHex: 0x262628),
        hairline: Color.white.opacity(0.07),
        textPrimary: Color(uiHex: 0xEBEBF5),
        textSecondary: Color(uiHex: 0xEBEBF5).opacity(0.60),
        textTertiary: Color(uiHex: 0xEBEBF5).opacity(0.35),
        subtleFill: Color.white.opacity(0.08),
        success: Color(uiHex: 0x86EFAC),
        destructive: Color(uiHex: 0xFF8F88)
    )

    static let light = AppTheme(
        windowBackground: Color(uiHex: 0xF5F5F7),
        sidebarBackground: Color(uiHex: 0xECECEE),
        hairline: Color.black.opacity(0.08),
        textPrimary: Color(uiHex: 0x1D1D1F),
        textSecondary: Color(uiHex: 0x1D1D1F).opacity(0.55),
        textTertiary: Color(uiHex: 0x1D1D1F).opacity(0.35),
        subtleFill: Color.black.opacity(0.06),
        success: Color(uiHex: 0x15692D),
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
    static let dockerItems: [DashboardDestination] = [
        .containers, .stacks, .images, .volumes, .networks, .doctor,
    ]

    static let generalItems: [DashboardDestination] = [.overview]

    /// Where the sidebar keeps the rows a user hid.
    static let hiddenItemsKey = "sidebarHiddenItems"

    // Comma-separated raw values keep the preference inspectable and need no Codable wrapper.
    static func hiddenItems(from stored: String) -> Set<DashboardDestination> {
        Set(stored.split(separator: ",").compactMap { DashboardDestination(rawValue: String($0)) })
    }

    static func storedValue(hiding hidden: Set<DashboardDestination>) -> String {
        hidden.map(\.rawValue).sorted().joined(separator: ",")
    }

    static func visibleDockerItems(hiding hidden: Set<DashboardDestination>) -> [DashboardDestination] {
        dockerItems.filter { !hidden.contains($0) }
    }
}

struct DashboardSidebar: View {
    @Binding var selection: DashboardDestination
    let model: RuntimeViewModel
    @AppStorage(DashboardDestination.hiddenItemsKey) private var hiddenRaw = ""

    private var hidden: Set<DashboardDestination> {
        DashboardDestination.hiddenItems(from: hiddenRaw)
    }

    var body: some View {
        List(selection: listSelection) {
            Section("Docker") {
                ForEach(DashboardDestination.visibleDockerItems(hiding: hidden)) { item in
                    row(item)
                }
            }
            Section("General") {
                ForEach(DashboardDestination.generalItems) { item in
                    row(item)
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Section("Show in Sidebar") {
                ForEach(DashboardDestination.dockerItems) { item in
                    Toggle(item.title, isOn: visibility(of: item))
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
                hiddenRaw = DashboardDestination.storedValue(hiding: next)
                if !show, selection == item { selection = .overview }
            }
        )
    }

    /// `List` sets its selection to nil on a click below the rows; the dashboard always shows a section.
    private var listSelection: Binding<DashboardDestination?> {
        Binding(
            get: { selection },
            set: { if let item = $0 { selection = item } }
        )
    }

    private func row(_ item: DashboardDestination) -> some View {
        let badge = badge(for: item)
        return Label {
            Text(item.title)
        } icon: {
            LucideIcon(item.lucide)
                .frame(width: 15, height: 15)
        }
        .badge(badge.isEmpty ? nil : Text(badge).monospacedDigit())
        .tag(item)
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
        // F-013: the Doctor row stays unadorned in v1; a verdict badge is a non-goal.
        case .overview, .doctor:
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
