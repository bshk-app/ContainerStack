import Foundation
import Testing

@testable import ContainerStackApp

struct WelcomePolicyTests {
    private let steps = WelcomeCatalog.steps

    @Test func settingsLocationsNameTheTargetPane() throws {
        let destinations: [(String, SettingsPane)] = [
            ("resources", .containers), ("builder", .imageBuilder),
            ("shared", .sharedRuntimes), ("cli", .codingAgents),
        ]
        for (id, pane) in destinations {
            let step = try #require(steps.first { $0.id == id })
            #expect(step.destination.settingsPane == pane)
        }
        for step in steps {
            if let pane = step.destination.settingsPane {
                #expect(step.location == "Settings › " + pane.title)
            }
        }
    }

    @Test func firstLaunchShowsAllStepsWithoutNewTags() {
        let policy = WelcomePolicy(currentVersion: "0.12.0", lastVersion: nil)
        #expect(policy.mode == .first)
        #expect(policy.newSteps.isEmpty)
        #expect(policy.orderedSteps.map(\.id) == WelcomeCatalog.steps.map(\.id))
    }

    @Test func minorReleaseWithNewStepsShowsUpdate() {
        let policy = WelcomePolicy(currentVersion: "0.12.0", lastVersion: "0.10.0", steps: steps)
        #expect(policy.mode == .update)
        #expect(policy.newSteps.map(\.id) == ["cli", "shared"])
        #expect(policy.orderedSteps.prefix(2).map(\.id) == ["cli", "shared"])
        #expect(policy.orderedSteps.count == WelcomeCatalog.steps.count)
    }

    @Test func minorReleaseWithoutNewStepsDoesNotShowWelcome() {
        #expect(WelcomeCatalog.steps.first { $0.id == "cli" }?.release == "0.12.0")
        let policy = WelcomePolicy(currentVersion: "0.12.1", lastVersion: "0.12.0")
        #expect(policy.mode == nil)
        #expect(policy.newSteps.isEmpty)
    }

    @Test func majorReleaseShowsWelcomeEvenWithoutNewSteps() {
        let policy = WelcomePolicy(currentVersion: "2.0.0", lastVersion: "1.9.0", steps: steps)
        #expect(policy.mode == .update)
        #expect(policy.newSteps.isEmpty)
    }

    @Test func sameVersionAndDowngradesDoNotShowWelcome() {
        #expect(WelcomePolicy(currentVersion: "0.12.0", lastVersion: "0.12.0").mode == nil)
        #expect(WelcomePolicy(currentVersion: "0.11.0", lastVersion: "0.12.0").mode == nil)
    }

    @Test func comparesVersionsNumericallyAndExcludesFutureSteps() {
        #expect(WelcomePolicy.compare("0.10.0", "0.9.0") == .orderedDescending)
        let policy = WelcomePolicy(currentVersion: "0.10.0", lastVersion: "0.9.0", steps: steps)
        #expect(!policy.newSteps.contains { $0.id == "shared" })
        #expect(policy.newSteps.isEmpty)
        #expect(WelcomeCatalog.steps.first { $0.id == "cli" }?.release == "0.12.0")
    }

    @MainActor @Test func skipRecordsSeenVersion() throws {
        let suite = "WelcomePolicyTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = WelcomeSession(defaults: defaults, version: "0.12.0")
        #expect(session.policy.mode == .first)
        session.select(session.selectedID)
        #expect(session.visited.isEmpty)
        session.finish()
        #expect(defaults.string(forKey: "lastWelcomeVersion") == "0.12.0")
        #expect(WelcomeSession(defaults: defaults, version: "0.12.0").policy.mode == nil)
        session.select("doctor")
        #expect(session.visited.contains("socket"))
        #expect(session.selected.id == "doctor")
    }

    @Test func extractsOnlyCurrentReleaseNotes() {
        let text = "## [0.12.0] - today\n\n### Features\n\nNew feature\n\n## [0.11.0]\nOld feature"
        #expect(WelcomeRelease.notes(version: "0.12.0", changelog: text) == "### Features\n\nNew feature")
        #expect(WelcomeRelease.notes(version: "0.9.0", changelog: text).isEmpty)
        #expect(!WelcomeRelease.version.isEmpty)
        #expect(!WelcomeRelease.notes.isEmpty)
    }
}
