import ContainerStackCore
import Foundation
import Observation

/// Whether ContainerStack links its `containerstack` skill into the coding agents' skill folders.
/// On by default. The app applies the choice after launch and when Settings opens, so a new app
/// version, or an app that moved, repairs its links. Making the settings links nothing: a second
/// copy of the app makes them before it finds the first copy and quits.
@MainActor
@Observable
final class AgentSkillSettings {
    static let key = "linksAgentSkill"
    /// The source that the app linked last. A link to it is the app's own, also after the app moved.
    static let linkedSourceKey = "agentSkillLinkedSource"

    private let defaults: UserDefaults
    private let links: AgentSkillLinks?
    private(set) var results: [AgentSkillLinks.Result] = []

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.key)
            apply()
        }
    }

    /// false for a build without the skill in its bundle, such as `swift run`.
    var isAvailable: Bool { links != nil }

    init(defaults: UserDefaults = .standard, links: AgentSkillLinks? = .bundled()) {
        self.defaults = defaults
        self.links = links
        isEnabled = defaults.object(forKey: Self.key) as? Bool ?? true
    }

    func apply() {
        guard let links else { return }
        let recorded = AgentSkillLinks(
            source: links.source,
            home: links.home,
            previousSource: defaults.string(forKey: Self.linkedSourceKey)
        )
        guard isEnabled else {
            results = recorded.remove()
            return
        }
        results = recorded.install()
        if results.contains(where: { $0.outcome == .linked || $0.outcome == .current }) {
            defaults.set(links.source.path, forKey: Self.linkedSourceKey)
        }
    }

    static func describe(_ result: AgentSkillLinks.Result) -> String {
        let path = (result.link.path as NSString).abbreviatingWithTildeInPath
        return switch result.outcome {
        case .linked, .current: "\(result.agent): linked at \(path)"
        case .keptUserCopy: "\(result.agent): \(path) is not ContainerStack's, so it stays"
        case .agentNotInstalled: "\(result.agent): not installed"
        case .notLinked: "\(result.agent): not linked"
        case .failed(let reason): "\(result.agent): cannot link \(path): \(reason)"
        }
    }
}
