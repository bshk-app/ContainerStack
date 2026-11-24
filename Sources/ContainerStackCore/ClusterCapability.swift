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

    static func usageNames(_ subcommand: String, in help: String) -> Bool {
        help.split(whereSeparator: \.isNewline).contains { line in
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard tokens.first == "USAGE:" else { return false }
            let command = tokens.dropFirst().prefix { !"[<-".contains($0.first ?? "-") }
            return command.suffix(2).elementsEqual(["cluster", Substring(subcommand)])
        }
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
        let build = try await launch(["--version"], timeout: probe, budget: budget)
        if build.status == 0, let known = await capabilityCache.value(for: build.output) {
            return known
        }
        var capability = ClusterCapability.capable
        for subcommand in ["start", "stop"] {
            let help = try await launch(["cluster", subcommand, "--help"], timeout: probe, budget: budget)
            guard help.status == 0 else { return .noClusterStart }
            if !ClusterCapability.usageNames(subcommand, in: help.output) {
                capability = .noClusterStart
            }
        }
        if build.status == 0 { await capabilityCache.store(capability, for: build.output) }
        return capability
    }
}
