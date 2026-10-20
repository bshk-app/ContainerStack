import ContainerStackCore
import Foundation
import Testing

/// One entry per `SystemProbe` method, so a recorded run reports which spawns
/// it made and not merely how many.
public enum ProbeCall: String, Sendable {
    case runtimeStatus, routingTable, socketHolder, processTable
}

public actor RecordingSystemProbe: SystemProbe {
    private let canned: [ProbeCall: ProbeResult]
    public private(set) var calls: [ProbeCall] = []
    public private(set) var socketPaths: [String] = []

    public var callCount: Int { calls.count }

    public init(
        runtimeStatus: ProbeResult? = nil,
        routingTable: ProbeResult? = nil,
        socketHolder: ProbeResult? = nil,
        processTable: ProbeResult? = nil
    ) {
        var canned: [ProbeCall: ProbeResult] = [:]
        canned[.runtimeStatus] = runtimeStatus
        canned[.routingTable] = routingTable
        canned[.socketHolder] = socketHolder
        canned[.processTable] = processTable
        self.canned = canned
    }

    public func callCount(of call: ProbeCall) -> Int { calls.count { $0 == call } }

    public func runtimeStatus() async -> ProbeResult { answer(.runtimeStatus) }

    public func routingTable() async -> ProbeResult { answer(.routingTable) }

    public func socketHolder(socketPath: String) async -> ProbeResult {
        socketPaths.append(socketPath)
        return answer(.socketHolder)
    }

    public func processTable() async -> ProbeResult { answer(.processTable) }

    // An unconfigured method fails the test: inventing `.output("")` here would
    // rebuild the laundering this protocol exists to prevent.
    private func answer(_ call: ProbeCall) -> ProbeResult {
        calls.append(call)
        guard let result = canned[call] else {
            let reason = "RecordingSystemProbe has no canned result for \(call.rawValue)"
            Issue.record(Comment(rawValue: reason))
            return .failed(reason: reason)
        }
        return result
    }
}

public actor GatedSystemProbe: SystemProbe {
    private let result: ProbeResult
    private var isOpen = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var exitWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
    public private(set) var callCount = 0
    public private(set) var completedCallCount = 0

    public init(result: ProbeResult) { self.result = result }

    /// Releases every parked call and admits later ones; reopening an open gate
    /// is a no-op, so no continuation is ever resumed twice.
    public func open() {
        isOpen = true
        let waiting = gateWaiters
        gateWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Returns once `count` calls have entered, so a test can act on a suspended
    /// run — including a second, coalescing one — without sleeping.
    public func waitUntilCalled(count: Int = 1) async {
        guard callCount < count else { return }
        await withCheckedContinuation { entryWaiters.append((count, $0)) }
    }

    /// The other end: returns once `count` calls have left the gate, so a test can let a
    /// run abandoned by a deadline finish before it asserts anything about it.
    public func waitUntilCompleted(count: Int = 1) async {
        guard completedCallCount < count else { return }
        await withCheckedContinuation { exitWaiters.append((count, $0)) }
    }

    public func runtimeStatus() async -> ProbeResult { await gate() }

    public func routingTable() async -> ProbeResult { await gate() }

    public func socketHolder(socketPath: String) async -> ProbeResult { await gate() }

    public func processTable() async -> ProbeResult { await gate() }

    private func gate() async -> ProbeResult {
        callCount += 1
        let entered = entryWaiters.filter { $0.threshold <= callCount }
        entryWaiters.removeAll { $0.threshold <= callCount }
        for waiter in entered { waiter.continuation.resume() }
        if !isOpen {
            await withCheckedContinuation { gateWaiters.append($0) }
        }
        completedCallCount += 1
        let left = exitWaiters.filter { $0.threshold <= completedCallCount }
        exitWaiters.removeAll { $0.threshold <= completedCallCount }
        for waiter in left { waiter.continuation.resume() }
        return result
    }
}
