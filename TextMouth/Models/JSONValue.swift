import Foundation

/// A JSON value kept exactly as read, so a row this TextMouth cannot read is
/// written back as it was (V03): a book a later TextMouth added in a format
/// this one does not know stays in library.json untouched. V04 may reuse it
/// for the keys a record holds that this version does not know.
///
/// Integers stay integers (`3` is written back as `3`, never `3.0`), and a
/// date stays the string it was, since it is only text here. A whole number
/// above `Int64.max` that a `UInt64` holds stays exact too (`unsigned`).
///
/// Two kinds of number do not come back digit for digit, since each is held
/// as a `Double`: a whole number beyond `UInt64`, and a fraction of more
/// than about 17 significant digits. TextMouth writes neither: every number
/// in its files is an `Int`, an `Int64`, or a `Double`, which `JSONEncoder`
/// writes in the shortest form that reads back as the same `Double`. A
/// number is also written in `JSONEncoder`'s form (`1.50` comes back as
/// `1.5`, and `1.0` as `1`), which is the form TextMouth wrote it in.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    /// A whole number above `Int64.max`, which an `Int64` cannot hold and a
    /// `Double` would round (V04): kept exact, as an identifier or a hash a
    /// later TextMouth stores might need.
    case unsigned(UInt64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// How deeply a value may nest. The file a value is read from is
    /// untrusted, so a value nested deeper is refused instead of recursing
    /// until the stack runs out.
    static let maximumDepth = 64

    // MARK: - Reading

    /// Reads whatever JSON value is there. The kinds are tried in a fixed
    /// order: null, bool, integer, unsigned, number, string, array, object. A bool is
    /// never read as an integer (the decoder keeps `true` apart from `1`),
    /// and a number that is not whole stays a number.
    ///
    /// Throws `DecodingError.dataCorrupted` when the value nests deeper than
    /// `maximumDepth`, measured by the decoder's coding path, or when it is
    /// none of the kinds above.
    init(from decoder: Decoder) throws {
        // The check comes first, so no branch below can recurse past it.
        guard decoder.codingPath.count <= Self.maximumDepth else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "A JSON value is nested deeper than the limit of \(Self.maximumDepth) levels." // l10n: no (damage reason: what is wrong inside a file stays English, question 3)
                )
            )
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let whole = try? container.decode(Int64.self) {
            self = .integer(whole)
        } else if let large = try? container.decode(UInt64.self) {
            // Only a whole number above `Int64.max` reaches here.
            self = .unsigned(large)
        } else if let fraction = try? container.decode(Double.self) {
            self = .number(fraction)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try Self.decodeIfShaped(as: [JSONValue].self, from: container) {
            self = .array(items)
        } else if let members = try Self.decodeIfShaped(as: [String: JSONValue].self, from: container) {
            self = .object(members)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "The value is not a JSON null, bool, number, string, array, or object." // l10n: no (damage reason: what is wrong inside a file stays English, question 3)
                )
            )
        }
    }

    /// Decodes `type` from `container`, or returns nil when the value is of
    /// another shape (a type mismatch). Any other error, such as the depth
    /// limit being passed inside an array, is thrown, so it is never mistaken
    /// for a value of another kind.
    private static func decodeIfShaped<Value: Decodable>(
        as type: Value.Type,
        from container: SingleValueDecodingContainer
    ) throws -> Value? {
        do {
            return try container.decode(type)
        } catch DecodingError.typeMismatch {
            return nil
        }
    }

    // MARK: - Writing

    /// Writes the value as the JSON it was: each case in its own form.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let flag): try container.encode(flag)
        case .integer(let whole): try container.encode(whole)
        case .unsigned(let large): try container.encode(large)
        case .number(let fraction): try container.encode(fraction)
        case .string(let text): try container.encode(text)
        case .array(let items): try container.encode(items)
        case .object(let members): try container.encode(members)
        }
    }

    // MARK: - Convenience

    /// The member named `key` when this value is an object that has one;
    /// nil for any other value or a missing member.
    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    /// The text of a string value; nil for any other kind of value.
    var stringValue: String? {
        guard case .string(let text) = self else { return nil }
        return text
    }
}
