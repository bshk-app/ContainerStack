import ContainerStackCore
import Foundation
import Observation

/// The CPUs and memory a container gets when its create request names no limit. The store is the
/// `[container]` table of Apple Container's `config.toml`, which socktainer and the `container` CLI
/// also read.
@MainActor
@Observable
final class ContainerResourceSettings {
    private static let legacyCPUsKey = "containerResourceDefaults.cpus"
    private static let legacyMemoryGiBKey = "containerResourceDefaults.memoryGiB"
    private static let bytesPerGiB: Int64 = 1_024 * 1_024 * 1_024

    private let userFile: URL
    private let appRootCopy: URL
    let maximumCPUs: Int
    let maximumMemoryGiB: Int
    private let hostMemoryBytes: Int64
    /// What ContainerStack writes for a key the file does not set: all CPUs, and a quarter of host
    /// memory with a minimum of 2 GiB.
    private let defaultCPUs: Int
    private let defaultMemoryGiB: Int
    /// Retained only until initialization saves successfully, so reopening Settings retries a
    /// failed migration instead of hiding its error behind a read of a still-missing file.
    private var pendingMigration: UserDefaults?
    private(set) var cpus: Int
    private(set) var memoryGiB: Int
    /// Why ContainerStack cannot read or edit the file. nil when it can.
    private(set) var problem: String?
    /// The user file and Apple's copy differ, so the running bridge still uses the old values.
    private(set) var awaitsBridgeRestart = false

    init(
        defaults: UserDefaults = .standard,
        userFile: URL = ContainerConfigFile.userFileURL(),
        appRootCopy: URL = ContainerConfigFile.appRootCopyURL(),
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.userFile = userFile
        self.appRootCopy = appRootCopy
        maximumCPUs = max(1, processorCount)
        maximumMemoryGiB = max(1, Int(physicalMemory / UInt64(Self.bytesPerGiB)))
        hostMemoryBytes = Int64(clamping: max(1, physicalMemory))
        defaultCPUs = maximumCPUs
        defaultMemoryGiB = max(2, maximumMemoryGiB / 4)
        cpus = defaultCPUs
        memoryGiB = defaultMemoryGiB
        pendingMigration = defaults
        reload()
    }

    /// Reads the file again, so a hand edit shows. A key the file does not set shows the default.
    func reload() {
        let seedFailure = pendingMigration.flatMap { seed(from: $0) }
        if seedFailure == nil { pendingMigration = nil }
        do {
            let file = try ContainerConfigFile.load(from: userFile)
            cpus = file.cpus ?? defaultCPUs
            memoryGiB = file.memoryBytes.map(Self.wholeGiB) ?? defaultMemoryGiB
            problem = seedFailure
            awaitsBridgeRestart = (try? ContainerConfigFile.load(from: appRootCopy)) != file
        } catch {
            cpus = defaultCPUs
            memoryGiB = defaultMemoryGiB
            problem = describe(error)
            awaitsBridgeRestart = false
        }
    }

    func setCPUs(_ value: Int) {
        write(cpus: Self.clamp(value, to: maximumCPUs), memoryGiB: nil)
    }

    func setMemoryGiB(_ value: Int) {
        write(cpus: nil, memoryGiB: Self.clamp(value, to: maximumMemoryGiB))
    }

    var memoryNote: String {
        let percent = Int((Double(Int64(memoryGiB) * Self.bytesPerGiB) / Double(hostMemoryBytes) * 100).rounded())
        let threshold = Int(MemoryCommitment.approachingFraction * 100)
        return "Each container without limits is a VM with \(memoryGiB) GiB, \(percent)% of this Mac's memory."
            + " The Doctor warns when running containers together reach \(threshold)%."
    }

    var filePath: String {
        (userFile.path as NSString).abbreviatingWithTildeInPath
    }

    static func limits(cpus: Int, memoryGiB: Int) -> ContainerResourceLimits {
        ContainerResourceLimits(
            cpus: cpus,
            memoryInBytes: Int64(memoryGiB) * bytesPerGiB
        )
    }

    /// Writes each key the file does not set: the value saved before this setting moved into the
    /// file, else the default. The saved keys are deleted after a good write, so this happens once.
    private func seed(from defaults: UserDefaults) -> String? {
        do {
            let file = try ContainerConfigFile.load(from: userFile)
            let savedCPUs = defaults.object(forKey: Self.legacyCPUsKey) as? Int
            let savedMemoryGiB = defaults.object(forKey: Self.legacyMemoryGiBKey) as? Int
            let cpus = file.cpus == nil ? savedCPUs.map { Self.clamp($0, to: maximumCPUs) } ?? defaultCPUs : nil
            let memoryGiB =
                file.memoryBytes == nil
                ? savedMemoryGiB.map { Self.clamp($0, to: maximumMemoryGiB) } ?? defaultMemoryGiB : nil
            if cpus != nil || memoryGiB != nil {
                try ContainerConfigFile.save(cpus: cpus, memoryGiB: memoryGiB, to: userFile)
            }
            defaults.removeObject(forKey: Self.legacyCPUsKey)
            defaults.removeObject(forKey: Self.legacyMemoryGiBKey)
            return nil
        } catch {
            return describe(error)
        }
    }

    private func write(cpus: Int?, memoryGiB: Int?) {
        do {
            try ContainerConfigFile.save(cpus: cpus, memoryGiB: memoryGiB, to: userFile)
            reload()
        } catch {
            problem = describe(error)
        }
    }

    private func describe(_ error: any Error) -> String {
        "Cannot edit \(userFile.path): \(error.localizedDescription)"
    }

    private static func wholeGiB(_ bytes: Int64) -> Int {
        max(1, Int((Double(bytes) / Double(bytesPerGiB)).rounded()))
    }

    private static func clamp(_ value: Int, to maximum: Int) -> Int {
        min(max(value, 1), maximum)
    }
}
