import Foundation

public enum RuntimePaths {
    /// Resolves a file next to an executable. `launchd` starts a `BundleProgram` agent with a
    /// bundle-relative `argv[0]`, so a relative path must be anchored to the working directory
    /// instead of the filesystem root.
    public static func sibling(
        named name: String,
        ofExecutableAt executablePath: String,
        workingDirectory: String
    ) -> String {
        let executable =
            executablePath.hasPrefix("/")
            ? URL(fileURLWithPath: executablePath)
            : URL(fileURLWithPath: workingDirectory).appending(path: executablePath)

        return
            executable
            .deletingLastPathComponent()
            .appending(path: name)
            .standardizedFileURL
            .path
    }

    /// Log destinations for the runtime helper, in the order it should try them. launchd gives the
    /// agent no output destination, so the helper's own file is the only sink; when it cannot be
    /// opened, a temporary-directory fallback is what keeps the process from running blind.
    public static func runtimeLogCandidates(home: URL, temporaryDirectory: URL) -> [URL] {
        [
            home.appending(path: "Library/Logs/ContainerStack/runtime.log"),
            temporaryDirectory.appending(path: "containerstack-runtime.log"),
        ]
    }
}
