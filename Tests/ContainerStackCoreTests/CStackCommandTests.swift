import Foundation
import Testing

@testable import ContainerStackCore

struct CStackCommandTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "cstack-command-\(UUID())")
    private var executable: URL { root.appending(path: "ContainerStack.app/Contents/MacOS/cstack") }
    private var link: URL { root.appending(path: "usr/local/bin/cstack") }
    private var brew: URL { root.appending(path: "opt/homebrew/bin/cstack") }
    private var command: CStackCommand { CStackCommand(executable: executable, link: link, homebrewLink: brew) }
    private var path: String { [link, brew].map { $0.deletingLastPathComponent().path }.joined(separator: ":") }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func symlink(_ url: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    @Test func missingAndNonExecutableCommands() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(command.state(path: path) == .missing)
        try makeExecutable(link)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: link.path)
        #expect(command.state(path: path) == .missing)
        #expect(throws: CStackCommand.CommandError.self) { try command.shellScript(for: .install) }
    }

    @Test func detectsOwnLinkAndHomebrewInPathOrder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(executable)
        try symlink(brew, to: executable)
        #expect(command.state(path: path) == .homebrew)
        try symlink(link, to: executable)
        #expect(command.state(path: path) == .installed)
        let reversed = brew.deletingLastPathComponent().path + ":" + link.deletingLastPathComponent().path
        #expect(command.state(path: reversed) == .homebrew)
        #expect(try command.shellScript(for: .remove).contains("readlink"))
    }

    @Test func detectsAnotherAppAndGuardsReplacementAndRemoval() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appending(path: "Other.app/Contents/MacOS/cstack")
        try makeExecutable(executable)
        try makeExecutable(other)
        try symlink(link, to: other)
        #expect(command.state(path: path) == .other(root.appending(path: "Other.app").path))
        #expect(try command.shellScript(for: .replace).contains("/bin/ln -sfn"))
        #expect(throws: CStackCommand.CommandError.self) { try command.shellScript(for: .remove) }
    }

    @Test func neverReplacesRegularFilesOrUnrelatedLinks() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(executable)
        try makeExecutable(link)
        #expect(throws: CStackCommand.CommandError.self) { try command.shellScript(for: .replace) }
        try FileManager.default.removeItem(at: link)
        let unrelated = root.appending(path: "custom-command")
        try makeExecutable(unrelated)
        try symlink(link, to: unrelated)
        #expect(throws: CStackCommand.CommandError.self) { try command.shellScript(for: .replace) }
    }

    @Test func detectsDanglingLinksAndQuotesShellArguments() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try symlink(link, to: executable)
        #expect(command.state(path: path) == .missing)
        #expect(throws: CStackCommand.CommandError.self) { try command.shellScript(for: .install) }
        #expect(CStackCommand.quote("a'b $(x)") == "'a'\\''b $(x)'")
    }

    @Test func linkOperationsChangeOnlyTheTemporaryLink() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(executable)
        func run(_ operation: CStackCommand.Operation) throws {
            let result = try ProcessRunner.run(
                executablePath: "/bin/sh", arguments: ["-c", command.shellScript(for: operation)],
                timeout: .seconds(2))
            #expect(result.status == 0)
        }
        try run(.install)
        #expect(command.state(path: path) == .installed)
        try run(.remove)
        #expect(command.state(path: path) == .missing)
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        let other = root.appending(path: "Other.app/Contents/MacOS/cstack")
        try makeExecutable(other)
        try symlink(link, to: other)
        try run(.replace)
        #expect(command.state(path: path) == .installed)
        #expect(FileManager.default.isExecutableFile(atPath: other.path))
    }

    @Test func installStopsIfDestinationBecomesADirectory() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(executable)
        let script = try command.shellScript(for: .install)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        let result = try ProcessRunner.run(
            executablePath: "/bin/sh", arguments: ["-c", script], timeout: .seconds(2))
        #expect(result.status != 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: link.path).isEmpty)
    }
}
