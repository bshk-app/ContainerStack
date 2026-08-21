import CryptoKit
import Foundation

/// Identity of the runtime helper the app launched, so the app can tell whether the bridge that is
/// serving is the one it currently ships.
///
/// The helper is supervised by a LaunchAgent, so replacing the app bundle — an update, or a
/// developer restaging a build — leaves the *old* process running from the old executable image. The
/// path it reports is unchanged, so nothing looks wrong: the app keeps talking to a bridge whose code
/// it no longer contains, which silently invalidates every check made against it.
///
/// Identity is compared rather than timestamps. A build delivered in a DMG or zip keeps the archive's
/// timestamps, so a helper file can be *older* than the process serving it while still being a
/// different build — and a downgrade is a legitimate change that no timestamp comparison can see.
public struct RuntimeHelperIdentity: Codable, Equatable, Sendable {
    public let bundleVersion: String
    /// Prefix of the helper binary's SHA-256. Truncated because it only has to distinguish builds,
    /// and a short value keeps the state file readable.
    public let digest: String

    public init(bundleVersion: String, digest: String) {
        self.bundleVersion = bundleVersion
        self.digest = digest
    }

    /// Reads the helper's digest. Returns nil when the helper is missing, which is an install
    /// problem rather than a staleness one — reporting it as a mismatch would send the app into a
    /// restart it cannot fix.
    public static func read(helperURL: URL, bundleVersion: String) -> RuntimeHelperIdentity? {
        guard let handle = try? FileHandle(forReadingFrom: helperURL) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        // Chunked so hashing a ~70 MB helper does not read it all into memory.
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return RuntimeHelperIdentity(bundleVersion: bundleVersion, digest: String(digest.prefix(16)))
    }
}

/// Records which helper the app launched, so a later probe can compare.
public struct RuntimeHelperIdentityStore: Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ContainerStack/runtime-helper.json")
    }

    private let url: URL

    public init(url: URL = RuntimeHelperIdentityStore.defaultURL) {
        self.url = url
    }

    public func load() -> RuntimeHelperIdentity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RuntimeHelperIdentity.self, from: data)
    }

    public func save(_ identity: RuntimeHelperIdentity) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(identity).write(to: url, options: .atomic)
    }
}

public enum RuntimeStaleness {
    /// True when a bridge is serving but it is not, or cannot be shown to be, the helper this bundle
    /// ships.
    ///
    /// An absent record counts as a mismatch. It is what the first launch of a build containing this
    /// check sees: a helper already serving, started by the previous build, with nothing recorded
    /// about it. Treating that as fresh would mean the guard never applies on its own rollout — the
    /// exact upgrade it exists for. The cost is one restart when the app first adopts a helper it did
    /// not launch, after which the recorded identity matches and nothing restarts again.
    ///
    /// The caller is expected to attempt this at most once per launch, so a restart that keeps
    /// failing cannot become a loop.
    public static func needsRestart(
        isServing: Bool,
        recorded: RuntimeHelperIdentity?,
        current: RuntimeHelperIdentity?
    ) -> Bool {
        // No helper on disk is an install problem, not a staleness one: restarting cannot fix it.
        guard isServing, let current else { return false }
        return recorded != current
    }
}
