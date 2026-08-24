import Foundation
import Testing

@testable import ContainerStackCore

/// The plumbing these tests cover replaced four copies of `process.run()` followed by a bare
/// `process.waitUntilExit()`. Two properties matter and neither held before: a child that never
/// exits must not block its caller forever, and a child that writes more than the pipe buffer
/// must not deadlock against the read that is supposed to collect it.
@Suite("Child processes are bounded and fully drained")
struct ProcessRunnerTests {

    @Test("captures stdout and reports a zero status")
    func capturesStandardOutput() throws {
        let result = try ProcessRunner.run(
            executablePath: "/bin/echo",
            arguments: ["hello"],
            output: .capture(includingStandardError: false),
            timeout: .seconds(5)
        )

        #expect(result.status == 0)
        #expect(result.output == "hello\n")
    }

    /// A non-zero exit is data, not an error: each caller keeps its own error type, and the one
    /// that used to discard the status is why `cstack` printed "Runtime restarted." after
    /// nothing restarted.
    @Test("a non-zero exit is returned rather than thrown")
    func reportsFailingStatusWithoutThrowing() throws {
        let result = try ProcessRunner.run(
            executablePath: "/usr/bin/false",
            timeout: .seconds(5)
        )

        #expect(result.status != 0)
    }

    @Test("stderr is merged only when the caller asks for it")
    func mergesStandardErrorOnRequest() throws {
        let missing = "/nonexistent-\(UUID().uuidString)"

        let merged = try ProcessRunner.run(
            executablePath: "/bin/ls",
            arguments: [missing],
            output: .capture(includingStandardError: true),
            timeout: .seconds(5)
        )
        let stdoutOnly = try ProcessRunner.run(
            executablePath: "/bin/ls",
            arguments: [missing],
            output: .capture(includingStandardError: false),
            timeout: .seconds(5)
        )

        #expect(merged.status != 0)
        #expect(!merged.output.isEmpty)
        #expect(stdoutOnly.output.isEmpty)
    }

    /// The regression that wedged the app: `waitUntilExit()` has no deadline, so a hung child
    /// pinned the 3s monitor loop and left Start/Stop permanently unresponsive. Without the
    /// deadline this test does not fail — it hangs until the suite is killed.
    @Test("a child that outlives its deadline is killed and reported")
    func killsAChildThatOutlivesItsDeadline() throws {
        let started = ContinuousClock.now

        #expect(throws: ProcessRunnerError.self) {
            try ProcessRunner.run(
                executablePath: "/bin/sleep",
                arguments: ["30"],
                timeout: .milliseconds(300)
            )
        }

        // Generous, so a loaded CI machine cannot make this flaky, while still far below the
        // 30s the child asked for: the point is that the deadline returned control at all.
        #expect(started.duration(to: .now) < .seconds(10))
    }

    @Test("the timeout error names the binary and the deadline")
    func timeoutErrorCarriesItsContext() throws {
        do {
            _ = try ProcessRunner.run(
                executablePath: "/bin/sleep",
                arguments: ["30"],
                timeout: .milliseconds(200)
            )
            Issue.record("expected the deadline to fire")
        } catch let error as ProcessRunnerError {
            #expect(error == .timedOut(executablePath: "/bin/sleep", seconds: 0.2))
            #expect(error.description.contains("/bin/sleep"))
        }
    }

    /// A pipe holds ~64 KB. Draining on the calling thread only after the child exits deadlocks
    /// here: the child blocks writing into a full pipe, so it never exits, so the read never
    /// starts. 512 KB is comfortably past the buffer.
    @Test("output larger than the pipe buffer neither truncates nor deadlocks")
    func drainsOutputLargerThanThePipeBuffer() throws {
        let result = try ProcessRunner.run(
            executablePath: "/bin/dd",
            arguments: ["if=/dev/zero", "bs=1024", "count=512"],
            output: .capture(includingStandardError: false),
            timeout: .seconds(20)
        )

        #expect(result.status == 0)
        #expect(result.output.utf8.count == 512 * 1024)
    }

    @Test("a missing binary throws instead of hanging on the drain")
    func missingBinaryThrows() throws {
        #expect(throws: (any Error).self) {
            try ProcessRunner.run(
                executablePath: "/nonexistent-\(UUID().uuidString)",
                output: .capture(includingStandardError: true),
                timeout: .seconds(5)
            )
        }
    }

    @Test("a descendant that inherits stdout cannot outlive the deadline")
    func descendantHoldingPipeIsBounded() throws {
        let started = ContinuousClock.now

        let result = try ProcessRunner.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 30 & printf done"],
            output: .capture(includingStandardError: true),
            timeout: .milliseconds(300)
        )

        #expect(result.output == "done")
        #expect(started.duration(to: .now) < .seconds(5))
    }
}
