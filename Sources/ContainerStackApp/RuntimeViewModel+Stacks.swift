import ContainerStackCore
import Foundation

@MainActor
extension RuntimeViewModel {
    private var stackRunner: ComposeRunner { ComposeRunner(socketPath: socketPath) }
    private var registry: StackRegistry { StackRegistry() }

    // MARK: Loading

    func loadStacks() {
        do {
            stacks = try registry.load()
            stacksErrorMessage = nil
        } catch {
            stacksErrorMessage = "Could not read the stack registry: \(error)"
        }
    }

    /// Fetches config and status for every registered stack concurrently. A single stack failing
    /// never aborts the rest: its error is folded into stackMessage so the list keeps working.
    func refreshStacks() async {
        // Registered and discovered alike: a project started from a terminal needs its config and
        // status fetched exactly like one the user added by hand.
        let listed = allStacks
        guard !listed.isEmpty else {
            stackModels.removeAll()
            stackStatuses.removeAll()
            return
        }

        let runner = stackRunner
        let registered = listed

        // Storing parsed values + error strings (not Result<_, Error>) keeps the struct
        // unconditionally Sendable regardless of any Error's Sendable conformance.
        struct StackRefresh: Sendable {
            let id: UUID
            let name: String
            let config: ComposeProjectModel?
            let configError: String?
            let status: [ComposeServiceStatus]
            let statusError: String?
        }

        let results = await withTaskGroup(of: StackRefresh.self) { group in
            for stack in registered {
                group.addTask {
                    let config: ComposeProjectModel?
                    let configError: String?
                    do {
                        config = try await runner.config(stack: stack)
                        configError = nil
                    } catch {
                        config = nil
                        configError = "\(error)"
                    }

                    let status: [ComposeServiceStatus]
                    let statusError: String?
                    do {
                        status = try await runner.status(stack: stack)
                        statusError = nil
                    } catch {
                        status = []
                        statusError = "\(error)"
                    }

                    return StackRefresh(
                        id: stack.id,
                        name: stack.name,
                        config: config,
                        configError: configError,
                        status: status,
                        statusError: statusError
                    )
                }
            }
            // Collected with an explicit loop rather than `reduce(into:)`: the group is bound to
            // this actor, and handing it to a non-Sendable closure trips Swift 6's isolation check.
            var collected: [StackRefresh] = []
            for await refresh in group {
                collected.append(refresh)
            }
            return collected
        }

        var models: [UUID: ComposeProjectModel] = [:]
        var statuses: [UUID: [ComposeServiceStatus]] = [:]
        var failures: [String] = []
        for refresh in results {
            if let model = refresh.config { models[refresh.id] = model }
            if refresh.statusError == nil { statuses[refresh.id] = refresh.status }
            if let error = refresh.configError { failures.append("\(refresh.name): \(error)") }
            if let error = refresh.statusError { failures.append("\(refresh.name) status: \(error)") }
        }
        stackModels = models
        stackStatuses = statuses
        stackMessage = failures.isEmpty
            ? nil
            : "Some stacks could not be refreshed: " + failures.joined(separator: ", ")
    }

    // MARK: Lifecycle actions

    func upStack(_ stack: ComposeStack) async {
        let runner = stackRunner
        await runStackAction(stack, verb: "Bringing up", pastTense: "is up") {
            try await runner.up(stack: stack)
        }
    }

    func downStack(_ stack: ComposeStack, removeVolumes: Bool) async {
        let runner = stackRunner
        await runStackAction(stack, verb: "Taking down", pastTense: "is down") {
            try await runner.down(stack: stack, removeVolumes: removeVolumes)
        }
    }

    func restartStack(_ stack: ComposeStack) async {
        let runner = stackRunner
        await runStackAction(stack, verb: "Restarting", pastTense: "restarted") {
            try await runner.restart(stack: stack)
        }
    }

    func stackLogs(_ stack: ComposeStack, service: String?) async {
        // Reading, so the API answering is enough - see `withContainer(mutates:)`.
        guard isHealthy, busyStackID == nil else { return }
        busyStackID = stack.id
        defer { busyStackID = nil }
        do {
            let output = try await stackRunner.logs(stack: stack, service: service, tail: 200)
            stackMessage = output.isEmpty ? "No log output for \(stack.name)." : output
        } catch {
            stackMessage = "Logs failed: \(error)"
        }
    }

    private func runStackAction(
        _ stack: ComposeStack,
        verb: String,
        pastTense: String,
        operation: () async throws -> String
    ) async {
        guard canMutate, busyStackID == nil else { return }
        busyStackID = stack.id
        stackMessage = "\(verb) \(stack.name)…"
        defer { busyStackID = nil }
        do {
            let output = try await operation()
            stackMessage = output.isEmpty ? "\(stack.name) \(pastTense)." : output
            await refreshStackStatus(stack)
        } catch {
            stackMessage = "\(stack.name) failed: \(error)"
        }
    }

    // MARK: Registration

    /// Registers an existing compose file. A duplicate file URL is rejected with a message rather
    /// than adding it twice.
    func addStack(fileURL: URL) async {
        let standardized = fileURL.standardizedFileURL
        if stacks.contains(where: { $0.fileURL.standardizedFileURL == standardized }) {
            stackMessage = "\(fileURL.lastPathComponent) is already registered."
            return
        }
        let name = uniqueStackName(ComposeStack.suggestedName(for: standardized))
        let stack = ComposeStack(name: name, fileURL: standardized)
        stacks.append(stack)
        persistStacks()
        stackMessage = "Added \(stack.name)."
        await refreshStackConfig(stack)
    }

    /// Unregisters a stack only. The user's compose file on disk is never touched.
    func removeStack(_ stack: ComposeStack) {
        guard !isDiscovered(stack) else {
            // Nothing to unregister: this row exists because the runtime is holding the project's
            // containers, and it goes away with them. Removing it from the list would be a lie the
            // next refresh undoes.
            stackMessage = "\(stack.name) is running, not registered. Take it down to remove it from the list."
            return
        }
        stacks.removeAll { $0.id == stack.id }
        stackModels[stack.id] = nil
        stackStatuses[stack.id] = nil
        persistStacks()
        stackMessage = "Unregistered \(stack.name). The compose file on disk was left untouched."
    }

    /// Writes a starter compose file into the chosen directory and registers it. The ./static bind
    /// mount the template references is created alongside so the stack runs immediately.
    func createStack(named name: String, in directory: URL) async {
        let sanitized = sanitizedStackName(name)
        guard !sanitized.isEmpty else {
            stackMessage = "Provide a stack name."
            return
        }
        let fileURL = directory.appending(path: "compose.yaml")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            stacksErrorMessage = "\(fileURL.lastPathComponent) already exists in \(directory.lastPathComponent)."
            return
        }
        do {
            try Self.starterTemplate.write(to: fileURL, atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                at: directory.appending(path: "static"),
                withIntermediateDirectories: true
            )
        } catch {
            stacksErrorMessage = "Could not write \(fileURL.lastPathComponent): \(error)"
            return
        }
        let stack = ComposeStack(name: sanitized, fileURL: fileURL)
        stacks.append(stack)
        persistStacks()
        stackMessage = "Created \(stack.name) in \(directory.lastPathComponent)."
        await refreshStackConfig(stack)
    }

    private func persistStacks() {
        do {
            try registry.save(stacks)
        } catch {
            stacksErrorMessage = "Could not save the stack registry: \(error)"
        }
    }

    private func uniqueStackName(_ base: String) -> String {
        let existing = Set(stacks.map(\.name))
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }

    /// Mirrors ComposeStack.suggestedName's charset ([a-z0-9_-]) so the -p project name is legal.
    private func sanitizedStackName(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        let cleaned = lowered.unicodeScalars.reduce(into: "") { result, scalar in
            result.append(allowed.contains(scalar) ? Character(scalar) : "-")
        }
        return cleaned
    }

    // MARK: Ports and volumes

    func ports(for stack: ComposeStack, service: String) -> [ComposePortMapping] {
        stackModels[stack.id]?.services.first { $0.name == service }?.ports ?? []
    }

    func volumes(for stack: ComposeStack, service: String) -> [ComposeVolumeMount] {
        stackModels[stack.id]?.services.first { $0.name == service }?.volumes ?? []
    }

    func addPort(_ mapping: ComposePortMapping, to service: String, in stack: ComposeStack) async {
        await applyEdit(in: stack, success: "Added \(mapping.raw) to \(service).") {
            try ComposeFileEditor.addPort(mapping, toService: service, in: $0)
        }
    }

    func removePort(_ mapping: ComposePortMapping, from service: String, in stack: ComposeStack) async {
        await applyEdit(in: stack, success: "Removed \(mapping.raw) from \(service).") {
            try ComposeFileEditor.removePort(mapping, fromService: service, in: $0)
        }
    }

    func addVolume(_ mount: ComposeVolumeMount, to service: String, in stack: ComposeStack) async {
        await applyEdit(in: stack, success: "Added \(mount.raw) to \(service).") {
            try ComposeFileEditor.addVolume(mount, toService: service, in: $0)
        }
    }

    func removeVolume(_ mount: ComposeVolumeMount, from service: String, in stack: ComposeStack) async {
        await applyEdit(in: stack, success: "Removed \(mount.raw) from \(service).") {
            try ComposeFileEditor.removeVolume(mount, fromService: service, in: $0)
        }
    }

    /// Loads the file, applies the transform, persists through Compose's validator, then re-reads
    /// the parsed model. On a validation failure Compose's message is surfaced and the UI keeps
    /// showing the unchanged model, because refreshStackConfig is only called on the success path.
    private func applyEdit(
        in stack: ComposeStack,
        success message: String,
        transform: (String) throws -> String
    ) async {
        let text: String
        do {
            text = try String(contentsOf: stack.fileURL, encoding: .utf8)
        } catch {
            stackMessage = "Could not read \(stack.fileURL.lastPathComponent): \(error)"
            return
        }
        do {
            let edited = try transform(text)
            try await stackRunner.saveValidated(text: edited, to: stack)
            // A file edit changes nothing that is already running. `compose restart` restarts the
            // existing containers with their existing configuration by design, so saying "Up" here
            // is the difference between the change taking effect and the user pressing the button
            // next to it and seeing nothing happen.
            let isRunning = stackStatuses[stack.id]?.contains(where: \.isRunning) ?? false
            stackMessage = isRunning ? "\(message) Press Up to apply it to the running stack." : message
            await refreshStackConfig(stack)
        } catch {
            stackMessage = "Compose rejected the edit: \(error)"
        }
    }

    // MARK: Single-stack refresh

    func refreshStackConfig(_ stack: ComposeStack) async {
        do {
            stackModels[stack.id] = try await stackRunner.config(stack: stack)
        } catch {
            stackMessage = "Could not parse \(stack.name): \(error)"
        }
    }

    private func refreshStackStatus(_ stack: ComposeStack) async {
        do {
            stackStatuses[stack.id] = try await stackRunner.status(stack: stack)
        } catch {
            stackMessage = "Could not read status for \(stack.name): \(error)"
        }
    }

    // MARK: Starter template

    /// Mirrors the user's motivating example. No `version:` key: Compose v2 ignores it and warns.
    static let starterTemplate = """
        services:
          webserver:
            image: lipanski/docker-static-website:latest
            restart: always
            ports:
              - "3000:3000"
            volumes:
              - ./static:/home/static
        """
}
