import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@Suite("Monitor tick")
@MainActor
struct MonitorTickTests {
    /// A context read running beside the probe let a probe-triggered adoption decide on a cached
    /// context the user had switched away from; inside the tick the two cannot overlap.
    @Test("With the window open, the tick reads the Docker context itself")
    func openWindowReadsContextInTick() async {
        let model = makeModel()
        model.readDockerContext = { _ in Self.reading(active: "orbstack") }
        model.isDashboardOpen = true

        await model.monitorTick()

        #expect(model.activeDockerContext == "orbstack")
    }

    @Test("With the window closed, the tick does not read the Docker context")
    func closedWindowSkipsContextRead() async {
        let model = makeModel()
        model.readDockerContext = { _ in Self.reading(active: "orbstack") }

        await model.monitorTick()

        #expect(model.activeDockerContext == nil)
    }

    /// Codex reproduced this one: takeover on, ContainerStack's context cached as active, the user
    /// switches to another. A second read overtakes the adoption's own, and the adoption used to
    /// decide on the cache and switch the user straight back.
    @Test("An adoption whose read was overtaken leaves the decision to the newer read")
    func overtakenAdoptionDoesNotAdopt() async throws {
        let suite = "containerstack-monitor-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = DockerContextTakeoverPreference(defaults: defaults)
        preference.setEnabled(true)
        let model = makeModel(preference: preference)
        model.readDockerContext = { _ in Self.reading(active: DockerContext.name, installed: true) }
        await model.refreshDockerContext()

        let gate = ReadGate()
        model.readDockerContext = { _ in gate.read(Self.reading(active: "orbstack", installed: true)) }
        let adopted = Flag()
        let adoption = Task { await model.adoptDockerContextIfEnabled(adopt: { _ in adopted.value = true }) }
        #expect(await Self.eventually { gate.started == 1 })
        let tick = Task { await model.refreshDockerContext(includeInstalledContext: false) }
        #expect(await Self.eventually { gate.started == 2 })

        gate.release(1)
        await adoption.value
        gate.release(2)
        await tick.value

        #expect(!adopted.value)
        #expect(model.activeDockerContext == "orbstack")
    }

    private func makeModel(
        preference: DockerContextTakeoverPreference = DockerContextTakeoverPreference()
    ) -> RuntimeViewModel {
        RuntimeViewModel(
            socketPath: "/tmp/containerstack-monitor-\(UUID().uuidString).sock",
            startsRuntime: false,
            dockerContextTakeoverPreference: preference
        )
    }

    private nonisolated static func reading(active: String, installed: Bool? = nil) -> DockerContextReading {
        DockerContextReading(
            active: active,
            installed: installed,
            defaultSocket: DockerContext.socketStatus(atPath: "/nonexistent/docker.sock")
        )
    }

    private static func eventually(
        within limit: Duration = .seconds(5), _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

@MainActor
private final class Flag {
    var value = false
}

/// Holds each Docker context read until the test releases it, so the order the reads finish in is
/// the test's to choose rather than the scheduler's.
private final class ReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var startedReads = 0
    private var releasedReads: Set<Int> = []

    var started: Int {
        condition.lock()
        defer { condition.unlock() }
        return startedReads
    }

    func read(_ reading: DockerContextReading) -> DockerContextReading {
        condition.lock()
        defer { condition.unlock() }
        startedReads += 1
        let index = startedReads
        while !releasedReads.contains(index) { condition.wait() }
        return reading
    }

    func release(_ index: Int) {
        condition.lock()
        releasedReads.insert(index)
        condition.broadcast()
        condition.unlock()
    }
}
