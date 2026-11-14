import Foundation
import Testing

@testable import ContainerStackCore

@Suite("The ContainerStack skill is linked into the agents' skill folders")
struct AgentSkillLinksTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "cstack-skill-\(UUID().uuidString)")
    private var home: URL { root.appending(path: "home") }
    private var codexLink: URL { home.appending(path: ".agents/skills/containerstack") }
    private var claudeLink: URL { home.appending(path: ".claude/skills/containerstack") }

    /// A skill folder at the place it has in a bundle.
    private func bundledSkill(in app: String) throws -> URL {
        let skill = root.appending(path: "\(app)/Contents/Resources/AgentSkills/containerstack")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: containerstack\n---\n".write(
            to: skill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        return skill
    }

    private func makeAgentHomes(_ names: String...) throws {
        for name in names {
            try FileManager.default.createDirectory(at: home.appending(path: name), withIntermediateDirectories: true)
        }
    }

    private func destination(of link: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    }

    private func outcomes(_ results: [AgentSkillLinks.Result]) -> [String: AgentSkillLinks.Outcome] {
        Dictionary(uniqueKeysWithValues: results.map { ($0.agent, $0.outcome) })
    }

    @Test func linksTheSkillForEachInstalledAgent() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = try bundledSkill(in: "ContainerStack.app")
        try makeAgentHomes(".codex", ".claude")

        let results = AgentSkillLinks(source: skill, home: home).install()

        #expect(outcomes(results) == ["Codex": .linked, "Claude Code": .linked])
        #expect(destination(of: codexLink) == skill.path)
        #expect(destination(of: claudeLink) == skill.path)
    }

    /// No agent folder means no agent: ContainerStack does not make `~/.claude` for a user who
    /// has no Claude Code.
    @Test func leavesAnAgentThatIsNotInstalled() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = try bundledSkill(in: "ContainerStack.app")
        try makeAgentHomes(".agents")

        let results = AgentSkillLinks(source: skill, home: home).install()

        #expect(outcomes(results) == ["Codex": .linked, "Claude Code": .agentNotInstalled])
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".claude").path))
    }

    @Test func aSecondInstallChangesNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = try bundledSkill(in: "ContainerStack.app")
        try makeAgentHomes(".claude")
        let links = AgentSkillLinks(source: skill, home: home)
        _ = links.install()

        #expect(outcomes(links.install())["Claude Code"] == .current)
    }

    /// The app moved: the link that it made at its old path follows it.
    @Test func repointsTheLinkThatItMadeBeforeItMoved() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try bundledSkill(in: "Old/ContainerStack.app")
        let skill = try bundledSkill(in: "ContainerStack.app")
        try makeAgentHomes(".claude")
        _ = AgentSkillLinks(source: old, home: home).install()
        try FileManager.default.removeItem(at: old.deletingLastPathComponent().deletingLastPathComponent())

        let moved = AgentSkillLinks(source: skill, home: home, ownedSources: [old.path])
        #expect(outcomes(moved.install())["Claude Code"] == .linked)
        #expect(destination(of: claudeLink) == skill.path)
    }

    /// A link that the user made to another copy of the app is theirs, even though its target
    /// looks like a bundled skill.
    @Test func keepsALinkToAnotherCopyThatItDidNotMake() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let beta = try bundledSkill(in: "Beta/ContainerStack.app")
        let skill = try bundledSkill(in: "ContainerStack.app")
        try makeAgentHomes(".claude")
        try FileManager.default.createDirectory(
            at: claudeLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: claudeLink, withDestinationURL: beta)
        let links = AgentSkillLinks(source: skill, home: home)

        #expect(outcomes(links.install())["Claude Code"] == .keptUserCopy)
        #expect(outcomes(links.remove())["Claude Code"] == .keptUserCopy)
        #expect(destination(of: claudeLink) == beta.path)
    }

    @Test func keepsTheUsersOwnFolderAndLink() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = try bundledSkill(in: "ContainerStack.app")
        try makeAgentHomes(".claude", ".agents")
        try FileManager.default.createDirectory(at: claudeLink, withIntermediateDirectories: true)
        let mine = root.appending(path: "my-skills/containerstack")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: codexLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: codexLink, withDestinationURL: mine)
        let links = AgentSkillLinks(source: skill, home: home)

        #expect(outcomes(links.install()) == ["Codex": .keptUserCopy, "Claude Code": .keptUserCopy])
        #expect(outcomes(links.remove()) == ["Codex": .keptUserCopy, "Claude Code": .keptUserCopy])
        #expect(destination(of: codexLink) == mine.path)
        #expect(destination(of: claudeLink) == nil)
        #expect(FileManager.default.fileExists(atPath: claudeLink.path))
    }

    @Test func removeTakesAwayOnlyContainerStackLinks() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = try bundledSkill(in: "ContainerStack.app")
        try makeAgentHomes(".claude", ".codex")
        let links = AgentSkillLinks(source: skill, home: home)
        _ = links.install()

        #expect(outcomes(links.remove()) == ["Codex": .notLinked, "Claude Code": .notLinked])
        #expect(destination(of: codexLink) == nil)
        #expect(destination(of: claudeLink) == nil)
        #expect(FileManager.default.fileExists(atPath: skill.path))
    }

    /// Agents run `scripts/cstack` through the link, so the script has to find the bundle's
    /// `cstack` from the link's target, not from the link.
    @Test func theSkillsCStackScriptRunsTheBundledCStackThroughALink() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let skill = root.appending(path: "ContainerStack.app/Contents/Resources/AgentSkills/containerstack")
        try FileManager.default.createDirectory(
            at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: repository.appending(path: "Packaging/AgentSkills/containerstack"), to: skill)
        let cstack = root.appending(path: "ContainerStack.app/Contents/MacOS/cstack")
        try FileManager.default.createDirectory(
            at: cstack.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho \"bundled cstack $*\"\n".write(to: cstack, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cstack.path)
        try makeAgentHomes(".claude")
        _ = AgentSkillLinks(source: skill, home: home).install()

        let result = try ProcessRunner.run(
            executablePath: claudeLink.appending(path: "scripts/cstack").path,
            arguments: ["doctor"],
            output: .capture(includingStandardError: true),
            timeout: .seconds(10)
        )

        #expect(result.status == 0)
        #expect(result.output == "bundled cstack doctor\n")
    }
}
