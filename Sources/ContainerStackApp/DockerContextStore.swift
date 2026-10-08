import ContainerStackCore

/// The user's Docker client configuration as the app reads and changes it. The model takes it
/// rather than calling `DockerCLI` itself: a test model with the real one rewrote the user's
/// `containerstack` context to a test socket that was gone a moment later (#102).
struct DockerContextStore: Sendable {
    var read: @Sendable (_ includeInstalledContext: Bool) async -> DockerContextReading
    var install: @Sendable (_ socketPath: String) throws -> Void
    /// True when the context itself was removed, not only switched away from.
    var uninstall: @Sendable () throws -> Bool
    var recordedSocketPath: @Sendable (_ contextName: String) throws -> String?
    /// Rewrites the context's endpoint without switching to it.
    var repairRecord: @Sendable (_ socketPath: String) throws -> Void

    static let live = DockerContextStore(
        read: { RuntimeViewModel.readDockerContextFromCLI(includeInstalledContext: $0) },
        install: { try DockerCLI.installContext(socketPath: $0) },
        uninstall: { try DockerCLI.uninstallContext() },
        recordedSocketPath: { try DockerCLI.recordedSocketPath(for: $0) },
        repairRecord: { try DockerCLI.repairRecord(socketPath: $0) }
    )
}
