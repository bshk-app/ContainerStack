import Foundation

/// Matches running processes by their absolute executable path, so ContainerStack only ever
/// stops the bridge it shipped and never a socktainer the user runs from somewhere else.
public enum ProcessTable {
    public static func pids(forExecutable executablePath: String, in listing: String) -> [Int32] {
        listing
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Int32? in
                let fields = line
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard fields.count == 2, let pid = Int32(fields[0]) else { return nil }

                let command = fields[1].trimmingCharacters(in: .whitespaces)
                guard command == executablePath || command.hasPrefix(executablePath + " ") else {
                    return nil
                }
                return pid
            }
    }
}

public enum RuntimeControlStep: Equatable, Sendable {
    case stopBridge(executablePath: String)
    case run(executablePath: String, arguments: [String])
    case startBridge
    case kickstartAgent(label: String)
}

/// Recovering a wedged runtime needs the same sequence regardless of who started it: drop the
/// bridge, cycle Apple Container so its vmnet attachment is rebuilt, then bring the bridge back.
public enum RuntimeRestartPlan {
    public static let agentLabel = "com.containerstack.runtime"

    public static func steps(
        configuration: RuntimeProcessConfiguration,
        agentRegistered: Bool
    ) -> [RuntimeControlStep] {
        stopSteps(configuration: configuration) + [
            .run(executablePath: configuration.containerPath, arguments: ["system", "stop"]),
            .run(executablePath: configuration.containerPath, arguments: configuration.containerStartArguments),
            agentRegistered ? .kickstartAgent(label: agentLabel) : .startBridge
        ]
    }

    public static func stopSteps(configuration: RuntimeProcessConfiguration) -> [RuntimeControlStep] {
        [.stopBridge(executablePath: configuration.socktainerPath)]
    }
}
