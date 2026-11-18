import Foundation
import Observation
import SwiftUI

/// Stable link targets. Display names can change without breaking saved selection or onboarding links.
enum SettingsPane: String, CaseIterable, Identifiable {
    case containers
    case imageBuilder
    case sharedRuntimes
    case codingAgents

    var id: Self { self }

    var title: String {
        switch self {
        case .containers: "Containers"
        case .imageBuilder: "Image Builder"
        case .sharedRuntimes: "Shared Runtimes"
        case .codingAgents: "Command Line and Agents"
        }
    }
}

@MainActor @Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    static let selectionKey = "settings.selectedPane"

    var selection: SettingsPane {
        didSet { defaults.set(selection.rawValue, forKey: Self.selectionKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.selectionKey).flatMap(SettingsPane.init(rawValue:)) ?? .containers
    }

    /// Select before opening, including when the Settings window is already visible.
    func openSettings(pane: SettingsPane, openWindow: () -> Void) {
        selection = pane
        openWindow()
    }
}

extension OpenSettingsAction {
    /// Use `@Environment(\.openSettings) var openSettings`, then `openSettings(pane: .codingAgents)`.
    @MainActor func callAsFunction(pane: SettingsPane) {
        SettingsNavigation.shared.openSettings(pane: pane) { self() }
    }
}
