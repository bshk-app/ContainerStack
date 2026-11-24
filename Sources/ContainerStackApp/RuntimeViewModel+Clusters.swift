import ContainerStackCore
import Foundation

extension RuntimeViewModel {
    var clusterRuntimeReachable: Bool { isHealthy && !isRestarting && !isStopping }

    func makeClusterSection() -> ClusterSectionModel {
        let commands = ClusterCommands(
            containerPath: runtimeConfiguration().containerPath,
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment,
            mutationOutput: .captureSeparately
        )
        let config = ClusterKubeconfig(commands: commands)
        let client = client
        return ClusterSectionModel(
            services: ClusterSectionServices(
                capability: { try await commands.capability() },
                list: {
                    let json = try await commands.list()
                    let clusters = try KubernetesCluster.decodeList(Data(json.utf8))
                    let nodes = clusters.isEmpty ? [] : try await client.listClusterNodes()
                    return ClusterInventory(
                        clusters: clusters, nodes: Set(nodes.map(\.name)), contexts: config.managedContexts())
                },
                checkAPI: { cluster in
                    await ClusterAPIReady.check(
                        endpoint: cluster.apiEndpoint, context: cluster.name, kubeconfig: commands.managedKubeconfig)
                },
                run: { action, name in
                    switch action {
                    case .start: try await commands.start(name: name)
                    case .stop: try await commands.stop(name: name)
                    case .delete: try await commands.delete(name: name)
                    case .restart: preconditionFailure("Restart uses Stop and Start.")
                    }
                },
                create: { try await commands.create(name: $0, options: $1) },
                checkAdd: { try config.checkAdd(name: $0) },
                write: { name, target in
                    switch target {
                    case .managed: try await config.writeManaged(name: name)
                    case .userDefault: try await config.add(name: name)
                    }
                },
                cleanup: { config.cleanupCommands(name: $0.name, endpoint: $0.apiEndpoint) },
                inspect: { try? await client.inspectContainer(id: DockerAPIClient.pathEncoded($0)) },
                canReachRuntime: { [weak self] in self?.clusterRuntimeReachable == true },
                canMutate: { [weak self] in self?.clusterRuntimeReachable == true && self?.canMutate == true }
            ))
    }
}
