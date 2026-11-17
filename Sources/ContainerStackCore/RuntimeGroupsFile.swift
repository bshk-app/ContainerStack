import Foundation

public enum RuntimeGroupsFile {
    public enum State: Equatable, Sendable {
        case missing
        case valid(RuntimeGroupsDocument)
        case invalid(cause: String)

        public var document: RuntimeGroupsDocument? {
            switch self {
            case .missing: .defaults
            case .valid(let document): document
            case .invalid: nil
            }
        }
    }

    public static func url(home: URL) -> URL {
        home.appending(path: ".containerstack/runtime-groups.json")
    }

    public static func read(at url: URL) -> State {
        do {
            return .valid(try decode(Data(contentsOf: url)))
        } catch let error as RuntimeGroupsDocumentError {
            return .invalid(cause: error.description)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .invalid(cause: "runtime-groups.json cannot be read: \(error.localizedDescription)")
        }
    }

    public static func decode(_ data: Data) throws -> RuntimeGroupsDocument {
        try RuntimeGroupsDocument.decode(data)
    }

    public static func encode(_ document: RuntimeGroupsDocument) -> Data {
        func quote(_ text: String) -> String {
            // A Swift String always has a valid JSON string representation.
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes]
                return String(decoding: try encoder.encode(text), as: UTF8.self)
            } catch {
                preconditionFailure("A string must encode as JSON: \(error)")
            }
        }
        let groups = document.groups.map {
            "    { \"name\": \(quote($0.name)), \"kind\": \(quote($0.kind.rawValue)), \"idleMinutes\": \($0.idleMinutes), \"enabled\": \($0.enabled) }"
        }
        let rules = document.rules.map { rule in
            switch rule {
            case .image(let group, let pattern): "    { \"group\": \(quote(group)), \"image\": \(quote(pattern)) }"
            case .stdioSession(let group): "    { \"group\": \(quote(group)), \"stdioSession\": true }"
            }
        }
        return Data(
            ("{\n  \"version\": \(document.version),\n  \"groups\": [\n" + groups.joined(separator: ",\n")
                + "\n  ],\n  \"rules\": [\n" + rules.joined(separator: ",\n") + "\n  ]\n}\n").utf8)
    }

    public static func write(_ document: RuntimeGroupsDocument, to url: URL, expecting: Date?) throws {
        let target = try resolvedTarget(url)
        let current = modificationDate(at: target)
        guard current == expecting else { throw EditError.changed }
        try save(document, to: target)
    }

    /// Re-read before applying a single edit, preserving all fields the editor does not own.
    public static func edit(at url: URL, change: (inout RuntimeGroupsDocument) -> Void) throws {
        try edit(at: url, readState: read(at:), change: change)
    }

    static func edit(
        at url: URL, readState: (URL) -> State, change: (inout RuntimeGroupsDocument) -> Void
    ) throws {
        let target = try resolvedTarget(url)
        let stamp = modificationDate(at: target)
        var document: RuntimeGroupsDocument
        switch readState(target) {
        case .missing: document = .defaults
        case .valid(let parsed): document = parsed
        case .invalid(let cause): throw EditError.invalid(cause)
        }

        change(&document)
        try write(document, to: target, expecting: stamp)
    }

    public static func reset(at url: URL) throws {
        try save(.defaults, to: resolvedTarget(url))
    }

    public static func modificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: resolvedTarget(url).path))?[.modificationDate]
            as? Date
    }

    private static func resolvedTarget(_ url: URL) throws -> URL {
        var target = url.standardizedFileURL
        var seen: Set<String> = []
        while let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) {
            guard seen.insert(target.path).inserted else {
                throw EditError.invalid("runtime-groups.json cannot be read: symbolic link loop")
            }
            target =
                (destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : target.deletingLastPathComponent().appending(path: destination)).standardizedFileURL
        }
        return target.resolvingSymlinksInPath()
    }

    private static func save(
        _ document: RuntimeGroupsDocument, to target: URL
    ) throws {
        let data = encode(document)
        _ = try decode(data)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: target, options: .atomic)
    }

    public enum EditError: Error, LocalizedError, Equatable {
        case changed
        case invalid(String)
        public var errorDescription: String? {
            switch self {
            case .changed: "The file changed. Reload it and try again."
            case .invalid(let cause): cause
            }
        }
    }
}
