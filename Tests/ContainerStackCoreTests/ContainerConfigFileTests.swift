import Foundation
import Testing

@testable import ContainerStackCore

private let gibibyte: Int64 = 1_024 * 1_024 * 1_024
private let mebibyte: Int64 = 1_024 * 1_024

@Suite("ContainerConfigFile reading")
struct ContainerConfigFileReadTests {
    @Test func readsTheContainerTable() throws {
        let text = """
            [container]
            cpus = 6
            memory = "6g"

            """

        #expect(try ContainerConfigFile.read(text) == ContainerResourceDefaults(cpus: 6, memoryBytes: 6 * gibibyte))
    }

    @Test func ignoresTheSameKeysInOtherTables() throws {
        let text = """
            [build]
            cpus = 2
            memory = "2048MB"

            [container]
            cpus = 6

            """

        #expect(try ContainerConfigFile.read(text) == ContainerResourceDefaults(cpus: 6, memoryBytes: nil))
    }

    @Test(arguments: ["", "[dns]\ndomain = \"test\"\n", "# only a comment\n"])
    func readsNothingWithoutAContainerTable(text: String) throws {
        #expect(try ContainerConfigFile.read(text) == ContainerResourceDefaults(cpus: nil, memoryBytes: nil))
    }

    @Test func readsQuotedNamesSpacingAndComments() throws {
        let text = """
            [ "container" ] # defaults for containers without limits
            "cpus"=3 # three
            memory = '1536m'

            """

        #expect(try ContainerConfigFile.read(text) == ContainerResourceDefaults(cpus: 3, memoryBytes: 1_536 * mebibyte))
    }

    /// Apple's `MemorySize`: a number, then an optional binary unit with an optional `b` or `ib`.
    @Test(arguments: [
        ("1g", gibibyte),
        ("4G", 4 * gibibyte),
        ("1024m", gibibyte),
        ("2GiB", 2 * gibibyte),
        ("512mb", 512 * mebibyte),
        ("1.5g", gibibyte + 512 * mebibyte),
        ("1048576", mebibyte),
    ])
    func readsMemoryInEveryUnitAppleAccepts(value: String, bytes: Int64) throws {
        let text = "[container]\nmemory = \"\(value)\"\n"

        #expect(try ContainerConfigFile.read(text).memoryBytes == bytes)
    }

    @Test(arguments: [
        ("cpus = \"6\"", "cpus"),
        ("cpus = 0", "cpus"),
        ("memory = 6", "memory"),
        ("memory = \"6x\"", "memory"),
        ("memory = \"\"", "memory"),
    ])
    func rejectsAValueAppleCannotDecode(line: String, key: String) {
        let text = "[container]\n\(line)\n"

        #expect(throws: ContainerConfigFile.EditError.invalidValue(key: key, line: 2)) {
            try ContainerConfigFile.read(text)
        }
    }

    /// A `[container]` header would define the table a second time, which makes the whole file
    /// invalid TOML and stops `container system start`.
    @Test(arguments: ["container.cpus = 4", "\"container\".memory = \"4g\"", "container = { cpus = 4 }"])
    func rejectsAContainerTableDefinedAtTheTop(line: String) {
        let text = "# defaults\n\(line)\n"

        #expect(throws: ContainerConfigFile.EditError.unsupportedLayout(line: 2)) {
            try ContainerConfigFile.read(text)
        }
    }

    @Test func rejectsASecondContainerTable() {
        let text = "[container]\ncpus = 4\n\n[container]\nmemory = \"4g\"\n"

        #expect(throws: ContainerConfigFile.EditError.unsupportedLayout(line: 4)) {
            try ContainerConfigFile.read(text)
        }
    }

    @Test func rejectsARepeatedKey() {
        let text = "[container]\ncpus = 4\ncpus = 6\n"

        #expect(throws: ContainerConfigFile.EditError.unsupportedLayout(line: 3)) {
            try ContainerConfigFile.read(text)
        }
    }
}

@Suite("ContainerConfigFile paths")
struct ContainerConfigFilePathTests {
    private let home = URL(fileURLWithPath: "/Users/someone")

    /// Apple's `PathUtils.BaseConfigPath.home`, the source `container system start` copies.
    @Test func userFileFollowsXDGConfigHome() {
        let url = ContainerConfigFile.userFileURL(environment: ["XDG_CONFIG_HOME": "/xdg"], home: home)

        #expect(url.path == "/xdg/container/config.toml")
    }

    @Test(arguments: [[:], ["XDG_CONFIG_HOME": ""]])
    func userFileDefaultsToDotConfig(environment: [String: String]) {
        let url = ContainerConfigFile.userFileURL(environment: environment, home: home)

        #expect(url.path == "/Users/someone/.config/container/config.toml")
    }

    /// `container system start` takes the default app root unless `--app-root` names another, and
    /// the helper passes no `--app-root`.
    @Test func appRootCopyIsUnderTheDefaultAppRoot() {
        let url = ContainerConfigFile.appRootCopyURL(
            applicationSupport: URL(fileURLWithPath: "/Users/someone/Library/Application Support")
        )

        #expect(url.path == "/Users/someone/Library/Application Support/com.apple.container/config/config.toml")
    }
}

@Suite("ContainerConfigFile editing")
struct ContainerConfigFileEditTests {
    @Test func changesOnlyTheTwoValues() throws {
        let text = """
            # Apple Container settings
            [build]
            rosetta = false
            cpus = 2

            [container]
            cpus = 4        # vCPUs
            memory = "1g"   # too small for builds

            [dns]
            domain = "test"

            """

        let expected = """
            # Apple Container settings
            [build]
            rosetta = false
            cpus = 2

            [container]
            cpus = 8        # vCPUs
            memory = "4g"   # too small for builds

            [dns]
            domain = "test"

            """
        #expect(try ContainerConfigFile.updating(text, cpus: 8, memoryGiB: 4) == expected)
    }

    @Test func addsAMissingKeyAfterTheLastKeyOfTheTable() throws {
        let text = "[container]\ncpus = 6\n\n# DNS\n[dns]\ndomain = \"test\"\n"

        #expect(
            try ContainerConfigFile.updating(text, cpus: nil, memoryGiB: 4)
                == "[container]\ncpus = 6\nmemory = \"4g\"\n\n# DNS\n[dns]\ndomain = \"test\"\n"
        )
    }

    @Test func addsKeysUnderAnEmptyTable() throws {
        #expect(
            try ContainerConfigFile.updating("[container]\n", cpus: 8, memoryGiB: 4)
                == "[container]\ncpus = 8\nmemory = \"4g\"\n"
        )
    }

    @Test(arguments: [
        ("", "[container]\ncpus = 8\nmemory = \"4g\"\n"),
        ("[dns]\ndomain = \"test\"\n", "[dns]\ndomain = \"test\"\n\n[container]\ncpus = 8\nmemory = \"4g\"\n"),
        ("[dns]\ndomain = \"test\"", "[dns]\ndomain = \"test\"\n\n[container]\ncpus = 8\nmemory = \"4g\"\n"),
    ])
    func appendsTheTableWhenTheFileHasNone(text: String, expected: String) throws {
        #expect(try ContainerConfigFile.updating(text, cpus: 8, memoryGiB: 4) == expected)
    }

    @Test func writesOnlyTheKeysItIsGiven() throws {
        let text = "[container]\ncpus = 4\nmemory = \"6g\"\n"

        #expect(
            try ContainerConfigFile.updating(text, cpus: 8, memoryGiB: nil)
                == "[container]\ncpus = 8\nmemory = \"6g\"\n"
        )
    }

    @Test func refusesALayoutItCannotExtend() {
        #expect(throws: ContainerConfigFile.EditError.unsupportedLayout(line: 1)) {
            try ContainerConfigFile.updating("container.cpus = 4\n", cpus: 8, memoryGiB: 4)
        }
    }
}

@Suite("ContainerConfigFile on disk")
struct ContainerConfigFileDiskTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "cstack-config-\(UUID().uuidString)")

    @Test func savesANewFileAndItsDirectory() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "container/config.toml")

        try ContainerConfigFile.save(cpus: 8, memoryGiB: 4, to: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "[container]\ncpus = 8\nmemory = \"4g\"\n")
        #expect(
            try ContainerConfigFile.load(from: url) == ContainerResourceDefaults(cpus: 8, memoryBytes: 4 * gibibyte))
    }

    @Test func loadsNothingFromAMissingFile() throws {
        #expect(
            try ContainerConfigFile.load(from: directory.appending(path: "config.toml")) == ContainerResourceDefaults())
    }

    /// A dotfiles manager links the file: replacing the link with a regular file would cut it off.
    @Test func savesThroughASymlink() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "dotfiles/config.toml")
        let link = directory.appending(path: "home/config.toml")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[dns]\ndomain = \"test\"\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try ContainerConfigFile.save(cpus: 8, memoryGiB: 4, to: link)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(
            try String(contentsOf: target, encoding: .utf8)
                == "[dns]\ndomain = \"test\"\n\n[container]\ncpus = 8\nmemory = \"4g\"\n"
        )
    }

    @Test func keepsThePermissionsOfTheFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.toml")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "[container]\ncpus = 4\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        try ContainerConfigFile.save(cpus: 8, memoryGiB: nil, to: url)

        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}
