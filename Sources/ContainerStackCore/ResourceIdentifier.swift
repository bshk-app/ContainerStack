import Foundation

public enum ResourceIdentifier {
    private static let digestPrefix = "sha256:"
    private static let shortLength = 12

    /// Docker identifiers are content digests; Apple Container names volumes and networks directly.
    /// Only digests are shortened so human-readable identifiers stay intact.
    public static func short(_ identifier: String) -> String {
        let trimmed =
            identifier.hasPrefix(digestPrefix)
            ? String(identifier.dropFirst(digestPrefix.count))
            : identifier
        guard trimmed.count > shortLength, trimmed.allSatisfy(\.isHexDigit) else {
            return trimmed
        }
        return String(trimmed.prefix(shortLength))
    }
}
