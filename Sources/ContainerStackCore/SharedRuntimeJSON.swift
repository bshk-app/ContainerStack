import CoreFoundation
import Foundation

/// A JSON value as written, for checks that must see keys the typed models drop.
enum SharedRuntimeJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// A number written with no fraction or exponent; other numbers are `.number`.
    case integer(Int)
    case number(Double)
    case string(String)
    case array([SharedRuntimeJSON])
    case object([String: SharedRuntimeJSON])

    /// Parses with `JSONSerialization`, which keeps `1` and `1.0` apart; `JSONDecoder` decodes
    /// both as the integer 1.
    static func parse(_ data: Data) throws -> SharedRuntimeJSON {
        try SharedRuntimeJSON(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    private init(_ value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if Self.integerTypes.contains(String(cString: number.objCType)), !(number is NSDecimalNumber),
                let integer = Int(exactly: number)
            {
                self = .integer(integer)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(try array.map(SharedRuntimeJSON.init))
        case let object as [String: Any]:
            self = .object(try object.mapValues(SharedRuntimeJSON.init))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unexpected JSON value"))
        }
    }

    private static let integerTypes: Set<String> = ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]

    var objectValue: [String: SharedRuntimeJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// null, false, 0, an empty string, an empty array or an empty object.
    var isEmptyDefault: Bool {
        switch self {
        case .null: true
        case .bool(let value): !value
        case .integer(let value): value == 0
        case .number(let value): value == 0
        case .string(let value): value.isEmpty
        case .array(let value): value.isEmpty
        case .object(let value): value.isEmpty
        }
    }

}
