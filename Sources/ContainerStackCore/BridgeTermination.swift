import Darwin
import Foundation

/// A restart may launch the replacement only after the old bridge has stopped answering.
/// These PIDs have already passed `BridgeOwnership.pidsToStop`; unrelated bridges stay alone.
public enum BridgeTermination {
    public static func stop(_ pids: [pid_t], grace: Duration = .seconds(2)) throws {
        let targets = Array(Set(pids.filter { $0 > 0 }))
        for pid in targets { try signal(pid, SIGTERM) }
        let remaining = try waitForExit(targets, within: grace)
        for pid in remaining { try signal(pid, SIGKILL) }
        let survivors = try waitForExit(remaining, within: grace)
        guard survivors.isEmpty else { throw Failure.stillRunning(survivors) }
    }

    private static func signal(_ pid: pid_t, _ signal: Int32) throws {
        guard kill(pid, signal) != 0 else { return }
        let code = errno
        guard code != ESRCH else { return }
        throw Failure.signal(pid: pid, code: code)
    }

    private static func waitForExit(_ pids: [pid_t], within grace: Duration) throws -> [pid_t] {
        let deadline = ContinuousClock.now + grace
        var remaining = pids
        repeat {
            remaining = try remaining.filter { pid in
                if kill(pid, 0) == 0 { return true }
                let code = errno
                guard code == ESRCH else { throw Failure.signal(pid: pid, code: code) }
                return false
            }
            guard !remaining.isEmpty, ContinuousClock.now < deadline else { return remaining }
            Thread.sleep(forTimeInterval: 0.02)
        } while true
    }

    private enum Failure: Error, CustomStringConvertible {
        case signal(pid: pid_t, code: Int32)
        case stillRunning([pid_t])

        var description: String {
            switch self {
            case .signal(let pid, let code):
                "Could not stop bridge process \(pid): \(String(cString: strerror(code)))."
            case .stillRunning(let pids):
                "Bridge processes did not exit after SIGKILL: \(pids)."
            }
        }
    }
}
