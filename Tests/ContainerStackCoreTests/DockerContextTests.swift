import Darwin
import Foundation
import Testing

@testable import ContainerStackCore

struct DockerContextTests {
    @Test
    func createsAndActivatesMissingContext() {
        let commands = DockerContext.installCommands(
            socketPath: "/Users/me/.socktainer/container.sock",
            exists: false
        )

        #expect(
            commands == [
                [
                    "context", "create", "containerstack",
                    "--description", "ContainerStack",
                    "--docker", "host=unix:///Users/me/.socktainer/container.sock",
                ],
                ["context", "use", "containerstack"],
            ])
    }

    @Test
    func updatesExistingContextInsteadOfRecreating() {
        let commands = DockerContext.installCommands(
            socketPath: "/tmp/c.sock",
            exists: true
        )

        #expect(
            commands.first == [
                "context", "update", "containerstack",
                "--description", "ContainerStack",
                "--docker", "host=unix:///tmp/c.sock",
            ])
        #expect(commands.last == ["context", "use", "containerstack"])
    }

    @Test
    func restoresRememberedContextBeforeRemovingActiveContext() {
        #expect(
            DockerContext.uninstallCommands(
                activeContext: "containerstack",
                previousContext: "orbstack",
                availableContexts: ["default", "orbstack", "containerstack"],
                removeContextOnUninstall: true
            ) == [
                ["context", "use", "orbstack"],
                ["context", "rm", "containerstack"],
            ])
    }

    @Test
    func fallsBackWhenRememberedContextNoLongerExists() {
        #expect(
            DockerContext.uninstallCommands(
                activeContext: "containerstack",
                previousContext: "orbstack",
                availableContexts: ["default", "containerstack"],
                removeContextOnUninstall: true
            ) == [
                ["context", "use", "default"],
                ["context", "rm", "containerstack"],
            ])
    }

    @Test
    func removesInactiveContextWithoutChangingTheUsersSelection() {
        #expect(
            DockerContext.uninstallCommands(
                activeContext: "orbstack",
                previousContext: "desktop-linux",
                availableContexts: ["default", "orbstack", "desktop-linux", "containerstack"],
                removeContextOnUninstall: true
            ) == [
                ["context", "rm", "containerstack"]
            ])
    }

    @Test
    func keepsAContextItDidNotCreateWhenOptingOut() {
        #expect(
            DockerContext.uninstallCommands(
                activeContext: "containerstack",
                previousContext: "orbstack",
                availableContexts: ["default", "orbstack", "containerstack"],
                removeContextOnUninstall: false
            ) == [
                ["context", "use", "orbstack"]
            ])
    }

    @Test
    func fallsBackWithoutRemovingAnUnownedActiveContext() {
        #expect(
            DockerContext.uninstallCommands(
                activeContext: "containerstack",
                previousContext: nil,
                availableContexts: ["default", "containerstack"],
                removeContextOnUninstall: false
            ) == [
                ["context", "use", "default"]
            ])
    }

    @Test
    func persistsPreviousContextAcrossProcesses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "docker-context-\(UUID().uuidString)")
        let store = DockerContextOwnershipStore(
            fileURL: directory.appending(path: "ownership.json")
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownership = DockerContextOwnership(
            previousContext: "orbstack",
            removeContextOnUninstall: true
        )

        try store.remember(ownership)
        #expect(try store.ownership() == ownership)

        try store.clear()
        #expect(try store.ownership() == nil)
    }

    @Test
    func scopesOwnershipToTheEffectiveDockerConfiguration() {
        let standard = DockerContextOwnershipStore.defaultURL(for: [:])
        let explicitStandard = DockerContextOwnershipStore.defaultURL(for: [
            "DOCKER_CONFIG": FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".docker").path
        ])
        let firstCustom = DockerContextOwnershipStore.defaultURL(for: [
            "DOCKER_CONFIG": "/tmp/docker-config-a"
        ])
        let secondCustom = DockerContextOwnershipStore.defaultURL(for: [
            "DOCKER_CONFIG": "/tmp/docker-config-b"
        ])

        #expect(explicitStandard == standard)
        #expect(firstCustom != standard)
        #expect(firstCustom != secondCustom)
    }

    @Test
    func treatsCorruptOwnershipAsUnknownOwnership() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "docker-context-corrupt-\(UUID().uuidString)")
        let fileURL = directory.appending(path: "ownership.json")
        let store = DockerContextOwnershipStore(fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: fileURL)

        #expect(try store.ownership() == nil)
    }

    @Test
    func reportsOnlyAnEnabledTakeoverAsAConflict() {
        #expect(
            DockerContext.conflictingContext(
                activeContext: "orbstack",
                takeoverEnabled: true
            ) == "orbstack")
        #expect(
            DockerContext.conflictingContext(
                activeContext: "containerstack",
                takeoverEnabled: true
            ) == nil)
        #expect(
            DockerContext.conflictingContext(
                activeContext: "orbstack",
                takeoverEnabled: false
            ) == nil)
    }

    @Test
    func adoptsOnlyAfterConfirmingTheContextIsMissing() {
        #expect(
            DockerContext.shouldAdopt(
                activeContext: "orbstack",
                installed: false,
                takeoverEnabled: true
            ))
        #expect(
            DockerContext.shouldAdopt(
                activeContext: DockerContext.name,
                installed: false,
                takeoverEnabled: true
            ))
        #expect(
            !DockerContext.shouldAdopt(
                activeContext: "orbstack",
                installed: nil,
                takeoverEnabled: true
            ))
        #expect(
            !DockerContext.shouldAdopt(
                activeContext: "orbstack",
                installed: true,
                takeoverEnabled: true
            ))
    }

    @Test
    func updatesAnInstalledContextWhenItIsAlreadyActive() {
        #expect(
            DockerContext.shouldAdopt(
                activeContext: DockerContext.name,
                installed: true,
                takeoverEnabled: true
            ))
        #expect(
            !DockerContext.shouldAdopt(
                activeContext: "orbstack",
                installed: true,
                takeoverEnabled: true
            ))
    }

    @Test
    func resolvesAndConnectsToTheDefaultSocketWithoutChangingIt() throws {
        let directory = URL(fileURLWithPath: "/tmp/cs-\(UUID().uuidString.prefix(8))")
        let target = directory.appending(path: "orbstack.sock")
        let link = directory.appending(path: "docker.sock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = try makeListeningUnixSocket(atPath: target.path)
        defer {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "orbstack.sock"
        )

        let status = DockerContext.socketStatus(atPath: link.path)

        #expect(status.target == target.path)
        #expect(status.isReachable)
    }

    @Test
    func reportsAStaleDefaultSocketAsUnavailable() throws {
        let directory = URL(fileURLWithPath: "/tmp/cs-stale-\(UUID().uuidString.prefix(8))")
        let target = directory.appending(path: "orbstack.sock")
        let link = directory.appending(path: "docker.sock")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: Data())
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        #expect(DockerContext.socketStatus(atPath: link.path).isReachable == false)
    }

    @Test
    func connectsToTheLongestDarwinUnixSocketPath() throws {
        let prefix = "/tmp/"
        let maximumPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        let uniquePrefix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let component =
            uniquePrefix
            + String(
                repeating: "x",
                count: maximumPathBytes - prefix.utf8.count - uniquePrefix.utf8.count
            )
        let path = prefix + component
        let descriptor = try makeListeningUnixSocket(atPath: path)
        defer {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(atPath: path)
        }

        #expect(path.utf8.count == maximumPathBytes)
        #expect(DockerContext.socketStatus(atPath: path).isReachable)
    }

    @Test
    func parsesContextOutputWithoutDockerWarnings() {
        let output = """
            WARNING: Error parsing config file
              default
            desktop-linux
            containerstack
            k8s+prod
            """

        #expect(
            DockerContext.contextNames(in: output)
                == ["default", "desktop-linux", "containerstack", "k8s+prod"])
        #expect(DockerContext.contextName(from: "WARNING: ignored\norbstack") == "orbstack")
        #expect(DockerContext.contextExists(in: output))
        #expect(DockerContext.contextExists(in: "default\norbstack") == false)
    }

    @Test
    func rejectsAmbiguousContextShowOutput() {
        #expect(DockerContext.contextName(from: "orbstack\nwarning") == nil)
    }

    @Test
    func removesContextOverridesFromManagementCommands() {
        #expect(
            DockerCLI.contextCommandEnvironment(from: [
                "DOCKER_CONFIG": "/tmp/docker-config",
                "DOCKER_CONTEXT": "temporary",
                "DOCKER_HOST": "unix:///tmp/docker.sock",
                "PATH": "/usr/bin",
            ]) == [
                "DOCKER_CONFIG": "/tmp/docker-config",
                "PATH": "/usr/bin",
            ])
    }

    @Test
    func keepsOverridesWhenResolvingTheEffectiveContext() {
        let environment = [
            "DOCKER_CONTEXT": "orbstack",
            "DOCKER_HOST": "unix:///tmp/docker.sock",
        ]
        var receivedEnvironment: [String: String]?

        let active = DockerCLI.activeContext(environment: environment) { arguments, environment in
            #expect(arguments == ["context", "show"])
            receivedEnvironment = environment
            return "orbstack"
        }

        #expect(active == "orbstack")
        #expect(receivedEnvironment == environment)
    }

    @Test
    func namesDockerEnvironmentOverridesThatContextUseCannotChange() {
        #expect(
            DockerCLI.contextEnvironmentOverride(from: ["DOCKER_CONTEXT": "orbstack"])
                == "DOCKER_CONTEXT")
        #expect(
            DockerCLI.contextEnvironmentOverride(from: ["DOCKER_HOST": "unix:///tmp/docker.sock"])
                == "DOCKER_HOST")
        #expect(
            DockerCLI.contextEnvironmentOverride(from: [
                "DOCKER_CONTEXT": "orbstack",
                "DOCKER_HOST": "unix:///tmp/docker.sock",
            ]) == "DOCKER_HOST")
        #expect(DockerCLI.contextEnvironmentOverride(from: ["DOCKER_CONTEXT": ""]) == nil)
    }

    @Test
    func ignoresAnEnvironmentOverrideThatAlreadySelectsContainerStack() {
        let environment = ["DOCKER_CONTEXT": DockerContext.name]

        #expect(
            DockerCLI.contextEnvironmentConflict(
                activeContext: DockerContext.name,
                isContextInstalled: true,
                environment: environment
            ) == nil
        )
        #expect(
            DockerCLI.contextEnvironmentConflict(
                activeContext: DockerContext.name,
                isContextInstalled: false,
                environment: environment
            ) == "DOCKER_CONTEXT"
        )
        #expect(
            DockerCLI.contextEnvironmentConflict(
                activeContext: "orbstack",
                isContextInstalled: true,
                environment: environment
            ) == "DOCKER_CONTEXT"
        )
    }

    @Test
    func preservesOwnershipWhenContextDiscoveryFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "docker-context-failure-\(UUID().uuidString)")
        let store = DockerContextOwnershipStore(fileURL: directory.appending(path: "ownership.json"))
        let ownership = DockerContextOwnership(
            previousContext: "orbstack",
            removeContextOnUninstall: true
        )
        try store.remember(ownership)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: DockerCLIError.self) {
            try DockerCLI.uninstallContext(ownershipStore: store) { arguments in
                if arguments == ["context", "show"] {
                    return "containerstack"
                }
                throw DockerCLIError.failed(
                    command: arguments.joined(separator: " "),
                    status: 1,
                    output: "config unreadable"
                )
            }
        }
        #expect(try store.ownership() == ownership)
    }
    @Test
    func preservesAContextThatContainerStackDidNotCreate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "docker-context-existing-\(UUID().uuidString)")
        let store = DockerContextOwnershipStore(fileURL: directory.appending(path: "ownership.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        var installCommands: [[String]] = []

        try DockerCLI.installContext(socketPath: "/tmp/containerstack.sock", ownershipStore: store) {
            arguments in
            installCommands.append(arguments)
            switch arguments {
            case ["context", "show"]:
                return "orbstack"
            case ["context", "ls", "--format", "{{.Name}}"]:
                return "default\norbstack\ncontainerstack"
            default:
                return ""
            }
        }

        #expect(
            try store.ownership()
                == DockerContextOwnership(
                    previousContext: "orbstack",
                    removeContextOnUninstall: false
                ))
        #expect(
            installCommands.contains([
                "context", "update", "containerstack",
                "--description", "ContainerStack",
                "--docker", "host=unix:///tmp/containerstack.sock",
            ]))

        var uninstallCommands: [[String]] = []
        let removed = try DockerCLI.uninstallContext(ownershipStore: store) { arguments in
            uninstallCommands.append(arguments)
            switch arguments {
            case ["context", "show"]:
                return "containerstack"
            case ["context", "ls", "--format", "{{.Name}}"]:
                return "default\norbstack\ncontainerstack"
            default:
                return ""
            }
        }

        #expect(!removed)
        #expect(uninstallCommands.contains(["context", "use", "orbstack"]))
        #expect(!uninstallCommands.contains(["context", "rm", "containerstack"]))
        #expect(try store.ownership() == nil)
    }

    @Test
    func doesNotWriteOwnershipWhenFirstContextMutationFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "docker-context-mutation-failure-\(UUID().uuidString)")
        let store = DockerContextOwnershipStore(fileURL: directory.appending(path: "ownership.json"))
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: DockerCLIError.self) {
            try DockerCLI.installContext(
                socketPath: "/tmp/containerstack.sock",
                ownershipStore: store
            ) { arguments in
                switch arguments {
                case ["context", "show"]:
                    return "orbstack"
                case ["context", "ls", "--format", "{{.Name}}"]:
                    return "default\norbstack"
                default:
                    throw DockerCLIError.failed(
                        command: arguments.joined(separator: " "),
                        status: 1,
                        output: "create failed"
                    )
                }
            }
        }

        #expect(try store.ownership() == nil)
    }

    @Test
    func removesANewContextWhenOwnershipCannotBeRecorded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "docker-context-ownership-failure-\(UUID().uuidString)")
        let store = DockerContextOwnershipStore(fileURL: directory.appending(path: "ownership.json"))
        var commands: [[String]] = []
        var didThrow = false
        defer {
            Darwin.chmod(directory.path, 0o700)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            try DockerCLI.installContext(
                socketPath: "/tmp/containerstack.sock",
                ownershipStore: store
            ) { arguments in
                commands.append(arguments)
                switch arguments {
                case ["context", "show"]:
                    return "orbstack"
                case ["context", "ls", "--format", "{{.Name}}"]:
                    return "default\norbstack"
                default:
                    Darwin.chmod(directory.path, 0o500)
                    return ""
                }
            }
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(commands.contains(["context", "rm", DockerContext.name]))
        #expect(try store.ownership() == nil)
    }

    @Test
    func preservesExistingOwnershipWhenContextMutationFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "docker-context-rollback-failure-\(UUID().uuidString)")
        let store = DockerContextOwnershipStore(fileURL: directory.appending(path: "ownership.json"))
        let ownership = DockerContextOwnership(
            previousContext: "desktop-linux",
            removeContextOnUninstall: false
        )
        let expectedError = DockerCLIError.failed(
            command: "context update containerstack",
            status: 1,
            output: "update failed"
        )
        defer {
            Darwin.chmod(directory.path, 0o700)
            try? FileManager.default.removeItem(at: directory)
        }
        try store.remember(ownership)

        #expect(throws: expectedError) {
            try DockerCLI.installContext(
                socketPath: "/tmp/containerstack.sock",
                ownershipStore: store
            ) { arguments in
                switch arguments {
                case ["context", "show"]:
                    return "orbstack"
                case ["context", "ls", "--format", "{{.Name}}"]:
                    return "default\norbstack\ncontainerstack"
                default:
                    Darwin.chmod(directory.path, 0o500)
                    throw expectedError
                }
            }
        }

        #expect(try store.ownership() == ownership)
    }

    @Test
    func retainsOwnershipAfterCreatingContextWhenActivationFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "docker-context-activation-failure-\(UUID().uuidString)")
        let store = DockerContextOwnershipStore(fileURL: directory.appending(path: "ownership.json"))
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: DockerCLIError.self) {
            try DockerCLI.installContext(
                socketPath: "/tmp/containerstack.sock",
                ownershipStore: store
            ) { arguments in
                switch arguments {
                case ["context", "show"]:
                    return "orbstack"
                case ["context", "ls", "--format", "{{.Name}}"]:
                    return "default\norbstack"
                case [
                    "context", "create", "containerstack", "--description", "ContainerStack",
                    "--docker", "host=unix:///tmp/containerstack.sock",
                ]:
                    return ""
                default:
                    throw DockerCLIError.failed(
                        command: arguments.joined(separator: " "),
                        status: 1,
                        output: "activation failed"
                    )
                }
            }
        }

        #expect(
            try store.ownership()
                == DockerContextOwnership(
                    previousContext: "orbstack",
                    removeContextOnUninstall: true
                ))
    }

    @Test
    func disablesTakeoverWithoutDeletingAnUnownedUpgradeContext() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "docker-context-upgrade-\(UUID().uuidString)")
        let store = DockerContextOwnershipStore(fileURL: directory.appending(path: "ownership.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        var commands: [[String]] = []

        let removed = try DockerCLI.uninstallContext(ownershipStore: store) { arguments in
            commands.append(arguments)
            switch arguments {
            case ["context", "show"]:
                return "containerstack"
            case ["context", "ls", "--format", "{{.Name}}"]:
                return "default\ncontainerstack"
            default:
                return ""
            }
        }

        #expect(!removed)
        #expect(commands.contains(["context", "use", "default"]))
        #expect(!commands.contains(["context", "rm", "containerstack"]))
    }

    @Test
    func ownsAContextItRecreatesAfterExternalRemoval() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "docker-context-recreated-\(UUID().uuidString)")
        let store = DockerContextOwnershipStore(fileURL: directory.appending(path: "ownership.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.remember(
            DockerContextOwnership(
                previousContext: "orbstack",
                removeContextOnUninstall: false
            ))

        try DockerCLI.installContext(socketPath: "/tmp/containerstack.sock", ownershipStore: store) {
            arguments in
            switch arguments {
            case ["context", "show"]:
                return "orbstack"
            case ["context", "ls", "--format", "{{.Name}}"]:
                return "default\norbstack"
            default:
                return ""
            }
        }

        #expect(
            try store.ownership()
                == DockerContextOwnership(
                    previousContext: "orbstack",
                    removeContextOnUninstall: true
                ))
    }

}

private func makeListeningUnixSocket(atPath path: String) throws -> Int32 {
    var address = try makeUnixSocketAddress(path: path)

    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw UnixSocketError.systemCallFailed(errno) }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw UnixSocketError.systemCallFailed(code)
    }
    return descriptor
}
