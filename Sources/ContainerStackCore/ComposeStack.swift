import Foundation

/// A registered Docker Compose project. `fileURL` points at the compose file; the app edits its
/// ports and volumes in place and drives `docker compose` against it.
public struct ComposeStack: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var fileURL: URL

    /// The override files Compose merged after `fileURL`, in order. Empty for a stack the user added
    /// by hand — the file picker takes one file — and populated for a discovered project whose
    /// containers record several in `com.docker.compose.project.config_files`.
    ///
    /// They have to be carried, not dropped: acting on the base file alone describes a different
    /// project than the one running, and `up` passes `--remove-orphans`, so a service defined only in
    /// an override would be deleted as a stray.
    public var overrideFiles: [URL] = []

    /// Every compose file, base first, as Compose itself merged them.
    public var composeFiles: [URL] { [fileURL] + overrideFiles }

    /// The directory containing the compose file. Passed to Compose as `--project-directory` so
    /// relative bind mounts (`./httpd.conf`) resolve against the file's own location, not the
    /// app's working directory.
    public var projectDirectory: URL {
        fileURL.deletingLastPathComponent()
    }

    public init(id: UUID = UUID(), name: String, fileURL: URL, overrideFiles: [URL] = []) {
        self.id = id
        self.name = name
        self.fileURL = fileURL
        self.overrideFiles = overrideFiles
    }

    /// Written by hand because the synthesized decoder demands every key: adding `overrideFiles` to
    /// the stored shape made every registry written before it unreadable, and a registry that fails
    /// to decode takes all of the user's registered stacks off the screen at once.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        fileURL = try container.decode(URL.self, forKey: .fileURL)
        overrideFiles = try container.decodeIfPresent([URL].self, forKey: .overrideFiles) ?? []
    }

    /// Derives a Compose-legal project name (`[a-z0-9_-]`, no other characters) from the parent
    /// directory. Runs of disallowed characters collapse to a single `-`, leading/trailing `-` is
    /// trimmed, and an empty result falls back to `"stack"` — Compose rejects names outside that
    /// alphabet, so the suggestion must always be valid.
    public static func suggestedName(for fileURL: URL) -> String {
        let directory = fileURL.deletingLastPathComponent().lastPathComponent.lowercased()
        var result = ""
        var needsSeparator = false
        for character in directory {
            let allowed = character.isASCII
                && (character.isLetter || character.isNumber || character == "_" || character == "-")
            if allowed {
                result.append(character)
                needsSeparator = false
            } else if !result.isEmpty, !needsSeparator {
                result.append("-")
                needsSeparator = true
            }
        }
        while result.hasPrefix("-") { result.removeFirst() }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "stack" : result
    }
}

/// Persists the list of registered stacks to disk. Writes are atomic so a crash mid-save can never
/// truncate the registry; a corrupt file surfaces as an error rather than being silently emptied.
public struct StackRegistry: Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ContainerStack/stacks.json")
    }

    public let url: URL

    public init(url: URL = StackRegistry.defaultURL) {
        self.url = url
    }

    /// Missing file is the normal first-run state and returns `[]`; a genuine decode failure is
    /// rethrown so corruption is visible to the user instead of being masked as an empty list.
    public func load() throws -> [ComposeStack] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ComposeStack].self, from: data)
    }

    /// Writes to a sibling temp file then swaps it in with `FileManager.replaceItem`, so a crash
    /// between writing and renaming leaves the previous registry intact. Creates the support
    /// directory on first save.
    public func save(_ stacks: [ComposeStack]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = try JSONEncoder().encode(stacks)
        let tempURL = directory.appending(path: ".stacks.\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItem(
                    at: url,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: [],
                    resultingItemURL: nil
                )
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}
