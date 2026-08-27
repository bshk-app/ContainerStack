import Foundation
import Testing

@testable import ContainerStackApp

@MainActor
struct ContainerResourceSettingsTests {
    @Test
    func persistsResourceDefaults() throws {
        let suiteName = "ContainerResourceSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = ContainerResourceSettings(
            defaults: defaults,
            processorCount: 8,
            physicalMemory: 16 * 1_024 * 1_024 * 1_024
        )
        #expect(settings.cpus == 4)
        #expect(settings.memoryGiB == 1)

        settings.setCPUs(6)
        settings.setMemoryGiB(5)

        let restored = ContainerResourceSettings(
            defaults: defaults,
            processorCount: 8,
            physicalMemory: 16 * 1_024 * 1_024 * 1_024
        )
        #expect(restored.cpus == 6)
        let expectedMemoryInBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
        #expect(restored.memoryGiB == 5)
        let restoredLimits = ContainerResourceSettings.limits(
            cpus: restored.cpus,
            memoryGiB: restored.memoryGiB
        )
        #expect(restoredLimits.cpus == 6)
        #expect(restoredLimits.memoryInBytes == expectedMemoryInBytes)
    }

    @Test
    func clampsDefaultsToHostCapacity() throws {
        let suiteName = "ContainerResourceSettingsClampTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = ContainerResourceSettings(
            defaults: defaults,
            processorCount: 2,
            physicalMemory: 3 * 1_024 * 1_024 * 1_024
        )
        settings.setCPUs(20)
        settings.setMemoryGiB(20)

        #expect(settings.cpus == 2)
        #expect(settings.memoryGiB == 3)
    }
}
