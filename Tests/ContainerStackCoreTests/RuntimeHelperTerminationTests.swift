import ContainerStackCore
import Foundation
import Testing

/// Runs the helper `swift test` builds next to this bundle, against a fake `container`.
@Suite("Runtime helper termination")
struct RuntimeHelperTerminationTests {
    /// Before #102 SIGTERM to the helper left its `container system start` running, where it could
    /// overlap the app's next `system stop`.
    @Test("SIGTERM to the helper ends the container system start it is waiting on")
    func sigtermEndsSystemStart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "containerstack-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appending(path: "system-start.pid")
        let container = directory.appending(path: "container")
        try """
        #!/bin/sh
        case "$1 $2" in
        "--version "*) echo "container CLI version \(RuntimeProcessConfiguration.pinnedContainerVersion)" ;;
        "system start") echo $$ > "\(pidFile.path)"; exec /bin/sleep 60 ;;
        *) exit 1 ;;
        esac
        """.write(to: container, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container.path)

        let helper = Process()
        helper.executableURL = Bundle(for: BundleMarker.self).bundleURL
            .deletingLastPathComponent().appending(path: "ContainerStackRuntime")
        helper.environment = ProcessInfo.processInfo.environment.merging([
            "CONTAINERSTACK_CONTAINER_PATH": container.path,
            "CONTAINERSTACK_RUNTIME_LOG": directory.appending(path: "runtime.log").path,
        ]) { $1 }
        try helper.run()
        defer { if helper.isRunning { kill(helper.processIdentifier, SIGKILL) } }

        let systemStart = try #require(
            await Self.poll {
                (try? String(contentsOf: pidFile, encoding: .utf8))
                    .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            })
        defer { kill(systemStart, SIGKILL) }

        helper.terminate()

        try #require(await Self.poll { helper.isRunning ? nil : true } == true)
        #expect(helper.terminationReason == .uncaughtSignal)
        #expect(helper.terminationStatus == SIGTERM)
        #expect(await Self.poll { kill(systemStart, 0) == 0 ? nil : true } == true)
    }

    private static func poll<Value>(
        within limit: Duration = .seconds(10), _ probe: () -> Value?
    ) async -> Value? {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let value = probe() { return value }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return probe()
    }
}

private final class BundleMarker {}
