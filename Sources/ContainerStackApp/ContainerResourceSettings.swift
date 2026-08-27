import ContainerStackCore
import Foundation
import Observation

@MainActor
@Observable
final class ContainerResourceSettings {
    static let defaultCPUs = 4
    static let defaultMemoryGiB = 1

    private static let cpusKey = "containerResourceDefaults.cpus"
    private static let memoryGiBKey = "containerResourceDefaults.memoryGiB"
    private static let bytesPerGiB: Int64 = 1_024 * 1_024 * 1_024

    private let defaults: UserDefaults
    let maximumCPUs: Int
    let maximumMemoryGiB: Int
    private(set) var cpus: Int
    private(set) var memoryGiB: Int

    init(
        defaults: UserDefaults = .standard,
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        self.defaults = defaults
        maximumCPUs = max(1, processorCount)
        maximumMemoryGiB = max(1, Int(physicalMemory / UInt64(Self.bytesPerGiB)))
        cpus = Self.clamp(
            defaults.object(forKey: Self.cpusKey) as? Int ?? Self.defaultCPUs,
            to: maximumCPUs
        )
        memoryGiB = Self.clamp(
            defaults.object(forKey: Self.memoryGiBKey) as? Int ?? Self.defaultMemoryGiB,
            to: maximumMemoryGiB
        )
    }

    func setCPUs(_ value: Int) {
        cpus = Self.clamp(value, to: maximumCPUs)
        defaults.set(cpus, forKey: Self.cpusKey)
    }

    func setMemoryGiB(_ value: Int) {
        memoryGiB = Self.clamp(value, to: maximumMemoryGiB)
        defaults.set(memoryGiB, forKey: Self.memoryGiBKey)
    }

    static func limits(cpus: Int, memoryGiB: Int) -> ContainerResourceLimits {
        ContainerResourceLimits(
            cpus: cpus,
            memoryInBytes: Int64(memoryGiB) * bytesPerGiB
        )
    }

    private static func clamp(_ value: Int, to maximum: Int) -> Int {
        min(max(value, 1), maximum)
    }
}
