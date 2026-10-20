import Darwin
import Foundation
import Synchronization

public enum ProcessRunnerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The child outlived its deadline and was terminated. Distinct from a non-zero exit so a
    /// caller can say "the runtime stopped answering" instead of "the command failed".
    case timedOut(executablePath: String, seconds: Double)

    /// The process is shutting down, so nothing would be left to wait on this
    /// child. It was refused rather than started and abandoned.
    case terminatingBeforeWait(executablePath: String)

    public var description: String {
        switch self {
        case .timedOut(let executablePath, let seconds):
            "\(executablePath) did not exit within \(seconds)s and was terminated"
        case .terminatingBeforeWait(let executablePath):
            "\(executablePath) was not started: this process is shutting down"
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
/// Output is drained on a thread of its own rather than with `readDataToEndOfFile()` on the
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

    /// The children currently being waited on with a deadline.
    ///
    /// A deadline protects the *wait*, not the child: when the waiting process
    /// exits first, the child is reparented to launchd and keeps running. Eight
    /// `container system stop` processes were found that way on one machine, aged
    /// up to four days, each wedged against a runtime that never answered.
    ///
    /// The deliberately unbounded child - `timeout: nil`, the Docker bridge - is
    /// excluded on purpose: it exists to outlive the app that started it.
    private static let boundedChildren = BoundedChildren()

    public static var outstandingBoundedChildren: Int { boundedChildren.count }

    /// Kills every child still under a deadline and closes the registry, so a
    /// child asked for after this is never started, and one being started while
    /// this runs is waited for and killed with the rest. For a process about to
    /// exit: its waits die with it, its children do not.
    @discardableResult
    public static func terminateBoundedChildren() -> Int {
        terminateBoundedChildren(in: boundedChildren)
    }

    /// The registry is closed for good, so a test that exercises this gets its own: closing the
    /// shared one refused every bounded run after it in the same test process.
    static func terminateBoundedChildren(in registry: BoundedChildren) -> Int {
        let children = registry.closeAndDrain()
        var killed = 0
        for child in children where child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            killed += 1
        }
        return killed
    }

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
        try run(
            executablePath: executablePath, arguments: arguments, output: mode, environment: environment,
            timeout: timeout, gracePeriod: gracePeriod, registry: boundedChildren)
    }

    static func run(
        executablePath: String,
        arguments: [String] = [],
        output mode: OutputMode = .discard,
        environment: [String: String]? = nil,
        timeout: Duration?,
        gracePeriod: Duration = .milliseconds(500),
        registry: BoundedChildren,
        startDrain: (Drain, @escaping @Sendable () -> Void) -> Void = { startOnOwnThread($1) }
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

        let drain = Drain()
        let drained = DispatchSemaphore(value: 0)
        if let pipe {
            let reader = pipe.fileHandleForReading
            startDrain(drain) {
                collect(from: reader.fileDescriptor, into: drain, gracePeriod: gracePeriod)
                drained.signal()
            }
        }

        // Only once the child is gone or was never started. The wait is bounded by the drain,
        // which stops `gracePeriod` after it notices, so a descendant cannot hold it open.
        func finishDrain() {
            guard pipe != nil else { return }
            drain.markChildGone()
            drained.wait()
        }

        // Registered only while this call is waiting on it, so a process that
        // exits mid-wait can take the child with it instead of orphaning it.
        do {
            if timeout == nil {
                try process.run()
            } else if try !registry.start(process, using: { try process.run() }) {
                throw ProcessRunnerError.terminatingBeforeWait(executablePath: executablePath)
            }
        } catch {
            try? pipe?.fileHandleForWriting.close()
            finishDrain()
            throw error
        }
        // The parent never writes. Keeping its copy open hides EOF after the
        // child exits, so close it as soon as the child has inherited the fd.
        try? pipe?.fileHandleForWriting.close()

        if let timeout {
            defer { registry.remove(process) }

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
            output: String(decoding: drain.output, as: UTF8.self)
        )
    }

    /// `run` waits for the drain to finish, and a drain queued on a pool behind threads that
    /// callers blocked in `run` are holding might never start.
    private static func startOnOwnThread(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Reads `fd` until EOF. A descendant can keep the child's stdout open long after the child
    /// exits, so once the child is gone the read stops `gracePeriod` after the drain noticed —
    /// but not before it has read what was already in the pipe then. Those bytes are the child's
    /// own, and a drain that starts late on a loaded machine must still collect them.
    private static func collect(from fd: Int32, into drain: Drain, gracePeriod: Duration) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var cutoff: ContinuousClock.Instant?
        var owed = 0
        while true {
            if cutoff == nil, drain.isChildGone {
                cutoff = .now + gracePeriod
                var pending: Int32 = 0
                if ioctl(fd, fionread, &pending) == 0 { owed = Int(pending) }
            }
            if let cutoff, owed <= 0, ContinuousClock.now >= cutoff { return }

            // A poll rather than a blocking read: nothing would wake the read when the child goes.
            var request = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            switch poll(&request, 1, 100) {
            case 0:
                owed = 0  // an empty pipe holds nothing still owed
                continue
            case ..<0:
                if errno == EINTR { continue }
                return
            default:
                break
            }

            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            drain.append(chunk[..<count])
            owed -= count
        }
    }

    /// `FIONREAD` from `<sys/filio.h>`, `_IOR('f', 127, int)`: Swift does not import the macro.
    private static let fionread =
        UInt(IOC_OUT) | (UInt(MemoryLayout<Int32>.size) & UInt(IOCPARM_MASK)) << 16
        | UInt(UInt8(ascii: "f")) << 8 | 127

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// What `run` shares with the thread draining the child's output.
final class Drain: Sendable {
    private let state = Mutex((output: Data(), childGone: false))

    func append(_ bytes: ArraySlice<UInt8>) {
        state.withLock { $0.output.append(contentsOf: bytes) }
    }

    var output: Data { state.withLock { $0.output } }

    func markChildGone() {
        state.withLock { $0.childGone = true }
    }

    var isChildGone: Bool { state.withLock { $0.childGone } }
}

/// Registered from whichever thread called `run`, drained from the one that is
/// shutting down, so the set needs a lock to cross between them.
///
/// `Process` rather than a pid: a pid recorded a moment ago can belong to
/// something else by the time the signal is sent, and `Process` answers whether
/// *its* child is still alive. Once shutdown starts the registry stays closed,
/// so a child asked for during it is never started.
final class BoundedChildren: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]
    private var isTerminating = false

    /// Starts `process` with `run` and registers it as one step, so a shutdown either drains it or
    /// has already refused it. Started first and registered after, a child begun while a shutdown
    /// drained an empty registry outlived a process that exited straight after (#102).
    ///
    /// False when shutdown has begun: nothing was started, and nobody will be here to wait.
    func start(_ process: Process, using run: () throws -> Void) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminating else { return false }
        try run()
        processes[ObjectIdentifier(process)] = process
        return true
    }

    func remove(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    func closeAndDrain() -> [Process] {
        lock.lock()
        defer {
            processes.removeAll()
            lock.unlock()
        }
        isTerminating = true
        return Array(processes.values)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return processes.count
    }
}
