import Foundation
import XCTest

@testable import ContainerStackApp
@testable import ContainerStackCore

/// The row's port column fits about 14 characters. The full `portSummary` there rendered as
/// "0.0.0.0:3000-…", so the row shows the first published mapping and a count.
final class ContainerPortLabelTests: XCTestCase {
    /// Docker lists the IPv4 and the IPv6 binding of one mapping as two ports.
    func testAMappingBoundTwiceShowsOnce() throws {
        let label = try container(
            ports: """
                [{"IP": "0.0.0.0", "PrivatePort": 3000, "PublicPort": 3000, "Type": "tcp"},
                 {"IP": "::", "PrivatePort": 3000, "PublicPort": 3000, "Type": "tcp"}]
                """
        ).rowPortLabel

        XCTAssertEqual(label, "3000→3000")
    }

    func testFurtherMappingsAreCounted() throws {
        let label = try container(
            ports: """
                [{"IP": "127.0.0.1", "PrivatePort": 80, "PublicPort": 8080, "Type": "tcp"},
                 {"IP": "127.0.0.1", "PrivatePort": 443, "PublicPort": 8443, "Type": "tcp"}]
                """
        ).rowPortLabel

        XCTAssertEqual(label, "8080→80 +1")
    }

    /// Only the address family folds: the same port pair over TCP and UDP is two mappings.
    func testTCPAndUDPOnTheSamePortsAreTwoMappings() throws {
        let label = try container(
            ports: """
                [{"IP": "0.0.0.0", "PrivatePort": 53, "PublicPort": 53, "Type": "tcp"},
                 {"IP": "0.0.0.0", "PrivatePort": 53, "PublicPort": 53, "Type": "udp"}]
                """
        ).rowPortLabel

        XCTAssertEqual(label, "53→53 +1")
    }

    func testUnpublishedPortsLeaveTheColumnEmpty() throws {
        let label = try container(
            ports: """
                [{"PrivatePort": 6379, "Type": "tcp"},
                 {"PrivatePort": 6380, "PublicPort": 0, "Type": "tcp"}]
                """
        ).rowPortLabel

        XCTAssertNil(label)
    }

    private func container(ports: String) throws -> DockerContainerSummary {
        let json = #"{"Id": "1", "Ports": \#(ports)}"#
        return try JSONDecoder().decode(DockerContainerSummary.self, from: Data(json.utf8))
    }
}
