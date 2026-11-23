import Foundation
import Testing

@testable import ContainerStackCore

let clusterListFixture: Data = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/cluster-list.json")
    return (try? Data(contentsOf: url)) ?? Data()
}()

func clusterListJSON(_ replacements: [(String, String)] = []) -> Data {
    var text = String(decoding: clusterListFixture, as: UTF8.self)
    for (old, new) in replacements {
        text = text.replacingOccurrences(of: old, with: new)
    }
    return Data(text.utf8)
}

struct KubernetesClusterTests {
    @Test("the fixture of spec 2.1 decodes")
    func decodesTheFixture() throws {
        let clusters = try KubernetesCluster.decodeList(clusterListFixture)

        #expect(clusters.count == 1)
        let cluster = try #require(clusters.first)
        #expect(cluster.name == "cs-spec")
        #expect(cluster.kubernetesVersion == "v1.35.5")
        #expect(cluster.remove == false)
        #expect(cluster.sharedImageStore == false)
        #expect(cluster.creationDate == ISO8601DateFormatter().date(from: "2026-11-23T17:23:33Z"))
        #expect(cluster.cni == nil)
        #expect(cluster.fqdn == nil)
        #expect(cluster.nodes == [.init(name: "cs-spec", roles: ["control-plane", "worker"])])
        #expect(cluster.state == .running)
        #expect(
            cluster.nodeStatuses == [
                .init(name: "cs-spec", status: "running", addresses: ["192.168.64.3"], ports: ["6445->6443"])
            ])
    }

    @Test("an unknown key is ignored")
    func ignoresUnknownKeys() throws {
        let data = clusterListJSON([(#""remove":false"#, #""remove":false,"future":{"a":1}"#)])
        #expect(try KubernetesCluster.decodeList(data).first?.name == "cs-spec")
    }

    @Test("a missing status.state fails and names the key")
    func missingStateNamesTheKey() {
        let data = clusterListJSON([(#","state":"running""#, "")])
        #expect(throws: ClusterListError.invalid("missing key status.state")) {
            try KubernetesCluster.decodeList(data)
        }
    }

    @Test("an unknown state fails and names the key")
    func unknownStateNamesTheKey() {
        let data = clusterListJSON([(#""state":"running""#, #""state":"paused""#)])
        #expect(throws: ClusterListError.invalid("unknown value 'paused' at status.state")) {
            try KubernetesCluster.decodeList(data)
        }
    }

    @Test("a missing key inside a node names its path")
    func missingNodeKeyNamesThePath() {
        let data = clusterListJSON([(#","roles":["control-plane","worker"]"#, "")])
        #expect(throws: ClusterListError.invalid("missing key configuration.nodes[0].roles")) {
            try KubernetesCluster.decodeList(data)
        }
    }

    @Test("optional keys can be absent")
    func optionalKeysCanBeAbsent() throws {
        let data = clusterListJSON([
            (#""cni":null,"#, ""), (#""fqdn":null,"#, ""),
            (#""addresses":["192.168.64.3"],"#, ""), (#""ports":["6445->6443"],"#, ""),
        ])
        let cluster = try #require(try KubernetesCluster.decodeList(data).first)
        #expect(cluster.nodeStatuses.first?.addresses == nil)
        #expect(cluster.apiEndpoint == nil)
    }

    @Test("the API endpoint comes from the host port of 6443")
    func endpointFromThePort() throws {
        let cluster = try #require(try KubernetesCluster.decodeList(clusterListFixture).first)
        #expect(cluster.apiEndpoint == URL(string: "https://127.0.0.1:6445"))
    }

    @Test("with an FQDN the API endpoint is the FQDN on 6443")
    func endpointFromTheFQDN() throws {
        let data = clusterListJSON([(#""fqdn":null"#, #""fqdn":"cs-spec.test""#)])
        let cluster = try #require(try KubernetesCluster.decodeList(data).first)
        #expect(cluster.apiEndpoint == URL(string: "https://cs-spec.test:6443"))
    }
}
