import Foundation
import Testing
@testable import ContainerStackCore

struct DockerResourceClientTests {
    @Test
    func listsVolumes() async throws {
        let transport = StubDockerTransport(responses: [
            jsonResponse(#"{"Volumes":[{"Name":"data","Driver":"local","Mountpoint":"/vol/data","CreatedAt":"2026-08-12T17:35:41Z"}],"Warnings":[]}"#)
        ])
        let client = DockerAPIClient(transport: transport)

        let volumes = try await client.listVolumes()

        #expect(volumes.count == 1)
        #expect(volumes[0].name == "data")
        #expect(volumes[0].mountpoint == "/vol/data")
        #expect(await transport.paths == ["/volumes"])
    }

    @Test
    func decodesContainerLabelsAndPorts() async throws {
        let json = """
        [{"Id":"c1","Names":["/web"],"Image":"nginx","State":"running","Status":"Up",
        "Labels":{"com.docker.compose.project":"demo","com.docker.compose.service":"web"},
        "Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},
        {"PrivatePort":443,"Type":"tcp"}]}]
        """
        let transport = StubDockerTransport(responses: [jsonResponse(json)])
        let client = DockerAPIClient(transport: transport)

        let containers = try await client.listContainers()

        #expect(containers[0].composeProject == "demo")
        #expect(containers[0].composeService == "web")
        #expect(containers[0].portSummary == "0.0.0.0:8080->80/tcp, 443/tcp")
    }

    @Test
    func pingChecksSocketWithoutVersionLookups() async throws {
        let transport = StubDockerTransport(responses: [httpResponse(status: 200, body: Data("OK".utf8))])
        let client = DockerAPIClient(transport: transport)

        let responds = try await client.ping()

        #expect(responds)
        #expect(await transport.paths == ["/_ping"])
    }

    @Test
    func encodesResourceNamesInPaths() async throws {
        let transport = StubDockerTransport(responses: [
            httpResponse(status: 204, body: Data()),
            httpResponse(status: 204, body: Data()),
            jsonResponse(#"[{"Deleted":"sha256:a"}]"#)
        ])
        let client = DockerAPIClient(transport: transport)

        try await client.removeVolume(name: "my volume#1")
        try await client.removeNetwork(id: "net work/2")
        try await client.removeImage(reference: "ghcr.io/apple/vminit:0.9.1")

        #expect(await transport.paths == [
            "/volumes/my%20volume%231",
            "/networks/net%20work%2F2",
            "/images/ghcr.io%2Fapple%2Fvminit%3A0.9.1?force=0"
        ])
    }

    @Test
    func createsAndRemovesVolume() async throws {
        let transport = StubDockerTransport(responses: [
            jsonResponse(#"{"Name":"cache","Driver":"local","Mountpoint":"/vol/cache"}"#, status: 201),
            httpResponse(status: 204, body: Data())
        ])
        let client = DockerAPIClient(transport: transport)

        let created = try await client.createVolume(name: "cache")
        try await client.removeVolume(name: "cache")

        #expect(created.name == "cache")
        #expect(await transport.paths == ["/volumes/create", "/volumes/cache"])
        #expect(await transport.requests[0].contains(#""Name":"cache""#))
    }

    @Test
    func listsNetworksWithSubnet() async throws {
        let transport = StubDockerTransport(responses: [
            jsonResponse("""
            [{"Id":"default","Name":"default","Driver":"nat","Scope":"local",
            "Subnet":"192.168.64.0/24"},
            {"Id":"n2","Name":"proj","Driver":"nat",
            "IPAM":{"Config":[{"Subnet":"192.168.254.0/24","Gateway":"192.168.254.1"}]}}]
            """)
        ])
        let client = DockerAPIClient(transport: transport)

        let networks = try await client.listNetworks()

        #expect(networks.count == 2)
        #expect(networks[0].subnet == "192.168.64.0/24")
        #expect(networks[1].subnet == "192.168.254.0/24")
        #expect(await transport.paths == ["/networks"])
    }

    @Test
    func createsAndRemovesNetwork() async throws {
        let transport = StubDockerTransport(responses: [
            jsonResponse(#"{"Id":"net-1","Warning":""}"#, status: 201),
            httpResponse(status: 204, body: Data())
        ])
        let client = DockerAPIClient(transport: transport)

        let id = try await client.createNetwork(name: "proj")
        try await client.removeNetwork(id: id)

        #expect(id == "net-1")
        #expect(await transport.paths == ["/networks/create", "/networks/net-1"])
    }

    @Test
    func readsDiskUsage() async throws {
        let transport = StubDockerTransport(responses: [
            jsonResponse("""
            {"LayersSize":2627125248,
            "Images":[{"Id":"sha256:a","RepoTags":["alpine:3.20"],"Size":4768}],
            "Containers":[{"Id":"c1","SizeRw":1024}],
            "Volumes":[{"Name":"data"}],"BuildCache":[]}
            """)
        ])
        let client = DockerAPIClient(transport: transport)

        let usage = try await client.diskUsage()

        #expect(usage.layersSize == 2_627_125_248)
        #expect(usage.images.count == 1)
        #expect(usage.containers.count == 1)
        #expect(usage.volumes.count == 1)
        #expect(await transport.paths == ["/system/df"])
    }

    @Test
    func prunesUnusedResources() async throws {
        let transport = StubDockerTransport(responses: [
            jsonResponse(#"{"ContainersDeleted":["buildkit"],"SpaceReclaimed":512}"#),
            jsonResponse(#"{"SpaceReclaimed":2048}"#),
            jsonResponse(#"{"VolumesDeleted":["stale"],"SpaceReclaimed":64}"#)
        ])
        let client = DockerAPIClient(transport: transport)

        let containers = try await client.pruneContainers()
        let images = try await client.pruneImages()
        let volumes = try await client.pruneVolumes()

        #expect(containers.spaceReclaimed == 512)
        #expect(containers.deleted == ["buildkit"])
        #expect(images.spaceReclaimed == 2048)
        #expect(volumes.deleted == ["stale"])
        #expect(await transport.paths == ["/containers/prune", "/images/prune", "/volumes/prune"])
    }

    @Test
    func readsContainerLogsWithoutSocketTimeout() async throws {
        var framed = Data([1, 0, 0, 0])
        let payload = Data("boot complete\n".utf8)
        framed.append(contentsOf: [
            UInt8((payload.count >> 24) & 0xFF),
            UInt8((payload.count >> 16) & 0xFF),
            UInt8((payload.count >> 8) & 0xFF),
            UInt8(payload.count & 0xFF)
        ])
        framed.append(payload)
        let transport = StubDockerTransport(responses: [httpResponse(status: 200, body: framed)])
        let client = DockerAPIClient(transport: transport)

        let logs = try await client.containerLogs(id: "c1", tail: 200)

        #expect(logs == "boot complete\n")
        #expect(await transport.paths == ["/containers/c1/logs?stdout=1&stderr=1&tail=200"])
        #expect(await transport.timeouts == [nil])
    }

    @Test
    func inspectsContainer() async throws {
        let transport = StubDockerTransport(responses: [
            jsonResponse("""
            {"Id":"c1","Name":"/probe","Created":"2026-08-12T17:37:16.758Z",
            "Image":"docker.io/library/alpine:3.20","Platform":"linux",
            "State":{"Status":"exited","Running":false,"ExitCode":3,
            "StartedAt":"2026-08-12T17:37:17Z","FinishedAt":"2026-08-12T17:37:18Z"},
            "Config":{"Image":"alpine:3.20","Cmd":["-c","echo probe"],
            "Labels":{"com.docker.compose.project":"demo"}},
            "HostConfig":{"Memory":6442450944}}
            """)
        ])
        let client = DockerAPIClient(transport: transport)

        let detail = try await client.inspectContainer(id: "c1")

        #expect(detail.name == "probe")
        #expect(detail.image == "docker.io/library/alpine:3.20")
        #expect(detail.isRunning == false)
        #expect(detail.exitCode == 3)
        #expect(detail.command == "-c echo probe")
        #expect(detail.composeProject == "demo")
        #expect(detail.memoryLimitBytes == 6_442_450_944)
        #expect(await transport.paths == ["/containers/c1/json"])
    }

    @Test
    func restartsContainer() async throws {
        let transport = StubDockerTransport(responses: [httpResponse(status: 204, body: Data())])
        let client = DockerAPIClient(transport: transport)

        try await client.restartContainer(id: "c1")

        #expect(await transport.paths == ["/containers/c1/restart"])
    }

    @Test
    func pullsImageAndReportsProgressEvents() async throws {
        let body = #"{"status":"Trying to pull docker.io/library/alpine:3.20"}{"id":"alpine:3.20","status":"Downloading","progress":"[====>] 4MB"}{"status":"Pull complete"}"#
        let transport = StubDockerTransport(responses: [jsonResponse(body)])
        let client = DockerAPIClient(transport: transport)

        let events = try await client.pullImage(reference: "alpine:3.20")

        #expect(events.count == 3)
        #expect(events.last?.status == "Pull complete")
        #expect(events[1].progress == "[====>] 4MB")
        #expect(await transport.paths == ["/images/create?fromImage=alpine&tag=3.20"])
        #expect(await transport.timeouts == [nil])
    }

    @Test
    func pullSurfacesRemoteFailure() async {
        let transport = StubDockerTransport(responses: [
            jsonResponse(#"{"status":"Trying to pull nope:1"}{"error":"manifest unknown"}"#)
        ])
        let client = DockerAPIClient(transport: transport)

        do {
            _ = try await client.pullImage(reference: "nope:1")
            Issue.record("Expected pull failure")
        } catch let error as DockerAPIError {
            #expect(error == .remoteFailure("manifest unknown"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func pullsDigestAndDefaultTagReferences() async throws {
        let transport = StubDockerTransport(responses: [
            jsonResponse(#"{"status":"Pull complete"}"#),
            jsonResponse(#"{"status":"Pull complete"}"#)
        ])
        let client = DockerAPIClient(transport: transport)

        _ = try await client.pullImage(reference: "ghcr.io/apple/containerization/vminit")
        _ = try await client.pullImage(reference: "alpine@sha256:abc")

        #expect(await transport.paths == [
            "/images/create?fromImage=ghcr.io%2Fapple%2Fcontainerization%2Fvminit&tag=latest",
            "/images/create?fromImage=alpine&tag=sha256%3Aabc"
        ])
    }

    @Test
    func inspectsImagePlatformByEncodedRepositoryTag() async throws {
        let transport = StubDockerTransport(responses: [
            jsonResponse(#"{"Architecture":"arm64","Os":"linux"}"#)
        ])
        let client = DockerAPIClient(transport: transport)

        let detail = try await client.inspectImage(
            reference: "ghcr.io/apple/containerization/vminit:0.12.1"
        )

        #expect(detail.architecture == "arm64")
        #expect(detail.operatingSystem == "linux")
        #expect(await transport.paths == [
            "/images/ghcr.io%2Fapple%2Fcontainerization%2Fvminit%3A0.12.1/json"
        ])
    }

    @Test
    func removesImage() async throws {
        let transport = StubDockerTransport(responses: [
            jsonResponse(#"[{"Untagged":"alpine:3.20"},{"Deleted":"sha256:a"}]"#)
        ])
        let client = DockerAPIClient(transport: transport)

        try await client.removeImage(reference: "alpine:3.20", force: true)

        #expect(await transport.paths == ["/images/alpine%3A3.20?force=1"])
    }
}
