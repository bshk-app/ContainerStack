import Foundation
import Testing

@testable import ContainerStackApp

@MainActor
struct SettingsNavigationTests {
    @Test func restoresSelectionAndFallsBackForAnUnknownPane() throws {
        let suite = "SettingsNavigationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SettingsNavigation(defaults: defaults)
        #expect(navigation.selection == .containers)
        for pane in SettingsPane.allCases {
            navigation.selection = pane
            #expect(SettingsNavigation(defaults: defaults).selection == pane)
        }
        defaults.set("removedPane", forKey: SettingsNavigation.selectionKey)
        #expect(SettingsNavigation(defaults: defaults).selection == .containers)
    }

    @Test func openAtPaneSelectsAndPersistsBeforeOpeningEveryTime() throws {
        let suite = "SettingsNavigationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SettingsNavigation(defaults: defaults)
        var opened = 0
        for pane in SettingsPane.allCases + [.codingAgents] {
            navigation.openSettings(pane: pane) {
                #expect(navigation.selection == pane)
                #expect(SettingsNavigation(defaults: defaults).selection == pane)
                opened += 1
            }
        }
        #expect(opened == SettingsPane.allCases.count + 1)
    }
}

extension SettingsNavigationTests {
    @Test func restartBarStaysVisibleForPendingChangesOrAnError() {
        #expect(!SystemSettingsView.showsRestartBar(awaitsRestart: false, problem: nil))
        #expect(SystemSettingsView.showsRestartBar(awaitsRestart: true, problem: nil))
        #expect(SystemSettingsView.showsRestartBar(awaitsRestart: false, problem: "Restart failed"))
        #expect(SystemSettingsView.showsRestartBar(awaitsRestart: true, problem: "Restart failed"))
    }

}
