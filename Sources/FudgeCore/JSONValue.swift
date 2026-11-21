import Foundation

/// Any JSON value, for manifest fields whose type depends on context (a preference's `default`, …).
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// Parses JSON text through `JSONSerialization`, about ten times faster than `JSONDecoder`, whose path goes
    /// through `init(from:)` above, trying each type in turn. Throws for what `JSONSerialization` refuses.
    public static func parse(_ data: Data) throws -> JSONValue {
        JSONValue(foundation: try JSONSerialization.jsonObject(with: data))
    }

    /// Converts what `JSONSerialization` returns.
    init(foundation object: Any) {
        if let object = object as? [String: Any] {
            self = .object(object.mapValues(JSONValue.init(foundation:)))
        } else if let string = object as? String {
            self = .string(string)
        } else if let number = object as? NSNumber {
            self = Self.value(of: number)
        } else if let array = object as? [Any] {
            self = .array(array.map(JSONValue.init(foundation:)))
        } else {
            self = .null
        }
    }

    /// A number as `JSONDecoder` reads it. `JSONSerialization` gives an `NSDecimalNumber` for 16 or more significant
    /// digits and for integers past `Int64`; its digits are exact, but its `doubleValue` can be a step off the
    /// correctly rounded `Double`, so it's read from its text. Other numbers are an `Int64`, `UInt64` or `Double`
    /// already, and their `doubleValue` is exact. (`-0` reads as 0 here and -0 in `JSONDecoder`, but
    /// `JSON.stringify` never writes it.)
    private static func value(of number: NSNumber) -> JSONValue {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        if number is NSDecimalNumber, let exact = Double(number.stringValue) { return .number(exact) }
        return .number(number.doubleValue)
    }
}
