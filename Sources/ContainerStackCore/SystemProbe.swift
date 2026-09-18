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
