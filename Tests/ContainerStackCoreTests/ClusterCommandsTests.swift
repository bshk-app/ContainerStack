import Foundation
import Synchronization
import Testing

@testable import ContainerStackCore

final class ClusterSpawnRecorder: Sendable {
    private let recorded = Mutex<[ClusterCommands.Launch]>([])
    private let reply: @Sendable (ClusterCommands.Launch) throws -> ProcessRunner.Result

    init(
        reply: @escaping @Sendable (ClusterCommands.Launch) throws -> ProcessRunner.Result = { _ in
            .init(status: 0, output: "")
        }
    ) {
        self.reply = reply
    }

    var launches: [ClusterCommands.Launch] {
        recorded.withLock { $0 }
    }

    var spawn: ClusterCommands.Spawn {
        { [self] launch in
            recorded.withLock { $0.append(launch) }
            return try reply(launch)
        }
    }
}

struct TemporaryHome: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "cluster-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appending(path: ".kube"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appending(path: ".containerstack"), withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var managed: URL { url.appending(path: ".containerstack/kubeconfig") }
    var userDefault: URL { url.appending(path: ".kube/config") }

    func write(_ text: String, to file: URL) throws {
        try Data(text.utf8).write(to: file)
    }

    func snapshot() throws -> [String: Data] {
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        var files: [String: Data] = [:]
        while let item = enumerator?.nextObject() as? URL {
            files[item.path] = (try? Data(contentsOf: item)) ?? Data()
        }
        return files
    }
}

struct ClusterCommandsTests {
    private func commands(
        _ home: borrowing TemporaryHome,
        environment: [String: String] = [:],
        spawn: @escaping ClusterCommands.Spawn
    ) -> ClusterCommands {
        ClusterCommands(
            containerPath: "/opt/runtime/bin/container", home: home.url, environment: environment, spawn: spawn)
    }

    @Test("a container first on PATH is not run")
    func runsTheResolvedRuntimeNotPath() async throws {
        let home = try TemporaryHome()
        let bin = home.url.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let trap = bin.appending(path: "container")
        let marker = home.url.appending(path: "path-container-ran")
        try home.write("#!/bin/sh\ntouch '\(marker.path)'\n", to: trap)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trap.path)
        let runtime = home.url.appending(path: "runtime-container")
        try home.write("#!/bin/sh\necho '[]'\n", to: runtime)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)

        let commands = ClusterCommands(
            containerPath: runtime.path, home: home.url, environment: ["PATH": "\(bin.path):/usr/bin:/bin"])

        #expect(try await commands.list() == "[]\n")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("every call sets KUBECONFIG to the app file only, and other files stay byte-equal")
    func everyCallUsesOnlyTheAppKubeconfig() async throws {
        let home = try TemporaryHome()
        let other = home.url.appending(path: "other-config")
        try home.write("owner: default\n", to: home.userDefault)
        try home.write("owner: other\n", to: other)
        let inherited = "\(home.userDefault.path):\(other.path)"
        let recorder = ClusterSpawnRecorder { launch in
            if let path = launch.environment["KUBECONFIG"] {
                try Data("written by the plugin\n".utf8).write(to: URL(fileURLWithPath: path))
            }
            let failed = launch.arguments.contains("fails")
            return .init(status: failed ? 1 : 0, output: "")
        }
        let commands = commands(
            home, environment: ["KUBECONFIG": inherited, "HOME": home.url.path], spawn: recorder.spawn)

        try await commands.create(name: "dev", options: [])
        await #expect(throws: ClusterCommandError.self) { try await commands.create(name: "fails", options: []) }
        try await commands.start(name: "dev")
        try await commands.stop(name: "dev")
        try await commands.delete(name: "dev")
        try await commands.writeConfig(name: "dev")

        #expect(recorder.launches.count == 6)
        for launch in recorder.launches {
            #expect(launch.environment["KUBECONFIG"] == home.managed.path)
            #expect(launch.environment["HOME"] == home.url.path)
        }
        #expect(try String(contentsOf: home.userDefault, encoding: .utf8) == "owner: default\n")
        #expect(try String(contentsOf: other, encoding: .utf8) == "owner: other\n")
    }

    @Test("the app file exists with mode 0600 before the first call")
    func managedFileExistsBeforeTheFirstCall() async throws {
        let home = try TemporaryHome()
        let managed = home.managed.path
        let recorder = ClusterSpawnRecorder { _ in
            let attributes = try FileManager.default.attributesOfItem(atPath: managed)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
            let text = try String(contentsOfFile: managed, encoding: .utf8)
            return .init(status: mode == 0o600 && text == "apiVersion: v1\nkind: Config\n" ? 0 : 9, output: "[]")
        }

        #expect(try await commands(home, spawn: recorder.spawn).list() == "[]")
    }

    @Test("an existing app file is kept as it is")
    func existingManagedFileIsKept() async throws {
        let home = try TemporaryHome()
        try home.write("apiVersion: v1\nkind: Config\ncontexts: []\n", to: home.managed)

        _ = try await commands(home, spawn: ClusterSpawnRecorder().spawn).list()

        #expect(try String(contentsOf: home.managed, encoding: .utf8) == "apiVersion: v1\nkind: Config\ncontexts: []\n")
    }

    enum Alias: CaseIterable {
        case defaultLinksToManaged, managedLinksToDefault, hardLink
    }

    @Test("an alias of the two kubeconfig files is refused before any write or launch", arguments: Alias.allCases)
    func aliasIsRefused(alias: Alias) async throws {
        let home = try TemporaryHome()
        switch alias {
        case .defaultLinksToManaged:
            try home.write("owner: managed\n", to: home.managed)
            try FileManager.default.createSymbolicLink(at: home.userDefault, withDestinationURL: home.managed)
        case .managedLinksToDefault:
            try home.write("owner: default\n", to: home.userDefault)
            try FileManager.default.createSymbolicLink(at: home.managed, withDestinationURL: home.userDefault)
        case .hardLink:
            try home.write("owner: default\n", to: home.userDefault)
            try FileManager.default.linkItem(at: home.userDefault, to: home.managed)
        }
        let before = try home.snapshot()
        let recorder = ClusterSpawnRecorder()
        let commands = commands(home, spawn: recorder.spawn)

        await #expect(throws: ClusterCommandError.kubeconfigAlias) { _ = try await commands.list() }
        await #expect(throws: ClusterCommandError.kubeconfigAlias) { try await commands.start(name: "dev") }
        await #expect(throws: ClusterCommandError.kubeconfigAlias) {
            try await commands.writeConfig(name: "dev", into: .userDefault)
        }

        #expect(recorder.launches.isEmpty)
        #expect(try home.snapshot() == before)
        #expect(
            ClusterCommandError.kubeconfigAlias.description
                == "~/.containerstack/kubeconfig is the same file as ~/.kube/config; remove the link")
    }

    @Test("a link from ~/.kube/config to an app file that does not exist yet is refused")
    func danglingAliasIsRefused() async throws {
        let home = try TemporaryHome()
        try FileManager.default.createSymbolicLink(at: home.userDefault, withDestinationURL: home.managed)
        let before = try home.snapshot()
        let recorder = ClusterSpawnRecorder()

        await #expect(throws: ClusterCommandError.kubeconfigAlias) {
            _ = try await commands(home, spawn: recorder.spawn).list()
        }

        #expect(recorder.launches.isEmpty)
        #expect(try home.snapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: home.managed.path))
    }

    @Test("write-config into ~/.kube/config names that file only")
    func writeConfigIntoTheUserFile() async throws {
        let home = try TemporaryHome()
        let recorder = ClusterSpawnRecorder()

        try await commands(home, environment: ["KUBECONFIG": "/a:/b"], spawn: recorder.spawn)
            .writeConfig(name: "dev", into: .userDefault)

        #expect(recorder.launches.map { $0.environment["KUBECONFIG"] } == [home.userDefault.path])
    }

    @Test("each command runs its runtime arguments with its time limit")
    func argumentsAndLimits() async throws {
        let home = try TemporaryHome()
        let recorder = ClusterSpawnRecorder()
        let commands = commands(home, spawn: recorder.spawn)

        _ = try await commands.list()
        try await commands.create(name: "dev", options: ["--cpus", "4"])
        try await commands.start(name: "dev")
        try await commands.stop(name: "dev")
        try await commands.delete(name: "dev")
        try await commands.writeConfig(name: "dev")

        let launches = recorder.launches
        #expect(Set(launches.map(\.executablePath)) == ["/opt/runtime/bin/container"])
        #expect(
            launches.map(\.arguments) == [
                ["cluster", "list", "--format", "json"],
                ["cluster", "create", "--name", "dev", "--cpus", "4"],
                ["cluster", "start", "--name", "dev"],
                ["cluster", "stop", "--name", "dev"],
                ["cluster", "delete", "--name", "dev"],
                ["cluster", "write-config", "--name", "dev"],
            ])
        #expect(
            launches.map(\.timeout) == [
                .seconds(20), .seconds(15 * 60), .seconds(10 * 60), .seconds(2 * 60), .seconds(5 * 60), .seconds(30),
            ])
        #expect(launches.first?.output == .captureSeparately)
        #expect(launches.dropFirst().allSatisfy { $0.output == .inherit })
    }

    @Test("a failed list carries the runtime's error text")
    func failedListCarriesTheErrorText() async throws {
        let home = try TemporaryHome()
        let recorder = ClusterSpawnRecorder { _ in
            .init(status: 1, output: "", errorOutput: "Error: cluster service is not available\n")
        }

        await #expect(
            throws: ClusterCommandError.failed(
                command: "cluster list", status: 1, message: "Error: cluster service is not available")
        ) { _ = try await commands(home, spawn: recorder.spawn).list() }
        #expect(
            ClusterCommandError.failed(command: "cluster list", status: 1, message: "Error: x").description
                == "container cluster list exited with status 1: Error: x")
    }

    @Test("a command that exits non-zero is an error with its status")
    func nonZeroExitIsAnError() async throws {
        let home = try TemporaryHome()
        let recorder = ClusterSpawnRecorder { _ in .init(status: 3, output: "") }

        await #expect(throws: ClusterCommandError.failed(command: "cluster start", status: 3, message: "")) {
            try await commands(home, spawn: recorder.spawn).start(name: "dev")
        }
    }
}
