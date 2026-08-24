import Darwin
import Foundation

/// Configured memory limits for running containers, and how they compare to the machine.
///
/// Apple Container gives every container its own micro-VM. `HostConfig.Memory`
/// is not current RSS and does not reserve every byte immediately, but host use
/// can grow toward it as the guest fills caches. One 6 GB container was measured
/// at 5.5 GB resident after 17 hours, charged to Apple's Virtualization service
/// rather than ContainerStack or `container-runtime-linux`.
///
/// This type reports configured capacity honestly; it does not claim every byte
/// is already resident.
public struct MemoryCommitment: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        /// Explicit limits are comfortably inside host memory.
        case within
        /// Guests approaching their limits could pressure other applications.
        case approaching
        /// Explicit limits consume at least four fifths of host capacity.
        case exceeding
    }

    /// Risk bands for configured capacity, not a prediction of current RSS.
    public static let approachingFraction = 0.5
    public static let exceedingFraction = 0.8

    public let configuredBytes: Int64
    public let hostBytes: Int64
    /// Containers running without an explicit `HostConfig.Memory`. Named separately because the
    /// total understates by however many there are — an unknown is not a zero.
    public let containersWithoutLimit: Int

    public init(configuredBytes: Int64, hostBytes: Int64, containersWithoutLimit: Int) {
        self.configuredBytes = configuredBytes
        self.hostBytes = hostBytes
        self.containersWithoutLimit = containersWithoutLimit
    }

    /// `limits` is one entry per running container: its `HostConfig.Memory`, or nil where the
    /// runtime reports none. Docker writes `0` for "no limit", so zero and negative are treated
    /// the same as nil rather than summed as nothing.
    public static func measure(limits: [Int64?], hostBytes: Int64) -> MemoryCommitment {
        let explicit = limits.compactMap { $0 }.filter { $0 > 0 }
        let configured = explicit.reduce(Int64.zero) { total, limit in
            let (sum, overflow) = total.addingReportingOverflow(limit)
            return overflow ? Int64.max : sum
        }
        return MemoryCommitment(
            configuredBytes: configured,
            hostBytes: hostBytes,
            containersWithoutLimit: limits.count - explicit.count
        )
    }

    /// nil when host memory is unknown, so a caller says nothing rather than dividing by zero.
    public var fraction: Double? {
        guard hostBytes > 0 else { return nil }
        return Double(configuredBytes) / Double(hostBytes)
    }

    public var verdict: Verdict {
        guard let fraction else { return .within }
        if fraction >= Self.exceedingFraction { return .exceeding }
        if fraction >= Self.approachingFraction { return .approaching }
        return .within
    }
}

public enum HostMemory {
    /// `hw.memsize`. nil rather than a guess when the sysctl fails, so the caller can omit the
    /// comparison instead of printing a fraction of nothing.
    public static func totalBytes() -> Int64? {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        guard
            sysctlbyname("hw.memsize", &size, &length, nil, 0) == 0,
            size > 0,
            size <= UInt64(Int64.max)
        else { return nil }
        return Int64(size)
    }
}
