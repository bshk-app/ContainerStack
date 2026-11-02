import Foundation
import Testing

@testable import ContainerStackCore

@Suite("The image builder is stopped after it is idle")
struct BuilderIdleStopTests {
    private let start = ContinuousClock.now
    private let tenMinutes = Duration.seconds(600)

    private func at(minutes: Int) -> ContinuousClock.Instant {
        start + .seconds(minutes * 60)
    }

    /// An idle BuildKit: a few milliseconds of CPU and a few bytes a minute.
    private func idle(after minutes: Int) -> BuilderActivity {
        BuilderActivity(cpuMicroseconds: UInt64(1_000_000 + minutes * 5_000), transferredBytes: UInt64(minutes * 1_000))
    }

    // MARK: - Parsing

    /// The fields socktainer fills in a Docker stats sample. `total_usage` is in nanoseconds.
    private static func statsJSON(cpuNanoseconds: UInt64, networkBytes: UInt64 = 0, blockBytes: UInt64 = 0) -> String {
        """
        {"id":"buildkit","cpu_stats":{"cpu_usage":{"total_usage":\(cpuNanoseconds)}},
         "networks":{"eth0":{"rx_bytes":\(networkBytes),"tx_bytes":0}},
         "blkio_stats":{"io_service_bytes_recursive":[{"major":0,"minor":0,"op":"read","value":\(blockBytes)}]}}
        """
    }

    @Test func parsesTheCountersOfADockerStatsSample() {
        let json = """
            {"id":"buildkit","cpu_stats":{"cpu_usage":{"total_usage":14807496000}},
             "networks":{"eth0":{"rx_bytes":3000,"tx_bytes":400},"eth1":{"rx_bytes":100,"tx_bytes":0}},
             "blkio_stats":{"io_service_bytes_recursive":[{"major":0,"minor":0,"op":"read","value":100},
               {"major":0,"minor":0,"op":"write","value":20}]}}
            """

        #expect(
            BuilderActivity.parse(dockerStats: Data(json.utf8))
                == BuilderActivity(cpuMicroseconds: 14_807_496, transferredBytes: 3_620))
    }

    /// The CPU total alone is enough: odd network or block fields must not make a running
    /// builder look stopped.
    @Test func readsTheCPUTotalDespiteOddCounters() {
        let json =
            #"{"cpu_stats":{"cpu_usage":{"total_usage":2000}},"networks":{"eth0":{"name":"x"}},"blkio_stats":{}}"#

        #expect(
            BuilderActivity.parse(dockerStats: Data(json.utf8))
                == BuilderActivity(cpuMicroseconds: 2, transferredBytes: 0))
    }

    @Test(arguments: ["", "not json", #"{"id":"buildkit"}"#])
    func readsNoActivityFromAnIncompleteSample(output: String) {
        #expect(BuilderActivity.parse(dockerStats: Data(output.utf8)) == nil)
    }

    // MARK: - Monitor

    private func idleRuntime(minute: Int, builders: [String], others: [String] = []) -> StubDockerTransport {
        let buildx = builders.filter { $0.hasPrefix("buildx_") }.map {
            #"{"Id":"\#($0)","Names":["/\#($0)"],"Command":"/usr/bin/buildkitd-entrypoint","State":"running"}"#
        }
        let containers =
            buildx
            + others.map {
                #"{"Id":"\#($0)","Names":["/\#($0)"],"Command":"nginx -g 'daemon off;'","State":"running"}"#
            }
        let apple = builders.filter { !$0.hasPrefix("buildx_") }.map {
            #"{"Id":"\#($0)","Names":["/\#($0)"],"State":"running"}"#
        }
        var byPath: [String: Result<Data, any Error>] = [
            "/containers/json": .success(jsonResponse("[\(containers.joined(separator: ","))]")),
            DockerAPIClient.runningBuildersPath: .success(jsonResponse("[\(apple.joined(separator: ","))]")),
        ]
        for name in builders + others {
            let sample = Self.statsJSON(cpuNanoseconds: UInt64(1_000_000_000 + minute * 5_000_000))
            byPath["/containers/\(name)/stats?stream=false"] = .success(jsonResponse(sample))
            byPath["/containers/\(name)/stop?t=5"] = .success(httpResponse(status: 204, body: Data()))
        }
        return StubDockerTransport(byPath: byPath)
    }

    private func client(_ transport: StubDockerTransport) -> DockerAPIClient {
        DockerAPIClient(transport: transport, retryPolicy: DockerRetryPolicy(maxAttempts: 1, delay: .zero))
    }

    /// The Apple builder serves `container build` and socktainer's build endpoint. A buildx
    /// builder serves `docker build`. Each is a VM that keeps the memory it has used.
    @Test func stopsBothKindsOfIdleBuilderAndNothingElse() async {
        var monitor = BuilderIdleMonitor()
        var stopped: [[String]] = []
        var last: StubDockerTransport?
        for minute in 0...10 {
            let transport = idleRuntime(
                minute: minute,
                builders: ["buildkit", "buildx_buildkit_containerstack"],
                others: ["web", "buildx_buildkit_web"]
            )
            stopped.append(
                await monitor.tick(client: client(transport), at: at(minutes: minute), idleLimit: tenMinutes))
            last = transport
        }

        let nothingStoppedEarlier = stopped.dropLast().allSatisfy(\.isEmpty)
        #expect(nothingStoppedEarlier)
        #expect(stopped.last?.sorted() == ["buildkit", "buildx_buildkit_containerstack"])
        let stops = await last?.paths.filter { $0.hasSuffix("/stop?t=5") } ?? []
        #expect(
            stops.sorted() == ["/containers/buildkit/stop?t=5", "/containers/buildx_buildkit_containerstack/stop?t=5"])
    }

    @Test func aBuilderThatStoppedOnItsOwnIsForgotten() async {
        var monitor = BuilderIdleMonitor()
        for minute in 0...9 {
            _ = await monitor.tick(
                client: client(idleRuntime(minute: minute, builders: ["buildkit"])),
                at: at(minutes: minute),
                idleLimit: tenMinutes
            )
        }
        _ = await monitor.tick(
            client: client(idleRuntime(minute: 10, builders: [])), at: at(minutes: 10), idleLimit: tenMinutes)

        let stopped = await monitor.tick(
            client: client(idleRuntime(minute: 11, builders: ["buildkit"])),
            at: at(minutes: 11),
            idleLimit: tenMinutes
        )
        #expect(stopped.isEmpty)
    }

    // MARK: - Tracking

    @Test func stopsABuilderIdleForTheWholeLimit() {
        var tracker = BuilderIdleTracker()

        let decisions = (0...10).map { minute in
            tracker.observe(idle(after: minute), at: at(minutes: minute), idleLimit: tenMinutes)
        }

        #expect(decisions == Array(repeating: false, count: 10) + [true])
    }

    @Test func aBuildRestartsTheIdleTime() {
        var tracker = BuilderIdleTracker()
        for minute in 0...8 {
            _ = tracker.observe(idle(after: minute), at: at(minutes: minute), idleLimit: tenMinutes)
        }
        // One minute of compiling: 30 CPU seconds.
        let busy = BuilderActivity(
            cpuMicroseconds: idle(after: 9).cpuMicroseconds + 30_000_000, transferredBytes: 9_000)
        let stoppedWhileBusy = tracker.observe(busy, at: at(minutes: 9), idleLimit: tenMinutes)
        #expect(!stoppedWhileBusy)

        let later = (10...19).map { minute in
            tracker.observe(
                BuilderActivity(
                    cpuMicroseconds: busy.cpuMicroseconds + UInt64(minute * 5_000),
                    transferredBytes: busy.transferredBytes + UInt64(minute * 1_000)),
                at: at(minutes: minute),
                idleLimit: tenMinutes
            )
        }
        #expect(later == Array(repeating: false, count: 9) + [true])
    }

    /// A slow download uses little CPU, but it moves bytes.
    @Test func aDownloadCountsAsActivity() {
        var tracker = BuilderIdleTracker()
        var decisions: [Bool] = []
        for minute in 0...12 {
            let downloading = BuilderActivity(cpuMicroseconds: 1_000_000, transferredBytes: UInt64(minute) * 6_000_000)
            decisions.append(tracker.observe(downloading, at: at(minutes: minute), idleLimit: tenMinutes))
        }
        #expect(!decisions.contains(true))
    }

    /// Counters that go back mean a new builder VM, so it starts with a full idle limit.
    @Test func aRecreatedBuilderStartsAgain() {
        var tracker = BuilderIdleTracker()
        for minute in 0...9 {
            _ = tracker.observe(idle(after: minute + 100), at: at(minutes: minute), idleLimit: tenMinutes)
        }
        let stoppedANewBuilder = tracker.observe(idle(after: 0), at: at(minutes: 10), idleLimit: tenMinutes)
        #expect(!stoppedANewBuilder)
    }

    @Test func aStoppedBuilderClearsTheIdleTime() {
        var tracker = BuilderIdleTracker()
        for minute in 0...9 {
            _ = tracker.observe(idle(after: minute), at: at(minutes: minute), idleLimit: tenMinutes)
        }
        let stoppedWithoutABuilder = tracker.observe(nil, at: at(minutes: 10), idleLimit: tenMinutes)
        #expect(!stoppedWithoutABuilder)
        let stoppedAfterItStarted = tracker.observe(idle(after: 11), at: at(minutes: 11), idleLimit: tenMinutes)
        #expect(!stoppedAfterItStarted)
    }

    @Test func neverStopsWithoutALimit() {
        var tracker = BuilderIdleTracker()

        let decisions = (0...120).map { minute in
            tracker.observe(idle(after: minute), at: at(minutes: minute), idleLimit: nil)
        }

        #expect(!decisions.contains(true))
    }

    // MARK: - Setting

    @Test(arguments: [(nil, Duration?.some(.seconds(600))), (0, nil), (5, .seconds(300)), (60, .seconds(3_600))])
    func minutesBecomeTheIdleLimit(minutes: Int?, limit: Duration?) {
        #expect(BuilderIdleStop.idleLimit(minutes: minutes) == limit)
    }

    /// The runtime helper reads the app's preferences domain by name.
    @Test func readsTheMinutesFromAPreferencesDomain() throws {
        let domain = "BuilderIdleStopTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(BuilderIdleStop.configuredIdleLimit(domain: domain) == .seconds(600))

        defaults.set(30, forKey: BuilderIdleStop.minutesKey)

        #expect(BuilderIdleStop.configuredIdleLimit(domain: domain) == .seconds(1_800))
    }
}

@Suite("The adopting helper ends with the bridge it adopted")
struct AdoptedBridgeExitTests {
    /// The app reads a live helper and a dead socket as a runtime that is still starting, which
    /// disables Start and Restart. So the helper must end as soon as the bridge does.
    @Test func returnsSoonAfterTheProcessExits() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.3"]
        try process.run()
        let clock = ContinuousClock()
        let started = clock.now

        let pid = process.processIdentifier
        let waiter = Task { await ProcessExit.wait(for: pid, interval: .milliseconds(50)) }
        // A wait that never returns would hang the run; cancelling it turns that into a failure.
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            waiter.cancel()
        }
        await waiter.value
        deadline.cancel()

        #expect(clock.now - started < .seconds(5))
        #expect(!process.isRunning)
    }
}
