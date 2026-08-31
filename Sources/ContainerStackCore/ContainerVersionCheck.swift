import Foundation

/// What `container --version` turned out to be, judged against the version this build pins.
public enum ContainerVersionVerdict: Equatable, Sendable {
    case supported
    case mismatch(found: String, expected: String)
    case unavailable(path: String, reason: String)

    public var isSupported: Bool {
        self == .supported
    }
}

/// The single owner of the version verdict.
///
/// Two things act on it and they must agree: the helper refuses to run, and the app refuses to
/// launch the helper. Left as two comparisons they would drift, and the user would meet a runtime
/// that one half of the product considers fine.
///
/// Judging is separated from running so the decision is testable without a binary on disk.
public enum ContainerVersionCheck {
    /// `container --version` prints a sentence, so the pin is looked for inside it - but on a
    /// component boundary, not as a bare substring. `contains("1.3.1")` also accepts `1.3.10`,
    /// and Apple has shipped a tenth patch before; a check that passes for the wrong reason is
    /// worse than none, because it is the thing standing between a user and a runtime this build
    /// was never tested against.
    public static func verdict(reportedVersion: String, expected: String) -> ContainerVersionVerdict {
        let trimmed = reportedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard containsVersionToken(expected, in: trimmed) else {
            return .mismatch(found: trimmed, expected: expected)
        }
        return .supported
    }

    /// True when `version` appears in `text` bounded by something that cannot extend a version:
    /// neither a digit nor a dot on either side.
    private static func containsVersionToken(_ version: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: version, range: searchRange) {
            let beforeOK =
                found.lowerBound == text.startIndex
                || !isVersionCharacter(text[text.index(before: found.lowerBound)])
            let afterOK =
                found.upperBound == text.endIndex
                || !isVersionCharacter(text[found.upperBound])
            if beforeOK, afterOK {
                return true
            }
            guard found.upperBound < text.endIndex else { return false }
            searchRange = text.index(after: found.lowerBound)..<text.endIndex
        }
        return false
    }

    private static func isVersionCharacter(_ character: Character) -> Bool {
        character.isNumber || character == "."
    }

    /// Asks the binary the configuration resolved. A binary that cannot answer is `unavailable`
    /// rather than a mismatch: "installed but wrong version" and "not installed" send the reader
    /// to different places.
    public static func run(
        _ configuration: RuntimeProcessConfiguration,
        timeout: Duration? = ProcessRunner.diagnosticTimeout
    ) -> ContainerVersionVerdict {
        do {
            let result = try ProcessRunner.run(
                executablePath: configuration.containerPath,
                arguments: ["--version"],
                output: .capture(includingStandardError: true),
                timeout: timeout
            )
            guard result.status == 0 else {
                return .unavailable(
                    path: configuration.containerPath,
                    reason: "exited with status \(result.status)"
                )
            }
            return verdict(
                reportedVersion: result.output,
                expected: configuration.expectedContainerVersion
            )
        } catch {
            return .unavailable(path: configuration.containerPath, reason: "\(error)")
        }
    }
}

extension ContainerVersionVerdict {
    /// What a person should read. `nil` when there is nothing to say.
    ///
    /// It names both versions: the log line this replaces said only what was found, which left
    /// the reader to guess what was wanted.
    public var userFacingMessage: String? {
        switch self {
        case .supported:
            return nil
        case .mismatch(let found, let expected):
            return """
                Apple Container \(expected) is required, but \(found) is installed. \
                Update ContainerStack and its runtime with `brew upgrade --cask containerstack`.
                """
        case .unavailable(let path, let reason):
            return "Apple Container could not be run at \(path): \(reason)"
        }
    }

    /// The same verdict for a log, where the caller is a process rather than a person.
    public var diagnosticMessage: String? {
        switch self {
        case .supported:
            return nil
        case .mismatch(let found, let expected):
            return "unsupported Apple Container version: \(found) (expected \(expected))"
        case .unavailable(let path, let reason):
            return "could not run \(path): \(reason)"
        }
    }
}
