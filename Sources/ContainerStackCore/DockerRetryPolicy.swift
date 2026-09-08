import Darwin
import Foundation

public struct DockerRetryPolicy: Equatable, Sendable {
    public let maxAttempts: Int
    public let delay: Duration

    public init(maxAttempts: Int = 3, delay: Duration = .milliseconds(250)) {
        self.maxAttempts = max(1, maxAttempts)
        self.delay = delay
    }
}

/// Which socket failures are worth asking again, and which cost too much to ask twice.
extension DockerAPIClient {
    /// Failures the kernel reports without spending the connect budget: the peer refused, reset,
    /// or was not there. Asking again costs a syscall rather than a deadline.
    static let immediateFailureCodes = [EAGAIN, ECONNREFUSED, ECONNRESET, ENOTCONN, EPIPE]

    /// EINTR does not belong above: the poll it interrupts can already be most of the way through
    /// its 5s wait when a signal lands (#78's connectPollFailure), so retrying it risks a second
    /// near-full wait, not a cheap syscall. Worth asking again on the general path all the same --
    /// it says nothing about the socket -- just not on `failsImmediately`'s tick-bounded one.
    static let generalRetryCodes = immediateFailureCodes + [EINTR]

    static func isRetryable(_ error: Error) -> Bool {
        guard let socketError = error as? UnixSocketError else {
            return false
        }
        switch socketError {
        case .timedOut:
            return true
        case .systemCallFailed(let code):
            return generalRetryCodes.contains(code)
        case .pathTooLong:
            return false
        }
    }

    /// Stricter than `isRetryable`: excludes `.timedOut` and, unlike it, excludes EINTR too. A
    /// caller polling on a tick can only afford failures proven to cost nothing, and EINTR is not
    /// one of them.
    static func failsImmediately(_ error: Error) -> Bool {
        guard let socketError = error as? UnixSocketError,
            case .systemCallFailed(let code) = socketError
        else {
            return false
        }
        return immediateFailureCodes.contains(code)
    }
}
