import Foundation
import Testing
@testable import ContainerStackCore

struct DockerAPIClientTests {
    @Test
    func healthReadsDockerPingVersionAndInfo() async throws {
        let transport = StubDockerTransport(responses: [
            httpResponse(status: 200, body: Data("OK".utf8)),
            httpResponse(
                status: 200,
                body: Data("{\"Version\":\"28.5.2\",\"ApiVersion\":\"1.51\",\"MinAPIVersion\":\"1.32\",\"GitCommit\":\"abc123\",\"Os\":\"linux\",\"Arch\":\"arm64\"}".utf8)
            ),
            httpResponse(
                status: 200,
                body: Data("{\"ServerVersion\":\"28.5.2\",\"OperatingSystem\":\"Apple Container\",\"Architecture\":\"arm64\",\"Containers\":1,\"Images\":2}".utf8)
            )
        ])
        let client = DockerAPIClient(transport: transport)

        let health = try await client.health()

        #expect(health.pingOK)
        #expect(health.version.apiVersion == "1.51")
        #expect(health.info.containers == 1)
        #expect(await transport.paths == ["/_ping", "/version", "/info"])
    }

    @Test
    func healthSurfacesDockerHTTPFailures() async {
        let transport = StubDockerTransport(responses: [
            httpResponse(status: 500, body: Data("unavailable".utf8))
        ])
        let client = DockerAPIClient(transport: transport)

        do {
            _ = try await client.health()
            Issue.record("Expected Docker API failure")
        } catch let error as DockerAPIError {
            // The body travels with the status: a bare code leaves the caller inventing a reason.
            #expect(error == .httpStatus(500, message: "unavailable"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func retriesTransientHealthRequestBeforeSuccess() async throws {
        let transport = FlakyDockerTransport(
            failuresBeforeSuccess: 1,
            responses: [
                httpResponse(status: 200, body: Data("OK".utf8)),
                httpResponse(status: 200, body: Data("{\"Version\":\"28.5.2\",\"ApiVersion\":\"1.51\"}".utf8)),
                httpResponse(status: 200, body: Data("{\"ServerVersion\":\"28.5.2\"}".utf8))
            ]
        )
        let policy = DockerRetryPolicy(maxAttempts: 2, delay: .zero)
        let client = DockerAPIClient(transport: transport, retryPolicy: policy)

        let health = try await client.health()

        #expect(health.pingOK)
        #expect(await transport.attempts == 4)
    }

    @Test
    func listsExistingImages() async throws {
        let transport = StubDockerTransport(responses: [
            httpResponse(
                status: 200,
                body: Data("[{\"Id\":\"sha256:abc\",\"RepoTags\":[\"hello-world:latest\"],\"Size\":4768,\"Created\":1700000000,\"Architecture\":\"arm64\",\"Os\":\"linux\"}]".utf8)
            )
        ])
        let client = DockerAPIClient(transport: transport)

        let images = try await client.listImages()

        #expect(images.count == 1)
        #expect(images[0].repositoryTags == ["hello-world:latest"])
        #expect(images[0].architecture == "arm64")
        #expect(await transport.paths == ["/images/json"])
    }

    @Test
    func listsContainersIncludingStoppedOnes() async throws {
        let transport = StubDockerTransport(responses: [
            httpResponse(
                status: 200,
                body: Data("[{\"Id\":\"container-123\",\"Names\":[\"/hello\"],\"Image\":\"hello-world:latest\",\"State\":\"exited\",\"Status\":\"Exited (0) 2 minutes ago\"}]".utf8)
            )
        ])
        let client = DockerAPIClient(transport: transport)

        let containers = try await client.listContainers(all: true)

        #expect(containers.count == 1)
        #expect(containers[0].name == "hello")
        #expect(containers[0].state == "exited")
        #expect(containers[0].isRunning == false)
        #expect(await transport.paths == ["/containers/json?all=1"])
    }

    @Test
    func decodesContainerNetworkMembership() async throws {
        let transport = StubDockerTransport(responses: [
            httpResponse(
                status: 200,
                body: Data(
                    """
                    [{"Id":"web-1","Names":["/web-1"],"State":"running",
                      "Ports":[{"IP":"0.0.0.0","PublicPort":8080,"PrivatePort":80,"Type":"tcp"}],
                      "NetworkSettings":{"Networks":{"apps_default":{},"default":{}}}}]
                    """.utf8
                )
            )
        ])
        let client = DockerAPIClient(transport: transport)

        let containers = try await client.listContainers(all: false)

        #expect(containers[0].networkNames == ["apps_default", "default"])
        #expect(containers[0].publishesPorts)
    }

    @Test
    func managesContainerLifecycle() async throws {
        let transport = StubDockerTransport(responses: [
            httpResponse(status: 204, body: Data()),
            httpResponse(status: 204, body: Data()),
            httpResponse(status: 204, body: Data())
        ])
        let client = DockerAPIClient(transport: transport)

        try await client.startContainer(id: "container-123")
        try await client.stopContainer(id: "container-123")
        try await client.removeContainer(id: "container-123", force: true)

        #expect(await transport.paths == [
            "/containers/container-123/start",
            "/containers/container-123/stop?t=5",
            "/containers/container-123?force=1"
        ])
    }

    @Test
    func runsImageAndRemovesExitedContainer() async throws {
        let logPayload = Data("Hello from container\n".utf8)
        var framedLogs = Data([1, 0, 0, 0, 0, 0, 0, UInt8(logPayload.count)])
        framedLogs.append(logPayload)
        let transport = StubDockerTransport(responses: [
            httpResponse(status: 201, body: Data("{\"Id\":\"container-123\",\"Warnings\":null}".utf8)),
            httpResponse(status: 204, body: Data()),
            chunkedHTTPResponse(body: Data("{\"StatusCode\":0}".utf8)),
            chunkedHTTPResponse(body: framedLogs),
            httpResponse(status: 204, body: Data())
        ])
        let client = DockerAPIClient(transport: transport)
        let result = try await client.run(
            image: "hello-world:latest",
            command: [],
            resourceLimits: nil
        )
        #expect(result.exitCode == 0)
        #expect(result.output == "Hello from container\n")
        #expect(await transport.paths == [
            "/containers/create",
            "/containers/container-123/start",
            "/containers/container-123/wait",
            "/containers/container-123/logs?stdout=1&stderr=1",
            "/containers/container-123?force=1"
        ])
        #expect(await transport.requests[0].contains("\"Image\":\"hello-world:latest\""))
        #expect(await transport.timeouts == [.seconds(5), .seconds(5), nil, nil, .seconds(5)])
    }

    @Test
    func runsImageWithResourceLimits() async throws {
        let transport = StubDockerTransport(responses: [
            httpResponse(status: 201, body: Data("{\"Id\":\"container-123\",\"Warnings\":null}".utf8)),
            httpResponse(status: 204, body: Data()),
            chunkedHTTPResponse(body: Data("{\"StatusCode\":0}".utf8)),
            chunkedHTTPResponse(body: Data()),
            httpResponse(status: 204, body: Data()),
        ])
        let client = DockerAPIClient(transport: transport)

        _ = try await client.run(
            image: "alpine:latest",
            command: [],
            resourceLimits: ContainerResourceLimits(
                cpus: 2,
                memoryInBytes: 3 * 1_024 * 1_024 * 1_024
            )
        )

        let createRequest = await transport.requests[0]
        #expect(createRequest.contains("\"HostConfig\""))
        #expect(createRequest.contains("\"Memory\":3221225472"))
        #expect(createRequest.contains("\"NanoCpus\":2000000000"))
    }

    @Test
    func preservesRunningContainerWhenWaitSocketTimesOut() async {
        let transport = RunningContainerTimeoutTransport()
        let client = DockerAPIClient(transport: transport)

        do {
            _ = try await client.run(
                image: "busybox:latest",
                command: ["sleep", "30"],
                resourceLimits: nil
            )
            Issue.record("Expected wait timeout")
        } catch let error as UnixSocketError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.paths == [
            "/containers/create",
            "/containers/container-running/start",
            "/containers/container-running/wait"
        ])
        #expect(await transport.timeouts == [.seconds(5), .seconds(5), nil])
    }

}

private actor RunningContainerTimeoutTransport: DockerAPITransport {
    private(set) var paths: [String] = []
    private(set) var timeouts: [Duration?] = []

    func send(request: Data) throws -> Data {
        try send(request: request, timeout: .seconds(5))
    }

    func send(request: Data, timeout: Duration?) throws -> Data {
        let path = String(decoding: request, as: UTF8.self)
            .split(separator: " ")[1]
            .description
        paths.append(path)
        timeouts.append(timeout)
        switch path {
        case "/containers/create":
            return httpResponse(
                status: 201,
                body: Data("{\"Id\":\"container-running\",\"Warnings\":null}".utf8)
            )
        case "/containers/container-running/start":
            return httpResponse(status: 204, body: Data())
        case "/containers/container-running/wait":
            throw UnixSocketError.timedOut
        default:
            throw UnixSocketError.systemCallFailed(2)
        }
    }
}

private actor FlakyDockerTransport: DockerAPITransport {
    private let failuresBeforeSuccess: Int
    private var responses: [Data]
    private(set) var attempts = 0

    init(failuresBeforeSuccess: Int, responses: [Data]) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.responses = responses
    }

    func send(request: Data) throws -> Data {
        attempts += 1
        if attempts <= failuresBeforeSuccess {
            throw UnixSocketError.systemCallFailed(61)
        }
        return responses.removeFirst()
    }
}

/// A dead end is only a dead end if the way out never reaches the person. The bridge writes the
/// remedy into the error body; before this the client kept the status code and dropped the sentence.
@Suite("What the daemon says about a failure")
struct DockerFailureMessageTests {
    @Test("the message is read out of a Docker-shaped error body")
    func readsTheDockerShape() {
        let body = Data(#"{"message":"cannot remove network app_default: restart the runtime"}"#.utf8)
        #expect(DockerAPIClient.failureMessage(in: body) == "cannot remove network app_default: restart the runtime")
    }

    @Test("a bare-text body is used rather than dropped")
    func fallsBackToText() {
        #expect(DockerAPIClient.failureMessage(in: Data("container web is not running".utf8)) == "container web is not running")
    }

    @Test("nothing is invented when there is nothing to read")
    func staysSilentWithoutABody() {
        #expect(DockerAPIClient.failureMessage(in: Data()) == nil)
        #expect(DockerAPIClient.failureMessage(in: Data(#"{"other":1}"#.utf8)) == #"{"other":1}"#)
    }

    @Test("the description a person sees is the daemon's own sentence")
    func descriptionPrefersTheMessage() {
        let remedy = "cannot remove network app_default: restart the runtime, then remove the network again."
        #expect(DockerAPIError.httpStatus(500, message: remedy).localizedDescription == remedy)
        #expect(DockerAPIError.httpStatus(500, message: nil).localizedDescription == "Docker API returned status 500.")
        #expect(DockerAPIError.httpStatus(404, message: "").localizedDescription == "Docker API returned status 404.")
        // The app reports failures through String(describing:), so that path has to carry it too —
        // otherwise the user reads `httpStatus(500, message: Optional(...))`.
        #expect(String(describing: DockerAPIError.httpStatus(500, message: remedy)) == remedy)
    }
}
