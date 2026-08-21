import Foundation

/// What the ports form in the app is allowed to submit.
///
/// The rules live here rather than in the view so they can be tested without driving the UI: an
/// invalid entry must never reach the compose file, and Compose's own validation on save is a
/// backstop, not the first line of defence.
public struct ComposePortDraft: Equatable, Sendable {
    public var host: String
    public var container: String
    public var bindAddress: String
    public var transport: String

    public init(host: String = "", container: String = "", bindAddress: String = "", transport: String = "tcp") {
        self.host = host
        self.container = container
        self.bindAddress = bindAddress
        self.transport = transport
    }

    private static let validPorts = 1...65535

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    private var trimmedContainer: String { container.trimmingCharacters(in: .whitespaces) }
    private var trimmedBind: String { bindAddress.trimmingCharacters(in: .whitespaces) }

    /// A container port is required; an empty host port means "let Compose pick one", which is
    /// what a bare `- "3000"` entry does.
    public var mapping: ComposePortMapping? {
        guard let container = Int(trimmedContainer), Self.validPorts.contains(container) else { return nil }

        var hostPort: Int?
        if !trimmedHost.isEmpty {
            guard let parsed = Int(trimmedHost), Self.validPorts.contains(parsed) else { return nil }
            hostPort = parsed
        }

        // A bind address without a host port has nothing to bind: Compose's short syntax has no
        // way to spell `ip::container`, so the entry would be silently reinterpreted.
        if !trimmedBind.isEmpty && hostPort == nil { return nil }

        let normalizedTransport = transport.lowercased()
        return ComposePortMapping(
            hostIP: trimmedBind.isEmpty ? nil : trimmedBind,
            hostPort: hostPort,
            containerPort: container,
            transport: normalizedTransport == "udp" ? "udp" : nil
        )
    }

    public var isValid: Bool { mapping != nil }
}

/// What the volumes form is allowed to submit. A bind mount needs both a source and a target;
/// a named volume is just a source that is not a path.
public struct ComposeVolumeDraft: Equatable, Sendable {
    public var source: String
    public var target: String
    public var isReadOnly: Bool

    public init(source: String = "", target: String = "", isReadOnly: Bool = false) {
        self.source = source
        self.target = target
        self.isReadOnly = isReadOnly
    }

    private var trimmedSource: String { source.trimmingCharacters(in: .whitespaces) }
    private var trimmedTarget: String { target.trimmingCharacters(in: .whitespaces) }

    public var mount: ComposeVolumeMount? {
        guard !trimmedSource.isEmpty, !trimmedTarget.isEmpty else { return nil }
        // Compose requires an absolute path inside the container; a relative target would be
        // rejected on save, so it is refused here where the user can still see the field.
        guard trimmedTarget.hasPrefix("/") else { return nil }
        return ComposeVolumeMount(source: trimmedSource, target: trimmedTarget, isReadOnly: isReadOnly)
    }

    public var isValid: Bool { mount != nil }

    /// Stores a chosen path relative to the project directory when it lives inside it, so the
    /// compose file stays portable instead of pinning the author's home directory.
    public static func relativeSource(for chosen: URL, projectDirectory: URL) -> String {
        let chosenPath = chosen.standardizedFileURL.path
        let root = projectDirectory.standardizedFileURL.path
        guard chosenPath != root else { return "." }
        guard chosenPath.hasPrefix(root + "/") else { return chosenPath }
        return "./" + String(chosenPath.dropFirst(root.count + 1))
    }
}
