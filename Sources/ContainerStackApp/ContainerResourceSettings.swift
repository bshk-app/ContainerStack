import ContainerStackCore
import Foundation
import Observation

/// The CPUs and memory a container gets when its create request names no limit (`[container]`), or
/// the image builder VM gets when it starts (`[build]`). The store is that table of Apple Container's
/// `config.toml`, which socktainer and the `container` CLI also read.
@MainActor
@Observable
final class ContainerResourceSettings {
    private static let legacyCPUsKey = "containerResourceDefaults.cpus"
    private static let legacyMemoryGiBKey = "containerResourceDefaults.memoryGiB"
    private static let bytesPerGiB: Int64 = 1_024 * 1_024 * 1_024
    /// Apple's `BuildConfig` defaults, which apply while `[build]` sets neither key.
    private static let appleBuilderCPUs = 2
    private static let appleBuilderMemoryGiB = 2

    let table: ContainerConfigFile.Table
    private let userFile: URL
    private let appRootCopy: URL
    let maximumCPUs: Int
    let maximumMemoryGiB: Int
    private let hostMemoryBytes: Int64
    /// What a key the file does not set means. For `[container]` ContainerStack writes it: all CPUs,
    /// and a quarter of host memory with a minimum of 2 GiB. For `[build]` it is Apple's default.
    private let defaultCPUs: Int
    private let defaultMemoryGiB: Int
    /// Retained only until initialization saves successfully, so reopening Settings retries a
    /// failed migration instead of hiding its error behind a read of a still-missing file.
    /// Always nil for `[build]`, which had no saved setting and gets nothing written for it.
    private var pendingMigration: UserDefaults?
    private(set) var cpus: Int
    private(set) var memoryBytes: Int64
    /// The whole-GiB control's position; display and Run use the exact bytes instead.
    var memoryGiB: Int { Self.wholeGiB(memoryBytes) }
    /// Why ContainerStack cannot read or edit the file. nil when it can.
    private(set) var problem: String?
    /// The user file and Apple's copy differ, so the running bridge still uses the old values.
    private(set) var awaitsBridgeRestart = false

    init(
        table: ContainerConfigFile.Table = .container,
        defaults: UserDefaults = .standard,
        userFile: URL = ContainerConfigFile.userFileURL(),
        appRootCopy: URL = ContainerConfigFile.appRootCopyURL(),
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.table = table
        self.userFile = userFile
        self.appRootCopy = appRootCopy
        maximumCPUs = max(1, processorCount)
        maximumMemoryGiB = max(1, Int(physicalMemory / UInt64(Self.bytesPerGiB)))
        hostMemoryBytes = Int64(clamping: max(1, physicalMemory))
        switch table {
        case .container:
            defaultCPUs = maximumCPUs
            defaultMemoryGiB = max(2, maximumMemoryGiB / 4)
            pendingMigration = defaults
        case .build:
            defaultCPUs = min(Self.appleBuilderCPUs, maximumCPUs)
            defaultMemoryGiB = min(Self.appleBuilderMemoryGiB, maximumMemoryGiB)
            pendingMigration = nil
        }
        cpus = defaultCPUs
        memoryBytes = Int64(defaultMemoryGiB) * Self.bytesPerGiB
        reload()
    }

    /// Reads the file again, so a hand edit shows. A key the file does not set shows the default.
    func reload() {
        let seedFailure = pendingMigration.flatMap { seed(from: $0) }
        if seedFailure == nil { pendingMigration = nil }
        do {
            let file = try ContainerConfigFile.load(from: userFile, table: table)
            cpus = file.cpus ?? defaultCPUs
            memoryBytes = file.memoryBytes ?? Int64(defaultMemoryGiB) * Self.bytesPerGiB
            problem = seedFailure
            awaitsBridgeRestart = (try? ContainerConfigFile.load(from: appRootCopy, table: table)) != file
        } catch {
            cpus = defaultCPUs
            memoryBytes = Int64(defaultMemoryGiB) * Self.bytesPerGiB
            problem = describe(error)
            awaitsBridgeRestart = false
        }
    }

    func setCPUs(_ value: Int) {
        write(cpus: Self.clamp(value, to: maximumCPUs), memoryGiB: nil)
    }

    func setMemoryGiB(_ value: Int) {
        let clamped = Self.clamp(value, to: maximumMemoryGiB)
        guard Int64(clamped) * Self.bytesPerGiB != memoryBytes else { return }
        write(cpus: nil, memoryGiB: clamped)
    }

    var memoryNote: String {
        let percent = Int((Double(memoryBytes) / Double(hostMemoryBytes) * 100).rounded())
        let threshold = Int(MemoryCommitment.approachingFraction * 100)
        return "Each container without limits is a VM with \(memoryDescription), \(percent)% of this Mac's memory."
            + " The Doctor warns when running containers together reach \(threshold)%."
    }

    var memoryDescription: String { Self.memoryDescription(bytes: memoryBytes) }

    /// Division by 2^30 terminates in decimal; keep every digit without floating-point rounding.
    static func memoryDescription(bytes: Int64) -> String {
        let whole = bytes / bytesPerGiB
        var remainder = bytes % bytesPerGiB
        var fraction = ""
        while remainder > 0 {
            remainder *= 10
            fraction += String(remainder / bytesPerGiB)
            remainder %= bytesPerGiB
        }
        return "\(whole)\(fraction.isEmpty ? "" : "." + fraction) GiB"
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
            try ContainerConfigFile.save(table: table, cpus: cpus, memoryGiB: memoryGiB, to: userFile)
            reload()
        } catch {
            problem = describe(error)
        }
    }

    private func describe(_ error: any Error) -> String {
        "Cannot edit \(userFile.path): \(error.localizedDescription)"
    }

    static func wholeGiB(_ bytes: Int64) -> Int {
        max(1, Int((Double(bytes) / Double(bytesPerGiB)).rounded()))
    }

    private static func clamp(_ value: Int, to maximum: Int) -> Int {
        min(max(value, 1), maximum)
    }
}

/// The Run Container sheet edits a snapshot; CPU edits leave its exact memory bytes alone.
@MainActor
struct ContainerResourceSelection {
    var cpus: Int
    private(set) var memoryBytes: Int64

    init(settings: ContainerResourceSettings) {
        cpus = settings.cpus
        memoryBytes = settings.memoryBytes
    }

    static func load(settings: ContainerResourceSettings) -> Self {
        settings.reload()
        return Self(settings: settings)
    }

    var memoryGiB: Int {
        get { ContainerResourceSettings.wholeGiB(memoryBytes) }
        set { memoryBytes = ContainerResourceSettings.limits(cpus: cpus, memoryGiB: newValue).memoryInBytes }
    }

    var memoryDescription: String { ContainerResourceSettings.memoryDescription(bytes: memoryBytes) }

    var limits: ContainerResourceLimits {
        ContainerResourceLimits(cpus: cpus, memoryInBytes: memoryBytes)
    }
}
