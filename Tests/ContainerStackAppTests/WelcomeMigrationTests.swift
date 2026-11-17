import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@MainActor
struct WelcomeMigrationTests {
    private let suite = "WelcomeMigrationTests-\(UUID())"
    private let root = FileManager.default.temporaryDirectory.appending(path: "welcome-migration-\(UUID())")

    @Test func closingWelcomeRecordsTheVersionWithoutSkipOrDone() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = WelcomeSession(defaults: defaults, version: "0.12.0")
        #expect(defaults.string(forKey: WelcomeSession.lastVersionKey) == nil)
        session.windowClosed()
        #expect(defaults.string(forKey: WelcomeSession.lastVersionKey) == "0.12.0")
        #expect(WelcomeSession(defaults: defaults, version: "0.12.0").policy.mode == nil)
    }

    @Test func previousSkillSourcesKeyIdentifiesAnUpdateBeforeStartupWrites() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([String](), forKey: AgentSkillSettings.linkedSourcesKey)
        let earlierInstall = WelcomeSession.hasEarlierInstall(defaults: defaults, links: nil)
        #expect(earlierInstall)
        let session = WelcomeSession(defaults: defaults, version: "0.12.0", earlierInstall: earlierInstall)
        #expect(session.policy.mode == .update)
        #expect(session.policy.lastVersion == "0.10.0")
        #expect(session.policy.newSteps.map(\.id) == ["cli", "shared"])
        #expect(session.policy.orderedSteps.prefix(2).map(\.id) == ["cli", "shared"])
        #expect(defaults.string(forKey: WelcomeSession.lastVersionKey) == nil)
    }

    @Test func newInstallUsesTheSnapshotTakenBeforeThisLaunchWritesDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let earlierInstall = WelcomeSession.hasEarlierInstall(defaults: defaults, links: nil)
        #expect(!earlierInstall)
        defaults.set([String](), forKey: AgentSkillSettings.linkedSourcesKey)
        let session = WelcomeSession(defaults: defaults, version: "0.12.0", earlierInstall: earlierInstall)
        #expect(session.policy.mode == .first)
        #expect(session.policy.newSteps.isEmpty)
    }

    @Test func existingSkillLinksAlsoIdentifyAnEarlierInstall() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let links = AgentSkillLinks(
            source: root.appending(path: "ContainerStack.app/Contents/Resources/AgentSkills/containerstack"), home: root
        )
        try FileManager.default.createDirectory(at: root.appending(path: ".claude"), withIntermediateDirectories: true)
        _ = links.install()
        #expect(WelcomeSession.hasEarlierInstall(defaults: defaults, links: links))
    }

    @Test func recordedWelcomeVersionWinsOverLegacyEvidence() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("0.12.0", forKey: WelcomeSession.lastVersionKey)
        let session = WelcomeSession(defaults: defaults, version: "0.12.1", earlierInstall: true)
        #expect(session.policy.mode == nil)
        #expect(session.policy.lastVersion == "0.12.0")
    }
}
