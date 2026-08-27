import Foundation
import Testing

@testable import ContainerStackCore

struct ComposeModelTests {
    // MARK: ComposePortMapping parsing

    @Test func parsesContainerOnlyPort() {
        let mapping = ComposePortMapping.parse("3000")
        #expect(mapping?.containerPort == 3000)
        #expect(mapping?.hostPort == nil)
        #expect(mapping?.hostIP == nil)
        #expect(mapping?.transport == nil)
        #expect(mapping?.raw == "3000")
    }

    @Test func parsesHostContainerPort() {
        let mapping = ComposePortMapping.parse("3000:3000")
        #expect(mapping?.hostPort == 3000)
        #expect(mapping?.containerPort == 3000)
        #expect(mapping?.raw == "3000:3000")
    }

    @Test func parsesHostIPHostContainer() {
        let mapping = ComposePortMapping.parse("127.0.0.1:8080:80")
        #expect(mapping?.hostIP == "127.0.0.1")
        #expect(mapping?.hostPort == 8080)
        #expect(mapping?.containerPort == 80)
        #expect(mapping?.raw == "127.0.0.1:8080:80")
    }

    @Test func parsesTransportSuffix() {
        let mapping = ComposePortMapping.parse("3000:3000/udp")
        #expect(mapping?.transport == "udp")
        #expect(mapping?.hostPort == 3000)
        #expect(mapping?.containerPort == 3000)
        #expect(mapping?.raw == "3000:3000/udp")
    }

    @Test func parsesExplicitTcpTransport() {
        let mapping = ComposePortMapping.parse("127.0.0.1:8080:80/tcp")
        #expect(mapping?.transport == "tcp")
        #expect(mapping?.raw == "127.0.0.1:8080:80/tcp")
    }

    @Test func parsesPortRangeKeepingRaw() {
        let mapping = ComposePortMapping.parse("8080-8090:80")
        #expect(mapping?.hostPort == nil)
        #expect(mapping?.containerPort == 80)
        #expect(mapping?.raw == "8080-8090:80")
    }

    @Test func rejectsUnparseablePort() {
        #expect(ComposePortMapping.parse("not-a-port") == nil)
        #expect(ComposePortMapping.parse("") == nil)
        #expect(ComposePortMapping.parse(":80") == nil)
    }

    @Test func portRoundTripsThroughRaw() {
        let mappings = [
            ComposePortMapping(hostPort: nil, containerPort: 3000),
            ComposePortMapping(hostPort: 3000, containerPort: 3000),
            ComposePortMapping(hostIP: "127.0.0.1", hostPort: 8080, containerPort: 80),
            ComposePortMapping(hostPort: 3000, containerPort: 3000, transport: "udp"),
            ComposePortMapping(hostIP: "127.0.0.1", hostPort: 8080, containerPort: 80, transport: "tcp"),
        ]
        for mapping in mappings {
            #expect(ComposePortMapping.parse(mapping.raw) == mapping, "failed to round-trip \(mapping.raw)")
        }
    }

    // MARK: ComposeVolumeMount parsing

    @Test func parsesNamedVolume() {
        let mount = ComposeVolumeMount.parse("data:/target")
        #expect(mount?.source == "data")
        #expect(mount?.target == "/target")
        #expect(mount?.isReadOnly == false)
        #expect(mount?.isBindMount == false)
        #expect(mount?.raw == "data:/target")
    }

    @Test func parsesAbsoluteBindMount() {
        let mount = ComposeVolumeMount.parse("/host:/target")
        #expect(mount?.source == "/host")
        #expect(mount?.isBindMount == true)
        #expect(mount?.raw == "/host:/target")
    }

    @Test func parsesRelativeBindMountReadOnly() {
        let mount = ComposeVolumeMount.parse("./rel:/target:ro")
        #expect(mount?.source == "./rel")
        #expect(mount?.isReadOnly == true)
        #expect(mount?.isBindMount == true)
        #expect(mount?.raw == "./rel:/target:ro")
    }

    @Test func parsesHomeDirSource() {
        let mount = ComposeVolumeMount.parse("~/x:/target")
        #expect(mount?.source == "~/x")
        #expect(mount?.isBindMount == true)
    }

    @Test func parsesAnonymousVolume() {
        let mount = ComposeVolumeMount.parse("/data")
        #expect(mount?.source == "")
        #expect(mount?.target == "/data")
        #expect(mount?.isBindMount == false)
        #expect(mount?.raw == "/data")
    }

    @Test func volumeRoundTripsThroughRaw() {
        let mounts = [
            ComposeVolumeMount(source: "data", target: "/target", isReadOnly: false),
            ComposeVolumeMount(source: "/host", target: "/target", isReadOnly: false),
            ComposeVolumeMount(source: "./rel", target: "/target", isReadOnly: true),
            ComposeVolumeMount(source: "", target: "/data", isReadOnly: false),
        ]
        for mount in mounts {
            #expect(ComposeVolumeMount.parse(mount.raw) == mount, "failed to round-trip \(mount.raw)")
        }
    }

    // MARK: ComposeProjectModel parsing

    @Test func parsesComposeConfigLongSyntax() throws {
        // Mirrors current `docker compose config --format json`: `published` is a string,
        // absent for ephemeral ports; volumes carry type/source/target/read_only.
        let json = """
            {
              "name": "demo",
              "services": {
                "web": {
                  "image": "nginx",
                  "restart": "always",
                  "ports": [
                    {"mode": "ingress", "target": 80, "published": "8080", "host_ip": "127.0.0.1", "protocol": "tcp"},
                    {"mode": "ingress", "target": 443}
                  ],
                  "volumes": [
                    {"type": "bind", "source": "/host", "target": "/data", "read_only": true}
                  ]
                },
                "db": {
                  "image": "postgres"
                }
              }
            }
            """
        let model = try ComposeProjectModel.parse(configJSON: Data(json.utf8), fallbackName: "fallback")

        #expect(model.name == "demo")
        #expect(model.services.map(\.name) == ["db", "web"])

        let web = try #require(model.services.first { $0.name == "web" })
        #expect(web.image == "nginx")
        #expect(web.restart == "always")
        #expect(web.ports.count == 2)
        #expect(web.ports[0].hostIP == "127.0.0.1")
        #expect(web.ports[0].hostPort == 8080)
        #expect(web.ports[0].containerPort == 80)
        #expect(web.ports[0].transport == "tcp")
        #expect(web.ports[1].hostPort == nil)
        #expect(web.ports[1].containerPort == 443)
        #expect(web.volumes.count == 1)
        #expect(web.volumes[0].source == "/host")
        #expect(web.volumes[0].target == "/data")
        #expect(web.volumes[0].isReadOnly == true)
    }

    @Test func parsesRangePublishedAsEphemeral() throws {
        let json =
            #"{"name":"x","services":{"web":{"ports":[{"target":90,"published":"8090-8092","protocol":"tcp"}]}}}"#
        let model = try ComposeProjectModel.parse(configJSON: Data(json.utf8), fallbackName: "f")
        let port = try #require(model.services.first?.ports.first)
        #expect(port.hostPort == nil)
        #expect(port.containerPort == 90)
        #expect(port.transport == "tcp")
    }

    @Test func parsesStringShortSyntaxEntries() throws {
        // Older Compose emits plain short-syntax strings for ports and volumes.
        let json = #"{"name":"x","services":{"web":{"ports":["3000:3000"],"volumes":["/h:/t"]}}}"#
        let model = try ComposeProjectModel.parse(configJSON: Data(json.utf8), fallbackName: "f")
        let web = try #require(model.services.first)
        #expect(web.ports[0].raw == "3000:3000")
        #expect(web.volumes[0].raw == "/h:/t")
    }

    @Test func usesFallbackNameWhenAbsent() throws {
        let model = try ComposeProjectModel.parse(configJSON: Data(#"{"services": {}}"#.utf8), fallbackName: "fallback")
        #expect(model.name == "fallback")
        #expect(model.services.isEmpty)
    }

    @Test func missingServicesYieldsEmptyModel() throws {
        let model = try ComposeProjectModel.parse(configJSON: Data(#"{"name":"lonely"}"#.utf8), fallbackName: "f")
        #expect(model.services.isEmpty)
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: ComposeProjectModel.DecodeError.self) {
            try ComposeProjectModel.parse(configJSON: Data("not json".utf8), fallbackName: "f")
        }
    }
}
