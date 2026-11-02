import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@MainActor
struct AgentSkillSettingsTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "cstack-agent-skill-\(UUID().uuidString)")
    private let suiteName = "AgentSkillSettingsTests-\(UUID().uuidString)"
    private var home: URL { root.appending(path: "home") }
    private var claudeLink: URL { home.appending(path: ".claude/skills/containerstack") }

    private func links(app: String = "ContainerStack.app") throws -> AgentSkillLinks {
        let skill = root.appending(path: "\(app)/Contents/Resources/AgentSkills/containerstack")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        return AgentSkillLinks(source: skill, home: home)
    }

    private func isLinked() -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: claudeLink.path)) != nil
    }

    private func cleanUp(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// A second copy of the app quits after its settings are made, so making them must not link.
    @Test func makingTheSettingsLinksNothing() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }

        _ = AgentSkillSettings(defaults: defaults, links: try links())

        #expect(!isLinked())
    }

    @Test func applyingLinksTheSkillByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        let settings = AgentSkillSettings(defaults: defaults, links: try links())

        settings.apply()

        #expect(settings.isEnabled)
        #expect(isLinked())
        #expect(settings.results.first { $0.agent == "Claude Code" }?.outcome == .linked)
    }

    @Test func turningItOffRemovesTheLinksAndStaysOff() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        let settings = AgentSkillSettings(defaults: defaults, links: try links())
        settings.apply()

        settings.isEnabled = false

        #expect(!isLinked())
        let relaunched = AgentSkillSettings(defaults: defaults, links: try links())
        relaunched.apply()
        #expect(!relaunched.isEnabled)
        #expect(!isLinked())
    }

    /// The app moved: it remembers the path it linked, so it repoints its own link.
    @Test func aMovedAppRepointsItsOwnLink() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        AgentSkillSettings(defaults: defaults, links: try links(app: "Old/ContainerStack.app")).apply()
        let moved = try links()

        AgentSkillSettings(defaults: defaults, links: moved).apply()

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: claudeLink.path) == moved.source.path)
    }

    /// A link that could not move yet is still the app's own on the next try.
    @Test func aFailedRepointKeepsTheOldRecord() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let skills = claudeLink.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: skills.path)
            cleanUp(defaults)
        }
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        AgentSkillSettings(defaults: defaults, links: try links(app: "Old/ContainerStack.app")).apply()
        let moved = try links()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: skills.path)

        let blocked = AgentSkillSettings(defaults: defaults, links: moved)
        blocked.apply()
        #expect(blocked.results.first { $0.agent == "Claude Code" }?.outcome.isFailure == true)
        #expect(blocked.results.first { $0.agent == "Codex" }?.outcome == .linked)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: skills.path)
        AgentSkillSettings(defaults: defaults, links: moved).apply()

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: claudeLink.path) == moved.source.path)
    }

    /// `swift run` builds have no bundle, so there is no skill to link.
    @Test func aBuildWithoutTheSkillLinksNothing() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }

        let settings = AgentSkillSettings(defaults: defaults, links: nil)
        settings.apply()

        #expect(!settings.isAvailable)
        #expect(settings.results.isEmpty)
    }
}
