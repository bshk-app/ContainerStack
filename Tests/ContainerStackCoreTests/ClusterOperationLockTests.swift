import Foundation
import Testing

@testable import ContainerStackCore

private actor EventLog {
    private(set) var events: [String] = []
    private var waiters: [(String, CheckedContinuation<Void, Never>)] = []

    func append(_ event: String) {
        events.append(event)
        for waiter in waiters where waiter.0 == event {
            waiter.1.resume()
        }
        waiters.removeAll { $0.0 == event }
    }

    func waitFor(_ event: String) async {
        if events.contains(event) { return }
        await withCheckedContinuation { waiters.append((event, $0)) }
    }
}

private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

struct ClusterOperationLockTests {
    @Test("a second operation waits until the first ends")
    func secondWaitsForFirst() async throws {
        let lock = ClusterOperationLock()
        let log = EventLog()
        let gate = Gate()

        let first = Task {
            try await lock.run {
                await log.append("first begins")
                await gate.wait()
                await log.append("first ends")
            }
        }
        await log.waitFor("first begins")
        let second = Task {
            await log.append("second requested")
            try await lock.run { await log.append("second begins") }
        }
        await log.waitFor("second requested")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await log.events == ["first begins", "second requested"])

        await gate.open()
        try await first.value
        try await second.value

        #expect(await log.events == ["first begins", "second requested", "first ends", "second begins"])
    }

    @Test("waiting operations run in the order they asked")
    func waitersRunInOrder() async throws {
        let lock = ClusterOperationLock()
        let log = EventLog()
        let gate = Gate()

        let first = Task { try await lock.run { await gate.wait() } }
        var waiting: [Task<Void, any Error>] = []
        for index in 1...3 {
            try await Task.sleep(for: .milliseconds(20))
            waiting.append(Task { try await lock.run { await log.append("\(index)") } })
        }
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        try await first.value
        for task in waiting { try await task.value }

        #expect(await log.events == ["1", "2", "3"])
    }

    @Test("an operation that throws releases the lock")
    func throwingOperationReleases() async throws {
        let lock = ClusterOperationLock()
        struct Failure: Error {}

        await #expect(throws: Failure.self) { try await lock.run { throw Failure() } }
        #expect(try await lock.run { 7 } == 7)
    }

    @Test("two cluster start requests in one process do not overlap")
    func twoStartsDoNotOverlap() async throws {
        let home = try TemporaryHome()
        let intervals = NSLock()
        nonisolated(unsafe) var spans: [(ContinuousClock.Instant, ContinuousClock.Instant)] = []
        let recorder = ClusterSpawnRecorder { _ in
            let begin = ContinuousClock.now
            usleep(200_000)
            let end = ContinuousClock.now
            intervals.withLock { spans.append((begin, end)) }
            return .init(status: 0, output: "")
        }
        let commands = ClusterCommands(
            containerPath: "/opt/runtime/bin/container", home: home.url, environment: [:], spawn: recorder.spawn,
            lock: ClusterOperationLock())

        async let one: Void = commands.start(name: "a")
        async let two: Void = commands.start(name: "b")
        _ = try await (one, two)

        let sorted = intervals.withLock { spans.sorted { $0.0 < $1.0 } }
        #expect(sorted.count == 2)
        #expect(sorted[1].0 >= sorted[0].1)
    }
}
