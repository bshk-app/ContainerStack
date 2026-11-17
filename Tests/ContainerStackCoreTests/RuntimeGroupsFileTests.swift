import Foundation
import Testing

@testable import ContainerStackCore

struct RuntimeGroupsFileTests {
    @Test func fixtureAndRoundTrip() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/runtime-groups.v1.json")
        let data = try Data(contentsOf: fixture)
        #expect(data == Data(RuntimeGroupsDocument.defaultJSON.utf8))
        let document = try RuntimeGroupsFile.decode(data)
        #expect(document == .defaults)
        #expect(try RuntimeGroupsFile.decode(RuntimeGroupsFile.encode(document)) == document)
    }

    @Test func exactDecoderErrors() throws {
        let base = RuntimeGroupsDocument.defaultJSON
        let cases: [(String, String)] = [
            ("{", "not JSON"),
            (
                base.replacingOccurrences(of: "\"version\": 1", with: "\"extra\": 0, \"version\": 1"),
                "the document: unknown key \"extra\""
            ),
            (
                base.replacingOccurrences(of: "\"kind\": \"exec\"", with: "\"extra\": 0, \"kind\": \"exec\""),
                "groups[0]: unknown key \"extra\""
            ),
            (
                base.replacingOccurrences(of: "\"image\": \"mcp/*\"", with: "\"extra\": 0, \"image\": \"mcp/*\""),
                "rules[0]: unknown key \"extra\""
            ),
            (
                base.replacingOccurrences(of: "\"mcp-catalog\"", with: "\"Bad\""),
                "groups[0].name: \"Bad\" is not [a-z0-9-]{1,32}"
            ),
            (
                base.replacingOccurrences(of: "\"stdio-sessions\"", with: "\"mcp-catalog\""),
                "groups[1]: duplicate name \"mcp-catalog\""
            ),
            (
                base.replacingOccurrences(of: "\"idleMinutes\": 10", with: "\"idleMinutes\": 7"),
                "groups[0].idleMinutes: 7 is not 0, 5, 10, 30 or 60"
            ),
            (
                base.replacingOccurrences(of: "\"idleMinutes\": 10", with: "\"idleMinutes\": 10.0"),
                "groups[0].idleMinutes: expected an integer"
            ),
            (
                base.replacingOccurrences(of: "\"enabled\": false", with: "\"enabled\": 1"),
                "groups[0].enabled: expected true or false"
            ),
            (
                base.replacingOccurrences(of: "\"enabled\": false", with: "\"enabled\": \"yes\""),
                "groups[0].enabled: expected true or false"
            ),
            (
                base.replacingOccurrences(
                    of: "\"image\": \"mcp/*\"", with: "\"image\": \"mcp/*\", \"stdioSession\": true"),
                "rules[0]: a rule needs exactly one of \"image\" and \"stdioSession\""
            ),
            (
                base.replacingOccurrences(of: "\"stdioSession\": true", with: "\"stdioSession\": false"),
                "rules[1].stdioSession: expected true"
            ),
            (
                base.replacingOccurrences(of: "\"image\": \"mcp/*\"", with: "\"image\": \"\""),
                "rules[0].image: empty pattern"
            ),
            (
                base.replacingOccurrences(of: "\"group\": \"mcp-catalog\"", with: "\"group\": \"missing\""),
                "rules[0]: unknown group \"missing\""
            ),
        ]
        for (json, detail) in cases {
            #expect(throws: RuntimeGroupsDocumentError.malformed(detail)) {
                try RuntimeGroupsFile.decode(Data(json.utf8))
            }
        }
        #expect(throws: RuntimeGroupsDocumentError.unsupportedVersion(2)) {
            try RuntimeGroupsFile.decode(
                Data(base.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2").utf8))
        }
    }

    @Test func flagTable() {
        #expect(!SharedRuntimesFlag.needed(for: .missing))
        #expect(!SharedRuntimesFlag.needed(for: .valid(.defaults)))
        #expect(SharedRuntimesFlag.needed(for: .invalid(cause: "bad key")))
        var document = RuntimeGroupsDocument.defaults
        document.groups[0].enabled = true
        #expect(SharedRuntimesFlag.needed(for: .valid(document)))
        document.groups[0].kind = .pod
        #expect(!SharedRuntimesFlag.needed(for: .valid(document)))
    }

    @Test func editsPreserveExternalChangesAndSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "target.json")
        let link = directory.appending(path: "link.json")
        #expect(RuntimeGroupsFile.read(at: target) == .missing)
        var external = RuntimeGroupsDocument.defaults
        external.groups.append(RuntimeGroup(name: "pod", kind: .pod, idleMinutes: 30, enabled: true))
        try RuntimeGroupsFile.write(external, to: target, expecting: nil)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try RuntimeGroupsFile.edit(at: link) { $0.groups[0].enabled = true }
        external.groups[0].enabled = true
        #expect(RuntimeGroupsFile.read(at: target) == .valid(external))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        try Data("bad".utf8).write(to: target)
        #expect(throws: RuntimeGroupsFile.EditError.invalid("runtime-groups.json does not parse: not JSON")) {
            try RuntimeGroupsFile.edit(at: link) { $0.groups[0].enabled = false }
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "bad")
    }

}

extension RuntimeGroupsFileTests {
    @Test func danglingSymlinksSurviveEveryWritePath() throws {
        for operation in ["write", "edit", "reset"] {
            for relative in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let target = directory.appending(path: "missing/target.json")
                let link = directory.appending(path: "groups.json")
                let destination = relative ? "missing/target.json" : target.path
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
                switch operation {
                case "write": try RuntimeGroupsFile.write(.defaults, to: link, expecting: nil)
                case "edit": try RuntimeGroupsFile.edit(at: link) { $0.groups[0].enabled = true }
                default: try RuntimeGroupsFile.reset(at: link)
                }
                #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == destination)
                #expect(FileManager.default.fileExists(atPath: target.path))
            }
        }
    }

    @Test func imagePatternsRemainReadable() {
        let json = String(decoding: RuntimeGroupsFile.encode(.defaults), as: UTF8.self)
        #expect(json.contains(#""image": "mcp/*""#))
    }
}

extension RuntimeGroupsFileTests {
    @Test func anInvalidReadCannotTurnIntoASilentSuccess() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        var reads = 0
        #expect(throws: RuntimeGroupsFile.EditError.invalid("bad file")) {
            try RuntimeGroupsFile.edit(
                at: url,
                readState: { _ in
                    reads += 1
                    return reads == 1 ? .invalid(cause: "bad file") : .missing
                },
                change: { $0.groups[0].enabled = true }
            )
        }
        #expect(reads == 1)
    }
}
