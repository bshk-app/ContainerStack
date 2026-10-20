import Foundation
import Testing

@testable import ContainerStackCore

/// The spawn as the probe requested it, so a test can assert the deadline that
/// `SystemProbe`'s timeout-free signatures cannot carry.
private struct SpawnedCommand: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let timeout: Duration?
}

private final class SpawnRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SpawnedCommand] = []

    var commands: [SpawnedCommand] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var spawn: ShellSystemProbe.Spawn {
        { [self] executablePath, arguments, timeout in
            lock.lock()
            recorded.append(SpawnedCommand(executablePath: executablePath, arguments: arguments, timeout: timeout))
            lock.unlock()
            return ProcessRunner.Result(status: 0, output: "")
        }
    }
}

@Suite("The production probe reports failure as failure")
struct ShellSystemProbeTests {
    @Test("a binary that cannot be spawned is failed, not empty output")
    func aMissingBinaryIsFailedNotEmptyOutput() async {
        let probe = ShellSystemProbe(containerPath: "/nonexistent/container")
        guard case .failed = await probe.runtimeStatus() else {
            Issue.record("a missing binary must not report empty output")
            return
        }
    }

    /// `ProcessRunner.run` returns a non-zero status rather than throwing, so this
    /// is the branch a `try?`-based helper turns into a healthy-looking `""`.
    @Test("a non-zero exit is failed, not empty output")
    func aNonZeroExitIsFailedNotEmptyOutput() async {
        let probe = ShellSystemProbe(containerPath: "/usr/bin/false")
        guard case .failed(let reason) = await probe.runtimeStatus() else {
            Issue.record("a non-zero exit must not report empty output")
            return
        }
        #expect(reason.contains("/usr/bin/false"))
        #expect(reason.contains("1"))
    }

    @Test("a command that exits zero carries its stdout")
    func aSuccessfulCommandCarriesItsOutput() async {
        let probe = ShellSystemProbe(containerPath: "/bin/echo")
        #expect(await probe.runtimeStatus() == .output("system status\n"))
    }

    @Test("every spawn carries the 10s diagnostic deadline, not the 120s lifecycle one")
    func everySpawnCarriesTheDiagnosticTimeout() async {
        let recorder = SpawnRecorder()
        let probe = ShellSystemProbe(containerPath: "/usr/local/bin/container", spawn: recorder.spawn)

        _ = await probe.runtimeStatus()
        _ = await probe.routingTable()
        _ = await probe.socketHolder(socketPath: "/tmp/x.sock")
        _ = await probe.processTable()

        #expect(ProcessRunner.diagnosticTimeout == .seconds(10))
        #expect(recorder.commands.map(\.timeout) == Array(repeating: ProcessRunner.diagnosticTimeout, count: 4))
    }

    @Test("each probe spawns the command the spec pins to it")
    func eachProbeSpawnsItsPinnedCommand() async {
        let recorder = SpawnRecorder()
        let probe = ShellSystemProbe(containerPath: "/usr/local/bin/container", spawn: recorder.spawn)

        _ = await probe.runtimeStatus()
        _ = await probe.routingTable()
        _ = await probe.socketHolder(socketPath: "/var/run/container.sock")
        _ = await probe.processTable()

        #expect(
            recorder.commands.map(\.executablePath) == [
                "/usr/local/bin/container",
                "/usr/sbin/netstat",
                "/usr/sbin/lsof",
                "/bin/ps",
            ]
        )
        #expect(
            recorder.commands.map(\.arguments) == [
                ["system", "status"],
                ["-rn", "-f", "inet"],
                ["-Fpcn", "--", "/var/run/container.sock"],
                ["-A", "-o", "pid=,command="],
            ]
        )
    }

    @Test("a thrown timeout becomes failed, naming the command")
    func aTimedOutSpawnIsFailed() async {
        let probe = ShellSystemProbe(containerPath: "/usr/local/bin/container") { executablePath, _, _ in
            throw ProcessRunnerError.timedOut(executablePath: executablePath, seconds: 10)
        }
        guard case .failed(let reason) = await probe.runtimeStatus() else {
            Issue.record("a timeout must not report empty output")
            return
        }
        #expect(reason.contains("/usr/local/bin/container"))
        #expect(reason.contains("did not exit within"))
    }
}
