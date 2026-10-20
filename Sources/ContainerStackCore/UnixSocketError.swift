import Foundation

public enum UnixSocketError: Error, Equatable, Sendable {
    case pathTooLong
    case timedOut
    case systemCallFailed(Int32)
}

/// Doctor renders these as its second line, so the wording has to be ours: without
/// `LocalizedError` a human reads Foundation's bridge, which names the module and a case index.
extension UnixSocketError: LocalizedError, CustomStringConvertible {
    public var description: String {
        switch self {
        case .pathTooLong: return "The Docker socket path is too long to open a connection to."
        case .timedOut: return "The connection to the Docker socket timed out."
        case .systemCallFailed(let code): return "The connection to the Docker socket failed with error \(code)."
        }
    }

    public var errorDescription: String? { description }
}
