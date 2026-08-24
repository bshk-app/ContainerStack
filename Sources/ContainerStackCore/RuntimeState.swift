import Foundation

/// Single source of truth for runtime health: the Docker socket, not the helper process.
/// The helper exits as soon as it hands the socket to an already running bridge, so its
/// liveness says nothing about whether containers can be managed.
public enum RuntimeState: Equatable, Sendable {
    case unknown
    case starting
    case running
    /// The Docker API answers, but containers on these networks cannot be reached from the host.
    /// Published ports are dead in this state even though every API call succeeds.
    case degraded(networks: [UnroutableNetwork])
    /// The Docker API answers, but the runtime is storing into a directory that no longer exists.
    /// Nothing distinguishes this from a healthy runtime over the API — which is the whole problem.
    case detached(appRoot: String)
    case offline(String)

    public static let genericFailure = "Docker socket is not responding."

    public static func resolve(
        socketResponds: Bool,
        helperRunning: Bool,
        isStarting: Bool,
        failure: String?,
        unroutableNetworks: [UnroutableNetwork] = [],
        missingAppRoot: String? = nil
    ) -> RuntimeState {
        // Ahead of the socket branch, not inside it. In this state `/info` fails while `_ping`
        // succeeds — measured: `cstack doctor` died on health with "Failed to generate system
        // information" while the same socket answered a ping. The app's full refresh leads with
        // health, so leaving this inside the responding branch had the refresh resolve
        // `.offline("Docker socket is not responding.")` — a plain untruth — while the poll resolved
        // `.detached` off the ping, and the banner alternated between them.
        //
        // Safe outside the branch because `RuntimeStatusParser.missingAppRoot` already requires the
        // apiserver to report itself running: a stopped runtime yields nil and falls through.
        if let missingAppRoot { return .detached(appRoot: missingAppRoot) }
        if socketResponds {
            return unroutableNetworks.isEmpty ? .running : .degraded(networks: unroutableNetworks)
        }
        if isStarting || helperRunning {
            return .starting
        }
        return .offline(failure ?? genericFailure)
    }

    /// True whenever the Docker API is usable, so container actions stay enabled while degraded.
    public var isHealthy: Bool {
        switch self {
        case .running, .degraded, .detached: true
        case .unknown, .starting, .offline: false
        }
    }

    public var isDegraded: Bool {
        switch self {
        case .degraded, .detached: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .unknown: "Runtime status unknown"
        case .starting: "Starting runtime…"
        case .running: "Runtime ready"
        case .degraded: "Runtime degraded"
        case .detached: "Runtime storage is missing"
        case .offline: "Runtime unavailable"
        }
    }

    public var detail: String? {
        switch self {
        case .unknown: nil
        case .starting: "Waiting for the Docker socket to accept connections."
        case .running: nil
        case let .degraded(networks):
            // Two things a person cannot see for themselves. What they will observe is not a port
            // that refuses: the forwarder accepts the connection and nothing answers, which reads
            // as a hung application. And restarting the containers does not fix it — measured on a
            // scratch runtime across four arms: with the network's helper dead, a container restart
            // recovered a network Apple's CLI had created and left one created here stopped after
            // 243s, while restarting the runtime recovered it in 17s and kept the same addresses.
            // This bridge pins a subnet on every network it creates, so the case that fails is the
            // only one users have.
            "No route to \(networks.map(\.label).joined(separator: ", ")). "
                + "Published ports still accept connections and then hang; "
                + "restarting the containers will not fix it — restart the runtime."
        case let .detached(appRoot):
            // The runtime keeps answering with its root deleted — measured: `_ping` returns 200 and
            // `container system status` still reports the path that is gone, so every check the app
            // had said "running". A person who used a temporary root to reproduce something lands
            // here, and the obvious remedy looks like it should not be needed. It is one step: the
            // restart moves the runtime back to the default location, measured twice in
            // `scripts/verify-stage0-remedies.sh erased-root` — while the daemon is well enough to be
            // stopped, which is the caveat `RuntimeStatusParser.missingAppRoot` spells out.
            "The runtime is storing into \(appRoot), which no longer exists. "
                + "Images, volumes and containers kept there cannot be found. "
                + "Restart the runtime to move it back to the default location."
        case let .offline(reason): reason
        }
    }

    public var symbol: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .starting: "arrow.triangle.2.circlepath"
        case .running: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .detached: "externaldrive.badge.questionmark"
        case .offline: "exclamationmark.triangle.fill"
        }
    }
}

public enum RuntimeStartupDecision: Equatable, Sendable {
    case bridgeAlreadyRunning
    /// Something answers on the socket and it is not the bridge this bundle
    /// ships. Measured consequence of adopting one anyway: a bridge from an
    /// unrelated build served every request while `start` never returned and a
    /// container stayed `Created` past 150s, with the app reporting a healthy
    /// engine because `_ping`, `/version` and `/info` all answered.
    case foreignBridge
    case removeStaleSocket
    case startBridge
}

public enum RuntimeStartupPlanner {
    public static func decide(
        socketFileExists: Bool,
        bridgeResponds: Bool,
        bridgeIsOurs: Bool
    ) -> RuntimeStartupDecision {
        if bridgeResponds {
            return bridgeIsOurs ? .bridgeAlreadyRunning : .foreignBridge
        }
        return socketFileExists ? .removeStaleSocket : .startBridge
    }
}
