import Foundation

/// A container network the host cannot route to. Carries the network name because users act on
/// networks ("the compose network"), not on raw subnets.
public struct UnroutableNetwork: Equatable, Sendable {
    public let networkName: String
    public let subnet: String

    public init(networkName: String, subnet: String) {
        self.networkName = networkName
        self.subnet = subnet
    }

    /// "default (192.168.64.0/24)" — names the network and the unreachable subnet in one label.
    public var label: String {
        "\(networkName) (\(subnet))"
    }
}

/// A healthy Docker socket says nothing about reachability: Apple Container can report a running
/// runtime while its vmnet attachment is gone, and then every published port silently fails.
/// The host routing table is the ground truth for "can this machine reach that subnet".
public enum NetworkRouteHealth {
    public static func hasRoute(to subnet: String, in routes: String) -> Bool {
        guard let prefix = routePrefix(for: subnet) else { return false }

        return
            routes
            .split(whereSeparator: \.isNewline)
            .contains { line in
                guard
                    let destination =
                        line
                        .trimmingCharacters(in: .whitespaces)
                        .split(separator: " ", omittingEmptySubsequences: true)
                        .first
                else { return false }

                // netstat prints 192.168.64.0/24 as "192.168.64" or "192.168.64/24".
                let normalized = destination.split(separator: "/").first.map(String.init) ?? String(destination)
                return normalized == prefix
            }
    }

    public static func unreachableSubnets(subnets: [String], routes: String) -> [String] {
        subnets.filter { !hasRoute(to: $0, in: routes) }
    }

    /// Networks that carry at least one running container publishing ports — the only networks
    /// whose reachability affects users. A network nothing publishes on (typically a wedged
    /// unused `default`) is invisible here, so it cannot condemn an otherwise healthy runtime.
    public static func publishingNetworks(
        containers: [DockerContainerSummary],
        networks: [DockerNetworkSummary]
    ) -> [UnroutableNetwork] {
        let inUse = Set(
            containers
                .filter { $0.isRunning && $0.publishesPorts }
                .flatMap(\.networkNames)
        )
        guard !inUse.isEmpty else { return [] }

        return networks.compactMap { network in
            guard inUse.contains(network.name) else { return nil }
            // An empty subnet is as uncheckable as a missing one: `hasRoute(to: "")` matches nothing
            // and would report a route failure the runtime never had.
            guard let subnet = network.subnet, !subnet.isEmpty else { return nil }
            return UnroutableNetwork(networkName: network.name, subnet: subnet)
        }
    }

    /// Networks a running publisher sits on that cannot be route-checked: either the runtime listed
    /// no record for them, or the record carries no subnet. `publishingNetworks` drops both silently,
    /// so without this an empty candidate set reads as "nothing publishes" when it may mean "nothing
    /// could be determined" (#45).
    public static func uncheckablePublishingNetworks(
        containers: [DockerContainerSummary],
        networks: [DockerNetworkSummary]
    ) -> [String] {
        let inUse = Set(
            containers
                .filter { $0.isRunning && $0.publishesPorts }
                .flatMap(\.networkNames)
        )
        guard !inUse.isEmpty else { return [] }

        let checkable = Set(publishingNetworks(containers: containers, networks: networks).map(\.networkName))
        return inUse.subtracting(checkable).sorted()
    }

    public static func unroutableNetworks(_ networks: [UnroutableNetwork], routes: String) -> [UnroutableNetwork] {
        networks.filter { !hasRoute(to: $0.subnet, in: routes) }
    }

    /// `192.168.64.0/24` -> `192.168.64`, matching how netstat truncates trailing zero octets.
    private static func routePrefix(for subnet: String) -> String? {
        let address = subnet.split(separator: "/").first.map(String.init) ?? subnet
        guard !address.isEmpty else { return nil }

        var octets = address.split(separator: ".").map(String.init)
        guard octets.count == 4 else { return nil }

        while octets.count > 1, octets.last == "0" {
            octets.removeLast()
        }
        return octets.joined(separator: ".")
    }
}

/// A network removal that produces no answer at all.
///
/// The bridge bounds a wedged removal at 60s and replies with the remedy — measured live: the socket
/// answered at 63s with `restart the runtime, then remove the network again`. But the app should not
/// depend on that answer arriving to know what silence means here: a removal is the one operation that
/// stops answering once the network's vmnet helper has died, and nothing but a runtime restart clears
/// it (measured, `scripts/verify-stage0-remedies.sh pending`).
public struct NetworkRemovalWedged: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public let network: String

    public init(network: String) {
        self.network = network
    }

    public var description: String {
        "cannot remove network \(network): the runtime stopped answering. This follows the death of "
            + "the network's helper process and does not clear on its own — restart the runtime, then "
            + "remove the network again."
    }

    public var errorDescription: String? { description }
}
