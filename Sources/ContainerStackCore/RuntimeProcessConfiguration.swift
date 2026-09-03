import Foundation

public struct RuntimeProcessConfiguration: Equatable, Sendable {
    public static let defaultSocketPath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".containerstack/docker.sock")
        .path

    /// The version this build is pinned to. Homebrew has no way to express a
    /// version constraint, so the pin is carried by the *name* of a keg-only
    /// formula — the `container@x.y.z` convention Homebrew itself uses for
    /// `node@20` and friends.
    public static let pinnedContainerVersion = "1.3.1"

    /// Ordered by how much they guarantee about the version.
    ///
    /// The keg-only tap formula comes first because it is the only system path
    /// that names a version: `brew upgrade` cannot move it, and it is installed
    /// alongside rather than over any homebrew-core `container`. The unversioned
    /// paths after it are whatever the machine happens to have, which is exactly
    /// the situation the pin exists to survive — they stay as a fallback so a
    /// development checkout keeps working.
    public static let containerSearchPaths = [
        "/opt/homebrew/opt/container@\(pinnedContainerVersion)/bin/container",
        "/usr/local/opt/container@\(pinnedContainerVersion)/bin/container",
        "/usr/local/bin/container",
        "/opt/homebrew/bin/container",
        "\(NSHomeDirectory())/.local/bin/container",
        "/usr/bin/container",
    ]

    /// The vendored runtime inside the app bundle, or nil outside a staged bundle.
    ///
    /// Works for both executables that need it: `Contents/MacOS/ContainerStack` and
    /// `Contents/Helpers/ContainerStackRuntime` sit two levels below `Contents`.
    public static func bundledInstallRoot(
        forExecutableAt executable: URL?,
        exists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String? {
        guard let executable else { return nil }
        let root =
            executable
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/container")
        return exists(root.appending(path: "bin/container").path) ? root.path : nil
    }

    /// The single owner of runtime resolution.
    ///
    /// The environment override wins. Otherwise the copy shipped inside the app
    /// bundle is preferred over anything installed system-wide, and a system copy
    /// remains the development fallback.
    ///
    /// Homebrew cannot pin a dependency's version: an unrelated `brew upgrade`
    /// can move Apple Container's API out from under a machine we never touched.
    /// Vendoring is what makes the pin reach a user, and `container system start`
    /// takes `--install-root` precisely so a copy can live elsewhere.
    ///
    /// The binary and its install root are decided together. Deriving them
    /// separately is how they drift apart.
    public static func make(
        socktainerPath: String,
        socketPath: String = RuntimeProcessConfiguration.defaultSocketPath,
        bundledInstallRoot: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        exists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> RuntimeProcessConfiguration {
        // The override exists to rescue a machine the search order cannot reach, so it wins.
        // It carries no install root: it may point at a copy unrelated to this bundle.
        if let override = environment["CONTAINERSTACK_CONTAINER_PATH"], !override.isEmpty {
            return RuntimeProcessConfiguration(
                containerPath: override,
                socktainerPath: socktainerPath,
                socketPath: socketPath,
                containerInstallRoot: nil
            )
        }

        if let bundledInstallRoot, exists("\(bundledInstallRoot)/bin/container") {
            return RuntimeProcessConfiguration(
                containerPath: "\(bundledInstallRoot)/bin/container",
                socktainerPath: socktainerPath,
                socketPath: socketPath,
                containerInstallRoot: bundledInstallRoot
            )
        }

        return RuntimeProcessConfiguration(
            containerPath: containerSearchPaths.first(where: exists) ?? containerSearchPaths[0],
            socktainerPath: socktainerPath,
            socketPath: socketPath,
            containerInstallRoot: nil
        )
    }

    public let containerPath: String
    public let socktainerPath: String
    public let socketPath: String
    public let expectedContainerVersion: String
    /// Set only when running the vendored copy; nil means a system install,
    /// which already knows its own root.
    public let containerInstallRoot: String?

    public init(
        containerPath: String,
        socktainerPath: String,
        socketPath: String = RuntimeProcessConfiguration.defaultSocketPath,
        expectedContainerVersion: String = RuntimeProcessConfiguration.pinnedContainerVersion,
        containerInstallRoot: String? = nil
    ) {
        self.containerInstallRoot = containerInstallRoot
        self.containerPath = containerPath
        self.socktainerPath = socktainerPath
        self.socketPath = socketPath
        self.expectedContainerVersion = expectedContainerVersion
    }

    public var containerStartArguments: [String] {
        // The flag is omitted rather than emptied for a system install: that
        // copy already knows its own root, and naming a wrong one would send
        // the daemon looking for plugins that are not there.
        guard let containerInstallRoot else {
            return ["system", "start"]
        }
        return ["system", "start", "--install-root", containerInstallRoot]
    }

    public var socktainerArguments: [String] {
        [
            "--no-check-compatibility", "--no-docker-context", "--socket", socketPath,
            "--startup-housekeeping",
        ]
    }

    /// Environment for the bridge, quieting its request log.
    ///
    /// socktainer logs every request it serves at INFO, and the destination is the helper's own
    /// `runtime.log`, which nothing rotates. Against the app's 3s poll that measured ~11 MB a
    /// day — a 20 MB file of 203,910 lines, 67,541 of them one container's stats — which buries
    /// the startup and XPC-failure lines that are the reason to open the file at all.
    ///
    /// The bridge has no log-level flag, but it is Vapor-based and honours `LOG_LEVEL`.
    /// Verified against the shipped binary: request lines disappear at `notice` while
    /// `Server started`, the DNS port fallback and every warning still appear.
    ///
    /// An explicit `LOG_LEVEL` is left untouched, so request logging can be turned back on for
    /// debugging.
    public static func socktainerEnvironment(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        guard (environment["LOG_LEVEL"] ?? "").isEmpty else {
            return environment
        }
        var quieted = environment
        quieted["LOG_LEVEL"] = "notice"
        return quieted
    }
}

public struct RuntimeLaunchPlan: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    /// The bridge the supervisor launches. Named here because the app compares the helper it ships
    /// against the one that is serving — a bundle replaced under a running LaunchAgent leaves the old
    /// process alive under an unchanged path.
    public let bridgePath: String

    public init(appBundleURL: URL) {
        let helpers = appBundleURL.appending(path: "Contents/Helpers")
        executablePath = helpers.appending(path: "ContainerStackRuntime").path
        bridgePath = helpers.appending(path: "socktainer").path
        arguments = []
    }
}

public enum RuntimeStatusParser {
    public static func isRunning(_ output: String) -> Bool {
        let normalizedOutput = output.lowercased()
        if normalizedOutput.contains("apiserver is not running") {
            return false
        }
        if normalizedOutput.contains("apiserver is running") {
            return true
        }

        return
            normalizedOutput
            .split(whereSeparator: \.isNewline)
            .contains { line in
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                return fields.count >= 2 && fields[0] == "status" && fields[1] == "running"
            }
    }

    /// The `appRoot` row of `container system status`, without its trailing slash.
    ///
    /// Everything after the field name is the value. Splitting the row on whitespace truncates
    /// `Library/Application Support` at the space — a restore script did exactly that and pointed a
    /// runtime at `Library/Application`.
    public static func appRoot(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let row = line.trimmingCharacters(in: .whitespaces)
            guard row.hasPrefix("appRoot"),
                let separator = row.dropFirst("appRoot".count).first,
                separator.isWhitespace
            else { continue }

            let value = row.dropFirst("appRoot".count).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            return value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
        }
        return nil
    }

    /// The path a runtime reports storing into, when that path is gone.
    ///
    /// Measured on a disposable runtime (`scripts/verify-stage0-remedies.sh erased-root`): with the
    /// root deleted underneath it the daemon keeps answering — `_ping` returns 200 and this same
    /// status keeps naming the missing directory — so socket health cannot see it. The remedy is the
    /// restart the app already performs: `container system start` takes no flag to reach the default,
    /// because `SystemStart.swift` declares `var appRoot = ApplicationRoot.defaultPath`.
    ///
    /// That holds while the daemon is well enough to be stopped. `container system stop` deregisters
    /// the apiserver's launchd label in exactly one place — `SystemStop.swift:90`, inside `if running`
    /// — reached only when the health ping succeeds and the container-list loop above it does not
    /// throw; the catch below swallows that failure and skips the deregister with it, and the
    /// fallback sweep filters the label back out. A wedged daemon therefore keeps its label loaded,
    /// the next start bootstraps an already-loaded label as a no-op, and the old root survives with
    /// or without the flag. In that case the state simply persists after a restart rather than
    /// clearing, which is why this reports rather than acts.
    public static func missingAppRoot(
        _ output: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        guard isRunning(output), let root = appRoot(output), !exists(root) else { return nil }
        return root
    }
}
