import Foundation
import Testing

@testable import ContainerStackCore

/// NFR-001: this is the one check whose cost grows with the container count, which is why
/// F-002 keeps it out of the UI set. The first test here is the one that guards that.
@Suite("Memory commitment is measured for the CLI and never paid for by the UI")
struct DiagnosticRunnerMemoryTests {
    private let hostBytes: Int64 = 16_000_000_000

    private func containerList(_ ids: [String]) -> String {
        let items = ids.map { #"{"Id":"\#($0)","Names":["/\#($0)"],"State":"running"}"# }
        return "[\(items.joined(separator: ","))]"
    }

    private func inspectResponse(id: String, memory: Int64?) -> Data {
        let hostConfig = memory.map { #"{"Memory":\#($0)}"# } ?? "{}"
        return jsonResponse(#"{"Id":"\#(id)","Name":"/\#(id)","State":{"Running":true},"HostConfig":\#(hostConfig)}"#)
    }

    /// Answers every call the other checks make, so a verdict here turns on memory alone.
    /// The containers publish no ports, which keeps the routes check `.ok`.
    private func runtime(
        containers: [String],
        inspects: [String: Result<Data, any Error>] = [:],
        containerListing: Result<Data, any Error>? = nil
    ) -> StubDockerTransport {
        var byPath: [String: Result<Data, any Error>] = [
            "/_ping": .success(jsonResponse("OK")),
            "/version": .success(jsonResponse(#"{"Version":"1.7.0","ApiVersion":"1.43"}"#)),
            "/info": .success(jsonResponse(#"{"Containers":\#(containers.count),"Images":0}"#)),
            "/containers/json": containerListing ?? .success(jsonResponse(containerList(containers))),
            "/networks": .success(jsonResponse("[]")),
        ]
        for (id, result) in inspects {
            byPath["/containers/\(id)/json"] = result
        }
        return StubDockerTransport(byPath: byPath)
    }

    /// One limit per container, all equal, so the total is the only thing a case varies.
    private func transport(limits: [Int64?]) -> StubDockerTransport {
        let ids = limits.indices.map { "c\($0)" }
        var inspects: [String: Result<Data, any Error>] = [:]
        for (index, id) in ids.enumerated() {
            inspects[id] = .success(inspectResponse(id: id, memory: limits[index]))
        }
        return runtime(containers: ids, inspects: inspects)
    }

    private func memoryCheck(
        limits: [Int64?],
        hostMemoryBytes: Int64? = 16_000_000_000
    ) async -> DiagnosticCheck? {
        await makeRunner(transport: transport(limits: limits), hostMemoryBytes: hostMemoryBytes)
            .run(checks: CheckID.cliSet)
            .check(.memoryCommitment)
    }

    private func inspectPaths(of transport: StubDockerTransport) async -> [String] {
        await transport.paths.filter { $0.hasPrefix("/containers/c") }
    }

    // The pin for F-002/NFR-001. Asserted as a difference, not an absolute: a UI count that
    // is flat because the fixture has no containers would pass a bare `== 0`.
    @Test("the CLI inspects one container per running container and the UI inspects none")
    func onlyTheCLISetPaysForAnInspectPerContainer() async {
        let emptyForCLI = runtime(containers: [])
        let manyForCLI = transport(limits: [1_000_000_000, 1_000_000_000, 1_000_000_000])
        let emptyForUI = runtime(containers: [])
        let manyForUI = transport(limits: [1_000_000_000, 1_000_000_000, 1_000_000_000])

        _ = await makeRunner(transport: emptyForCLI, hostMemoryBytes: hostBytes).run(checks: CheckID.cliSet)
        _ = await makeRunner(transport: manyForCLI, hostMemoryBytes: hostBytes).run(checks: CheckID.cliSet)
        _ = await makeRunner(transport: emptyForUI, hostMemoryBytes: hostBytes).run(checks: CheckID.uiSet)
        _ = await makeRunner(transport: manyForUI, hostMemoryBytes: hostBytes).run(checks: CheckID.uiSet)

        let cliWithNone = await inspectPaths(of: emptyForCLI).count
        let cliWithThree = await inspectPaths(of: manyForCLI).count
        let uiWithNone = await inspectPaths(of: emptyForUI).count
        let uiWithThree = await inspectPaths(of: manyForUI).count
        #expect(cliWithNone == 0)
        #expect(cliWithThree == 3)
        #expect(cliWithNone != cliWithThree)
        #expect(uiWithNone == 0)
        #expect(uiWithThree == 0)
        #expect(uiWithNone == uiWithThree)
    }

    // F-003: the bytes `cstack doctor` prints today (`CStackCommands.swift:117`, `:120`).
    @Test("limits comfortably inside host memory are a passing check")
    func limitsWithinHostMemoryPass() async {
        let check = await memoryCheck(limits: [4_000_000_000])
        #expect(check?.verdict == .ok)
        #expect(check?.summary == "Container memory limits: 4.0 GB in explicit container limits vs 16.0 GB host memory")
        #expect(check?.detail == nil)
        #expect(check?.remedy == nil)
    }

    // F-003: `CStackCommands.swift:123`.
    @Test("limits approaching host memory are amber with the CLI's own sentence")
    func limitsApproachingHostMemoryWarn() async {
        let check = await memoryCheck(limits: [10_000_000_000])
        #expect(check?.verdict == .warning)
        #expect(
            check?.summary == "Container memory limits: 10.0 GB in explicit container limits vs 16.0 GB host memory"
                + " — guests approaching their limits may pressure other applications"
        )
        #expect(check?.remedy == nil)
    }

    // Decision 5 in `spec-gaps.md`: over-commitment is a risk, not a broken system, so it is
    // amber with a repair only a person can perform.
    // F-003: `CStackCommands.swift:126-128`.
    @Test("limits exceeding host memory are amber with a manual remedy, never red")
    func limitsExceedingHostMemoryWarnWithAManualRemedy() async {
        let check = await memoryCheck(limits: [14_000_000_000])
        #expect(check?.verdict == .warning)
        #expect(check?.verdict != .failure)
        #expect(
            check?.summary
                == "Container memory limits: HIGH — 14.0 GB in explicit container limits vs 16.0 GB host memory"
        )
        #expect(
            check?.detail
                == """
                Guests do not reserve every byte immediately, but host use can grow toward these limits.
                Stop a container or recreate it with a smaller --memory.
                """
        )
        #expect(check?.remedy == .manual("Stop a container or recreate it with a smaller --memory."))
        #expect(check?.remedy != .restartRuntime)
    }

    // Decision 6: an unread `hw.memsize` is a measurement failure, not a healthy machine.
    // F-003: `CStackCommands.swift:132`.
    @Test("host memory nobody could read leaves the check unknown, not passing")
    func unknownHostMemoryIsIndeterminate() async {
        let check = await memoryCheck(limits: [4_000_000_000], hostMemoryBytes: nil)
        #expect(check?.verdict == .indeterminate)
        #expect(check?.verdict != .ok)
        #expect(check?.summary == "Container memory limits: 4.0 GB configured (host memory unknown)")
        #expect(check?.remedy == nil)
    }

    // Decision 6 again, on the other input. F-003: `CStackCommands.swift:107`.
    @Test("a container nobody could inspect leaves the check unknown, not passing")
    func aFailedInspectIsIndeterminate() async {
        let transport = runtime(
            containers: ["c0"],
            inspects: ["c0": .failure(UnixSocketError.timedOut)]
        )
        let check = await makeRunner(transport: transport, hostMemoryBytes: hostBytes)
            .run(checks: CheckID.cliSet)
            .check(.memoryCommitment)
        #expect(check?.verdict == .indeterminate)
        #expect(check?.verdict != .ok)
        #expect(
            check?.summary == "Container memory limits: unavailable — 1 running container(s) could not be inspected."
        )
        #expect(check?.remedy == nil)
    }

    // A total that is missing a container is not a total, however healthy the part we read
    // looks. F-003: `CStackCommands.swift:143`.
    @Test("one failed inspect among several leaves the whole check unknown and says so")
    func aPartiallyFailedInspectIsIndeterminateAndNamesTheGap() async {
        let transport = runtime(
            containers: ["c0", "c1"],
            inspects: [
                "c0": .success(inspectResponse(id: "c0", memory: 1_000_000_000)),
                "c1": .failure(UnixSocketError.timedOut),
            ]
        )
        let check = await makeRunner(transport: transport, hostMemoryBytes: hostBytes)
            .run(checks: CheckID.cliSet)
            .check(.memoryCommitment)
        #expect(check?.verdict == .indeterminate)
        #expect(check?.verdict != .ok)
        #expect(check?.summary == "Container memory limits: 1.0 GB in explicit container limits vs 16.0 GB host memory")
        #expect(
            check?.detail
                == "1 running container(s) could not be inspected, so the total is incomplete."
        )
    }

    // F-003: `CStackCommands.swift:138`. An unlimited container is an unknown, not a zero.
    @Test("a container with no explicit limit is named as excluded from the total")
    func containersWithoutALimitAreNamed() async {
        let check = await memoryCheck(limits: [4_000_000_000, nil])
        #expect(check?.verdict == .ok)
        #expect(check?.summary == "Container memory limits: 4.0 GB in explicit container limits vs 16.0 GB host memory")
        #expect(
            check?.detail
                == "1 running container(s) have no explicit memory limit and are excluded from that total."
        )
    }

    // Today's CLI returns at `CStackCommands.swift:46` before it reaches the memory report, so
    // there is no line to reproduce and nothing was measured.
    @Test("a runtime with nothing running spends no inspect and claims no verdict")
    func nothingRunningIsSkippedRatherThanPassed() async {
        let transport = runtime(containers: [])
        let check = await makeRunner(transport: transport, hostMemoryBytes: hostBytes)
            .run(checks: CheckID.cliSet)
            .check(.memoryCommitment)
        #expect(check?.verdict == .skipped)
        #expect(check?.verdict != .ok)
        #expect(check?.remedy == nil)
        #expect(await inspectPaths(of: transport).isEmpty)
    }

    // The container listing is the memory check's other input, and a listing that never
    // arrived is not an empty machine (F-009).
    @Test("a container listing that failed leaves the check unknown, not empty")
    func aFailedContainerListingIsIndeterminate() async {
        let transport = runtime(containers: [], containerListing: .failure(UnixSocketError.timedOut))
        let check = await makeRunner(transport: transport, hostMemoryBytes: hostBytes)
            .run(checks: CheckID.cliSet)
            .check(.memoryCommitment)
        #expect(check?.verdict == .indeterminate)
        #expect(check?.verdict != .skipped)
        #expect(check?.detail?.isEmpty == false)
    }

    // NFR-001: the memory check does not re-list the containers the routes check already read.
    @Test("the CLI set lists containers once however many checks want them")
    func theContainerListingIsPaidForOnce() async {
        let transport = transport(limits: [4_000_000_000])
        _ = await makeRunner(transport: transport, hostMemoryBytes: hostBytes).run(checks: CheckID.cliSet)
        #expect(await transport.paths.filter { $0 == "/containers/json" }.count == 1)
    }

    // F-013, and the first check able to reach `.warning`: until now the rank sat in a unit
    // table with nothing in a produced report to exercise it.
    @Test("a memory warning outranks the ok and skipped checks around it")
    func aMemoryWarningDecidesTheReportsAggregate() async {
        let warned = await makeRunner(
            transport: transport(limits: [10_000_000_000]),
            hostMemoryBytes: hostBytes
        ).run(checks: CheckID.cliSet)
        let healthy = await makeRunner(
            transport: transport(limits: [4_000_000_000]),
            hostMemoryBytes: hostBytes
        ).run(checks: CheckID.cliSet)
        #expect(healthy.verdict == .ok)
        #expect(warned.verdict == .warning)
        #expect(warned.verdict != healthy.verdict)
    }
}
