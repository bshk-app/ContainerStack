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
        let executable = executablePath.hasPrefix("/")
            ? URL(fileURLWithPath: executablePath)
            : URL(fileURLWithPath: workingDirectory).appending(path: executablePath)

        return executable
            .deletingLastPathComponent()
            .appending(path: name)
            .standardizedFileURL
            .path
    }
}
