import Foundation
import Testing
@testable import ContainerStackCore

struct ComposeStackTests {
    // MARK: - suggestedName

    @Test
    func suggestedNameSanitizesDirectories() {
        let cases: [(directory: String, expected: String)] = [
            ("My App", "my-app"),
            ("WebServer", "webserver"),
            ("project.name", "project-name"),
            ("my-app_v2", "my-app_v2"),
            ("  leading", "leading"),
            ("trailing  ", "trailing"),
            ("Hello World!", "hello-world"),
            ("!!!", "stack"),
            ("测试目录", "stack"),
            ("Café", "caf")
        ]

        for (directory, expected) in cases {
            let fileURL = URL(fileURLWithPath: "/projects/\(directory)/compose.yaml")
            #expect(ComposeStack.suggestedName(for: fileURL) == expected, "\(directory) must sanitize to \(expected)")
        }
    }

    @Test
    func suggestedNameFallsBackWhenThereIsNoDirectoryName() {
        // A compose file at the filesystem root has no directory name to sanitize. A relative
        // path would not test this: URL resolves it against the current directory, so the name
        // would come from wherever the tests happen to run.
        let fileURL = URL(fileURLWithPath: "/compose.yaml")
        #expect(ComposeStack.suggestedName(for: fileURL) == "stack")
    }

    @Test
    func projectDirectoryIsFilesContainer() {
        let stack = ComposeStack(name: "demo", fileURL: URL(fileURLWithPath: "/tmp/demo/compose.yaml"))
        #expect(stack.projectDirectory.path == "/tmp/demo")
    }

    // MARK: - StackRegistry

    @Test
    func missingFileReturnsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "stacks.json")
        let registry = StackRegistry(url: url)

        #expect(try registry.load() == [])
    }

    @Test
    func roundTripsStacks() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "stacks.json")
        let registry = StackRegistry(url: url)

        let stacks = [
            ComposeStack(name: "demo", fileURL: URL(fileURLWithPath: "/tmp/demo/compose.yaml")),
            ComposeStack(name: "web", fileURL: URL(fileURLWithPath: "/srv/web/compose.yml"))
        ]
        try registry.save(stacks)

        #expect(try registry.load() == stacks)
    }

    @Test
    func saveCreatesParentDirectory() throws {
        let nested = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "deeply/nested/stacks.json")
        let registry = StackRegistry(url: nested)

        try registry.save([ComposeStack(name: "demo", fileURL: URL(fileURLWithPath: "/tmp/demo/compose.yaml"))])

        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    @Test
    func corruptFileThrowsRatherThanEmptying() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appending(path: "stacks.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("definitely not json".utf8).write(to: url)

        let registry = StackRegistry(url: url)

        #expect(throws: DecodingError.self) {
            try registry.load()
        }
    }
}
