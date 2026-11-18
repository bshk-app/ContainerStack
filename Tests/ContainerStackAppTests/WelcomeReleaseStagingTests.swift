import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

struct WelcomeReleaseStagingTests {
    @Test func stagesRealReleaseFilesWithoutBuildingOrSigning() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appending(path: "welcome-release-staging-\(UUID())")
        defer { try? files.removeItem(at: root) }
        let source = root.appending(path: "source")
        let resources = root.appending(
            path: "Staged.app/Contents/Resources/ContainerStack_ContainerStackApp.bundle/Contents/Resources")
        try files.createDirectory(at: source, withIntermediateDirectories: true)
        try files.createDirectory(at: resources, withIntermediateDirectories: true)
        try "9.8.7\n".write(to: source.appending(path: "VERSION"), atomically: true, encoding: .utf8)
        try "## [9.8.7] - today\n\n### Features\n\nCurrent notes\n\n## [9.8.6]\nOld notes\n".write(
            to: source.appending(path: "CHANGELOG.md"), atomically: true, encoding: .utf8)

        let outside = root.appending(path: "outside.txt")
        try "Keep this file".write(to: outside, atomically: true, encoding: .utf8)
        try files.createSymbolicLink(at: resources.appending(path: "WelcomeVersion.txt"), withDestinationURL: outside)
        try files.createSymbolicLink(
            atPath: resources.appending(path: "WelcomeChangelog.md").path, withDestinationPath: "../../../CHANGELOG.md")

        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let result = try ProcessRunner.run(
            executablePath: "/bin/bash",
            arguments: [
                repository.appending(path: "scripts/stage-welcome-release-resources.sh").path,
                source.path, resources.path,
            ],
            output: .capture(includingStandardError: true), timeout: .seconds(10))
        #expect(result.status == 0, Comment(rawValue: result.output))
        for name in ["WelcomeVersion.txt", "WelcomeChangelog.md"] {
            let attributes = try resources.appending(path: name).resourceValues(forKeys: [
                .isSymbolicLinkKey, .isRegularFileKey,
            ])
            #expect(attributes.isSymbolicLink == false)
            #expect(attributes.isRegularFile == true)
        }
        let versionText = try String(contentsOf: resources.appending(path: "WelcomeVersion.txt"), encoding: .utf8)
        let changelog = try String(contentsOf: resources.appending(path: "WelcomeChangelog.md"), encoding: .utf8)
        #expect(WelcomeRelease.version(from: versionText) == "9.8.7")
        #expect(WelcomeRelease.notes(version: "9.8.7", changelog: changelog) == "### Features\n\nCurrent notes")
        #expect(!changelog.contains("Old notes"))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "Keep this file")
    }
}
