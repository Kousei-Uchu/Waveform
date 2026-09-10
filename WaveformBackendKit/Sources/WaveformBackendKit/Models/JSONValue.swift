import Foundation
import CoreFoundation

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

public extension JSONValue {
    /// Converts a loosely-typed value from `JSONSerialization` (what
    /// every REST client in this package — `SpotifyClient`, `GeniusClient`
    /// — actually gets back from `JSONSerialization.jsonObject`) into a
    /// `JSONValue`. Needed because `album_meta`/`author_meta` are meant to
    /// carry the *real* Spotify object (spec: "full Spotify Album object,
    /// a slim fallback, or `{}`") rather than a hand-picked subset of
    /// fields — without this, there was no way to turn Spotify's raw
    /// `[String: Any]` album/artist dictionaries into the `Codable`
    /// `[String: JSONValue]` shape `MediaInfoDocument` actually stores,
    /// so those fields only ever got written as `{}`.
    ///
    /// Unrecognized/unbridgeable types (anything not covered below) become
    /// `.null` rather than throwing or dropping the key — `NSNumber`
    /// covers both `Bool` and every numeric type `JSONSerialization`
    /// produces (Foundation bridges them all through `NSNumber` on both
    /// Apple platforms and swift-corelibs-foundation), so it has to be
    /// checked before the generic numeric/string cases, and specifically
    /// checked for its `Bool` case first since `NSNumber`'s own `Bool`
    /// bridging is otherwise indistinguishable from `0`/`1`.
    static func from(_ value: Any) -> JSONValue {
        switch value {
        case is NSNull:
            return .null
        case let number as NSNumber:
            // `CFGetTypeID`/`CFBooleanGetTypeID` is the standard way to
            // tell a boxed `Bool` (`CFBoolean` under the hood) apart from
            // a boxed numeric `NSNumber` — `number.objCType` is `"c"` for
            // both a `Bool` and a plain `Int8`, so it can't disambiguate
            // on its own.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let bool as Bool:
            return .bool(bool)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map(JSONValue.from))
        case let dict as [String: Any]:
            return .object(dict.mapValues(JSONValue.from))
        default:
            return .null
        }
    }

    /// Convenience for the common case of converting a whole
    /// `[String: Any]` dictionary (a decoded Spotify/Genius JSON object)
    /// straight into the `[String: JSONValue]` shape `album_meta`/
    /// `author_meta` are stored as.
    static func object(from dict: [String: Any]) -> [String: JSONValue] {
        dict.mapValues(JSONValue.from)
    }
}
