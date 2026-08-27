import Foundation

/// Targeted textual edits to a compose file's `ports:`/`volumes:` sequences. The editor never
/// round-trips through a YAML library (there is none in the project, and round-tripping would
/// destroy comments, key order and quoting): it locates a service block by indentation and
/// inserts or deletes a single sequence entry, leaving every other byte untouched.
public enum ComposeFileEditor {
    public enum EditError: Error, Equatable {
        case serviceNotFound(String)
        case entryNotFound(String)
        case malformedDocument(String)
    }

    public static func addPort(_ mapping: ComposePortMapping, toService service: String, in text: String) throws
        -> String
    {
        try perform(entry: mapping, key: "ports", service: service, text: text, mode: .add)
    }

    public static func removePort(_ mapping: ComposePortMapping, fromService service: String, in text: String) throws
        -> String
    {
        try perform(entry: mapping, key: "ports", service: service, text: text, mode: .remove)
    }

    public static func addVolume(_ mount: ComposeVolumeMount, toService service: String, in text: String) throws
        -> String
    {
        try perform(entry: mount, key: "volumes", service: service, text: text, mode: .add)
    }

    public static func removeVolume(_ mount: ComposeVolumeMount, fromService service: String, in text: String) throws
        -> String
    {
        try perform(entry: mount, key: "volumes", service: service, text: text, mode: .remove)
    }

    // MARK: - Driver

    private enum Mode { case add, remove }

    private static func perform<E: ComposeSequenceEntry>(
        entry: E,
        key: String,
        service: String,
        text: String,
        mode: Mode
    ) throws -> String {
        var lines: [String]
        var trailingNewline: Bool
        (lines, trailingNewline) = splitLines(text)

        guard let servicesLine = index(ofTopLevelKey: "services", in: lines) else {
            throw EditError.malformedDocument("no services: mapping")
        }
        // The indent unit is whatever the first child under `services:` uses.
        guard let serviceIndent = childIndent(after: servicesLine, in: lines) else {
            throw EditError.serviceNotFound(service)
        }

        guard
            let (svcLine, blockEnd) = serviceBlock(name: service, indent: serviceIndent, after: servicesLine, in: lines)
        else {
            throw EditError.serviceNotFound(service)
        }

        let keyIndent = serviceChildIndent(svcLine: svcLine, blockEnd: blockEnd, fallback: serviceIndent * 2, in: lines)
        let itemIndentFallback = keyIndent + serviceIndent

        guard let keyLine = index(ofChildKey: key, indent: keyIndent, from: svcLine + 1, to: blockEnd, in: lines) else {
            if mode == .remove { throw EditError.entryNotFound(entry.raw) }
            return createKey(
                entry: entry, key: key, keyIndent: keyIndent, itemIndent: itemIndentFallback,
                svcLine: svcLine, blockEnd: blockEnd, lines: &lines, trailingNewline: trailingNewline)
        }

        if let flow = parseFlow(lines[keyLine]) {
            return try editFlow(
                flow: flow, entry: entry, mode: mode, keyLine: keyLine,
                lines: &lines, trailingNewline: trailingNewline)
        }
        return try editBlock(
            entry: entry, mode: mode, lines: &lines,
            at: SequenceLocation(
                key: key,
                keyLine: keyLine,
                keyIndent: keyIndent,
                itemIndentFallback: itemIndentFallback,
                blockEnd: blockEnd,
                trailingNewline: trailingNewline
            ))
    }

    /// Where a service's `ports:`/`volumes:` sequence sits in the document, and how the document
    /// is shaped around it. Grouped so the block editor keeps one argument per concern.
    private struct SequenceLocation {
        let key: String
        let keyLine: Int
        let keyIndent: Int
        let itemIndentFallback: Int
        let blockEnd: Int
        let trailingNewline: Bool
    }

    // MARK: - Block sequences

    private static func editBlock<E: ComposeSequenceEntry>(
        entry: E,
        mode: Mode,
        lines: inout [String],
        at location: SequenceLocation
    ) throws -> String {
        let key = location.key
        let keyLine = location.keyLine
        let trailingNewline = location.trailingNewline
        let items = try collectBlockItems(
            key: key, keyLine: keyLine, keyIndent: location.keyIndent,
            blockEnd: location.blockEnd, lines: lines)
        let itemIndent = items.first?.indent ?? location.itemIndentFallback

        switch mode {
        case .add:
            if items.contains(where: { matches(scalar: $0.scalar, entry: entry) }) {
                return join(lines, trailingNewline: trailingNewline)
            }
            let line = String(repeating: " ", count: itemIndent) + "- " + entry.renderedScalar()
            lines.insert(line, at: (items.last?.index ?? keyLine) + 1)
            return join(lines, trailingNewline: trailingNewline)
        case .remove:
            guard let match = items.firstIndex(where: { matches(scalar: $0.scalar, entry: entry) }) else {
                throw EditError.entryNotFound(entry.raw)
            }
            let matchIndex = items[match].index
            if items.count == 1 {
                lines.remove(at: max(matchIndex, keyLine))
                lines.remove(at: min(matchIndex, keyLine))
            } else {
                lines.remove(at: matchIndex)
            }
            return join(lines, trailingNewline: trailingNewline)
        }
    }

    private struct BlockItem {
        let index: Int
        let indent: Int
        let scalar: String
    }

    /// Walks the block sequence under `keyLine`, returning its items. Throws `.malformedDocument`
    /// for long-syntax entries (nested mappings) the editor cannot safely touch.
    private static func collectBlockItems(
        key: String,
        keyLine: Int,
        keyIndent: Int,
        blockEnd: Int,
        lines: [String]
    ) throws -> [BlockItem] {
        var items: [BlockItem] = []
        var index = keyLine + 1
        while index < blockEnd {
            let line = lines[index]
            if isBlankOrComment(line) {
                index += 1
                continue
            }
            let indent = leadingSpaces(line)
            if indent <= keyIndent { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                let scalar = extractItemScalar(line)
                if isLongSyntaxMapping(scalar) {
                    throw EditError.malformedDocument("\(key) entry '\(scalar)' uses long syntax")
                }
                items.append(BlockItem(index: index, indent: indent, scalar: scalar))
            } else {
                // A non-dash line deeper than the key is the continuation of a long-syntax
                // mapping item (e.g. `- target: 80` followed by `  published: 8080`).
                throw EditError.malformedDocument("\(key) sequence contains a nested mapping")
            }
            index += 1
        }
        return items
    }

    private static func createKey<E: ComposeSequenceEntry>(
        entry: E,
        key: String,
        keyIndent: Int,
        itemIndent: Int,
        svcLine: Int,
        blockEnd: Int,
        lines: inout [String],
        trailingNewline: Bool
    ) -> String {
        // Insert after the service's last existing content line so scalar keys stay grouped.
        var lastContent = svcLine
        for index in (svcLine + 1)..<blockEnd where !isBlankOrComment(lines[index]) {
            lastContent = index
        }
        let keyText = String(repeating: " ", count: keyIndent) + "\(key):"
        let itemText = String(repeating: " ", count: itemIndent) + "- " + entry.renderedScalar()
        lines.insert(contentsOf: [keyText, itemText], at: lastContent + 1)
        return join(lines, trailingNewline: trailingNewline)
    }

    // MARK: - Flow sequences

    private struct FlowSequence {
        let prefix: String  // through and including "["
        let items: [String]  // raw item text, quoting preserved
        let suffix: String  // from "]" onward
    }

    private static func editFlow<E: ComposeSequenceEntry>(
        flow: FlowSequence,
        entry: E,
        mode: Mode,
        keyLine: Int,
        lines: inout [String],
        trailingNewline: Bool
    ) throws -> String {
        var items = flow.items
        switch mode {
        case .add:
            if items.contains(where: { matches(scalar: unquote($0), entry: entry) }) {
                return join(lines, trailingNewline: trailingNewline)
            }
            items.append(entry.renderedScalar())
        case .remove:
            guard let offset = items.firstIndex(where: { matches(scalar: unquote($0), entry: entry) }) else {
                throw EditError.entryNotFound(entry.raw)
            }
            items.remove(at: offset)
            if items.isEmpty {
                lines.remove(at: keyLine)
                return join(lines, trailingNewline: trailingNewline)
            }
        }
        lines[keyLine] = flow.prefix + items.joined(separator: ", ") + flow.suffix
        return join(lines, trailingNewline: trailingNewline)
    }

    private static func parseFlow(_ line: String) -> FlowSequence? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let afterColon = line[line.index(after: colon)...]
        guard let open = afterColon.firstIndex(of: "[") else { return nil }
        // Only whitespace may sit between the colon and the opening bracket.
        let between = afterColon[..<open].filter { !$0.isWhitespace }
        guard between.isEmpty else { return nil }
        guard let close = afterColon[open...].firstIndex(of: "]") else { return nil }
        let inner = String(afterColon[afterColon.index(after: open)..<close])
        let items =
            inner
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return FlowSequence(
            prefix: String(line[...open]),
            items: items,
            suffix: String(line[close...])
        )
    }

    // MARK: - Structural helpers

    private static func index(ofTopLevelKey name: String, in lines: [String]) -> Int? {
        for index in lines.indices where mappingKey(lines[index], atIndent: 0) == name {
            return index
        }
        return nil
    }

    private static func childIndent(after lineIndex: Int, in lines: [String]) -> Int? {
        for index in (lineIndex + 1)..<lines.count {
            let line = lines[index]
            if isBlankOrComment(line) { continue }
            let indent = leadingSpaces(line)
            return indent > 0 ? indent : nil
        }
        return nil
    }

    /// Finds a service block, scanning past sibling services until the named one (or the end of
    /// the `services:` mapping) is reached.
    private static func serviceBlock(
        name: String,
        indent serviceIndent: Int,
        after servicesLine: Int,
        in lines: [String]
    ) -> (svcLine: Int, blockEnd: Int)? {
        var svcLine: Int?
        for index in (servicesLine + 1)..<lines.count {
            let line = lines[index]
            if isBlankOrComment(line) { continue }
            let indent = leadingSpaces(line)
            if indent < serviceIndent { break }
            if indent == serviceIndent {
                if mappingKey(line, atIndent: serviceIndent) == name {
                    svcLine = index
                    break
                }
                continue
            }
        }
        guard let svcLine else { return nil }

        var blockEnd = lines.count
        for index in (svcLine + 1)..<lines.count {
            let line = lines[index]
            if isBlankOrComment(line) { continue }
            if leadingSpaces(line) <= serviceIndent {
                blockEnd = index
                break
            }
        }
        return (svcLine, blockEnd)
    }

    private static func serviceChildIndent(svcLine: Int, blockEnd: Int, fallback: Int, in lines: [String]) -> Int {
        for index in (svcLine + 1)..<blockEnd {
            let line = lines[index]
            if isBlankOrComment(line) { continue }
            let indent = leadingSpaces(line)
            return indent > 0 ? indent : fallback
        }
        return fallback
    }

    private static func index(ofChildKey name: String, indent: Int, from: Int, to: Int, in lines: [String]) -> Int? {
        for index in from..<to where mappingKey(lines[index], atIndent: indent) == name {
            return index
        }
        return nil
    }

    /// The key of a mapping line at exactly `indent` leading spaces, or nil. A leading `-` or a
    /// space inside the key disqualifies it so sequence items never masquerade as mapping keys.
    private static func mappingKey(_ line: String, atIndent indent: Int) -> String? {
        guard leadingSpaces(line) == indent else { return nil }
        let rest = String(line.dropFirst(indent))
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let key = String(rest[..<colon])
        guard !key.isEmpty, !key.contains(" "), !key.hasPrefix("-") else { return nil }
        return key
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    private static func extractItemScalar(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("- ") { text = String(text.dropFirst(2)) } else if text == "-" { text = "" }
        return unquote(text.trimmingCharacters(in: .whitespaces))
    }

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        if text.first == "\"" && text.last == "\"" { return String(text.dropFirst().dropLast()) }
        if text.first == "'" && text.last == "'" { return String(text.dropFirst().dropLast()) }
        return text
    }

    /// Long-syntax mapping items look like `- target: 80` — an identifier key followed by a colon
    /// and then whitespace or end-of-line. Numeric ports and volume paths never match this.
    private static func isLongSyntaxMapping(_ scalar: String) -> Bool {
        scalar.range(of: #"^[A-Za-z_][A-Za-z0-9_]*:(\s|$)"#, options: .regularExpression) != nil
    }

    private static func matches<E: ComposeSequenceEntry>(scalar: String, entry: E) -> Bool {
        guard let parsed = E.parse(scalar) else { return false }
        return parsed.matches(entry)
    }

    private static func splitLines(_ text: String) -> (lines: [String], trailingNewline: Bool) {
        var parts = text.components(separatedBy: "\n")
        var trailingNewline = false
        if parts.last == "" {
            trailingNewline = true
            parts.removeLast()
        }
        return (parts, trailingNewline)
    }

    private static func join(_ lines: [String], trailingNewline: Bool) -> String {
        lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    // MARK: - Scalar rendering

    /// Quotes a scalar only when YAML plain-scalar rules would misread it. Volume paths are plain
    /// scalars in practice (letters, digits, `/`, `.`, `:`, `~`, `-`), so they are left alone; a
    /// space or flow indicator forces double quotes.
    static func quoteIfNeeded(_ scalar: String) -> String {
        guard needsQuoting(scalar) else { return scalar }
        let escaped =
            scalar
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func needsQuoting(_ scalar: String) -> Bool {
        if scalar.isEmpty { return true }
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:~+-")
        if !scalar.unicodeScalars.allSatisfy({ safe.contains($0) }) { return true }
        if scalar.contains(": ") || scalar.hasSuffix(":") { return true }
        if let first = scalar.first, "-?:#&*!|>'\"%@`".contains(first) { return true }
        if scalar.first == " " || scalar.last == " " { return true }
        return false
    }
}

// MARK: - Editable sequence entries

/// Unifies ports and volumes behind the editor's generic machinery. Each type supplies its own
/// `matches`, because a value derived from `docker compose config` is not textually identical to
/// the file entry it came from: bind sources are resolved to absolute paths, and ports gain an
/// explicit `tcp` protocol.
private protocol ComposeSequenceEntry: Equatable {
    var raw: String { get }
    static func parse(_ raw: String) -> Self?
    func renderedScalar() -> String
    /// True when `self` (parsed from a file entry) represents the same thing as `entry`
    /// (the value being added or removed).
    func matches(_ entry: Self) -> Bool
}

extension ComposePortMapping: ComposeSequenceEntry {
    fileprivate func renderedScalar() -> String {
        // Always quote: unquoted `3000:3000` is a YAML sexagesimal trap.
        "\"\(raw)\""
    }

    fileprivate func matches(_ entry: ComposePortMapping) -> Bool {
        guard containerPort == entry.containerPort else { return false }
        guard Self.transportEquivalent(transport, entry.transport) else { return false }
        // A fully specified port (host port known) must match on the host side too. Ranges and
        // ephemeral ports carry no host port, so they match on container port + transport alone —
        // Compose assigns or rewrites that side, never the container port.
        if let entryHost = entry.hostPort {
            guard hostPort == entryHost, (hostIP ?? "") == (entry.hostIP ?? "") else { return false }
        }
        return true
    }

    private static func transportEquivalent(_ lhs: String?, _ rhs: String?) -> Bool {
        // `tcp` is Compose's default, so it equals an unspecified protocol.
        let normalized = { (value: String?) -> String? in value == "tcp" ? nil : value }
        return normalized(lhs) == normalized(rhs)
    }
}

extension ComposeVolumeMount: ComposeSequenceEntry {
    fileprivate func renderedScalar() -> String {
        ComposeFileEditor.quoteIfNeeded(raw)
    }

    fileprivate func matches(_ entry: ComposeVolumeMount) -> Bool {
        // Docker allows one mount per container path, so the target identifies a mount even when
        // the source differs (config resolves bind sources to absolute paths). Fall back to a full
        // value match for anonymous volumes and any same-text duplicate.
        target == entry.target || self == entry
    }
}
