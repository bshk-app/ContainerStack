import Foundation

/// Every external command the Doctor depends on. A command that could not run
/// returns `.failed`, never `.output("")`, so a broken probe cannot read healthy.
public protocol SystemProbe: Sendable {
    func runtimeStatus() async -> ProbeResult
    func routingTable() async -> ProbeResult
    /// `lsof` and `ps`: bridge ownership is not answerable from the Docker API,
    /// so only the `foreignBridge` check spends these two spawns.
    func socketHolder(socketPath: String) async -> ProbeResult
    func processTable() async -> ProbeResult
}

/// The production probe. Every spawn goes through `ProcessRunner.run` directly:
/// `CommandShell`/`RuntimeShell` wrap it in `try?` and return `""`, which reads as health.
public struct ShellSystemProbe: SystemProbe {
    /// One spawn, injectable because the protocol's methods carry no timeout: this
    /// is the only seam where the deadline each command gets is assertable.
    typealias Spawn =
        @Sendable (
            _ executablePath: String,
            _ arguments: [String],
            _ timeout: Duration?
        ) throws -> ProcessRunner.Result

    private let containerPath: String
    private let spawn: Spawn

    public init(containerPath: String) {
        self.init(containerPath: containerPath, spawn: ShellSystemProbe.processRunnerSpawn)
    }

    init(containerPath: String, spawn: @escaping Spawn) {
        self.containerPath = containerPath
        self.spawn = spawn
    }

    public func runtimeStatus() async -> ProbeResult {
        await result(executablePath: containerPath, arguments: ["system", "status"])
    }

    public func routingTable() async -> ProbeResult {
        await result(executablePath: "/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
    }

    public func socketHolder(socketPath: String) async -> ProbeResult {
        await result(executablePath: "/usr/sbin/lsof", arguments: ["-Fpcn", "--", socketPath])
    }

    public func processTable() async -> ProbeResult {
        await result(executablePath: "/bin/ps", arguments: ["-A", "-o", "pid=,command="])
    }

    /// A non-zero exit is returned by `ProcessRunner.run`, not thrown, so it needs
    /// its own branch: dropping it here is exactly how a dead command reads healthy.
    private func result(executablePath: String, arguments: [String]) async -> ProbeResult {
        let spawn = self.spawn
        return await Task.detached {
            do {
                let completed = try spawn(executablePath, arguments, ProcessRunner.diagnosticTimeout)
                guard completed.status == 0 else {
                    return ProbeResult.failed(reason: "\(executablePath) exited with status \(completed.status)")
                }
                return .output(completed.output)
            } catch {
                return .failed(reason: "\(executablePath) could not be run: \(error)")
            }
        }.value
    }

    /// stderr is dropped rather than merged: `netstat`/`lsof`/`ps` output is parsed
    /// positionally, so a reason names the path and status but never the command's own message.
    private static let processRunnerSpawn: Spawn = { executablePath, arguments, timeout in
        try ProcessRunner.run(
            executablePath: executablePath,
            arguments: arguments,
            output: .capture(includingStandardError: false),
            timeout: timeout
        )
    }
}
