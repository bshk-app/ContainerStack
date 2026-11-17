public enum SharedRuntimesFlag {
    public static func needed(for state: RuntimeGroupsFile.State) -> Bool {
        switch state {
        case .missing: false
        case .invalid: true
        case .valid(let document): document.groups.contains { $0.isActive }
        }
    }
}
