import Foundation

public enum ByteSize {
    private static let units = ["B", "kB", "MB", "GB", "TB", "PB"]

    public static func formatted(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else {
            return "—"
        }
        if bytes < 1000 {
            return "\(bytes) B"
        }

        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1000, unitIndex < units.count - 1 {
            value /= 1000
            unitIndex += 1
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}
