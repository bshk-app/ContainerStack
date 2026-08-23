import Darwin
import Foundation

/// Total host memory claimed by running containers, and how that compares to the machine.
///
/// This matters here in a way it does not on a shared-VM runtime. Apple Container gives every
/// container **its own micro-VM**, and the guest's memory is resident in the host — inside
/// Apple's `com.apple.Virtualization.VirtualMachine` XPC service, charged to neither
/// ContainerStack nor `container-runtime-linux`. So a container's `HostConfig.Memory` is not a
/// ceiling that costs nothing until reached: it is host memory the guest will occupy as it fills
/// its own caches. One container allocated 6 GB was measured holding 5.5 GB of host memory after
/// 17 hours, climbing toward its limit.
///
/// Nothing in the app or the CLI reported that total, so the only place a person could see the
/// consequence was the system's own out-of-memory dialog — which attributes it to whichever
/// applications happen to be running, not to the runtime.
public struct MemoryCommitment: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        /// Comfortably inside host memory.
        case within
        /// Enough of the machine that other applications will feel it.
        case approaching
        /// More than the machine can hold alongside anything else.
        case exceeding
    }

    /// Reported rather than predicted: a guest reaches its limit only if it wants to. These are
    /// the points at which the total is worth saying out loud.
    public static let approachingFraction = 0.5
    public static let exceedingFraction = 0.8

    public let allocatedBytes: Int64
    public let hostBytes: Int64
    /// Containers running without an explicit `HostConfig.Memory`. Named separately because the
    /// total understates by however many there are — an unknown is not a zero.
    public let containersWithoutLimit: Int

    public init(allocatedBytes: Int64, hostBytes: Int64, containersWithoutLimit: Int) {
        self.allocatedBytes = allocatedBytes
        self.hostBytes = hostBytes
        self.containersWithoutLimit = containersWithoutLimit
    }

    /// `limits` is one entry per running container: its `HostConfig.Memory`, or nil where the
    /// runtime reports none. Docker writes `0` for "no limit", so zero and negative are treated
    /// the same as nil rather than summed as nothing.
    public static func measure(limits: [Int64?], hostBytes: Int64) -> MemoryCommitment {
        let explicit = limits.compactMap { $0 }.filter { $0 > 0 }
        return MemoryCommitment(
            allocatedBytes: explicit.reduce(0, +),
            hostBytes: hostBytes,
            containersWithoutLimit: limits.count - explicit.count
        )
    }

    /// nil when host memory is unknown, so a caller says nothing rather than dividing by zero.
    public var fraction: Double? {
        guard hostBytes > 0 else { return nil }
        return Double(allocatedBytes) / Double(hostBytes)
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
        guard sysctlbyname("hw.memsize", &size, &length, nil, 0) == 0, size > 0 else {
            return nil
        }
        return Int64(size)
    }
}
