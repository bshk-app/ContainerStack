import ContainerStackCore
import Foundation
import Synchronization
import Testing

@testable import ContainerStackApp

@MainActor
struct DockerContextRecordRepairTests {
    @Test
    func repairsInactiveStaleRecordWithoutSwitchingContext() async throws {
        let (model, defaults, suite) = try makeModel(enabled: true)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.activeDockerContext = "other"
        model.isDockerContextInstalled = true
        let writes = Mutex<[String]>([])
        let socketPath = model.socketPath

        let repaired = await model.repairDockerContextRecord(
            recordedSocketPath: { _ in "/retired/docker.sock" },
            repairRecord: { path in writes.withLock { $0.append(path) } }
        )

        #expect(repaired)
        #expect(writes.withLock { $0 } == [socketPath])
        #expect(model.activeDockerContext == "other")
        #expect(model.serviceMessage?.contains("repaired the record without switching") == true)
    }

    @Test
    func failedRepairReturnsFalseWithoutSurfacingAnError() async throws {
        let (model, defaults, suite) = try makeModel(enabled: true)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.activeDockerContext = "other"
        model.isDockerContextInstalled = true

        let repaired = await model.repairDockerContextRecord(
            recordedSocketPath: { _ in "/retired/docker.sock" },
            repairRecord: { _ in throw RepairError.failed }
        )

        #expect(!repaired)
        #expect(model.serviceMessage == nil)
    }

    @Test
    func guardPathsDoNotWriteTheContextRecord() async throws {
        let (model, defaults, suite) = try makeModel(enabled: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.activeDockerContext = "other"
        model.isDockerContextInstalled = true
        let reads = Mutex(0)
        let writes = Mutex(0)
        func attempt() async -> Bool {
            await model.repairDockerContextRecord(
                recordedSocketPath: { _ in
                    reads.withLock { $0 += 1 }
                    return "/retired/docker.sock"
                },
                repairRecord: { _ in writes.withLock { $0 += 1 } }
            )
        }

        // Takeover disabled, context missing, or already active: no record read or write.
        #expect(!(await attempt()))
        model.dockerContextTakeoverPreference.setEnabled(true)
        model.isDockerContextInstalled = false
        #expect(!(await attempt()))
        model.isDockerContextInstalled = true
        model.activeDockerContext = DockerContext.name
        #expect(!(await attempt()))
        model.activeDockerContext = "other"
        #expect(reads.withLock { $0 } == 0)
        #expect(writes.withLock { $0 } == 0)
        let socketPath = model.socketPath
        let alreadyCurrent = await model.repairDockerContextRecord(
            recordedSocketPath: { _ in socketPath },
            repairRecord: { _ in writes.withLock { $0 += 1 } }
        )
        #expect(!alreadyCurrent)
        #expect(writes.withLock { $0 } == 0)
    }

    @Test
    func stateChangingWhileWaitingForMutationSlotSkipsRepair() async throws {
        let (model, defaults, suite) = try makeModel(enabled: true)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.activeDockerContext = "other"
        model.isDockerContextInstalled = true
        model.isMutatingDockerContext = true
        let writes = Mutex(0)
        let repair = Task {
            await model.repairDockerContextRecord(
                recordedSocketPath: { _ in "/retired/docker.sock" },
                repairRecord: { _ in writes.withLock { $0 += 1 } }
            )
        }
        while model.dockerContextMutationWaiters.isEmpty { await Task.yield() }
        model.isDockerContextInstalled = false
        model.dockerContextMutationWaiters.removeFirst().resume()

        #expect(!(await repair.value))
        #expect(writes.withLock { $0 } == 0)
        #expect(!model.isMutatingDockerContext)
    }

    private func makeModel(enabled: Bool) throws -> (RuntimeViewModel, UserDefaults, String) {
        let suite = "DockerContextRecordRepairTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let preference = DockerContextTakeoverPreference(defaults: defaults, key: "takeover")
        if enabled { preference.setEnabled(true) }
        let model = RuntimeViewModel(
            socketPath: "/tmp/containerstack-test.sock",
            startsRuntime: false,
            dockerContextTakeoverPreference: preference
        )
        return (model, defaults, suite)
    }
}

private enum RepairError: Error {
    case failed
}
