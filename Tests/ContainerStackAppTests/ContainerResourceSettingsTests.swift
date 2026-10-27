import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@MainActor
struct ContainerResourceSettingsTests {
    private static let gibibyte: UInt64 = 1_024 * 1_024 * 1_024
    private static let cpusKey = "containerResourceDefaults.cpus"
    private static let memoryKey = "containerResourceDefaults.memoryGiB"

    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "cstack-settings-\(UUID().uuidString)")
    private let suiteName = "ContainerResourceSettingsTests-\(UUID().uuidString)"
    private var userFile: URL { directory.appending(path: "container/config.toml") }
    private var appRootCopy: URL { directory.appending(path: "com.apple.container/config/config.toml") }

    @Test func writesTheDefaultsIntoAFileThatSetsNone() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }

        let settings = makeSettings(defaults: defaults, processorCount: 8, memoryGiB: 16)

        #expect(try contents(of: userFile) == "[container]\ncpus = 8\nmemory = \"4g\"\n")
        #expect(settings.cpus == 8)
        #expect(settings.memoryGiB == 4)
    }

    @Test(arguments: [(8, 2), (16, 4), (18, 4), (32, 8), (64, 16)])
    func defaultMemoryIsAQuarterOfTheHostAndAtLeastTwoGiB(hostGiB: UInt64, expectedGiB: Int) throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }

        _ = makeSettings(defaults: defaults, memoryGiB: hostGiB)

        #expect(try ContainerConfigFile.load(from: userFile).memoryBytes == Int64(expectedGiB) * Int64(Self.gibibyte))
    }

    @Test func keepsTheValuesTheFileSets() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        let text = "[container]\ncpus = 6\nmemory = \"6g\" # mine\n"
        try write(text, to: userFile)

        let settings = makeSettings(defaults: defaults)

        #expect(try contents(of: userFile) == text)
        #expect(settings.cpus == 6)
        #expect(settings.memoryGiB == 6)
    }

    @Test func addsOnlyTheKeyTheFileDoesNotSet() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        try write("[container]\ncpus = 6\n", to: userFile)

        _ = makeSettings(defaults: defaults, memoryGiB: 16)

        #expect(try contents(of: userFile) == "[container]\ncpus = 6\nmemory = \"4g\"\n")
    }

    @Test func carriesTheOldSettingIntoTheFileOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        defaults.set(6, forKey: Self.cpusKey)
        defaults.set(5, forKey: Self.memoryKey)

        _ = makeSettings(defaults: defaults)

        #expect(try contents(of: userFile) == "[container]\ncpus = 6\nmemory = \"5g\"\n")
        #expect(defaults.object(forKey: Self.cpusKey) == nil)
        #expect(defaults.object(forKey: Self.memoryKey) == nil)
    }

    @Test func oldSettingDoesNotReplaceAValueInTheFile() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        defaults.set(2, forKey: Self.cpusKey)
        defaults.set(2, forKey: Self.memoryKey)
        try write("[container]\ncpus = 6\nmemory = \"6g\"\n", to: userFile)

        _ = makeSettings(defaults: defaults)

        #expect(try contents(of: userFile) == "[container]\ncpus = 6\nmemory = \"6g\"\n")
        #expect(defaults.object(forKey: Self.cpusKey) == nil)
        #expect(defaults.object(forKey: Self.memoryKey) == nil)
    }

    @Test func aChangeGoesIntoTheFile() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        let settings = makeSettings(defaults: defaults)

        settings.setCPUs(6)
        settings.setMemoryGiB(5)

        #expect(try contents(of: userFile) == "[container]\ncpus = 6\nmemory = \"5g\"\n")
        let restored = makeSettings(defaults: defaults)
        #expect(restored.cpus == 6)
        #expect(restored.memoryGiB == 5)
    }

    @Test func clampsAChangeToHostCapacity() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        let settings = makeSettings(defaults: defaults, processorCount: 2, memoryGiB: 3)

        settings.setCPUs(20)
        settings.setMemoryGiB(20)

        #expect(settings.cpus == 2)
        #expect(settings.memoryGiB == 3)
        #expect(try contents(of: userFile) == "[container]\ncpus = 2\nmemory = \"3g\"\n")
    }

    @Test func readsAHandEditOnReload() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        let settings = makeSettings(defaults: defaults)
        try write("[container]\ncpus = 3\nmemory = \"7g\"\n", to: userFile)

        settings.reload()

        #expect(settings.cpus == 3)
        #expect(settings.memoryGiB == 7)
    }

    @Test func reportsAFileItCannotEditAndLeavesItAlone() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        defaults.set(6, forKey: Self.cpusKey)
        try write("container.cpus = 4\n", to: userFile)

        let settings = makeSettings(defaults: defaults)

        #expect(try contents(of: userFile) == "container.cpus = 4\n")
        #expect(settings.problem?.contains("line 1") == true)
        #expect(defaults.object(forKey: Self.cpusKey) as? Int == 6)
    }

    /// The copy is what the running bridge read: `container system start` writes it, then the
    /// helper starts socktainer.
    @Test func awaitsABridgeRestartWhileAppleCopyDiffers() throws {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { cleanUp(defaults) }
        try write("[container]\ncpus = 4\nmemory = \"1g\"\n", to: appRootCopy)
        let settings = makeSettings(defaults: defaults)

        #expect(settings.awaitsBridgeRestart)

        try write(contents(of: userFile), to: appRootCopy)
        settings.reload()
        #expect(!settings.awaitsBridgeRestart)
    }

    @Test func limitsConvertGiBToBytes() {
        let limits = ContainerResourceSettings.limits(cpus: 6, memoryGiB: 5)

        #expect(limits.cpus == 6)
        #expect(limits.memoryInBytes == 5 * 1_024 * 1_024 * 1_024)
    }

    private func makeSettings(
        defaults: UserDefaults,
        processorCount: Int = 8,
        memoryGiB: UInt64 = 16
    ) -> ContainerResourceSettings {
        ContainerResourceSettings(
            defaults: defaults,
            userFile: userFile,
            appRootCopy: appRootCopy,
            processorCount: processorCount,
            physicalMemory: memoryGiB * Self.gibibyte
        )
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func cleanUp(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
