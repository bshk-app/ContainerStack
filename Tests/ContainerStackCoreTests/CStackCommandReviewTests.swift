import Foundation
import Testing

@testable import ContainerStackCore

struct CStackCommandReviewTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "cstack-review-\(UUID())")
    private var executable: URL { root.appending(path: "New/ContainerStack.app/Contents/MacOS/cstack") }
    private var link: URL { root.appending(path: "bin/cstack") }
    private var command: CStackCommand { CStackCommand(executable: executable, link: link) }

    private func prepare() throws {
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    @Test func repairsOnlyDanglingContainerStackLinks() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try prepare()
        let retired = root.appending(path: "Retired/ContainerStack.app/Contents/MacOS/cstack")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: retired)
        let script = try command.shellScript(for: .install)
        let result = try ProcessRunner.run(executablePath: "/bin/sh", arguments: ["-c", script], timeout: .seconds(2))
        #expect(result.status == 0)
        #expect(command.state(path: link.deletingLastPathComponent().path) == .installed)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root.appending(path: "Other.app/Contents/MacOS/cstack"))
        #expect(throws: CStackCommand.CommandError.self) { try command.shellScript(for: .install) }
    }

    @Test func danglingRepairRechecksTheLinkAfterThePasswordPrompt() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try prepare()
        let retired = root.appending(path: "Retired/ContainerStack.app/Contents/MacOS/cstack")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: retired)
        let script = try command.shellScript(for: .install)
        try FileManager.default.removeItem(at: link)
        let replacement = root.appending(path: "User.app/Contents/MacOS/cstack")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: replacement)
        let result = try ProcessRunner.run(executablePath: "/bin/sh", arguments: ["-c", script], timeout: .seconds(2))
        #expect(result.status != 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == replacement.path)
    }

    @Test(arguments: [
        "/Volumes/ContainerStack/ContainerStack.app/Contents/MacOS/cstack",
        "/private/var/folders/test/AppTranslocation/id/d/ContainerStack.app/Contents/MacOS/cstack",
    ])
    func refusesTransientAppLocations(path: String) {
        let transient = CStackCommand(executable: URL(filePath: path), link: link)
        for operation in [CStackCommand.Operation.install, .replace] {
            do {
                _ = try transient.shellScript(for: operation)
                Issue.record("A transient app must not install a command link")
            } catch {
                #expect(
                    error.localizedDescription
                        == "Move ContainerStack to Applications before installing the cstack command.")
            }
        }
    }

    @Test func pathLinkToThisAppIsInstalled() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try prepare()
        let local = root.appending(path: ".local/bin/cstack")
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: local, withDestinationURL: executable)
        #expect(command.state(path: local.deletingLastPathComponent().path) == .installed)
        #expect(command.state(path: executable.deletingLastPathComponent().path) == .installed)
    }
}
