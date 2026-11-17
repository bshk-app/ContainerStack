import ContainerStackCore
import Foundation
import Observation

@MainActor @Observable
final class SharedRuntimeSettings {
    let fileURL: URL
    private(set) var fileState: RuntimeGroupsFile.State = .missing
    private(set) var problem: String?
    private var restartPending = false
    var bridgeStatus: SharedRuntimesStatus? {
        didSet {
            if let bridgeStatus, bridgeStatus != .notRunning { restartPending = false }
        }
    }

    func beginBridgeRestart() { restartPending = awaitsBridgeRestart }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        fileURL = RuntimeGroupsFile.url(home: home)
        reload()
    }

    var awaitsBridgeRestart: Bool {
        SharedRuntimesFlag.needed(for: fileState) && (bridgeStatus == .notRunning || restartPending)
    }

    var bridgeProblem: String? {
        if case .off(let cause) = bridgeStatus { return cause }
        return nil
    }

    var document: RuntimeGroupsDocument? { fileState.document }
    var hasEditableGroups: Bool {
        ["mcp-catalog", "stdio-sessions"].contains { document?.group(named: $0) != nil }
    }

    var idleMinutes: Int? {
        let values = ["mcp-catalog", "stdio-sessions"].compactMap { document?.group(named: $0)?.idleMinutes }
        guard Set(values).count == 1 else { return nil }
        return values.first
    }

    func reload() {
        fileState = RuntimeGroupsFile.read(at: fileURL)
        if !SharedRuntimesFlag.needed(for: fileState) { restartPending = false }
        if case .invalid(let cause) = fileState { problem = cause } else { problem = nil }
    }

    func setEnabled(_ enabled: Bool, group: String) {
        edit { document in
            guard let index = document.groups.firstIndex(where: { $0.name == group }) else { return }
            document.groups[index].enabled = enabled
        }
    }

    func setIdleMinutes(_ minutes: Int) {
        guard RuntimeGroupsDocument.allowedIdleMinutes.contains(minutes) else { return }
        edit { document in
            for index in document.groups.indices
            where ["mcp-catalog", "stdio-sessions"].contains(document.groups[index].name) {
                document.groups[index].idleMinutes = minutes
            }
        }
    }

    func resetToDefaults() {
        do {
            try RuntimeGroupsFile.reset(at: fileURL)
            reload()
        } catch { problem = error.localizedDescription }
    }

    private func edit(_ change: (inout RuntimeGroupsDocument) -> Void) {
        do {
            try RuntimeGroupsFile.edit(at: fileURL, change: change)
            reload()
        } catch {
            reload()
            problem = error.localizedDescription
        }
    }
}
