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
        for line in lsofOutput.split(whereSeparator: \.isNewline) {
            guard line.first == "p" else { continue }
            if let pid = pid_t(line.dropFirst()) { return pid }
        }
        return nil
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
}
