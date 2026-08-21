import Foundation

/// Parsed `cstack` command line: a command, its positional arguments, global and local options.
public struct CStackInvocation: Equatable, Sendable {
    public static let defaultCommand = "doctor"

    private static let valueOptions: Set<String> = ["socket", "tail"]
    private static let flagAliases: [String: String] = ["a": "all", "f": "force", "h": "help"]

    public let command: String
    public let positional: [String]
    public let trailing: [String]
    public let passthrough: [String]
    public let options: [String: String]
    public let flags: Set<String>

    public var socketPath: String? {
        options["socket"]
    }

    public init(arguments: [String]) {
        var command: String?
        var positional: [String] = []
        var trailing: [String] = []
        var passthrough: [String] = []
        var options: [String: String] = [:]
        var flags: Set<String> = []

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            if argument == "--" {
                trailing = Array(arguments[index...])
                passthrough.append(contentsOf: trailing)
                break
            }

            guard argument.hasPrefix("-"), argument != "-" else {
                if command == nil {
                    command = argument
                } else {
                    positional.append(argument)
                    passthrough.append(argument)
                }
                continue
            }

            let name = Self.normalizedOptionName(argument)
            if Self.valueOptions.contains(name), index < arguments.count {
                options[name] = arguments[index]
                if name != "socket", command != nil {
                    passthrough.append(contentsOf: [argument, arguments[index]])
                }
                index += 1
            } else {
                flags.insert(name)
                if command != nil {
                    passthrough.append(argument)
                }
            }
        }

        self.command = command ?? Self.defaultCommand
        self.positional = positional
        self.trailing = trailing
        self.passthrough = passthrough
        self.options = options
        self.flags = flags
    }

    public func isSet(_ flag: String) -> Bool {
        flags.contains(flag)
    }

    public func value(_ option: String) -> String? {
        options[option]
    }

    public func intValue(_ option: String) -> Int? {
        options[option].flatMap(Int.init)
    }

    private static func normalizedOptionName(_ argument: String) -> String {
        let trimmed = String(argument.drop(while: { $0 == "-" }))
        return flagAliases[trimmed] ?? trimmed
    }
}
