import Darwin
import Foundation

public enum ProcessRunnerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The child outlived its deadline and was terminated. Distinct from a non-zero exit so a
    /// caller can say "the runtime stopped answering" instead of "the command failed".
    case timedOut(executablePath: String, seconds: Double)

    public var description: String {
        switch self {
        case .timedOut(let executablePath, let seconds):
            "\(executablePath) did not exit within \(seconds)s and was terminated"
        }
    }
}

/// One bounded way to run a child process.
///
/// Every previous copy of this plumbing paired `process.run()` with a bare
/// `process.waitUntilExit()`. That call has no deadline, so a wedged child blocks its caller
/// forever: the helper is single-threaded and launchd's `SuccessfulExit=false` does not restart
/// a merely-hung process, and in the app a stuck wait leaves the 3s monitor loop and the
/// Start/Stop buttons permanently unresponsive. macOS ships no `timeout(1)` to lean on.
///
/// Output is drained on a separate queue rather than with `readDataToEndOfFile()` on the
/// calling thread, because that call only returns at EOF — it would outlast the deadline it is
/// supposed to be bounded by, and a child that fills the 64 KB pipe buffer while nobody reads
/// deadlocks against its own exit.
public enum ProcessRunner {
    /// Status queries: `container system status`, `netstat`, `ps`, `docker context ls`. Long
    /// enough to survive a busy machine, short enough that the monitor loop keeps its cadence.
    public static let diagnosticTimeout: Duration = .seconds(10)

    /// Booting or tearing down a micro-VM. Matches `DockerAPIClient.lifecycleRequestTimeout`:
    /// a measured restart takes ~6.4s and a stop waits out the container's grace period first.
    public static let lifecycleTimeout: Duration = .seconds(120)

    public enum OutputMode: Equatable, Sendable {
        /// `/dev/null`. The caller wants the exit status only.
        case discard
        /// The parent's own stdout/stderr, for a child whose output is the user-facing log.
        case inherit
        /// Collected and returned. `includingStandardError` merges stderr into the same buffer;
        /// when false stderr is discarded, which is what callers parsing stdout expect.
        case capture(includingStandardError: Bool)
    }

    public struct Result: Sendable {
        public let status: Int32
        public let output: String

        public init(status: Int32, output: String) {
            self.status = status
            self.output = output
        }
    }

    /// Runs `executablePath` and returns once it exits or the deadline passes.
    ///
    /// On timeout the child gets `SIGTERM`, then `SIGKILL` after `gracePeriod`, and
    /// `ProcessRunnerError.timedOut` is thrown. A non-zero exit is *not* an error here — the
    /// status is returned so each caller can keep its own error type.
    ///
    /// A `nil` timeout waits indefinitely, matching the `Duration?` convention
    /// `DockerAPIClient.streamingRequestTimeout` already uses. It is for **supervising a
    /// long-lived child** — the runtime helper exists to sit on `socktainer` for as long as it
    /// runs, and a deadline there would kill the Docker bridge on a timer. Every other caller
    /// passes a real deadline; an unbounded wait that is not deliberate is the bug this type
    /// was written to remove.
    public static func run(
        executablePath: String,
        arguments: [String] = [],
        output mode: OutputMode = .discard,
        environment: [String: String]? = nil,
        timeout: Duration?,
        gracePeriod: Duration = .milliseconds(500)
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        // Never inherited: a child prompting on stdin would hang behind the deadline for no
        // reason, and nothing here is interactive.
        process.standardInput = FileHandle.nullDevice

        let pipe: Pipe?
        switch mode {
        case .discard:
            pipe = nil
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        case .inherit:
            pipe = nil
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        case .capture(let includingStandardError):
            let created = Pipe()
            pipe = created
            process.standardOutput = created
            process.standardError = includingStandardError ? created : FileHandle.nullDevice
        }

        let exited = DispatchSemaphore(value: 0)
        // Set before run(): a child that exits immediately must still signal.
        process.terminationHandler = { _ in exited.signal() }

        let collected = OutputBuffer()
        let drained = DispatchSemaphore(value: 0)
        if let pipe {
            let reader = pipe.fileHandleForReading
            DispatchQueue.global(qos: .userInitiated).async {
                defer { drained.signal() }
                while true {
                    do {
                        guard
                            let data = try reader.read(upToCount: 64 * 1024),
                            !data.isEmpty
                        else { return }
                        collected.append(data)
                    } catch {
                        // The direct child can exit while a descendant keeps its
                        // inherited stdout open. The caller closes the reader after a
                        // bounded drain grace; that close lands here.
                        return
                    }
                }
            }
        }

        func finishDrain() {
            guard let pipe else { return }
            if drained.wait(timeout: .now() + seconds(gracePeriod)) == .timedOut {
                try? pipe.fileHandleForReading.close()
                _ = drained.wait(timeout: .now() + seconds(gracePeriod))
            }
        }

        do {
            try process.run()
            // The parent never writes. Keeping its copy open hides EOF after the
            // child exits, so close it as soon as the child has inherited the fd.
            try? pipe?.fileHandleForWriting.close()
        } catch {
            try? pipe?.fileHandleForWriting.close()
            finishDrain()
            throw error
        }

        if let timeout {
            if exited.wait(timeout: .now() + seconds(timeout)) == .timedOut {
                process.terminate()
                if exited.wait(timeout: .now() + seconds(gracePeriod)) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    exited.wait()
                }
                finishDrain()
                throw ProcessRunnerError.timedOut(
                    executablePath: executablePath,
                    seconds: seconds(timeout)
                )
            }
        } else {
            exited.wait()
        }

        finishDrain()

        return Result(
            status: process.terminationStatus,
            output: String(decoding: collected.data, as: UTF8.self)
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// The drain runs on another queue, so the buffer it fills needs a lock to cross back.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
