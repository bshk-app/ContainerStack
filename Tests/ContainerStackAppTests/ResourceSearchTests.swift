import XCTest

@testable import ContainerStackApp
@testable import ContainerStackCore

final class ResourceSearchTests: XCTestCase {
    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(ResourceSearch.matches("", "demo-webserver-1", "nginx"))
        XCTAssertTrue(ResourceSearch.matches("   ", nil, "anything"))
    }

    func testQueryMatchesAnyFieldCaseInsensitively() {
        XCTAssertTrue(ResourceSearch.matches("WEB", "demo-webserver-1", "nginx:latest"))
        XCTAssertTrue(ResourceSearch.matches("nginx", "demo-webserver-1", "nginx:latest"))
        XCTAssertFalse(ResourceSearch.matches("postgres", "demo-webserver-1", "nginx:latest"))
    }

    func testNilAndEmptyFieldsAreIgnored() {
        XCTAssertFalse(ResourceSearch.matches("demo", nil, "", "   "))
        XCTAssertTrue(ResourceSearch.matches("demo", nil, "demo-api"))
    }

    func testContainerGroupsDropGroupsWithNoHits() {
        let shop = ContainerGroup(
            project: "shop-api",
            containers: [
                container(id: "1", name: "shop-api-api-1", image: "shop-api:dev"),
                container(id: "2", name: "shop-api-postgres-1", image: "postgres:16"),
            ]
        )
        let standalone = ContainerGroup(
            project: nil,
            containers: [
                container(id: "3", name: "ollama", image: "ollama/ollama:latest")
            ]
        )

        let postgres = ResourceSearch.containerGroups([shop, standalone], query: "postgres")
        XCTAssertEqual(postgres.map(\.id), [shop.id])
        XCTAssertEqual(postgres.first?.containers.map(\.name), ["shop-api-postgres-1"])

        let miss = ResourceSearch.containerGroups([shop, standalone], query: "redis")
        XCTAssertTrue(miss.isEmpty)

        let all = ResourceSearch.containerGroups([shop, standalone], query: "")
        XCTAssertEqual(all.map(\.id), [shop.id, standalone.id])
    }

    private func container(id: String, name: String, image: String) -> DockerContainerSummary {
        DockerContainerSummary(
            id: id,
            names: ["/\(name)"],
            image: image,
            imageID: nil,
            command: nil,
            created: nil,
            state: "running",
            status: "Up 1h",
            labels: nil,
            ports: nil,
            networkSettings: nil
        )
    }
}
