import CryptoKit
import Foundation

/// A compose project the runtime is already holding containers for, read off the labels Compose
/// writes on every container it creates.
///
/// The Stacks list used to come only from a registry the user fills through Add Existing / New Stack,
/// so a project started the normal way — `docker compose up` in a terminal — left the screen empty
/// while Containers happily listed its containers. Everything the row needs is on the containers.
public struct DiscoveredComposeProject: Equatable, Sendable {
    /// `com.docker.compose.project`: the project name Compose derived or was given with `-p`.
    public let name: String
    /// `com.docker.compose.project.config_files`, in the order Compose merged them, exactly as the
    /// label records them: the first is the base file, the rest are overrides. Kept as text because
    /// `URL(fileURLWithPath:)` resolves a relative path against the app's working directory the
    /// moment it is built, which silently invents a path Compose never meant.
    public let configFiles: [String]
    /// `com.docker.compose.project.working_dir`: where Compose resolved relative paths against.
    public let workingDirectory: URL?
    /// The services seen, from `com.docker.compose.service`.
    public let services: [String]
    /// Whether any of the project's containers is running.
    public let hasRunningContainer: Bool

    public var primaryFile: String? { configFiles.first }
}

public enum ComposeProjectDiscovery {
    public static let projectLabel = "com.docker.compose.project"
    public static let serviceLabel = "com.docker.compose.service"
    public static let workingDirLabel = "com.docker.compose.project.working_dir"
    public static let configFilesLabel = "com.docker.compose.project.config_files"

    /// Groups containers into the projects they belong to. Containers without a project label — the
    /// ones started with `docker run` — are not projects and are ignored.
    public static func discover(from containers: [DockerContainerSummary]) -> [DiscoveredComposeProject] {
        var order: [String] = []
        var byProject: [String: [DockerContainerSummary]] = [:]

        for container in containers {
            guard let project = container.labels?[projectLabel], !project.isEmpty else { continue }
            if byProject[project] == nil { order.append(project) }
            byProject[project, default: []].append(container)
        }

        return order.compactMap { project in
            guard let members = byProject[project] else { return nil }
            // Compose writes the same project labels on every container it creates, but a container
            // can be recreated by an older Compose or edited by hand, so take the first member that
            // actually carries each value rather than assuming the first container has them all.
            let configFiles =
                members
                .compactMap { $0.labels?[configFilesLabel] }
                .first
                .map(parseConfigFiles) ?? []
            let workingDir =
                members
                .compactMap { $0.labels?[workingDirLabel] }
                .first
                .map { URL(fileURLWithPath: $0) }

            let services =
                members
                .compactMap { $0.labels?[serviceLabel] }
                .reduce(into: [String]()) { seen, service in
                    if !seen.contains(service) { seen.append(service) }
                }

            return DiscoveredComposeProject(
                name: project,
                configFiles: configFiles,
                workingDirectory: workingDir,
                services: services,
                hasRunningContainer: members.contains(where: \.isRunning)
            )
        }
    }

    /// `config_files` is a comma-separated list of absolute paths. A path containing a comma cannot be
    /// told apart from a separator — Compose has the same ambiguity — so the components are trimmed
    /// and empties dropped, and a relative entry is resolved against the project's working directory
    /// by the caller that has it.
    public static func parseConfigFiles(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A stack row for a project the registry has never heard of.
    ///
    /// The id is derived from the project's identity rather than random, so the row keeps the same
    /// identity across refreshes: SwiftUI would otherwise tear down and rebuild the row — losing
    /// selection and any per-stack state — every few seconds.
    public static func stack(for project: DiscoveredComposeProject) -> ComposeStack? {
        let files = resolvedFiles(for: project)
        guard let base = files.first else { return nil }
        return ComposeStack(
            id: deterministicID(for: project),
            name: project.name,
            fileURL: base,
            overrideFiles: Array(files.dropFirst())
        )
    }

    /// Every config file Compose recorded, made absolute. Overrides are kept: acting on the base file
    /// alone describes a different project, and `up --remove-orphans` would delete services that only
    /// the override defines.
    public static func resolvedFiles(for project: DiscoveredComposeProject) -> [URL] {
        project.configFiles.compactMap { resolve(path: $0, workingDirectory: project.workingDirectory) }
    }

    private static func resolve(path: String, workingDirectory: URL?) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        guard let workingDirectory else { return nil }
        return workingDirectory.appendingPathComponent(path).standardizedFileURL
    }

    /// The compose file to act on: the base file, made absolute against the working directory when
    /// Compose recorded it relative.
    public static func resolvedPrimaryFile(for project: DiscoveredComposeProject) -> URL? {
        guard let primary = project.primaryFile else { return nil }
        return resolve(path: primary, workingDirectory: project.workingDirectory)
    }

    static func deterministicID(for project: DiscoveredComposeProject) -> UUID {
        let seed = "\(project.name)\u{0}\(resolvedPrimaryFile(for: project)?.path ?? "")"
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        // Shape the digest into a v4-looking UUID so nothing downstream trips over a reserved bit
        // pattern; the value stays a pure function of the project's identity.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Registered stacks plus the projects only the runtime knows about.
    ///
    /// A registered stack wins on identity: it carries the name and id the user chose, and its row
    /// already works. A running project matches a registered stack when it points at the same compose
    /// file, or — for a stack the app started, which passes `--project-name <stack name>` — when the
    /// names match.
    public static func merge(registered: [ComposeStack], discovered: [DiscoveredComposeProject]) -> [ComposeStack] {
        let additions = discovered.compactMap { project -> ComposeStack? in
            let file = resolvedPrimaryFile(for: project)?.path
            let alreadyListed = registered.contains { stack in
                // Identity is the pair. Matching on either half alone hid a real project: one file
                // can back several projects (`docker compose -p production -f compose.yaml up`
                // beside a registered `demo`), and one name can be reused for another file.
                guard stack.name == project.name else { return false }
                guard let file else { return true }
                return stack.fileURL.standardizedFileURL.path == file
            }
            return alreadyListed ? nil : stack(for: project)
        }
        return registered + additions
    }
}
