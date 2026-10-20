import Foundation

/// Who holds the Docker socket.
///
/// "Is our bridge running?" is not the same question: the bridge takes a
/// `--socket` argument, so a copy of the bundled build can be running on another
/// path while an unrelated one serves the default. Adopting on process existence
/// alone therefore still adopts a foreign bridge - measured consequence, from a
/// socktainer reporting `unspecified`: every request answered while
/// `POST /containers/{id}/start` never returned.
public enum BridgeOwnership {
    /// The pid `lsof -Fpcn -- <socket>` reports.
    ///
    /// The `-F` output is one field per line, each prefixed by its type: `p` for
    /// the pid, `c` for the command, `n` for the name. Only the pid is needed
    /// here - the executable is compared through the process table, which already
    /// knows how to match a full path.
    public static func holder(lsofOutput: String) -> pid_t? {
        holders(lsofOutput: lsofOutput).first
    }

    /// Every pid listed. A wedged bridge whose socket file was replaced still lists under the
    /// path, ahead of the bridge that now serves it.
    static func holders(lsofOutput: String) -> [pid_t] {
        lsofOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { $0.first == "p" ? pid_t($0.dropFirst()) : nil }
    }

    /// Whether the process holding the socket is one of ours.
    ///
    /// Nobody holding it is not "ours": an unheld socket is a stale file, and the
    /// caller's other branches deal with that. A holder that is not in the list is
    /// foreign, which is the case worth reporting.
    public static func isOurs(holder: pid_t?, ourPIDs: [pid_t]) -> Bool {
        guard let holder else { return false }
        return ourPIDs.contains(holder)
    }

    /// The identifier every ContainerStack bundle ships under, whatever its path or build.
    public static let containerStackBundleIdentifier = "app.bshk.containerstack"

    /// Nil when `holder` is this build's bridge. A holder `lsof` could not name is still
    /// foreign: a socket that answers is held by something.
    public static func foreignBridge(
        socketPath: String,
        holder: pid_t?,
        ourBridgePath: String,
        listing: String,
        bundleIdentifier: (String) -> String? = BridgeOwnership.bundleIdentifier(atPath:)
    ) -> ForeignBridge? {
        guard let holder else { return ForeignBridge(socketPath: socketPath) }
        if isOurs(holder: holder, ourPIDs: ProcessTable.pids(forExecutable: ourBridgePath, in: listing)) {
            return nil
        }
        let command = ProcessTable.command(of: holder, in: listing) ?? ""
        return ForeignBridge(
            socketPath: socketPath,
            pid: holder,
            command: command,
            siblingBundlePath: siblingBundlePath(command: command, bundleIdentifier: bundleIdentifier)
        )
    }

    /// F-014: what the restart's bridge stop signals. Every copy of this build's bridge, and
    /// each holder of the socket that is another ContainerStack copy's. Nobody else's process.
    public static func pidsToStop(
        bridgePath: String,
        lsofOutput: String,
        listing: String,
        bundleIdentifier: (String) -> String? = BridgeOwnership.bundleIdentifier(atPath:)
    ) -> [pid_t] {
        let ours = ProcessTable.pids(forExecutable: bridgePath, in: listing)
        let siblings = holders(lsofOutput: lsofOutput).filter { holder in
            guard !ours.contains(holder), let command = ProcessTable.command(of: holder, in: listing) else {
                return false
            }
            return siblingBundlePath(command: command, bundleIdentifier: bundleIdentifier) != nil
        }
        return ours + siblings
    }

    public static func bundleIdentifier(atPath path: String) -> String? {
        Bundle(path: path)?.bundleIdentifier
    }

    private static let bundledBridge = "/Contents/Helpers/socktainer"

    /// The bundle whose bridge `command` runs, when that bundle is ContainerStack. `ps` joins
    /// argv with spaces and a bundle path may hold one, so the executable ends at the first
    /// `bundledBridge` that a space or the end of the line follows.
    private static func siblingBundlePath(
        command: String,
        bundleIdentifier: (String) -> String?
    ) -> String? {
        let bare = command.hasSuffix(bundledBridge) ? command.range(of: bundledBridge, options: .backwards) : nil
        guard command.hasPrefix("/"),
            let end = command.range(of: bundledBridge + " ")?.lowerBound ?? bare?.lowerBound
        else { return nil }
        let bundle = String(command[..<end])
        return bundleIdentifier(bundle) == containerStackBundleIdentifier ? bundle : nil
    }
}

/// The process holding the Docker socket when it is not the bridge this build ships.
public struct ForeignBridge: Equatable, Sendable {
    public let socketPath: String
    /// The pid `lsof` named; nil when it named none.
    public let pid: pid_t?
    /// What `ps` printed for that pid, empty when the table did not list it.
    public let command: String
    /// The ContainerStack bundle that ships this bridge, when it is one. Only such a bridge is
    /// stopped by a restart (F-014); anything else is someone's own and is only named.
    public let siblingBundlePath: String?

    public init(socketPath: String, pid: pid_t? = nil, command: String = "", siblingBundlePath: String? = nil) {
        self.socketPath = socketPath
        self.pid = pid
        self.command = command
        self.siblingBundlePath = siblingBundlePath
    }
}
