import AppKit
import ContainerStackCore
import Testing

@testable import ContainerStackApp

@MainActor
struct CommandLineSettingsTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "command-line-settings-\(UUID())")
    private var executable: URL { root.appending(path: "ContainerStack.app/Contents/MacOS/cstack") }
    private var link: URL { root.appending(path: "bin/cstack") }

    private func prepare() throws {
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    @Test func fallbackPathIncludesLocalCommandsEvenWithMinimalLaunchEnvironment() {
        for environment in [[:], ["PATH": "/usr/bin:/bin"]] {
            let directories = CommandLineSettings.fallbackPath(environment: environment).split(separator: ":")
            #expect(directories.contains("/opt/homebrew/bin"))
            #expect(directories.contains("/usr/local/bin"))
        }
    }

    @Test func cancelDoesNotShowAnErrorOrSuccessMessage() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try prepare()
        let settings = CommandLineSettings(
            command: CStackCommand(executable: executable, link: link),
            path: { link.deletingLastPathComponent().path },
            runAdministratorScript: { _ in
                [NSAppleScript.errorNumber: -128, NSAppleScript.errorMessage: "User canceled."]
            })
        settings.perform(.install)
        #expect(settings.problem == nil)
        #expect(settings.state == .missing)
    }

    @Test func changedStateClearsAnEarlierFailure() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try prepare()
        let settings = CommandLineSettings(
            command: CStackCommand(executable: executable, link: link),
            path: { link.deletingLastPathComponent().path },
            runAdministratorScript: { _ in
                [NSAppleScript.errorNumber: -10000, NSAppleScript.errorMessage: "Permission denied."]
            })
        settings.perform(.install)
        #expect(settings.problem == "Permission denied.")
        settings.refresh()
        #expect(settings.problem == "Permission denied.")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        settings.refresh()
        #expect(settings.state == .installed)
        #expect(settings.problem == nil)
    }

    @Test func onlyTheManagedLinkOffersRemoval() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try prepare()
        let local = root.appending(path: "local/cstack")
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: local, withDestinationURL: executable)
        let unmanaged = CommandLineSettings(
            command: CStackCommand(executable: executable, link: link),
            path: { local.deletingLastPathComponent().path })
        #expect(unmanaged.state == .installed)
        #expect(unmanaged.installedCommandPath == local.path)
        #expect(!unmanaged.canRemoveCommand)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        let managed = CommandLineSettings(
            command: CStackCommand(executable: executable, link: link),
            path: { link.deletingLastPathComponent().path })
        #expect(managed.canRemoveCommand)
    }
}
