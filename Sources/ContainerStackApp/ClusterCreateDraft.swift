import Foundation

struct ClusterCreateDraft {
    enum Network: String, CaseIterable, Identifiable {
        case kindnet = "kindnet"
        case manifest = "Manifest file"
        case none = "None"

        var id: Self { self }
    }

    struct WorkerGroup: Identifiable {
        let id = UUID()
        var count = 1
        var cpus = ""
        var memory = ""

        var option: String {
            var fields = ["count=\(count)"]
            if !cpus.isEmpty { fields.append("cpus=\(cpus)") }
            if !memory.isEmpty { fields.append("memory=\(memory)") }
            return fields.joined(separator: ",")
        }
    }

    var name = ""
    var cpus = ""
    var memory = ""
    var workers: [WorkerGroup] = []
    var nodeImage = ""
    var network = Network.kindnet
    var manifestPath = ""
    var sharedImageStore = false

    func nameError(existing: Set<String>) -> String? {
        let bytes = name.utf8
        guard (1...63).contains(bytes.count), let first = bytes.first, let last = bytes.last,
            Self.isLetterOrDigit(first), Self.isLetterOrDigit(last),
            bytes.allSatisfy({ Self.isLetterOrDigit($0) || $0 == 45 })
        else { return "Use 1 to 63 lowercase letters, digits, or hyphens. Start and end with a letter or digit." }
        return existing.contains(name) ? "A cluster already uses this name." : nil
    }

    var optionsError: String? {
        var remaining = 1024
        for group in workers {
            guard group.count > 0, group.count <= remaining else {
                return "Use 1 to 1024 workers across all groups."
            }
            remaining -= group.count
        }
        guard Self.validCPUs(cpus), workers.allSatisfy({ Self.validCPUs($0.cpus) }) else {
            return "Enter a positive whole number for CPUs."
        }
        guard Self.validMemory(memory), workers.allSatisfy({ Self.validMemory($0.memory) }) else {
            return "Enter a memory size such as 6g or 2048m."
        }
        if network == .manifest, !manifestPath.hasPrefix("/") {
            return "Choose a network manifest file."
        }
        return nil
    }

    var options: [String] {
        var arguments: [String] = []
        if !cpus.isEmpty { arguments += ["--cpus", cpus] }
        if !memory.isEmpty { arguments += ["--memory", memory] }
        for group in workers { arguments += ["--workers", group.option] }
        if !nodeImage.isEmpty { arguments += ["--node-image", nodeImage] }
        switch network {
        case .kindnet: break
        case .manifest: arguments += ["--cni", manifestPath]
        case .none: arguments += ["--cni", "NONE"]
        }
        if sharedImageStore { arguments.append("--shared-image-store") }
        return arguments
    }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || (48...57).contains(byte)
    }

    private static func validCPUs(_ value: String) -> Bool {
        value.isEmpty || (Int(value) ?? 0) > 0
    }

    private static func validMemory(_ value: String) -> Bool {
        value.isEmpty || (!value.hasPrefix("-") && !value.contains(",") && !value.contains("="))
    }
}
