import Foundation

public actor ClusterOperationLock {
    public static let shared = ClusterOperationLock()

    private var busy = false
    private var waiters: [(id: UUID, turn: CheckedContinuation<Void, any Error>)] = []

    public init() {}

    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await run(before: nil, timeout: nil, operation)
    }

    func run<T: Sendable>(
        before deadline: ContinuousClock.Instant?,
        timeout: ProcessRunnerError?,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        if busy {
            try await waitForTurn(before: deadline, timeout: timeout)
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().turn.resume()
            }
        }
        try Task.checkCancellation()
        return try await operation()
    }

    private func waitForTurn(
        before deadline: ContinuousClock.Instant?, timeout: ProcessRunnerError?
    ) async throws {
        let id = UUID()
        let timer: Task<Void, Never>?
        if let deadline, let timeout {
            timer = Task {
                do { try await Task.sleep(until: deadline) } catch { return }
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
                waiters.remove(at: index).turn.resume(throwing: timeout)
            }
        } else {
            timer = nil
        }
        defer { timer?.cancel() }
        try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
    }
}
