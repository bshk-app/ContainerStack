import ContainerStackCore
import Foundation
import Synchronization
import Testing

@testable import ContainerStackApp

@MainActor
struct DockerContextRecordRepairTests {
    @Test
    func repairsInactiveStaleRecordWithoutSwitchingContext() async throws {
        let model = makeModel(enabled: true)
        model.activeDockerContext = "other"
        model.isDockerContextInstalled = true
        let writes = Mutex<[String]>([])
        let socketPath = model.socketPath
        model.dockerContextStore.recordedSocketPath = { _ in "/retired/docker.sock" }
        model.dockerContextStore.repairRecord = { path in writes.withLock { $0.append(path) } }

        let repaired = await model.repairDockerContextRecord()

        #expect(repaired)
        #expect(writes.withLock { $0 } == [socketPath])
        #expect(model.activeDockerContext == "other")
        #expect(model.serviceMessage?.contains("repaired the record without switching") == true)
    }

    @Test
    func failedRepairReturnsFalseWithoutSurfacingAnError() async throws {
        let model = makeModel(enabled: true)
        model.activeDockerContext = "other"
        model.isDockerContextInstalled = true
        model.dockerContextStore.recordedSocketPath = { _ in "/retired/docker.sock" }
        model.dockerContextStore.repairRecord = { _ in throw RepairError.failed }

        let repaired = await model.repairDockerContextRecord()

        #expect(!repaired)
        #expect(model.serviceMessage == nil)
    }

    @Test
    func guardPathsDoNotWriteTheContextRecord() async throws {
        let model = makeModel(enabled: false)
        let preference = model.dockerContextTakeoverPreference
        model.activeDockerContext = "other"
        model.isDockerContextInstalled = true
        let reads = Mutex(0)
        let writes = Mutex(0)
        model.dockerContextStore.recordedSocketPath = { _ in
            reads.withLock { $0 += 1 }
            return "/retired/docker.sock"
        }
        model.dockerContextStore.repairRecord = { _ in writes.withLock { $0 += 1 } }
        func attempt() async -> Bool {
            await model.repairDockerContextRecord()
        }

        // Takeover disabled, context missing, or already active: no record read or write.
        #expect(!(await attempt()))
        preference.setEnabled(true)
        model.isDockerContextInstalled = false
        #expect(!(await attempt()))
        model.isDockerContextInstalled = true
        model.activeDockerContext = DockerContext.name
        #expect(!(await attempt()))
        model.activeDockerContext = "other"
        #expect(reads.withLock { $0 } == 0)
        #expect(writes.withLock { $0 } == 0)
        let socketPath = model.socketPath
        model.dockerContextStore.recordedSocketPath = { _ in socketPath }
        let alreadyCurrent = await model.repairDockerContextRecord()
        #expect(!alreadyCurrent)
        #expect(writes.withLock { $0 } == 0)
    }

    @Test
    func stateChangingWhileWaitingForMutationSlotSkipsRepair() async throws {
        let model = makeModel(enabled: true)
        model.activeDockerContext = "other"
        model.isDockerContextInstalled = true
        model.isMutatingDockerContext = true
        let writes = Mutex(0)
        model.dockerContextStore.recordedSocketPath = { _ in "/retired/docker.sock" }
        model.dockerContextStore.repairRecord = { _ in writes.withLock { $0 += 1 } }
        let repair = Task { await model.repairDockerContextRecord() }
        while model.dockerContextMutationWaiters.isEmpty { await Task.yield() }
        model.isDockerContextInstalled = false
        model.dockerContextMutationWaiters.removeFirst().resume()

        #expect(!(await repair.value))
        #expect(writes.withLock { $0 } == 0)
        #expect(!model.isMutatingDockerContext)
    }

    private func makeModel(enabled: Bool) -> RuntimeViewModel {
        RuntimeViewModel(dockerContextTakeoverPreference: .inMemory(enabled ? true : nil))
    }
}

private enum RepairError: Error {
    case failed
}
