import Foundation

extension DiagnosticRunner {
    /// The one check whose cost grows with the container count (NFR-001): one inspect per
    /// running container, which is why F-002 keeps it out of the UI set.
    func memoryMeasurement(_ listing: ContainersMeasurement) async -> MemoryMeasurement {
        let listedContainers: [DockerContainerSummary]
        switch listing {
        case .notAsked:
            return .notAsked
        case .unmeasurable(let reason):
            return .unmeasurable(reason: reason)
        case .listed(let listed):
            listedContainers = listed
        }
        let active = listedContainers.filter(\.isRunning)
        let running = active.filter { !$0.isSession }
        let builders = try? await client.runningBuilderIDs()
        if running.isEmpty, builders == nil { return .unmeasurable(reason: "The image builder could not be listed.") }
        guard !running.isEmpty || !(builders ?? []).isEmpty else { return .nothingRunning }

        var failures = 0
        let limits = await memoryLimits(of: running.map(\.id), failures: &failures)
        let builderLimits = await memoryLimits(of: builders ?? [], failures: &failures)
        guard !limits.isEmpty || !builderLimits.isEmpty else { return .noneInspected(failures: failures) }
        // 0 is `HostMemory`'s own "could not read", and the one value `fraction` refuses to divide by.
        let commitment = MemoryCommitment.measure(
            limits: limits,
            builderLimits: builderLimits,
            hostBytes: hostMemoryBytes() ?? 0,
            sessions: active.filter(\.isSession).count,
            sharedContainers: running.filter(\.isSharedContainer).count
        )
        return .inspected(commitment, failures: failures, builderUnlisted: builders == nil)
    }

    private func memoryLimits(of ids: [String], failures: inout Int) async -> [Int64?] {
        var limits: [Int64?] = []
        for id in ids {
            do {
                limits.append(try await client.memoryLimitBytes(containerID: id))
            } catch {
                failures += 1
            }
        }
        return limits
    }

}
