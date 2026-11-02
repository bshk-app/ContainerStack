import Foundation

/// Cumulative counters of a builder VM, from a Docker stats sample.
public struct BuilderActivity: Equatable, Sendable {
    public var cpuMicroseconds: UInt64
    /// Network and block I/O bytes together: a download or a layer write is work too.
    public var transferredBytes: UInt64

    public init(cpuMicroseconds: UInt64, transferredBytes: UInt64) {
        self.cpuMicroseconds = cpuMicroseconds
        self.transferredBytes = transferredBytes
    }

    /// `GET /containers/{id}/stats?stream=false`. nil without a CPU total.
    public static func parse(dockerStats: Data) -> BuilderActivity? {
        (try? JSONDecoder().decode(DockerStatsSample.self, from: dockerStats))?.activity
    }
}

/// The part of a Docker stats sample that shows work.
struct DockerStatsSample: Decodable, Sendable {
    let activity: BuilderActivity

    private enum Key: String, CodingKey {
        case cpuStats = "cpu_stats"
        case cpuUsage = "cpu_usage"
        case totalUsage = "total_usage"
        case networks
        case rxBytes = "rx_bytes"
        case txBytes = "tx_bytes"
        case blockIO = "blkio_stats"
        case serviceBytes = "io_service_bytes_recursive"
        case value
    }

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: Key.self)
        let usage = try root.nestedContainer(keyedBy: Key.self, forKey: .cpuStats)
            .nestedContainer(keyedBy: Key.self, forKey: .cpuUsage)
        let nanoseconds = try usage.decode(UInt64.self, forKey: .totalUsage)

        // Best effort: an unexpected field here must not hide the CPU total, or a builder would
        // read as not running and never stop.
        let networks = (try? root.decodeIfPresent([String: [String: UInt64]].self, forKey: .networks)) ?? [:]
        let networkBytes = networks.values.reduce(UInt64.zero) {
            $0 &+ ($1[Key.rxBytes.rawValue] ?? 0) &+ ($1[Key.txBytes.rawValue] ?? 0)
        }
        let bytes = networkBytes &+ ((try? Self.blockBytes(in: root)) ?? 0)
        activity = BuilderActivity(cpuMicroseconds: nanoseconds / 1_000, transferredBytes: bytes)
    }

    private static func blockBytes(in root: KeyedDecodingContainer<Key>) throws -> UInt64 {
        guard root.contains(.blockIO), try !root.decodeNil(forKey: .blockIO) else { return 0 }
        let blockIO = try root.nestedContainer(keyedBy: Key.self, forKey: .blockIO)
        guard blockIO.contains(.serviceBytes), try !blockIO.decodeNil(forKey: .serviceBytes) else { return 0 }
        var entries = try blockIO.nestedUnkeyedContainer(forKey: .serviceBytes)
        var bytes = UInt64.zero
        while !entries.isAtEnd {
            bytes &+= try entries.nestedContainer(keyedBy: Key.self).decode(UInt64.self, forKey: .value)
        }
        return bytes
    }
}

/// Decides when a running builder has been idle for the whole limit. A builder VM keeps the
/// memory it has used until it stops, and nothing else stops it.
public struct BuilderIdleTracker: Sendable {
    /// An idle BuildKit was measured at 0.01% of one CPU. A compile, an image pull or a context
    /// upload is far above one of these two.
    static let activeCPUShare = 0.01
    static let activeBytesPerMinute = 1_048_576.0

    private var previous: (activity: BuilderActivity, at: ContinuousClock.Instant)?
    private var lastActive: ContinuousClock.Instant?

    public init() {}

    /// Feeds one sample, nil while no builder runs. true when the builder should stop now.
    public mutating func observe(
        _ activity: BuilderActivity?,
        at now: ContinuousClock.Instant,
        idleLimit: Duration?
    ) -> Bool {
        guard let activity else {
            previous = nil
            lastActive = nil
            return false
        }
        defer { previous = (activity, now) }
        guard let previous, let lastActive else {
            self.lastActive = now
            return false
        }
        let active = Self.isActive(from: previous.activity, to: activity, over: now - previous.at)
        let since = active ? now : lastActive
        self.lastActive = since
        guard let idleLimit else { return false }
        return now - since >= idleLimit
    }

    /// Counters that go back belong to a new builder VM, which counts as activity.
    private static func isActive(from old: BuilderActivity, to new: BuilderActivity, over elapsed: Duration) -> Bool {
        guard new.cpuMicroseconds >= old.cpuMicroseconds, new.transferredBytes >= old.transferredBytes else {
            return true
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let cpu = Double(new.cpuMicroseconds - old.cpuMicroseconds)
        let bytes = Double(new.transferredBytes - old.transferredBytes)
        return cpu > seconds * 1_000_000 * activeCPUShare || bytes > seconds / 60 * activeBytesPerMinute
    }
}

/// Stops idle builders. Two kinds run BuildKit in a VM of their own: Apple's image builder, which
/// `container build` and socktainer's build endpoint start, and the buildx builder containers that
/// `docker build` starts with the docker-container driver. All calls go through the Docker API, so
/// socktainer knows that a stop was asked for and does not apply a restart policy to it.
public struct BuilderIdleMonitor: Sendable {
    static let buildxNamePrefix = "/buildx_buildkit_"

    private var trackers: [String: BuilderIdleTracker] = [:]

    public init() {}

    /// One sample of every running builder. Returns the builders it stopped.
    public mutating func tick(client: DockerAPIClient, at now: ContinuousClock.Instant, idleLimit: Duration?) async
        -> [String]
    {
        let builders = await Self.runningBuilders(client: client)
        trackers = trackers.filter { builders.contains($0.key) }
        var stopped: [String] = []
        for id in builders {
            let activity = try? await client.builderActivity(id: id)
            var tracker = trackers[id] ?? BuilderIdleTracker()
            if tracker.observe(activity, at: now, idleLimit: idleLimit),
                (try? await client.stopContainer(id: id)) != nil
            {
                trackers[id] = nil
                stopped.append(id)
            } else {
                trackers[id] = tracker
            }
        }
        return stopped
    }

    /// Ticks once a minute until the task is cancelled.
    public static func watch(
        client: DockerAPIClient,
        idleLimit: @Sendable () -> Duration? = { BuilderIdleStop.configuredIdleLimit() },
        stopped: @Sendable (_ id: String, _ idleLimit: Duration?) -> Void
    ) async {
        var monitor = BuilderIdleMonitor()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            let limit = idleLimit()
            for id in await monitor.tick(client: client, at: .now, idleLimit: limit) {
                stopped(id, limit)
            }
        }
    }

    private static func runningBuilders(client: DockerAPIClient) async -> [String] {
        let apple = (try? await client.runningBuilderIDs()) ?? []
        // buildx sets no label, so the name and the BuildKit daemon command identify its builders.
        let buildx = ((try? await client.listContainers(all: false)) ?? [])
            .filter { $0.names?.contains { $0.hasPrefix(buildxNamePrefix) } == true }
            .filter { $0.command?.contains("buildkitd") == true }
            .map(\.id)
        return apple + buildx
    }
}

/// The Settings choice the runtime helper acts on. The helper is a separate process, so it reads
/// the app's preferences domain by name.
public enum BuilderIdleStop {
    public static let defaultsDomain = "app.bshk.containerstack"
    public static let minutesKey = "builderIdleStopMinutes"
    public static let defaultMinutes = 10
    /// 0 is Never.
    public static let choices = [0, 5, 10, 30, 60]

    /// nil means never stop. A value nobody saved is the default.
    public static func idleLimit(minutes: Int?) -> Duration? {
        let minutes = minutes ?? defaultMinutes
        return minutes > 0 ? .seconds(minutes * 60) : nil
    }

    public static func configuredIdleLimit(domain: String = defaultsDomain) -> Duration? {
        let value = CFPreferencesCopyAppValue(minutesKey as CFString, domain as CFString)
        return idleLimit(minutes: (value as? NSNumber)?.intValue)
    }
}

public enum ProcessExit {
    /// Returns when `pid` no longer exists, or when the task is cancelled. It polls, because the
    /// process need not be a child.
    public static func wait(for pid: pid_t, interval: Duration = .seconds(1)) async {
        while !Task.isCancelled, kill(pid, 0) == 0 || errno == EPERM {
            try? await Task.sleep(for: interval)
        }
    }
}
