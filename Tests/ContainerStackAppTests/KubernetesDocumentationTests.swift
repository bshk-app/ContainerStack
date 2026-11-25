import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

struct KubernetesDocumentationTests {
    private func guide() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "docs/kubernetes.md"), encoding: .utf8)
    }

    @Test func guideNamesEveryClusterSubcommand() throws {
        let text = try guide()
        let commands = ClusterCLI.usage.split(separator: "\n").filter {
            $0.hasPrefix("  ") && !$0.hasPrefix("   ")
        }.compactMap { $0.split(separator: " ").first }
        try #require(!commands.isEmpty)
        for command in commands {
            #expect(text.contains("cstack cluster \(command) ") || text.contains("cstack cluster \(command)\n"))
        }
    }

    @Test func guideNamesEveryClusterRowState() throws {
        let text = try guide()
        let states = ClusterTestScenario.all.map(\.expected) + [.operating(.writing)]
        for state in states {
            // Counts and node names vary. Compare the fixed part of the label.
            let label = state.label.prefix { $0 != ":" }
            let suffix = label.count == state.label.count ? "**" : ":"
            #expect(text.contains("**\(label)\(suffix)"))
        }
    }
}
