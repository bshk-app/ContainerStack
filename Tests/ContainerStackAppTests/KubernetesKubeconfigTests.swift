import Foundation
import Synchronization
import Testing

@testable import ContainerStackApp
@testable import ContainerStackCore

struct KubernetesKubeconfigTests {
    @Test(arguments: [
        "contexts: [{name: 'dev', context: {cluster: production, user: somebody}}]",
        "clusters:\n- name: \"dev\" # used by another context\n  cluster: {server: https://production.test}\n"
            + "contexts: [{name: another, context: {cluster: dev, user: somebody}}]",
        "users: [{name: \"d\\x65v\", user: {token: secret}}]",
    ])
    func refusesEverySameNameEntry(fixture: String) throws {
        let home = try KubeconfigTestHome()
        try home.write(fixture)
        let before = try Data(contentsOf: home.userConfig)
        #expect(throws: ClusterKubeconfigError.collision("dev")) { try home.config.checkAdd(name: "dev") }
        #expect(try Data(contentsOf: home.userConfig) == before)
        #expect(home.launches.withLock { $0 }.isEmpty)
    }

    @Test func checksAgainBeforeWritingToTheUserFile() async throws {
        let home = try KubeconfigTestHome()
        try home.config.checkAdd(name: "dev")
        #expect(home.launches.withLock { $0 }.isEmpty)
        try home.write("users: [{name: dev, user: {token: secret}}]")
        let before = try Data(contentsOf: home.userConfig)
        await #expect(throws: ClusterKubeconfigError.collision("dev")) {
            try await home.config.add(name: "dev")
        }
        #expect(try Data(contentsOf: home.userConfig) == before)
        #expect(home.launches.withLock { $0 }.isEmpty)
    }

    @Test func usesTheChosenFileOnlyAfterApproval() async throws {
        let home = try KubeconfigTestHome()
        try home.write("contexts: [{name: production, context: {cluster: production, user: admin}}]")
        try home.config.checkAdd(name: "dev")
        #expect(home.launches.withLock { $0 }.isEmpty)
        try await home.config.add(name: "dev")
        try await home.config.writeManaged(name: "dev")
        let calls = home.launches.withLock { $0 }
        #expect(calls.map(\.arguments) == Array(repeating: ["cluster", "write-config", "--name", "dev"], count: 2))
        #expect(calls.map { $0.environment["KUBECONFIG"] } == [home.userConfig.path, home.managedConfig.path])
    }

    @Test func refusesAnAliasBeforeCollisionCheckingAndWithoutLaunching() async throws {
        let home = try KubeconfigTestHome()
        try FileManager.default.createDirectory(
            at: home.managedConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("users: [{name: dev}]".utf8).write(to: home.managedConfig)
        try FileManager.default.linkItem(at: home.managedConfig, to: home.userConfig)
        #expect(throws: ClusterCommandError.kubeconfigAlias) { try home.config.checkAdd(name: "dev") }
        await #expect(throws: ClusterCommandError.kubeconfigAlias) { try await home.config.add(name: "dev") }
        #expect(home.launches.withLock { $0 }.isEmpty)
        #expect(try String(contentsOf: home.userConfig, encoding: .utf8) == "users: [{name: dev}]")
    }

    @Test func reportsInvalidYamlWithoutWriting() async throws {
        let home = try KubeconfigTestHome()
        try home.write("contexts: [")
        await #expect(throws: ClusterKubeconfigError.self) { try await home.config.add(name: "dev") }
        #expect(home.launches.withLock { $0 }.isEmpty)
        #expect(try String(contentsOf: home.userConfig, encoding: .utf8) == "contexts: [")
    }

    @Test func deleteInstructionsMatchAContextEndpointAndExplicitlyNameTheFile() throws {
        let home = try KubeconfigTestHome()
        try home.write(
            """
            contexts: [{name: dev, context: {cluster: target, user: dev}}]
            clusters: [{name: target, cluster: {server: https://127.0.0.1:6445}}]
            """)
        let endpoint = try #require(URL(string: "https://127.0.0.1:6445"))
        let other = try #require(URL(string: "https://127.0.0.1:6446"))
        let commands = home.config.cleanupCommands(name: "dev", endpoint: endpoint)
        #expect(
            commands == [
                #"kubectl --kubeconfig "$HOME/.kube/config" config delete-context dev"#,
                #"kubectl --kubeconfig "$HOME/.kube/config" config delete-cluster dev"#,
                #"kubectl --kubeconfig "$HOME/.kube/config" config delete-user dev"#,
            ])
        #expect(home.config.cleanupCommands(name: "dev", endpoint: other).isEmpty)
        #expect(home.config.cleanupCommands(name: "other", endpoint: endpoint).isEmpty)
    }
}

private final class KubeconfigTestHome {
    let home = FileManager.default.temporaryDirectory.appending(path: "app-kubeconfig-\(UUID())")
    let launches = Mutex<[ClusterCommands.Launch]>([])

    init() throws {
        try FileManager.default.createDirectory(
            at: userConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    var userConfig: URL { home.appending(path: ".kube/config") }
    var managedConfig: URL { home.appending(path: ".containerstack/kubeconfig") }

    var config: ClusterKubeconfig {
        ClusterKubeconfig(
            commands: ClusterCommands(
                containerPath: "/fake/container", home: home, environment: [:],
                spawn: { [self] launch in
                    launches.withLock { $0.append(launch) }
                    return .init(status: 0, output: "")
                }))
    }

    func write(_ text: String) throws { try Data(text.utf8).write(to: userConfig) }
}

extension KubeconfigTestHome: Sendable {}
