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
    /// Failures the kernel reports without waiting: the peer refused, reset, or was not there.
    /// Asking again costs a syscall rather than a deadline.
    static let immediateFailureCodes = [EAGAIN, EINTR, ECONNREFUSED, ECONNRESET, ENOTCONN, EPIPE]

    static func isRetryable(_ error: Error) -> Bool {
        guard let socketError = error as? UnixSocketError else {
            return false
        }
        switch socketError {
        case .timedOut:
            return true
        case .systemCallFailed(let code):
            return immediateFailureCodes.contains(code)
        case .pathTooLong:
            return false
        }
    }

    /// `isRetryable` minus `.timedOut`. A timeout has already spent its whole budget, so retrying
    /// it turns one request into several deadlines — which a caller polling on a tick cannot
    /// afford, and which says nothing new about a socket already answering too slowly.
    static func failsImmediately(_ error: Error) -> Bool {
        guard let socketError = error as? UnixSocketError,
            case .systemCallFailed(let code) = socketError
        else {
            return false
        }
        return immediateFailureCodes.contains(code)
    }
}
