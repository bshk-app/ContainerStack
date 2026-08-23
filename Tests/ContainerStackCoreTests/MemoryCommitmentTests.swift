import Foundation
import Testing

@testable import ContainerStackCore

/// Apple Container gives every container its own micro-VM, and the guest's memory is resident in
/// the host — inside Apple's Virtualization XPC service, charged to neither ContainerStack nor
/// `container-runtime-linux`. A container allocated 6 GB was measured holding 5.5 GB of host
/// memory after 17 hours. Nothing reported that total, so the numbers below are the point.
@Suite("Container memory allocations are summed against host memory")
struct MemoryCommitmentTests {
    private let gigabyte: Int64 = 1_073_741_824

    @Test("explicit limits are summed")
    func sumsExplicitLimits() {
        let commitment = MemoryCommitment.measure(
            limits: [2 * gigabyte, 4 * gigabyte],
            hostBytes: 32 * gigabyte
        )

        #expect(commitment.allocatedBytes == 6 * gigabyte)
        #expect(commitment.containersWithoutLimit == 0)
    }

    /// Docker writes `0` for "no limit". Summing it as nothing would be arithmetically fine and
    /// still wrong: the container is unbounded, which is the opposite of contributing zero.
    @Test("zero and nil both count as no limit, not as zero bytes")
    func treatsZeroAsUnlimited() {
        let commitment = MemoryCommitment.measure(
            limits: [4 * gigabyte, 0, nil],
            hostBytes: 32 * gigabyte
        )

        #expect(commitment.allocatedBytes == 4 * gigabyte)
        #expect(commitment.containersWithoutLimit == 2)
    }

    @Test("a fraction of host memory below half reads as within")
    func withinBelowHalf() {
        let commitment = MemoryCommitment.measure(limits: [6 * gigabyte], hostBytes: 32 * gigabyte)

        #expect(commitment.verdict == .within)
        #expect(commitment.fraction == 6.0 / 32.0)
    }

    @Test("half of host memory reads as approaching")
    func approachingAtHalf() {
        let commitment = MemoryCommitment.measure(limits: [16 * gigabyte], hostBytes: 32 * gigabyte)

        #expect(commitment.verdict == .approaching)
    }

    @Test("four fifths of host memory reads as exceeding")
    func exceedingAtFourFifths() {
        let commitment = MemoryCommitment.measure(
            limits: [16 * gigabyte, 10 * gigabyte],
            hostBytes: 32 * gigabyte
        )

        #expect(commitment.verdict == .exceeding)
    }

    /// The case that motivated this: one 6 GB container on a 32 GB machine. It is **not** an
    /// over-commit, and the check must not claim otherwise — the value is that the 6 GB is
    /// stated at all, since it was invisible.
    @Test("the measured incident is reported, not warned about")
    func theMeasuredIncidentIsWithin() {
        let commitment = MemoryCommitment.measure(
            limits: [6_442_450_944],
            hostBytes: 34_359_738_368
        )

        #expect(commitment.verdict == .within)
        #expect(commitment.allocatedBytes == 6_442_450_944)
    }

    /// Dividing by an unknown host size would print a fraction of nothing.
    @Test("unknown host memory yields no fraction and no warning")
    func unknownHostMemoryIsSilent() {
        let commitment = MemoryCommitment.measure(limits: [4 * gigabyte], hostBytes: 0)

        #expect(commitment.fraction == nil)
        #expect(commitment.verdict == .within)
    }

    @Test("no running containers means nothing allocated")
    func noContainers() {
        let commitment = MemoryCommitment.measure(limits: [], hostBytes: 32 * gigabyte)

        #expect(commitment.allocatedBytes == 0)
        #expect(commitment.containersWithoutLimit == 0)
        #expect(commitment.verdict == .within)
    }

    /// Not a fixed expectation — the machine varies — but the sysctl has to answer with
    /// something plausible, or the comparison it feeds is meaningless.
    @Test("host memory is readable and plausible")
    func hostMemoryIsReadable() throws {
        let total = try #require(HostMemory.totalBytes())

        #expect(total >= gigabyte)
    }
}
