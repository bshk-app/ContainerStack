import Foundation

/// Live state of one Compose service, mirrored from `docker compose ps`.
public struct ComposeServiceStatus: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var state: String
    public var health: String?
    public var publishedPorts: [String]
    public var isRunning: Bool

    public init(name: String, state: String, health: String?, publishedPorts: [String], isRunning: Bool) {
        self.name = name
        self.state = state
        self.health = health
        self.publishedPorts = publishedPorts
        self.isRunning = isRunning
    }
}

/// Runs `docker compose` against a registered stack. Every invocation goes through
/// `ComposeCommand.plan` so `DOCKER_HOST` and the docker binary lookup stay in one place; the
/// global flags (`--project-name`/`--file`/`--project-directory`) precede the verb so relative
/// bind mounts resolve against the compose file's own directory.
public struct ComposeRunner: Sendable {
    public enum RunnerError: Error, Equatable {
        case dockerCLIMissing
        case invalidComposeFile(String)
        case commandFailed(String)
    }

    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: - Commands

    /// `config --format json`: the merged, normalized project model. Compose writes the JSON to
    /// stdout and any deprecation warnings (e.g. a `version:` key) to stderr, so stdout and stderr
    /// are captured separately to keep the JSON clean; a non-zero exit carries stderr verbatim.
    public func config(stack: ComposeStack) async throws -> ComposeProjectModel {
        let arguments = Self.composeArguments(for: stack, verb: "config", extra: ["--format", "json"])
        let result = try await runSeparate(arguments)
        guard result.status == 0 else {
            throw RunnerError.invalidComposeFile(result.stderr)
        }
        return try ComposeProjectModel.parse(
            configJSON: Data(result.stdout.utf8),
            fallbackName: stack.name
        )
    }

    /// `ps --format json --all`. Recent Compose emits one JSON object per line (JSON Lines), older
    /// versions a single array; both are accepted.
    public func status(stack: ComposeStack) async throws -> [ComposeServiceStatus] {
        let arguments = Self.composeArguments(for: stack, verb: "ps", extra: ["--format", "json", "--all"])
        let result = try await run(arguments)
        guard result.status == 0 else {
            throw RunnerError.commandFailed(result.output)
        }
        return Self.parseStatus(result.output)
    }

    /// `up --detach --remove-orphans`. Returns combined stdout+stderr verbatim.
    public func up(stack: ComposeStack) async throws -> String {
        let arguments = Self.composeArguments(for: stack, verb: "up", extra: ["--detach", "--remove-orphans"])
        return try await runReturningOutput(arguments)
    }

    /// `down`, with `--volumes` when `removeVolumes`. Returns combined stdout+stderr verbatim.
    public func down(stack: ComposeStack, removeVolumes: Bool) async throws -> String {
        let arguments = Self.composeArguments(
            for: stack,
            verb: "down",
            extra: removeVolumes ? ["--volumes"] : []
        )
        return try await runReturningOutput(arguments)
    }

    /// `restart`. Returns combined stdout+stderr verbatim.
    public func restart(stack: ComposeStack) async throws -> String {
        let arguments = Self.composeArguments(for: stack, verb: "restart", extra: [])
        return try await runReturningOutput(arguments)
    }

    /// `logs --no-color --tail <n>` plus an optional service. Returns combined stdout+stderr verbatim.
    public func logs(stack: ComposeStack, service: String?, tail: Int) async throws -> String {
        var extra = ["--no-color", "--tail", String(tail)]
        if let service {
            extra.append(service)
        }
        let arguments = Self.composeArguments(for: stack, verb: "logs", extra: extra)
        return try await runReturningOutput(arguments)
    }

    /// Writes `text` only if `docker compose config -q` accepts it, so a malformed edit can never
    /// replace a working file. Validation runs against a sibling temp file in the stack's own
    /// directory (same `--project-directory`), and on success the real file is replaced atomically.
    /// The temp file is always removed, including on failure.
    public func saveValidated(text: String, to stack: ComposeStack) async throws {
        let directory = stack.projectDirectory
        let tempURL = directory.appending(path: Self.validationTempName(for: stack))
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try Data(text.utf8).write(to: tempURL, options: .atomic)

        // `--file` points at the temp copy; the project directory is unchanged so relative binds
        // validate against the same roots the real file uses.
        let arguments = [
            "--project-name", stack.name,
            "--file", tempURL.path,
            "--project-directory", directory.path,
            "config", "-q",
        ]
        let result = try await run(arguments)
        guard result.status == 0 else {
            throw RunnerError.invalidComposeFile(result.output)
        }

        // Atomic swap: the validated temp becomes the real file.
        if FileManager.default.fileExists(atPath: stack.fileURL.path) {
            _ = try FileManager.default.replaceItem(
                at: stack.fileURL,
                withItemAt: tempURL,
                backupItemName: nil,
                options: [],
                resultingItemURL: nil
            )
        } else {
            try FileManager.default.moveItem(at: tempURL, to: stack.fileURL)
        }
    }

    // MARK: - Testable builders/parsers

    /// A per-call name for the validation temp file. `StackRegistry.save` already carries a UUID
    /// for the same reason: two saves of one stack, or a crash mid-`config -q`, must not share a
    /// file sitting next to the user's compose file. Leading dot hides it, `.yaml` keeps compose
    /// reading it as one.
    internal static func validationTempName(for stack: ComposeStack) -> String {
        ".\(stack.name).containerstack-validate.\(UUID().uuidString).yaml"
    }
    /// The arguments that follow the `compose` subcommand: global flags first (compose parses
    /// `--file`/`--project-name`/`--project-directory` as top-level options, before the verb), then
    /// the verb and its options. Kept internal so tests can assert exact flag order without docker.
    internal static func composeArguments(
        for stack: ComposeStack,
        verb: String,
        extra: [String] = []
    ) -> [String] {
        // One `--file` per compose file, in Compose's own merge order: passing only the base file
        // would describe a different project than the one running, and `up --remove-orphans` would
        // then treat a service defined in an override as a stray and delete it.
        ["--project-name", stack.name]
            + stack.composeFiles.flatMap { ["--file", $0.path] }
            + ["--project-directory", stack.projectDirectory.path, verb]
            + extra
    }

    /// Parses `ps --format json` output into statuses. Tries a single JSON array first (older
    /// Compose), then falls back to JSON Lines (recent Compose), skipping any non-JSON line such as
    /// a stray warning so the result is robust to combined stdout/stderr capture.
    internal static func parseStatus(_ output: String) -> [ComposeServiceStatus] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let data = Data(output.utf8)
        if let array = try? JSONDecoder().decode([ComposePSItem].self, from: data) {
            return array.map(toStatus)
        }

        return output.split(separator: "\n").compactMap { line in
            guard let bytes = String(line).data(using: .utf8),
                let item = try? JSONDecoder().decode(ComposePSItem.self, from: bytes)
            else {
                return nil
            }
            return toStatus(item)
        }
    }

    private static func toStatus(_ item: ComposePSItem) -> ComposeServiceStatus {
        let state = item.state ?? ""
        // Compose emits an empty Health string (not null) when a service has no healthcheck.
        let health = item.health.flatMap { $0.isEmpty ? nil : $0 }
        let publishedPorts = (item.publishers ?? []).compactMap { publisher -> String? in
            // Compose lists unpublished ports too (PublishedPort 0); skip those.
            guard let published = publisher.publishedPort, published != 0 else { return nil }
            let url = publisher.url ?? "0.0.0.0"
            let target = publisher.targetPort ?? 0
            let transport = publisher.protocolName ?? "tcp"
            return "\(url):\(published)->\(target)/\(transport)"
        }
        return ComposeServiceStatus(
            name: item.service ?? item.name ?? "",
            state: state,
            health: health,
            publishedPorts: publishedPorts,
            isRunning: state == "running"
        )
    }

    // MARK: - Execution

    /// Resolves docker and assembles the Process; throws `.dockerCLIMissing` when ComposeCommand
    /// cannot locate the binary. Wiring the pipes is left to each caller.
    private static func makeProcess(socketPath: String, arguments: [String]) throws -> Process {
        let plan = ComposeCommand.plan(socketPath: socketPath, arguments: arguments)
        guard let executablePath = plan.executablePath else {
            throw RunnerError.dockerCLIMissing
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.standardInput = FileHandle.nullDevice
        return process
    }

    /// Runs a command, combining stdout and stderr into one stream for verbatim display. Reads the
    /// pipe to EOF before `waitUntilExit` so a chatty Compose run cannot deadlock on a full buffer.
    private func run(_ arguments: [String]) async throws -> (status: Int32, output: String) {
        let socketPath = self.socketPath
        return try await Task.detached(priority: .userInitiated) {
            let process = try Self.makeProcess(socketPath: socketPath, arguments: arguments)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Runs a command keeping stdout and stderr apart. `config --format json` writes the JSON to
    /// stdout and deprecation warnings (a `version:` key) to stderr; the split keeps the JSON clean
    /// and surfaces the real error on failure. Config output is small (one merged document), so
    /// draining stdout fully before stderr cannot deadlock on the pipe buffer.
    private func runSeparate(_ arguments: [String]) async throws -> (status: Int32, stdout: String, stderr: String) {
        let socketPath = self.socketPath
        return try await Task.detached(priority: .userInitiated) {
            let process = try Self.makeProcess(socketPath: socketPath, arguments: arguments)
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                status: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }.value
    }

    private func runReturningOutput(_ arguments: [String]) async throws -> String {
        let result = try await run(arguments)
        guard result.status == 0 else {
            throw RunnerError.commandFailed(result.output)
        }
        return result.output
    }
}

// MARK: - `ps` decoding

/// Mirrors the shape of a `docker compose ps --format json` object. Keys are optional because
/// Compose omits them rather than nulling them out.
private struct ComposePSItem: Decodable {
    let name: String?
    let service: String?
    let state: String?
    let health: String?
    let publishers: [ComposePublisher]?

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case service = "Service"
        case state = "State"
        case health = "Health"
        case publishers = "Publishers"
    }
}

private struct ComposePublisher: Decodable {
    let url: String?
    let targetPort: Int?
    let publishedPort: Int?
    let protocolName: String?

    private enum CodingKeys: String, CodingKey {
        case url = "URL"
        case targetPort = "TargetPort"
        case publishedPort = "PublishedPort"
        case protocolName = "Protocol"
    }
}
