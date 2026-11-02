import Foundation

/// Links the bundled `containerstack` skill into the skill folders of coding agents, so they use
/// ContainerStack instead of the `container` CLI. A link, not a copy: the skill changes with the
/// app, and an app update needs no step here.
public struct AgentSkillLinks: Sendable {
    public enum Outcome: Equatable, Sendable {
        case linked
        case current
        /// A folder, file or link that this app did not make. It stays.
        case keptUserCopy
        /// The agent's home folder does not exist.
        case agentNotInstalled
        case notLinked
        case failed(String)

        public var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    public struct Result: Equatable, Sendable {
        public let agent: String
        public let link: URL
        public let outcome: Outcome
    }

    struct Agent {
        let name: String
        /// Any one of these folders under the home folder shows that the agent is installed.
        let homes: [String]
        let skills: String
    }

    /// Codex reads `~/.agents/skills` and follows symlinked skill folders. Claude Code reads
    /// `~/.claude/skills`.
    static let agents = [
        Agent(name: "Codex", homes: [".agents", ".codex"], skills: ".agents/skills"),
        Agent(name: "Claude Code", homes: [".claude"], skills: ".claude/skills"),
    ]
    public static let skillName = "containerstack"
    /// Where the skill is in the app bundle, under `Contents/Resources`.
    public static let bundledPath = "AgentSkills/\(skillName)"

    public let source: URL
    public let home: URL
    /// The source that this app linked before, at its old path if it moved. A link is this app's
    /// only when it points at `source` or here: a link to any other copy may be the user's own.
    public let previousSource: String?

    public init(
        source: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        previousSource: String? = nil
    ) {
        self.source = source
        self.home = home
        self.previousSource = previousSource
    }

    /// The skill in this app's bundle. nil for a build that has none, such as `swift run`.
    public static func bundled(in bundle: Bundle = .main, previousSource: String? = nil) -> AgentSkillLinks? {
        guard let resources = bundle.resourceURL else { return nil }
        let source = resources.appending(path: bundledPath)
        guard FileManager.default.fileExists(atPath: source.appending(path: "SKILL.md").path) else { return nil }
        return AgentSkillLinks(source: source, previousSource: previousSource)
    }

    public func install() -> [Result] {
        Self.agents.map { agent in
            let link = home.appending(path: "\(agent.skills)/\(Self.skillName)")
            return Result(agent: agent.name, link: link, outcome: install(agent, at: link))
        }
    }

    public func remove() -> [Result] {
        Self.agents.map { agent in
            let link = home.appending(path: "\(agent.skills)/\(Self.skillName)")
            return Result(agent: agent.name, link: link, outcome: remove(at: link))
        }
    }

    private func install(_ agent: Agent, at link: URL) -> Outcome {
        let files = FileManager.default
        guard agent.homes.contains(where: { files.fileExists(atPath: home.appending(path: $0).path) }) else {
            return .agentNotInstalled
        }
        do {
            if let destination = try? files.destinationOfSymbolicLink(atPath: link.path) {
                if destination == source.path { return .current }
                guard destination == previousSource else { return .keptUserCopy }
                try files.removeItem(at: link)
            } else if files.fileExists(atPath: link.path) {
                return .keptUserCopy
            }
            try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createSymbolicLink(atPath: link.path, withDestinationPath: source.path)
            return .linked
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func remove(at link: URL) -> Outcome {
        let files = FileManager.default
        guard let destination = try? files.destinationOfSymbolicLink(atPath: link.path) else {
            return files.fileExists(atPath: link.path) ? .keptUserCopy : .notLinked
        }
        guard destination == source.path || destination == previousSource else { return .keptUserCopy }
        do {
            try files.removeItem(at: link)
            return .notLinked
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
