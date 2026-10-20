import Testing

@testable import ContainerStackApp

@Suite("Which runtime operation runs")
struct RuntimeLifecycleQueueTests {
    enum Outcome { case runs, queues, replaces, dropped }

    struct Row: CustomTestStringConvertible {
        let running: RuntimeOperation?
        let pending: RuntimeOperation?
        let operation: RuntimeOperation
        let origin: RuntimeOperationOrigin
        let outcome: Outcome

        var testDescription: String {
            let state = [running.map { "\($0) runs" }, pending.map { "\($0) waits" }]
                .compactMap { $0 }.joined(separator: ", ")
            return "\(origin) \(operation) while \(state.isEmpty ? "idle" : state): \(outcome)"
        }
    }

    static let start = RuntimeOperation.start
    static let stop = RuntimeOperation.stop(replacingSibling: false)
    static let restart = RuntimeOperation.restart(replacingSibling: false)

    static let rows: [Row] = [
        Row(running: nil, pending: nil, operation: start, origin: .user, outcome: .runs),
        Row(running: nil, pending: nil, operation: restart, origin: .recovery, outcome: .runs),
        Row(running: nil, pending: nil, operation: restart, origin: .staleBridge, outcome: .runs),
        Row(running: nil, pending: nil, operation: start, origin: .launch, outcome: .runs),

        Row(running: start, pending: nil, operation: stop, origin: .user, outcome: .queues),
        Row(running: start, pending: nil, operation: restart, origin: .user, outcome: .queues),
        Row(running: start, pending: nil, operation: restart, origin: .recovery, outcome: .queues),
        Row(running: start, pending: nil, operation: restart, origin: .staleBridge, outcome: .dropped),
        Row(running: start, pending: nil, operation: start, origin: .launch, outcome: .dropped),
        Row(running: start, pending: nil, operation: start, origin: .user, outcome: .dropped),

        Row(running: stop, pending: nil, operation: start, origin: .user, outcome: .queues),
        Row(running: stop, pending: nil, operation: restart, origin: .user, outcome: .queues),
        Row(running: stop, pending: nil, operation: restart, origin: .recovery, outcome: .dropped),
        Row(running: stop, pending: nil, operation: restart, origin: .staleBridge, outcome: .dropped),
        Row(running: stop, pending: nil, operation: stop, origin: .user, outcome: .dropped),

        Row(running: restart, pending: nil, operation: stop, origin: .user, outcome: .queues),
        Row(running: restart, pending: nil, operation: start, origin: .user, outcome: .queues),
        Row(running: restart, pending: nil, operation: restart, origin: .recovery, outcome: .dropped),
        Row(running: restart, pending: nil, operation: restart, origin: .user, outcome: .dropped),

        Row(running: start, pending: stop, operation: restart, origin: .user, outcome: .replaces),
        // The running Start is already superseded, so asking for it again is not a repeat.
        Row(running: start, pending: stop, operation: start, origin: .user, outcome: .replaces),
        Row(running: start, pending: stop, operation: stop, origin: .user, outcome: .dropped),
        Row(running: start, pending: stop, operation: restart, origin: .recovery, outcome: .dropped),
        Row(running: start, pending: restart, operation: restart, origin: .staleBridge, outcome: .dropped),
        Row(running: restart, pending: stop, operation: restart, origin: .recovery, outcome: .dropped),
    ]

    @Test("admission follows the table", arguments: rows)
    func admission(_ row: Row) {
        var queue = RuntimeLifecycleQueue()
        if let running = row.running {
            _ = queue.request(running, origin: .user)
        }
        if let pending = row.pending {
            _ = queue.request(pending, origin: .user)
        }

        let admission = queue.request(row.operation, origin: row.origin, observed: queue.generation)

        switch (row.outcome, admission) {
        case (.runs, .runNow), (.queues, .queued(_, replaced: nil)), (.dropped, .dropped): break
        case (.replaces, .queued(_, replaced: .some)): break
        default: Issue.record("got \(admission)")
        }
    }

    @Test("a superseded operation stops being current, and what superseded it runs once it finishes")
    func supersededOperationHandsOver() throws {
        var queue = RuntimeLifecycleQueue()
        let start = try #require(Self.token(queue.request(Self.start, origin: .user)))
        guard case .queued(let stop, _) = queue.request(Self.stop, origin: .user) else {
            Issue.record("Stop did not queue behind Start")
            return
        }

        #expect(!queue.isCurrent(start))
        #expect(queue.finish(start) == stop)
        #expect(queue.isCurrent(stop))
    }

    @Test("a replaced request never runs; its replacement does")
    func replacedRequestNeverRuns() throws {
        var queue = RuntimeLifecycleQueue()
        let start = try #require(Self.token(queue.request(Self.start, origin: .user)))
        guard case .queued(let stop, _) = queue.request(Self.stop, origin: .user),
            case .queued(let restart, let replaced) = queue.request(Self.restart, origin: .user)
        else {
            Issue.record("Stop and Restart did not queue")
            return
        }

        #expect(replaced == stop)
        #expect(queue.finish(start) == restart)
    }

    @Test("the latest instruction is what waits, or else what runs")
    func latestIsWhatRunsOnceDrained() {
        var queue = RuntimeLifecycleQueue()
        #expect(queue.latest == nil)

        _ = queue.request(Self.start, origin: .user)
        #expect(queue.latest == Self.start)

        _ = queue.request(Self.stop, origin: .user)
        #expect(queue.latest == Self.stop)
    }

    @Test("finishing with nothing waiting leaves the queue idle")
    func finishLeavesQueueIdle() throws {
        var queue = RuntimeLifecycleQueue()
        let stop = try #require(Self.token(queue.request(Self.stop, origin: .user)))

        #expect(queue.finish(stop) == nil)
        #expect(!queue.isCurrent(stop))
        #expect(Self.token(queue.request(Self.start, origin: .launch, observed: queue.generation)) != nil)
    }

    @Test("an automatic request observed before an operation began is dropped, even once idle")
    func observationBeforeOperationIsStale() throws {
        var queue = RuntimeLifecycleQueue()
        let observed = queue.generation
        let stop = try #require(Self.token(queue.request(Self.stop, origin: .user)))
        _ = queue.finish(stop)

        #expect(queue.request(Self.restart, origin: .recovery, observed: observed) == .dropped)
    }

    /// The interleaving Codex reproduced on #105: a probe began while a Stop ran, and its "not
    /// running" verdict arrived once the Stop was over.
    @Test("a probe begun during a Stop cannot restart the runtime after it")
    func probeDuringStopIsStaleAfterIt() throws {
        var queue = RuntimeLifecycleQueue()
        let stop = try #require(Self.token(queue.request(Self.stop, origin: .user)))
        let observed = queue.generation
        _ = queue.finish(stop)

        #expect(queue.request(Self.restart, origin: .recovery, observed: observed) == .dropped)
    }

    @Test("a user request is admitted whatever was observed before it")
    func userRequestIgnoresObservation() throws {
        var queue = RuntimeLifecycleQueue()
        let observed = queue.generation
        let stop = try #require(Self.token(queue.request(Self.stop, origin: .user)))
        _ = queue.finish(stop)

        #expect(Self.token(queue.request(Self.start, origin: .user, observed: observed)) != nil)
    }

    private static func token(_ admission: RuntimeLifecycleQueue.Admission) -> Int? {
        guard case .runNow(let token) = admission else { return nil }
        return token
    }
}
