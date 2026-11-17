import Foundation

public struct CStackCommand: Sendable {
    public enum State: Equatable, Sendable {
        case missing
        case installed
        case homebrew
        case other(String)
    }

    public let executable: URL
    public let link: URL
    public let homebrewLink: URL

    public init(
        executable: URL,
        link: URL = URL(filePath: "/usr/local/bin/cstack"),
        homebrewLink: URL = URL(filePath: "/opt/homebrew/bin/cstack")
    ) {
        self.executable = executable
        self.link = link
        self.homebrewLink = homebrewLink
    }

    public func resolvedCommand(path: String) -> URL? {
        path.split(separator: ":", omittingEmptySubsequences: false).lazy.map {
            URL(filePath: $0.isEmpty ? FileManager.default.currentDirectoryPath : String($0))
                .appending(path: "cstack")
        }.first { url in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
        }
    }

    public func state(path: String) -> State {
        guard let found = resolvedCommand(path: path) else { return .missing }
        if found.standardizedFileURL == homebrewLink.standardizedFileURL { return .homebrew }
        if found.standardizedFileURL == link.standardizedFileURL,
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil,
            found.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath()
        {
            return .installed
        }
        let target = found.resolvingSymlinksInPath().path
        let suffix = "/Contents/MacOS/cstack"
        return .other(target.hasSuffix(suffix) ? String(target.dropLast(suffix.count)) : target)
    }

    public enum Operation { case install, remove, replace }

    public func shellScript(for operation: Operation) throws -> String {
        let files = FileManager.default
        let destination = try? files.destinationOfSymbolicLink(atPath: link.path)
        let quotedLink = Self.quote(link.path)
        let quotedExecutable = Self.quote(executable.path)
        switch operation {
        case .install:
            guard destination == nil, !files.fileExists(atPath: link.path),
                files.isExecutableFile(atPath: executable.path)
            else { throw CommandError.conflict }
            return "set -eu; /bin/mkdir -p \(Self.quote(link.deletingLastPathComponent().path)); "
                + "test ! -e \(quotedLink); test ! -L \(quotedLink); /bin/ln -s \(quotedExecutable) \(quotedLink)"
        case .remove, .replace:
            guard let destination,
                operation == .remove
                    ? link.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath()
                    : destination.hasSuffix(".app/Contents/MacOS/cstack")
            else { throw CommandError.conflict }
            let check =
                "set -eu; test -L \(quotedLink); test \"$(/usr/bin/readlink \(quotedLink))\" = \(Self.quote(destination)); "
            if operation == .remove { return check + "/bin/rm -f \(quotedLink)" }
            guard files.isExecutableFile(atPath: executable.path) else { throw CommandError.conflict }
            return check + "/bin/ln -sfn \(quotedExecutable) \(quotedLink)"
        }
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public enum CommandError: LocalizedError {
        case conflict
        public var errorDescription: String? {
            "The cstack link changed or is not an app link. Only /usr/local/bin/cstack links to ContainerStack can be replaced or removed."
        }
    }
}
