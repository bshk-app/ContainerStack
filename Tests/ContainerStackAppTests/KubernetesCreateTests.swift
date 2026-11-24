import Testing

@testable import ContainerStackApp

struct KubernetesCreateTests {
    @Test(arguments: [
        "", "-dev", "dev-", "DEV", "dev.local", "my_dev", "dev space", "café", String(repeating: "a", count: 64),
    ])
    func refusesInvalidNames(name: String) {
        var draft = ClusterCreateDraft()
        draft.name = name
        #expect(draft.nameError(existing: []) != nil)
    }

    @Test(arguments: ["a", "0", "0-dev", "a-b", String(repeating: "a", count: 63)])
    func acceptsValidNamesUnlessTaken(name: String) {
        var draft = ClusterCreateDraft()
        draft.name = name
        #expect(draft.nameError(existing: []) == nil)
        #expect(draft.nameError(existing: [name]) != nil)
    }

    @Test func mapsCreateOptionsAndLetsRuntimeSupplyDefaults() {
        var draft = ClusterCreateDraft()
        draft.name = "dev"
        #expect(draft.options == [])
        draft.cpus = "4"
        draft.memory = "8g"
        draft.workers = [.init(count: 2, cpus: "3", memory: "4g"), .init(count: 1)]
        draft.nodeImage = "example.org/custom:v1.35.5"
        draft.network = .manifest
        draft.manifestPath = "/tmp/my manifest.yaml"
        draft.sharedImageStore = true
        #expect(
            draft.options == [
                "--cpus", "4", "--memory", "8g", "--workers", "count=2,cpus=3,memory=4g", "--workers", "count=1",
                "--node-image", "example.org/custom:v1.35.5", "--cni", "/tmp/my manifest.yaml", "--shared-image-store",
            ])
        draft.network = .none
        #expect(draft.options.contains("NONE"))
        #expect(!draft.options.contains("/tmp/my manifest.yaml"))
    }

    @Test func workerLimitAndResourceErrors() {
        var draft = ClusterCreateDraft()
        draft.name = "dev"
        draft.workers = [.init(count: 512), .init(count: 512)]
        #expect(draft.optionsError == nil)
        draft.workers[1].count += 1
        #expect(draft.optionsError != nil)
        draft.workers = [.init(count: .max)]
        #expect(draft.optionsError != nil)
        draft.workers = [.init(count: 1, memory: "4g,count=3")]
        #expect(draft.optionsError != nil)
        draft.workers = []
        draft.cpus = "0"
        #expect(draft.optionsError != nil)
        draft.cpus = ""
        draft.network = .manifest
        #expect(draft.optionsError != nil)
    }
}
