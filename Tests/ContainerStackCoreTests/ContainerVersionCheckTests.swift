import Testing

@testable import ContainerStackCore

/// The verdict decides whether the runtime this build was tested against is the one on the
/// machine. Both the helper and the app act on it, so it is judged here once.
@Suite("Judging the Apple Container version")
struct ContainerVersionCheckTests {
    private let real = "container CLI version 1.3.1 (build: release, commit: 0190097)"

    @Test("the pinned version inside the sentence is supported")
    func exactVersionIsSupported() {
        #expect(ContainerVersionCheck.verdict(reportedVersion: real, expected: "1.3.1") == .supported)
    }

    /// The reason this is not `contains`: Apple has shipped a tenth patch before, and a check
    /// that accepts 1.3.10 for 1.3.1 lets an untested runtime through silently.
    @Test("a longer patch number is not the pinned version")
    func nearPrefixIsRejected() {
        let verdict = ContainerVersionCheck.verdict(
            reportedVersion: "container CLI version 1.3.10 (build: release)",
            expected: "1.3.1"
        )

        #expect(verdict != .supported)
        #expect(verdict == .mismatch(found: "container CLI version 1.3.10 (build: release)", expected: "1.3.1"))
    }

    @Test("a longer major number is not the pinned version")
    func longerPrefixIsRejected() {
        let verdict = ContainerVersionCheck.verdict(
            reportedVersion: "container CLI version 11.3.1",
            expected: "1.3.1"
        )

        #expect(verdict != .supported)
    }

    @Test("an older runtime is a mismatch that names both versions")
    func olderVersionIsMismatch() {
        let verdict = ContainerVersionCheck.verdict(
            reportedVersion: "container CLI version 1.2.2 (build: release)",
            expected: "1.3.1"
        )

        #expect(verdict == .mismatch(found: "container CLI version 1.2.2 (build: release)", expected: "1.3.1"))
        let message = verdict.userFacingMessage
        #expect(message?.contains("1.3.1") == true)
        #expect(message?.contains("1.2.2") == true)
    }

    @Test("surrounding whitespace does not decide the verdict")
    func outputIsTrimmed() {
        #expect(ContainerVersionCheck.verdict(reportedVersion: "  \(real)\n", expected: "1.3.1") == .supported)
    }

    @Test("a supported runtime has nothing to say")
    func supportedIsSilent() {
        #expect(ContainerVersionVerdict.supported.userFacingMessage == nil)
        #expect(ContainerVersionVerdict.supported.diagnosticMessage == nil)
    }

    /// "not installed" and "installed but wrong" send the reader to different places, so they
    /// are different cases rather than one failure string.
    @Test("a runtime that cannot answer is unavailable, not a mismatch")
    func unavailableIsItsOwnCase() {
        let verdict = ContainerVersionVerdict.unavailable(path: "/nope/container", reason: "no such file")

        #expect(verdict.userFacingMessage?.contains("/nope/container") == true)
        #expect(verdict.diagnosticMessage?.contains("no such file") == true)
    }
}
