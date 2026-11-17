import Foundation

public enum SharedRuntimesStatus: Equatable, Sendable {
    case notRunning
    case on
    case off(cause: String)
    case starting

    public static func parse(info: DockerInfo) -> Self {
        guard let label = info.labels?.first(where: { $0.hasPrefix("containerstack.shared-runtimes=") }) else {
            return .notRunning
        }
        if label == "containerstack.shared-runtimes=on" { return .on }
        let prefix = "shared runtimes are off: "
        let cause =
            info.warnings?.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
            ?? "The bridge did not report a cause."
        if cause == "the removal of shared containers of a previous run has not finished" { return .starting }
        return .off(cause: cause)
    }
}

extension DockerContainerSummary {
    public var sharedGroup: String? { labels?["containerstack.shared.group"] }
    public var sharedSocket: String? { labels?["containerstack.shared.socket"] }
    public var sessionGroup: String? { labels?["containerstack.session.group"] }
    public var sessionContainerID: String? { labels?["containerstack.session.container"] }
    public var isSession: Bool { sessionGroup != nil }
    public var isSharedContainer: Bool { sharedGroup != nil }
    public var skippedGroup: SkippedReason? {
        labels?["containerstack.group.skipped"].flatMap(SkippedReason.init)
    }
}
