import Foundation

/// Matches running processes by their absolute executable path, so ContainerStack only ever
/// stops the bridge it shipped and never a socktainer the user runs from somewhere else.
public enum ProcessTable {
    public static func pids(forExecutable executablePath: String, in listing: String) -> [Int32] {
        listing
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Int32? in
                let fields =
                    line
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

    public static func legacyBundledSocktainerPIDs(
        forExecutable executablePath: String,
        in listing: String
    ) -> [Int32] {
        guard executablePath.hasPrefix("/"),
            executablePath.hasSuffix("/Contents/Helpers/socktainer")
        else { return [] }

        let legacyCommand = "\(executablePath) --no-check-compatibility --no-docker-context"
        return
            listing
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Int32? in
                let fields =
                    line
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard fields.count == 2, let pid = Int32(fields[0]) else { return nil }

                let command = fields[1].trimmingCharacters(in: .whitespaces)
                return command == legacyCommand ? pid : nil
            }
    }
}

public enum LegacySocktainerSignalResult: Equatable, Sendable {
    case delivered
    case alreadyExited
}

public enum LegacySocktainerRetirementError: Error, Equatable, CustomStringConvertible, Sendable {
    case processEnumerationFailed
    case signalFailed(pid: Int32)
    case timedOut(pids: [Int32])

    public var description: String {
        switch self {
        case .processEnumerationFailed:
            "could not enumerate processes while retiring legacy bundled socktainer"
        case .signalFailed(let pid):
            "could not signal legacy bundled socktainer pid \(pid)"
        case .timedOut(let pids):
            "legacy bundled socktainer did not exit before timeout: \(pids)"
        }
    }
}

public enum LegacySocktainerRetirement {
    public static func retire(
        executablePath: String,
        maxChecks: Int,
        processListing: () throws -> String,
        signal: (Int32) throws -> LegacySocktainerSignalResult,
        wait: () -> Void
    ) throws {
        let initialPIDs = try legacyPIDs(executablePath: executablePath, processListing: processListing)
        guard !initialPIDs.isEmpty else { return }

        for pid in initialPIDs {
            do {
                _ = try signal(pid)
            } catch {
                throw LegacySocktainerRetirementError.signalFailed(pid: pid)
            }
        }

        var remainingPIDs = initialPIDs
        for _ in 0..<maxChecks {
            remainingPIDs = try legacyPIDs(executablePath: executablePath, processListing: processListing)
            if remainingPIDs.isEmpty { return }
            wait()
        }

        throw LegacySocktainerRetirementError.timedOut(pids: remainingPIDs)
    }

    private static func legacyPIDs(
        executablePath: String,
        processListing: () throws -> String
    ) throws -> [Int32] {
        do {
            return ProcessTable.legacyBundledSocktainerPIDs(
                forExecutable: executablePath,
                in: try processListing()
            )
        } catch {
            throw LegacySocktainerRetirementError.processEnumerationFailed
        }
    }
}

public enum RuntimeControlStep: Equatable, Sendable {
    case stopBridge(executablePath: String)
    /// Ask every running container to exit before the service under it is stopped.
    ///
    /// A case of its own rather than a `.run`, because it is the one step in the sequence that is
    /// **advisory**: it must never abort the restart. The situation this whole plan exists to repair
    /// is a wedged Apple Container, and a stop is precisely the call measured hanging when the
    /// daemon has lost its XPC service. Executed as a plain `.run` it would time out, throw, and
    /// take `system stop` — the step that actually clears the wedge — down with it.
    case stopContainers(executablePath: String, graceSeconds: Int)
    case run(executablePath: String, arguments: [String])
    case startBridge
    case kickstartAgent(label: String)

    /// The command behind `stopContainers`, kept here so both executors spell it the same way.
    public static func stopContainersArguments(graceSeconds: Int) -> [String] {
        ["stop", "--all", "--time", String(graceSeconds)]
    }
}

/// Recovering a wedged runtime needs the same sequence regardless of who started it: drop the
/// bridge, ask the containers to exit, cycle Apple Container so its vmnet attachment is rebuilt,
/// then bring the bridge back.
public enum RuntimeRestartPlan {
    public static let agentLabel = "com.containerstack.runtime"

    /// Matches the five seconds `DockerAPIClient.stopContainer` already gives a guest (`?t=5`), so a
    /// container sees the same grace period whichever path stops it.
    public static let gracefulStopSeconds = 5

    public static func steps(
        configuration: RuntimeProcessConfiguration,
        agentRegistered: Bool
    ) -> [RuntimeControlStep] {
        stopSteps(configuration: configuration) + [
            // `container system stop` stops the services, and the running guests go down with them
            // without being asked to exit. Anything holding a filesystem open across that loses the
            // writes it had not flushed: recovering a wedged network this way once left postgres
            // reporting `database system was not properly shut down` and an ext4 that needed
            // `e2fsck` before it would mount.
            .stopContainers(
                executablePath: configuration.containerPath,
                graceSeconds: gracefulStopSeconds
            ),
            .run(executablePath: configuration.containerPath, arguments: ["system", "stop"]),
            .run(executablePath: configuration.containerPath, arguments: configuration.containerStartArguments),
            agentRegistered ? .kickstartAgent(label: agentLabel) : .startBridge,
        ]
    }

    public static func stopSteps(configuration: RuntimeProcessConfiguration) -> [RuntimeControlStep] {
        [.stopBridge(executablePath: configuration.socktainerPath)]
    }
}
