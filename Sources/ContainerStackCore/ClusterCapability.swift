import Foundation

public enum ClusterCapability: Equatable, Sendable, CustomStringConvertible {
    case capable
    case runtimeNotRunning
    case noClusterStart

    public var description: String {
        switch self {
        case .capable: "The runtime has cluster start and stop."
        case .runtimeNotRunning: "The runtime is not running. Start it to manage clusters."
        case .noClusterStart: "This runtime has no cluster start; update ContainerStack"
        }
    }

    fileprivate enum HelpReply {
        case confirmed
        case unsupported
        case transient
    }

    static func usageNames(_ subcommand: String, in help: String) -> Bool {
        helpReply(for: subcommand, in: help) == .confirmed
    }

    fileprivate static func helpReply(for subcommand: String, in help: String) -> HelpReply {
        var hasUsage = false
        for line in help.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard tokens.first == "USAGE:" else { continue }
            hasUsage = true
            let command = tokens.dropFirst().prefix { !"[<-".contains($0.first ?? "-") }
            if command.suffix(2).elementsEqual(["cluster", Substring(subcommand)]) {
                return .confirmed
            }
        }
        return hasUsage ? .unsupported : .transient
    }
}

public actor ClusterCapabilityCache {
    public static let shared = ClusterCapabilityCache()

    private var byBuild: [String: ClusterCapability] = [:]

    public init() {}

    func value(for build: String) -> ClusterCapability? {
        byBuild[build]
    }

    func store(_ capability: ClusterCapability, for build: String) {
        byBuild[build] = capability
    }
}

extension ClusterCommands {
    public func capability() async throws -> ClusterCapability {
        try await capability(budget: nil)
    }

    func capability(budget: ClusterCommandBudget?) async throws -> ClusterCapability {
        let probe = ProcessRunner.diagnosticTimeout
        guard try await launch(["system", "status"], timeout: probe, budget: budget).status == 0 else {
            return .runtimeNotRunning
        }
        return try await clusterCommandCapability(budget: budget)
    }

    func clusterCommandCapability(budget: ClusterCommandBudget?) async throws -> ClusterCapability {
        let probe = ProcessRunner.diagnosticTimeout
        let build = try await launch(["--version"], timeout: probe, budget: budget)
        if build.status == 0, let known = await capabilityCache.value(for: build.output) {
            return known
        }
        var capability = ClusterCapability.capable
        for subcommand in ["start", "stop"] {
            let reply = try await probeHelp(for: subcommand, timeout: probe, budget: budget)
            if reply == .transient { return .noClusterStart }
            if reply == .unsupported {
                capability = .noClusterStart
                break
            }
        }
        if build.status == 0 { await capabilityCache.store(capability, for: build.output) }
        return capability
    }

    private func probeHelp(
        for subcommand: String, timeout: Duration, budget: ClusterCommandBudget?
    ) async throws -> ClusterCapability.HelpReply {
        for _ in 0..<2 {
            let help = try await launch(["cluster", subcommand, "--help"], timeout: timeout, budget: budget)
            guard help.status == 0 else { continue }
            let reply = ClusterCapability.helpReply(for: subcommand, in: help.output)
            if reply != .transient { return reply }
        }
        return .transient
    }
}
