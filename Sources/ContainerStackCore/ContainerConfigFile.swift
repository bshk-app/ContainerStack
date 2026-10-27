import Foundation

/// `cpus` and `memory` of the `[container]` table: what a container gets when its create request
/// names no limit. nil where the file does not set the key.
public struct ContainerResourceDefaults: Equatable, Sendable {
    public var cpus: Int?
    public var memoryBytes: Int64?

    public init(cpus: Int? = nil, memoryBytes: Int64? = nil) {
        self.cpus = cpus
        self.memoryBytes = memoryBytes
    }
}

/// The `[container]` table of Apple Container's `config.toml`. `container system start` copies the
/// user file into the app root, and socktainer and the `container` CLI read that copy.
///
/// Targeted textual edits, like `ComposeFileEditor`: the user may have written the file, so only
/// the `cpus` and `memory` lines change and every other byte stays.
public enum ContainerConfigFile {
    public enum EditError: Error, Equatable {
        /// `container` is a dotted key or inline table at the top, or a table or key is repeated.
        case unsupportedLayout(line: Int)
        case invalidValue(key: String, line: Int)
    }

    public static func read(_ text: String) throws -> ContainerResourceDefaults {
        let lines = lines(of: text)
        let table = try containerTable(in: lines)
        var defaults = ContainerResourceDefaults()
        if let index = table.keys["cpus"] {
            guard let cpus = Int(value(of: lines[index])), cpus > 0 else {
                throw EditError.invalidValue(key: "cpus", line: index + 1)
            }
            defaults.cpus = cpus
        }
        if let index = table.keys["memory"] {
            guard let size = unquoted(value(of: lines[index])), let bytes = memoryBytes(parsing: size) else {
                throw EditError.invalidValue(key: "memory", line: index + 1)
            }
            defaults.memoryBytes = bytes
        }
        return defaults
    }

    /// Sets the given keys in `[container]`. A missing key goes after the last key of the table, and
    /// a missing table goes at the end of the file.
    public static func updating(_ text: String, cpus: Int?, memoryGiB: Int?) throws -> String {
        var lines = lines(of: text)
        let table = try containerTable(in: lines)
        let entries = [("cpus", cpus.map { String($0) }), ("memory", memoryGiB.map { "\"\($0)g\"" })]
            .compactMap { key, value in value.map { (key, $0) } }

        guard let header = table.header else {
            guard !entries.isEmpty else { return text }
            let separator = text.isEmpty ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
            let block = (["[container]"] + entries.map { "\($0) = \($1)" }).joined(separator: "\n")
            return text + separator + block + "\n"
        }

        var insertion = (table.keys.values.max() ?? header) + 1
        for (key, value) in entries {
            if let index = table.keys[key] {
                lines[index] = replacingValue(of: lines[index], with: value)
            } else {
                lines.insert(Substring("\(key) = \(value)"), at: insertion)
                insertion += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A missing file sets nothing, as it does for Apple's `ConfigurationLoader`.
    public static func load(from url: URL) throws -> ContainerResourceDefaults {
        try read(text(at: url))
    }

    /// Writes a temporary file and renames it over the target of `url`, so a symlink stays a link.
    public static func save(cpus: Int?, memoryGiB: Int?, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        let updated = try updating(text(at: target), cpus: cpus, memoryGiB: memoryGiB)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(updated.utf8).write(to: target, options: .atomic)
    }

    /// Apple's `PathUtils.BaseConfigPath.home`: `$XDG_CONFIG_HOME/container`, else `~/.config/container`.
    public static func userFileURL(environment: [String: String], home: URL) -> URL {
        let configHome =
            environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".config")
        return configHome.appending(path: "container/config.toml")
    }

    /// `container system start` copies into `ApplicationRoot.defaultPath` unless `--app-root` names
    /// another root, and the runtime helper passes none.
    public static func appRootCopyURL(applicationSupport: URL) -> URL {
        applicationSupport.appending(path: "com.apple.container/config/config.toml")
    }

    /// Apple's `MemorySize`: a number, then an optional binary unit with an optional `b` or `ib`.
    static func memoryBytes(parsing size: String) -> Int64? {
        let units: [Character] = ["b", "k", "m", "g", "t", "p"]
        let trimmed = size.trimmingCharacters(in: .whitespaces).lowercased()
        let number = trimmed.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        let unit = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        guard let value = Double(number),
            let power = units.firstIndex(of: unit.first ?? "b"),
            ["", "b", "ib"].contains(String(unit.dropFirst()))
        else { return nil }
        let bytes = (value * pow(1_024, Double(power))).rounded()
        guard bytes > 0, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes)
    }

    // MARK: - Scanning

    private struct Table {
        var header: Int?
        var keys: [String: Int] = [:]
    }

    private enum LineKind {
        /// nil for `[[array]]` headers: they end a table but never name `[container]`.
        case header([String]?)
        case keyValue([String])
        case other
    }

    private static func lines(of text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private static func containerTable(in lines: [Substring]) throws -> Table {
        var table = Table()
        var current: [String]? = []
        for (index, line) in lines.enumerated() {
            switch kind(of: line) {
            case .header(let path):
                if path == ["container"] {
                    guard table.header == nil else { throw EditError.unsupportedLayout(line: index + 1) }
                    table.header = index
                }
                current = path
            case .keyValue(let path):
                if current == [], path.first == "container" {
                    throw EditError.unsupportedLayout(line: index + 1)
                }
                if current == ["container"], path.count == 1 {
                    guard table.keys[path[0]] == nil else { throw EditError.unsupportedLayout(line: index + 1) }
                    table.keys[path[0]] = index
                }
            case .other:
                break
            }
        }
        return table
    }

    private static func kind(of line: Substring) -> LineKind {
        let code = line[..<(firstUnquoted("#", in: line) ?? line.endIndex)]
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[[") {
            return .header(nil)
        }
        if trimmed.hasPrefix("[") {
            guard trimmed.hasSuffix("]"), let path = keyPath(trimmed.dropFirst().dropLast()) else { return .other }
            return .header(path)
        }
        guard let equals = firstUnquoted("=", in: code), let path = keyPath(code[..<equals]) else {
            return .other
        }
        return .keyValue(path)
    }

    /// The value text of a `key = value` line, without its comment and surrounding whitespace.
    private static func value(of line: Substring) -> String {
        guard let equals = firstUnquoted("=", in: line) else { return "" }
        let rest = line[line.index(after: equals)...]
        return String(rest[..<(firstUnquoted("#", in: rest) ?? rest.endIndex)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `line` with a new value. The key, the spacing and the comment stay.
    private static func replacingValue(of line: Substring, with value: String) -> Substring {
        guard let equals = firstUnquoted("=", in: line) else { return line }
        let rest = line[line.index(after: equals)...]
        let start = rest.firstIndex { $0 != " " && $0 != "\t" } ?? rest.endIndex
        let code = line[start..<(firstUnquoted("#", in: line[start...]) ?? line.endIndex)]
        let end = code.lastIndex { !$0.isWhitespace }.map(line.index(after:)) ?? start
        return Substring(String(line[..<start]) + value + String(line[end...]))
    }

    private static func text(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func unquoted(_ value: String) -> String? {
        guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else {
            return nil
        }
        return String(value.dropFirst().dropLast())
    }

    /// A dotted key of bare or quoted parts. nil when the text is not one, such as `1, 2` inside a
    /// multi-line array.
    private static func keyPath(_ text: Substring) -> [String]? {
        var parts: [String] = []
        var rest = text.drop(while: \.isWhitespace)
        while let first = rest.first {
            if first == "\"" || first == "'" {
                guard let close = rest.dropFirst().firstIndex(of: first) else { return nil }
                parts.append(String(rest[rest.index(after: rest.startIndex)..<close]))
                rest = rest[rest.index(after: close)...]
            } else {
                let bare = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
                guard !bare.isEmpty else { return nil }
                parts.append(String(bare))
                rest = rest.dropFirst(bare.count)
            }
            rest = rest.drop(while: \.isWhitespace)
            guard !rest.isEmpty else { return parts }
            guard rest.first == "." else { return nil }
            rest = rest.dropFirst().drop(while: \.isWhitespace)
        }
        return nil
    }

    /// The first `target` outside a basic or literal string.
    private static func firstUnquoted(_ target: Character, in text: Substring) -> Substring.Index? {
        var quote: Character?
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if let open = quote {
                if escaped {
                    escaped = false
                } else if character == "\\", open == "\"" {
                    escaped = true
                } else if character == open {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == target {
                return index
            }
        }
        return nil
    }
}
