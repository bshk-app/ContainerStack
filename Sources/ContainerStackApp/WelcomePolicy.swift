import ContainerStackCore
import Foundation
import Observation

struct WelcomePolicy {
    enum Mode: String { case first, update }
    let currentVersion: String
    let lastVersion: String?
    var steps: [WelcomeStep] = WelcomeCatalog.steps

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    var newSteps: [WelcomeStep] {
        guard let lastVersion else { return [] }
        return steps.filter {
            Self.compare($0.release, lastVersion) == .orderedDescending
                && Self.compare($0.release, currentVersion) != .orderedDescending
        }
    }

    var mode: Mode? {
        guard let lastVersion else { return .first }
        guard Self.compare(currentVersion, lastVersion) == .orderedDescending else { return nil }
        let majorChanged = currentVersion.split(separator: ".").first != lastVersion.split(separator: ".").first
        return majorChanged || !newSteps.isEmpty ? .update : nil
    }

    var orderedSteps: [WelcomeStep] {
        let newIDs = Set(newSteps.map(\.id))
        return newSteps + steps.filter { !newIDs.contains($0.id) }
    }
}

enum WelcomeRelease {
    static var version: String {
        resource("WelcomeVersion", extension: "txt").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var notes: String { notes(version: version, changelog: resource("WelcomeChangelog", extension: "md")) }

    static func notes(version: String, changelog: String) -> String {
        var collecting = false
        var lines: [String] = []
        for line in changelog.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                if collecting { break }
                collecting = line.hasPrefix("## [\(version)]")
            } else if collecting {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resource(_ name: String, extension suffix: String) -> String {
        #if SWIFT_PACKAGE
            let bundle = Bundle.module
        #else
            let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: suffix),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }
}

@MainActor @Observable
final class WelcomeSession {
    static let lastVersionKey = "lastWelcomeVersion"
    let policy: WelcomePolicy
    let defaults: UserDefaults
    var selectedID: String
    var visited: Set<String> = []
    var attemptedAutomaticPresentation = false

    init(
        defaults: UserDefaults = .standard, version: String = WelcomeRelease.version,
        steps: [WelcomeStep] = WelcomeCatalog.steps, earlierInstall: Bool = false
    ) {
        self.defaults = defaults
        policy = WelcomePolicy(
            currentVersion: version,
            lastVersion: defaults.string(forKey: Self.lastVersionKey) ?? (earlierInstall ? "0.10.0" : nil), steps: steps
        )
        selectedID = policy.orderedSteps[0].id
    }

    var selected: WelcomeStep { policy.steps.first { $0.id == selectedID } ?? policy.orderedSteps[0] }
    var index: Int { policy.orderedSteps.firstIndex { $0.id == selectedID } ?? 0 }
    var title: String {
        policy.mode == .first ? "Welcome to ContainerStack" : "Welcome to ContainerStack \(policy.currentVersion)"
    }

    func select(_ id: String) {
        guard id != selectedID else { return }
        visited.insert(selectedID)
        selectedID = id
    }

    func finish() { defaults.set(policy.currentVersion, forKey: Self.lastVersionKey) }

    func windowClosed() { finish() }

    static func hasEarlierInstall(defaults: UserDefaults, links: AgentSkillLinks?) -> Bool {
        defaults.object(forKey: AgentSkillSettings.linkedSourcesKey) != nil
            || !(links?.existingContainerStackSources().isEmpty ?? true)
    }
}
