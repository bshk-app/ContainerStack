import Containerization
import ContainerizationOCI
import Foundation

// Spike A/C: prove a third-party SPM binary can (1) link Apple's Containerization
// public API and (2) read Apple Container's on-disk image store, read-only.

let store = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/com.apple.containerization")

print("== ContainerizationOCI ==")
print("index      = \(MediaTypes.index)")
print("dockerList = \(MediaTypes.dockerManifestList)")

print("\n== LinuxContainer.Configuration defaults ==")
var cfg = LinuxContainer.Configuration()
cfg.cpus = 2
cfg.memoryInBytes = 2048 * 1024 * 1024
cfg.process.arguments = ["/bin/sh", "-c", "echo hi"]
print("cpus=\(cfg.cpus) memMiB=\(cfg.memoryInBytes / 1024 / 1024) mounts=\(cfg.mounts.count) virtualization=\(cfg.virtualization)")

print("\n== ImageStore over Apple Container's store ==")
print("path = \(store.path)")
do {
    let imageStore = try ImageStore(path: store)
    let images = try await imageStore.list()
    print("images found = \(images.count)")
    for img in images.prefix(12) {
        print("  - \(img.reference)  [\(img.descriptor.mediaType)]  \(img.descriptor.size)B")
    }
} catch {
    print("ImageStore error: \(error)")
}
