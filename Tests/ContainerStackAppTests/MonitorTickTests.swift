import ContainerStackCore
import Foundation
import Testing

@testable import ContainerStackApp

@Suite("Monitor tick")
@MainActor
struct MonitorTickTests {
    /// A context read running beside the probe let a probe-triggered adoption decide on a cached
    /// context the user had switched away from; inside the tick the two cannot overlap.
    @Test("With the window open, the tick reads the Docker context itself")
    func openWindowReadsContextInTick() async {
        let model = makeModel()
        model.readDockerContext = { _ in Self.reading(active: "orbstack") }
        model.isDashboardOpen = true

        await model.monitorTick()

        #expect(model.activeDockerContext == "orbstack")
    }

    @Test("With the window closed, the tick does not read the Docker context")
    func closedWindowSkipsContextRead() async {
        let model = makeModel()
        model.readDockerContext = { _ in Self.reading(active: "orbstack") }

        await model.monitorTick()

        #expect(model.activeDockerContext == nil)
    }

    private func makeModel() -> RuntimeViewModel {
        RuntimeViewModel(
            socketPath: "/tmp/containerstack-monitor-\(UUID().uuidString).sock",
            startsRuntime: false
        )
    }

    private nonisolated static func reading(active: String) -> DockerContextReading {
        DockerContextReading(
            active: active,
            installed: nil,
            defaultSocket: DockerContext.socketStatus(atPath: "/nonexistent/docker.sock")
        )
    }
}
