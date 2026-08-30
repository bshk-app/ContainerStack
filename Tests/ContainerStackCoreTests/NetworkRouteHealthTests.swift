import Foundation
import Testing

@testable import ContainerStackCore

struct NetworkRouteHealthTests {
    private let routes = """
        Routing tables

        Internet:
        Destination        Gateway            Flags               Netif Expire
        default            192.168.1.1        UGScg                 en0
        127                127.0.0.1          UCS                   lo0
        192.168.64         link#24            UC                 bridge1
        192.168.253/24     link#25            UC                 bridge2
        """

    /// The measured state from issue #45: the host routes to the compose network only.
    private let routesWithoutDefault = """
        Routing tables

        Internet:
        Destination        Gateway            Flags               Netif Expire
        default            192.168.1.1        UGScg                 en0
        127                127.0.0.1          UCS                   lo0
        192.168.253/24     link#25            UC                 bridge2
        """

    @Test
    func acceptsSubnetWithAHostRoute() throws {
        #expect(NetworkRouteHealth.hasRoute(to: "192.168.64.0/24", in: routes))
        #expect(NetworkRouteHealth.hasRoute(to: "192.168.253.0/24", in: routes))
    }

    @Test
    func rejectsSubnetWithoutAHostRoute() throws {
        #expect(NetworkRouteHealth.hasRoute(to: "192.168.99.0/24", in: routes) == false)
    }

    @Test
    func emptyRoutingTableCannotBeJudged() {
        #expect(NetworkRouteHealth.canJudgeRoutes("") == false)
        #expect(NetworkRouteHealth.canJudgeRoutes("   \n") == false)
        #expect(NetworkRouteHealth.canJudgeRoutes(routes))
        #expect(
            NetworkRouteHealth.unroutableNetworks(
                [UnroutableNetwork(networkName: "default", subnet: "192.168.64.0/24")],
                routes: ""
            ).map(\.networkName) == ["default"],
            "callers must consult canJudgeRoutes before treating this as NO ROUTE"
        )
    }

    /// A network whose containers are all stopped has no host attachment yet; only networks with
    /// running containers are expected to be routable.
    @Test
    func reportsOnlyNetworksThatShouldBeReachable() throws {
        let unreachable = NetworkRouteHealth.unreachableSubnets(
            subnets: ["192.168.64.0/24", "192.168.99.0/24"],
            routes: routes
        )

        #expect(unreachable == ["192.168.99.0/24"])
    }

    private func container(
        id: String,
        state: String,
        ports: [[String: Any]]? = nil,
        networks: [String] = []
    ) throws -> DockerContainerSummary {
        let json: [String: Any] = [
            "Id": id,
            "Names": ["/\(id)"],
            "State": state,
            "Ports": ports as Any,
            "NetworkSettings": [
                "Networks": Dictionary(
                    uniqueKeysWithValues: networks.map { ($0, [String: String]()) }
                )
            ] as Any,
        ]
        let data = try JSONSerialization.data(withJSONObject: [json])
        return try JSONDecoder().decode([DockerContainerSummary].self, from: data)[0]
    }

    private func network(name: String, subnet: String?) throws -> DockerNetworkSummary {
        var json: [String: Any] = ["Id": "net-\(name)", "Name": name]
        if let subnet { json["Subnet"] = subnet }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(DockerNetworkSummary.self, from: data)
    }

    @Test
    func ignoresNetworksNoPublishingContainerUses() throws {
        // Issue #45: a compose stack publishes on its own network while the unused `default`
        // has no host route; the runtime must not be condemned for the idle network.
        let containers = [
            try container(
                id: "web",
                state: "running",
                ports: [["IP": "0.0.0.0", "PublicPort": 8080, "PrivatePort": 80, "Type": "tcp"]],
                networks: ["apps_default"]
            )
        ]
        let networks = [
            try network(name: "default", subnet: "192.168.64.0/24"),
            try network(name: "apps_default", subnet: "192.168.253.0/24"),
        ]

        let candidates = NetworkRouteHealth.publishingNetworks(containers: containers, networks: networks)
        let unroutable = NetworkRouteHealth.unroutableNetworks(candidates, routes: routesWithoutDefault)

        #expect(candidates.map(\.label) == ["apps_default (192.168.253.0/24)"])
        #expect(unroutable.isEmpty, "only the broken but unused default lacks a route here")
    }

    @Test
    func degradesWhenAPublishingContainerUsesTheBrokenNetwork() throws {
        let containers = [
            try container(
                id: "web",
                state: "running",
                ports: [["IP": "0.0.0.0", "PublicPort": 8080, "PrivatePort": 80, "Type": "tcp"]],
                networks: ["default"]
            )
        ]
        let networks = [
            try network(name: "default", subnet: "192.168.64.0/24"),
            try network(name: "apps_default", subnet: "192.168.99.0/24"),
        ]

        let unroutable = NetworkRouteHealth.unroutableNetworks(
            NetworkRouteHealth.publishingNetworks(containers: containers, networks: networks),
            routes: routesWithoutDefault
        )
        #expect(unroutable.map(\.label) == ["default (192.168.64.0/24)"])
    }

    @Test
    func stoppedOrUnpublishedContainersDoNotPutTheirNetworkInPlay() throws {
        let containers = [
            try container(
                id: "stopped", state: "exited", ports: [["PublicPort": 8080, "PrivatePort": 80]], networks: ["default"]),
            try container(id: "unpublished", state: "running", ports: [["PrivatePort": 80]], networks: ["default"]),
            try container(
                id: "zeroPort", state: "running", ports: [["PublicPort": 0, "PrivatePort": 80]], networks: ["default"]),
        ]
        let networks = [try network(name: "default", subnet: "192.168.64.0/24")]

        #expect(NetworkRouteHealth.publishingNetworks(containers: containers, networks: networks).isEmpty)
    }

    /// #45: an empty candidate set is not proof that nothing publishes. A network the runtime
    /// reports without a subnet is dropped silently, so doctor would call it "no publishers".
    @Test
    func treatsAnEmptySubnetAsUncheckableRatherThanUnroutable() throws {
        let containers = [
            try container(
                id: "web",
                state: "running",
                ports: [["PublicPort": 8080, "PrivatePort": 80]],
                networks: ["apps_default"]
            )
        ]
        let networks = [try network(name: "apps_default", subnet: "")]

        // Without this, the empty subnet becomes a candidate, `hasRoute(to: "")` fails, and doctor
        // reports NO ROUTE for a network it never actually checked.
        #expect(NetworkRouteHealth.publishingNetworks(containers: containers, networks: networks).isEmpty)
        #expect(
            NetworkRouteHealth.uncheckablePublishingNetworks(containers: containers, networks: networks)
                == ["apps_default"]
        )
    }

    @Test
    func namesAPublishingNetworkThatReportsNoSubnet() throws {
        let containers = [
            try container(
                id: "web",
                state: "running",
                ports: [["PublicPort": 8080, "PrivatePort": 80]],
                networks: ["apps_default"]
            )
        ]
        let networks = [try network(name: "apps_default", subnet: nil)]

        #expect(NetworkRouteHealth.publishingNetworks(containers: containers, networks: networks).isEmpty)
        #expect(
            NetworkRouteHealth.uncheckablePublishingNetworks(containers: containers, networks: networks)
                == ["apps_default"]
        )
    }

    /// The other way a candidate disappears: the container names a network the runtime did not
    /// list at all, so there is no record to read a subnet from.
    @Test
    func namesAPublishingNetworkTheRuntimeDidNotReport() throws {
        let containers = [
            try container(
                id: "web",
                state: "running",
                ports: [["PublicPort": 8080, "PrivatePort": 80]],
                networks: ["ghost"]
            )
        ]
        let networks = [try network(name: "default", subnet: "192.168.64.0/24")]

        #expect(
            NetworkRouteHealth.uncheckablePublishingNetworks(containers: containers, networks: networks)
                == ["ghost"]
        )
    }

    /// A network that resolves fully is not uncheckable, and neither is one nothing publishes on.
    @Test
    func aResolvableOrIdleNetworkIsNotUncheckable() throws {
        let publishing = [
            try container(
                id: "web",
                state: "running",
                ports: [["PublicPort": 8080, "PrivatePort": 80]],
                networks: ["apps_default"]
            )
        ]
        let idle = [try container(id: "quiet", state: "running", ports: [["PrivatePort": 80]], networks: ["default"])]
        let networks = [
            try network(name: "apps_default", subnet: "192.168.253.0/24"),
            try network(name: "default", subnet: nil),
        ]

        #expect(NetworkRouteHealth.uncheckablePublishingNetworks(containers: publishing, networks: networks).isEmpty)
        #expect(NetworkRouteHealth.uncheckablePublishingNetworks(containers: idle, networks: networks).isEmpty)
    }
}
