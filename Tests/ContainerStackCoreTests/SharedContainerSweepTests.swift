import Foundation
import Synchronization
import Testing

@testable import ContainerStackCore

struct SharedContainerSweepTests {
    private func summary(_ id: String, socket: String?, shared: Bool = true, running: Bool = true) throws
        -> DockerContainerSummary
    {
        var labels: [String: String] = [:]
        if let socket { labels["containerstack.shared.socket"] = socket }
        labels[shared ? "containerstack.shared.group" : "containerstack.session.group"] = "mcp"
        return try JSONDecoder().decode(
            DockerContainerSummary.self,
            from: JSONSerialization.data(withJSONObject: [
                "Id": id, "State": running ? "running" : "exited", "Labels": labels,
            ]))
    }

    @Test func leftoversMatchOnlyOurSocketWithoutTheFlag() throws {
        let ours = try summary("ours", socket: "/ours")
        let stopped = try summary("stopped", socket: "/ours", running: false)
        let other = try summary("other", socket: "/other")
        let session = try summary("session", socket: nil, shared: false)
        let labelOnly = try JSONDecoder().decode(
            DockerContainerSummary.self,
            from: Data(
                #"{"Id":"label-only","Labels":{"containerstack.shared.socket":"/ours"}}"#.utf8))
        let containers = [ours, other, stopped, session, labelOnly]

        #expect(
            SharedContainerSweep.leftovers(in: containers, socketPath: "/ours", status: .notRunning) == [
                ours, stopped, labelOnly,
            ])
        for status in [SharedRuntimesStatus.on, .starting, .off(cause: "bad file")] {
            #expect(SharedContainerSweep.leftovers(in: containers, socketPath: "/ours", status: status).isEmpty)
        }
    }

    @Test func aFailedDeleteDoesNotStopTheNextOne() async throws {
        let containers = [try summary("first", socket: "/ours"), try summary("next", socket: "/ours", running: false)]
        let transport = StubDockerTransport(byPath: [
            "/_ping": .success(jsonResponse("OK")),
            "/info": .success(jsonResponse("{}")),
            "/containers/json?all=1": .success(httpResponse(status: 200, body: try JSONEncoder().encode(containers))),
            "/containers/first?force=1": .failure(DockerAPIError.httpStatus(500, message: "failed")),
            "/containers/next?force=1": .success(jsonResponse("")),
        ])
        let lines = Mutex<[String]>([])
        await SharedContainerSweep.waitAndRun(
            client: DockerAPIClient(transport: transport), socketPath: "/ours",
            log: { line in lines.withLock { $0.append(line) } })
        let messages = lines.withLock { $0 }
        #expect(messages.count == 2)
        #expect(messages.first?.contains("Could not remove shared container first") == true)
        #expect(messages.last == "Removed shared container next left by an earlier bridge.")
        #expect(
            await transport.paths == [
                "/_ping", "/info", "/containers/json?all=1", "/containers/first?force=1", "/containers/next?force=1",
            ])
    }

    @Test func anUnreadableInfoNeverMeansTheFlagIsOff() async {
        for response in [Result<Data, any Error>.failure(UnixSocketError.timedOut), .success(jsonResponse("not JSON"))]
        {
            let transport = StubDockerTransport(byPath: ["/info": response])
            await SharedContainerSweep.run(
                client: DockerAPIClient(transport: transport), socketPath: "/ours", log: { _ in })
            #expect(await transport.paths == ["/info"])
        }
        let transport = StubDockerTransport(byPath: [
            "/info": .success(jsonResponse(#"{"Labels":["containerstack.shared-runtimes=on"]}"#))
        ])
        await SharedContainerSweep.run(
            client: DockerAPIClient(transport: transport), socketPath: "/ours", log: { _ in })
        #expect(await transport.paths == ["/info"])
    }

    @Test func anExpiredWaitSendsNoRequest() async {
        let transport = StubDockerTransport(responses: [])
        await SharedContainerSweep.waitAndRun(
            client: DockerAPIClient(transport: transport), socketPath: "/ours", timeout: .zero, log: { _ in })
        #expect(await transport.paths.isEmpty)
    }
}

extension SharedContainerSweepTests {
    @Test func cancellationAdmitsNoMoreDeletes() async throws {
        let containers = [try summary("first", socket: "/ours"), try summary("next", socket: "/ours")]
        let base = StubDockerTransport(byPath: [
            "/info": .success(jsonResponse("{}")),
            "/containers/json?all=1": .success(httpResponse(status: 200, body: try JSONEncoder().encode(containers))),
            "/containers/first?force=1": .success(jsonResponse("")),
        ])
        let task = Task {
            await SharedContainerSweep.run(
                client: DockerAPIClient(transport: CancellingSweepTransport(base: base)), socketPath: "/ours",
                log: { _ in })
        }
        await task.value
        #expect(await base.paths == ["/info", "/containers/json?all=1", "/containers/first?force=1"])
    }
}

private struct CancellingSweepTransport: DockerAPITransport {
    let base: StubDockerTransport
    func send(request: Data) async throws -> Data {
        let response = try await base.send(request: request)
        if String(decoding: request, as: UTF8.self).hasPrefix("DELETE ") {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return response
    }
}
