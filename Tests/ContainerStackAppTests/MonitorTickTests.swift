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
        // The probe ran first: its ping found no socket here.
        #expect(model.livenessFilter.consecutiveFailures == 1)
    }

    /// Codex reproduced the starvation: with full reads slower than the 3s tick, every retry of
    /// the adoption was overtaken again, 11 full reads and 70 tick reads without one adoption.
    @Test("While an adoption runs, the tick leaves the Docker context to it")
    func tickSkipsContextReadDuringAdoption() async {
        let model = makeModel()
        model.readDockerContext = { _ in Self.reading(active: "orbstack") }
        model.isDashboardOpen = true
        model.isAdoptingDockerContext = true

        await model.monitorTick()

        #expect(model.activeDockerContext == nil)
    }

    /// #94 settled leftover checks from the loop this tick replaced; merging the two dropped the
    /// call once, silently.
    @Test("The tick settles a runtime check that is over")
    func tickSettlesFinishedCheck() async {
        let model = makeModel()
        model.stackMessage = RuntimeViewModel.checkingRuntimeMessage

        await model.monitorTick()

        #expect(model.stackMessage == "Stack action failed; the runtime is offline.")
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
    @Test("An adoption whose read was overtaken decides on a fresh read, not the cache")
    func overtakenAdoptionRespectsSwitch() async throws {
        let (model, cleanup) = try makeModelWithTakeover()
        defer { cleanup() }
        model.readDockerContext = { _ in Self.reading(active: DockerContext.name, installed: true) }
        await model.refreshDockerContext()
        let gate = ReadGate()
        model.readDockerContext = { _ in await gate.read(Self.reading(active: "orbstack", installed: true)) }

        let outcome = await Self.overtakeAdoption(of: model, gate: gate)

        #expect(outcome.adoptions == 0)
        #expect(outcome.repairs == 1)
        #expect(model.activeDockerContext == "orbstack")
    }

    /// Codex again: skipping the overtaken adoption instead dropped one that had to run. A passive
    /// tick read installs nothing, and nothing retried the first-run setup.
    @Test("An overtaken first-run adoption still installs the context")
    func overtakenFirstRunAdoptionStillAdopts() async throws {
        let (model, cleanup) = try makeModelWithTakeover()
        defer { cleanup() }
        let gate = ReadGate()
        model.readDockerContext = { _ in await gate.read(Self.reading(active: "default", installed: false)) }

        let outcome = await Self.overtakeAdoption(of: model, gate: gate)

        #expect(outcome.adoptions == 1)
    }

    @Test("An adoption asked for while one runs waits its turn, then runs once")
    func overlappingAdoptionIsQueued() async throws {
        let (model, cleanup) = try makeModelWithTakeover()
        defer { cleanup() }
        let gate = ReadGate()
        defer { Task { await gate.releaseAll() } }
        model.readDockerContext = { _ in await gate.read(Self.reading(active: "orbstack", installed: true)) }
        let repairs = Counter()
        let firstReturned = Counter()
        Task {
            await model.adoptDockerContextIfEnabled(adopt: { _ in }, repair: { repairs.value += 1 })
            firstReturned.value += 1
        }
        #expect(await Self.eventually { await gate.started == 1 })

        // Run beside the first, its read would overtake the first's and the two could trade
        // places for as long as their timing lines up.
        let secondReturned = Counter()
        Task {
            await model.adoptDockerContextIfEnabled(adopt: { _ in }, repair: { repairs.value += 1 })
            secondReturned.value += 1
        }
        #expect(await Self.eventually(within: .milliseconds(500)) { secondReturned.value == 1 })
        #expect(await gate.started == 1)

        await gate.release(1)
        #expect(await Self.eventually { await gate.started == 2 })
        await gate.release(2)
        #expect(await Self.eventually { firstReturned.value == 1 })
        #expect(repairs.value == 2)
    }

    /// The adoption reads first and stays blocked while a tick's read starts, then finishes first
    /// and is overtaken. Its retry is the newest read and is let through.
    private static func overtakeAdoption(
        of model: RuntimeViewModel, gate: ReadGate
    ) async -> (adoptions: Int, repairs: Int) {
        defer { Task { await gate.releaseAll() } }
        let adoptions = Counter()
        let repairs = Counter()
        let adoption = Task {
            await model.adoptDockerContextIfEnabled(
                adopt: { _ in adoptions.value += 1 }, repair: { repairs.value += 1 })
        }
        #expect(await eventually { await gate.started == 1 })
        let tick = Task { await model.refreshDockerContext(includeInstalledContext: false) }
        #expect(await eventually { await gate.started == 2 })

        await gate.release(1)
        #expect(await eventually { await gate.started == 3 })
        await gate.release(3)
        await adoption.value
        await gate.release(2)
        await tick.value
        return (adoptions.value, repairs.value)
    }

    private func makeModelWithTakeover() throws -> (RuntimeViewModel, () -> Void) {
        let suite = "containerstack-monitor-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let preference = DockerContextTakeoverPreference(defaults: defaults)
        preference.setEnabled(true)
        return (makeModel(preference: preference), { defaults.removePersistentDomain(forName: suite) })
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
        within limit: Duration = .seconds(5), _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while await !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

@MainActor
private final class Counter {
    var value = 0
}

/// Holds each Docker context read until the test releases it, so the order the reads finish in is
/// the test's to choose rather than the scheduler's. It suspends rather than blocks: a blocked read
/// holds a cooperative-pool thread, and on a three-core CI runner a few of them hung the suite.
private actor ReadGate {
    private(set) var started = 0
    private var released: Set<Int> = []
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]

    func read(_ reading: DockerContextReading) async -> DockerContextReading {
        started += 1
        let index = started
        if !released.contains(index) {
            await withCheckedContinuation { waiting[index] = $0 }
        }
        return reading
    }

    func release(_ index: Int) {
        released.insert(index)
        waiting.removeValue(forKey: index)?.resume()
    }

    /// So a failing test cannot leave a read suspended for good.
    func releaseAll() {
        for index in 1...(started + 8) { release(index) }
    }
}
