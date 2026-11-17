import Foundation

public struct SkippedReason: Equatable, Sendable {
    public let group: String
    public let reason: String

    public init?(_ label: String) {
        guard let colon = label.firstIndex(of: ":"), colon != label.startIndex else { return nil }
        group = String(label[..<colon])
        reason = String(label[label.index(after: colon)...])
        guard !reason.isEmpty else { return nil }
    }

    public var explanation: String {
        switch reason {
        case "no-stdin": "The run does not keep stdin open."
        case "no-autoremove": "The run does not remove itself when it ends."
        case "tty": "The run has a TTY."
        case "mount": "The run or its image has a mount or a volume."
        case "port": "The run publishes a port."
        case "network": "The run sets a network."
        case "limits": "The run sets resource limits."
        case "unknown-group": "The group is unknown."
        case "disabled-group": "The group is disabled."
        default: reason.hasPrefix("option:") ? "The run sets \(reason.dropFirst(7))." : reason
        }
    }
}
