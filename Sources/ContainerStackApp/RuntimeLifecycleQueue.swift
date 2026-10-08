/// What the runtime is asked to do. `replacingSibling` is for an operation a person asked for, the
/// only kind that may stop another copy's bridge (F-014).
enum RuntimeOperation: Equatable {
    case start
    case stop(replacingSibling: Bool)
    case restart(replacingSibling: Bool)
}

/// Why an operation was asked for. The automatic reasons differ in what they may supersede, so the
/// queue needs the reason, not just "automatic".
enum RuntimeOperationOrigin: Equatable {
    case user
    /// The probe proved the API server gone.
    case recovery
    /// The probe found a bridge from another build holding the socket.
    case staleBridge
    case launch
}

/// Decides which runtime operation runs: one at a time, at most one more waiting, and the user's
/// last instruction wins. It holds no process and awaits nothing, so every rule is tested on its
/// own (#102).
///
/// Superseding is queueing: a request that displaces the running operation waits behind it, and
/// the operation it displaced keeps the queue until its next checkpoint, where it finds its token
/// no longer current and finishes. So an operation is current exactly while nothing waits.
struct RuntimeLifecycleQueue {
    enum Admission: Equatable {
        case runNow(token: Int)
        /// Waits for the running operation to finish, then runs under `id` as its token.
        /// `replaced` is the waiting request this one displaced, which settles as superseded.
        case queued(id: Int, replaced: Int?)
        case dropped
    }

    private struct Entry {
        let number: Int
        let operation: RuntimeOperation
    }

    /// Moves when an operation begins and when it ends. An automatic request carries the value its
    /// observation began under, and is dropped once that has moved: what it saw is out of date.
    private(set) var generation = 0
    private var running: Entry?
    private var pending: Entry?
    private var lastNumber = 0

    func isCurrent(_ token: Int) -> Bool {
        running?.number == token && pending == nil
    }

    mutating func request(
        _ operation: RuntimeOperation,
        origin: RuntimeOperationOrigin,
        observed: Int? = nil
    ) -> Admission {
        if origin != .user, let observed, observed != generation { return .dropped }
        guard let current = running else {
            running = entry(for: operation)
            generation &+= 1
            return .runNow(token: lastNumber)
        }
        if let waiting = pending {
            guard origin == .user, operation != waiting.operation else { return .dropped }
            pending = entry(for: operation)
            return .queued(id: lastNumber, replaced: waiting.number)
        }
        // A start whose API server is gone cannot finish without a restart, so recovery may
        // displace one; the other automatic work never undoes something already under way.
        let mayDisplace = origin == .user || (origin == .recovery && current.operation == .start)
        guard mayDisplace, operation != current.operation else { return .dropped }
        pending = entry(for: operation)
        return .queued(id: lastNumber, replaced: nil)
    }

    /// Ends the running operation and returns the waiting request now running under its id, if any.
    mutating func finish(_ token: Int) -> Int? {
        precondition(running?.number == token, "Only the running operation can finish")
        generation &+= 1
        running = pending
        pending = nil
        return running?.number
    }

    private mutating func entry(for operation: RuntimeOperation) -> Entry {
        lastNumber &+= 1
        return Entry(number: lastNumber, operation: operation)
    }
}
