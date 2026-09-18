import Foundation
import Testing

@testable import ContainerStackCore

/// Issue #45: "nothing publishes", "could not tell" and "genuinely unroutable" are three
/// answers, and merging any two of them is the defect this suite exists to keep out.
@Suite("The routes check keeps its three outcomes apart")
struct DiagnosticRunnerRoutesTests {
    private let publishingContainers = """
        [{"Id":"c1","Names":["/web"],"State":"running",
          "Ports":[{"PrivatePort":80,"PublicPort":8080,"Type":"tcp"}],
          "NetworkSettings":{"Networks":{"compose_default":{}}}}]
        """
    private let idleContainers = """
        [{"Id":"c1","Names":["/web"],"State":"running",
          "Ports":[{"PrivatePort":80,"Type":"tcp"}],
          "NetworkSettings":{"Networks":{"compose_default":{}}}}]
        """
    private let networksWithSubnet = """
        [{"Id":"n1","Name":"compose_default","Driver":"bridge",
          "IPAM":{"Config":[{"Subnet":"192.168.64.0/24"}]}}]
        """
    private let networksWithoutSubnet = #"[{"Id":"n1","Name":"compose_default","Driver":"bridge"}]"#
    private let unroutableLabel = "compose_default (192.168.64.0/24)"

    private let routedTable = """
        Internet:
        Destination        Gateway            Flags        Netif
        default            192.168.1.1        UGScg          en0
        192.168.64         link#18            UC       bridge100
        """
    private let tableWithoutTheBridge = """
        Internet:
        Destination        Gateway            Flags        Netif
        default            192.168.1.1        UGScg          en0
        """

    private func runtime(
        containers: String,
        networks: Result<Data, any Error>
    ) -> StubDockerTransport {
        StubDockerTransport(byPath: [
            "/_ping": .success(jsonResponse("OK")),
            "/version": .success(jsonResponse(#"{"Version":"1.7.0","ApiVersion":"1.43"}"#)),
            "/info": .success(jsonResponse(#"{"Containers":1,"Images":1}"#)),
            "/containers/json": .success(jsonResponse(containers)),
            "/networks": networks,
        ])
    }

    private func routes(
        table: ProbeResult,
        containers: String,
        networks: Result<Data, any Error>
    ) async -> DiagnosticCheck? {
        await makeRunner(
            routingTable: table,
            transport: runtime(containers: containers, networks: networks)
        ).run(checks: CheckID.uiSet).check(.routes)
    }

    // The pin. Three inputs, three verdicts, asserted as a set so collapsing any pair fails
    // here rather than in whichever fixture happened to cover the survivor.
    @Test("no publisher, cannot judge and unroutable are three verdicts, not two")
    func theThreeRouteOutcomesNeverCollapse() async {
        let nothingToCheck = await routes(
            table: .output(routedTable),
            containers: idleContainers,
            networks: .success(jsonResponse(networksWithSubnet))
        )
        let cannotJudge = await routes(
            table: .output(""),
            containers: publishingContainers,
            networks: .success(jsonResponse(networksWithSubnet))
        )
        let unroutable = await routes(
            table: .output(tableWithoutTheBridge),
            containers: publishingContainers,
            networks: .success(jsonResponse(networksWithSubnet))
        )
        #expect(nothingToCheck?.verdict == .ok)
        #expect(cannotJudge?.verdict == .indeterminate)
        #expect(unroutable?.verdict == .failure)
        #expect(Set([nothingToCheck?.verdict, cannotJudge?.verdict, unroutable?.verdict]).count == 3)
    }

    // F-009 again, on netstat: an empty table from a dead probe is "could not ask", and reading
    // it as "no routes needed" is the laundering `missingAppRoot("")` already performed once.
    @Test("a netstat that could not run is amber, never a clean bill of health")
    func aFailedRoutingProbeLeavesTheRoutesCheckIndeterminate() async {
        let check = await routes(
            table: .failed(reason: "/usr/sbin/netstat could not be run: ENOENT"),
            containers: publishingContainers,
            networks: .success(jsonResponse(networksWithSubnet))
        )
        #expect(check?.verdict == .indeterminate)
        #expect(check?.verdict != .ok)
        #expect(check?.verdict != .skipped)
        #expect(check?.detail?.contains("ENOENT") == true)
        #expect(check?.remedy == nil)
    }

    @Test("an empty routing table is a table nobody read, not a host with no routes")
    func anEmptyRoutingTableIsNotAJudgement() async {
        let check = await routes(
            table: .output("   \n  "),
            containers: publishingContainers,
            networks: .success(jsonResponse(networksWithSubnet))
        )
        #expect(check?.verdict == .indeterminate)
        #expect(check?.remedy == nil)
    }

    // The second way this check fails to measure: the networks it would have judged never arrived.
    @Test("a network listing that failed is amber, not an empty list of networks")
    func aFailedNetworkListingLeavesTheRoutesCheckIndeterminate() async {
        let transport = runtime(containers: publishingContainers, networks: .failure(UnixSocketError.timedOut))
        let check = await makeRunner(routingTable: .output(routedTable), transport: transport)
            .run(checks: CheckID.uiSet).check(.routes)
        #expect(check?.verdict == .indeterminate)
        #expect(check?.verdict != .ok)
        #expect(check?.detail?.isEmpty == false)
        // NFR-002: `failsImmediately` excludes `.timedOut`, so this wait is paid once, not three times.
        #expect(await transport.paths.filter { $0 == "/networks" }.count == 1)
    }

    // T-008: the runner hands `resolve` the unroutable networks and projects what it decided,
    // so the expected state is computed here rather than restated.
    @Test("an unroutable publishing network is the failure resolve names")
    func anUnroutableNetworkIsProjectedFromResolve() async {
        let report = await makeRunner(
            routingTable: .output(tableWithoutTheBridge),
            transport: runtime(containers: publishingContainers, networks: .success(jsonResponse(networksWithSubnet)))
        ).run(checks: CheckID.uiSet)
        let state = RuntimeState.resolve(
            socketResponds: true,
            helperRunning: false,
            isStarting: false,
            failure: nil,
            unroutableNetworks: [UnroutableNetwork(networkName: "compose_default", subnet: "192.168.64.0/24")]
        )
        #expect(state.isDegraded)
        #expect(report.check(.routes)?.verdict == .failure)
        #expect(report.check(.routes)?.remedy == .restartRuntime)
        #expect(report.checks.filter { $0.verdict == .failure }.map(\.id) == [.routes])
        #expect(report.check(.socket)?.verdict == .ok)
    }

    // F-003 forbids drift: these are the bytes `cstack doctor` prints today
    // (`CStackCommands.swift:45`, `:56`, `:63`, `:67`, `:69`, `:74-75`).
    @Test("every routes verdict reproduces today's CLI wording verbatim")
    func theRoutesCheckCarriesTheCLIsOwnWording() async {
        let reachable = await routes(
            table: .output(routedTable),
            containers: publishingContainers,
            networks: .success(jsonResponse(networksWithSubnet))
        )
        #expect(reachable?.verdict == .ok)
        #expect(reachable?.summary == "Container routes: reachable (\(unroutableLabel))")

        let unroutable = await routes(
            table: .output(tableWithoutTheBridge),
            containers: publishingContainers,
            networks: .success(jsonResponse(networksWithSubnet))
        )
        #expect(unroutable?.summary == "Container routes: NO ROUTE to \(unroutableLabel)")
        #expect(
            unroutable?.detail
                == """
                Published ports accept connections and then hang.
                Restarting the containers does not fix it. Run: cstack runtime restart
                """
        )

        let unreadable = await routes(
            table: .output(""),
            containers: publishingContainers,
            networks: .success(jsonResponse(networksWithSubnet))
        )
        #expect(unreadable?.summary == "Container routes: could not read the routing table")

        let idle = await routes(
            table: .output(routedTable),
            containers: idleContainers,
            networks: .success(jsonResponse(networksWithSubnet))
        )
        #expect(idle?.summary == "Container routes: no running container publishes ports")

        let stopped = await routes(
            table: .output(routedTable),
            containers: "[]",
            networks: .success(jsonResponse(networksWithSubnet))
        )
        #expect(stopped?.verdict == .ok)
        #expect(stopped?.summary == "Container routes: no running containers to check")
    }

    // `publishingNetworks` drops a subnet-less network silently, so without
    // `uncheckablePublishingNetworks` this reads as "nothing publishes" (#45).
    @Test("a publisher whose network reported no subnet is amber, and names it")
    func aPublisherWithoutASubnetCannotBeJudged() async {
        let check = await routes(
            table: .output(routedTable),
            containers: publishingContainers,
            networks: .success(jsonResponse(networksWithoutSubnet))
        )
        #expect(check?.verdict == .indeterminate)
        #expect(check?.summary == "Container routes: cannot check compose_default \u{2014} no subnet reported")
        #expect(check?.remedy == nil)
    }

    // NFR-002: the routes check is two Docker calls, and neither is paid three times.
    @Test("the routes check asks for containers and networks once each")
    func theRoutesCheckAsksEachEndpointOnce() async {
        let transport = runtime(containers: publishingContainers, networks: .success(jsonResponse(networksWithSubnet)))
        _ = await makeRunner(routingTable: .output(routedTable), transport: transport).run(checks: [.routes])
        #expect(await transport.paths.filter { $0 == "/containers/json" }.count == 1)
        #expect(await transport.paths.filter { $0 == "/networks" }.count == 1)
    }

    // A runtime that is not there decides for the routes check too, and spends no Docker call
    // proving it.
    @Test("an unreachable socket leaves the routes check grey and unasked")
    func anUnreachableSocketDoesNotSpendARouteCall() async {
        let transport = StubDockerTransport(byPath: [:])
        let report = await makeRunner(routingTable: .output(routedTable), transport: transport)
            .run(checks: CheckID.uiSet)
        #expect(report.check(.routes)?.verdict == .skipped)
        #expect(await transport.paths == ["/_ping"])
    }
}
