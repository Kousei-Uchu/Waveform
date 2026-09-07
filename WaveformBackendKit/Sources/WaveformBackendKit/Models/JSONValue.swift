import Foundation

/// A minimal `Codable`, `Hashable` representation of an arbitrary JSON value.
///
/// `info.json`'s `album_meta` / `author_meta` fields are deliberately
/// open-ended ("any other parts you think are appropriate may be added"),
/// so they're modeled as `[String: JSONValue]` instead of a fixed struct.
public enum JSONValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public extension JSONValue {
    /// Convenience accessors for reading values back out without a `switch`.
    var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    var numberValue: Double? { if case .number(let v) = self { v } else { nil } }
    var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    var objectValue: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
}
