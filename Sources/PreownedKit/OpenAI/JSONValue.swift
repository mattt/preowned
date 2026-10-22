import Foundation

/// An arbitrary JSON value,
/// used for request fields that preowned inspects but does not model,
/// such as JSON Schema documents and tool definitions.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
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
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a JSON value."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
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
    /// The string value, if this value is a string.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The number value, if this value is a number.
    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The integer value, if this value is a number without a fractional part.
    public var integerValue: Int? {
        guard case .number(let value) = self,
            value.rounded() == value,
            let integer = Int(exactly: value)
        else { return nil }
        return integer
    }

    /// The Boolean value, if this value is a Boolean.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The elements, if this value is an array.
    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// The members, if this value is an object.
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
