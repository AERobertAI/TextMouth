import Foundation

/// The members of a stored JSON object that this TextMouth does not know
/// (V04): keys a later TextMouth added to a library row, a package record,
/// config.json, or an object inside one of them. They are read with the
/// object, held beside its fields, and written back with it exactly as they
/// were, so opening a library in an older TextMouth and saving it loses
/// nothing a later one keeps there.
///
/// The rules every type that keeps them follows:
///
/// - **A known key always wins.** A name is unknown only when it is not one
///   of the type's coding keys; a type writes its unknown members first and
///   its own fields after them, so no member can ever stand over a field.
/// - **They are never read for meaning**, and nothing changes them: a save
///   writes back what the load read.
/// - **They belong to their object.** A copy keeps them, and so does a change
///   made to a field of the object in place. An object this TextMouth makes
///   anew (a reading position at another place, a fingerprint of rewritten
///   files) starts with none: what a later TextMouth noted about the object
///   that was replaced would describe the wrong one. Where TextMouth makes
///   an object anew though the thing it describes is the same, the new one
///   is given the old one's: a reading position saved again at the place it
///   holds (`ReadingPosition.keepingUnknownKeys(ofSamePlaceIn:)`), a skipped
///   heading that still names its heading after the text was read again.
/// - **They take part in `==`** (see `==` below) **and not in hashing**
///   (`hash(into:)`).
/// - **Keys are written sorted**, as every file TextMouth writes sorts its
///   keys, and an array keeps its order (`JSONValue`).
///
/// A type keeps them in one of two ways:
///
/// - A type that codes itself by hand (`Book`, `ReadingPosition`, …) reads
///   them at the end of its `init(from:)` with `init(from:besides:)` and
///   writes them at the start of its `encode(to:)` with `write(to:)`.
/// - A type whose coding Swift synthesizes (`BookMetadata`, `BookState`,
///   `ConfigService.AppConfig`) declares `var unknownKeys = UnknownKeys()`
///   and conforms to `KeepsUnknownKeysBesideSynthesizedCoding`. Its
///   synthesized coding passes the property over (the keyed-container
///   extensions at the end of this file), and whoever reads or writes the
///   object does so through `WithUnknownKeys`.
///
/// An object without unknown members, which is every object a TextMouth of
/// this version or an earlier one wrote, holds an empty dictionary (one
/// word, nothing allocated) and is written exactly as before.
struct UnknownKeys: Sendable {
    /// The unknown members, by name. Never holds a name its object knows,
    /// when read from a file.
    private(set) var members: [String: JSONValue]

    /// No unknown members: what every object made here starts with.
    init() {
        members = [:]
    }

    /// The unknown members `members`, as a test or a merge states them.
    init(_ members: [String: JSONValue]) {
        self.members = members
    }

    /// Whether there are none, as for every object this version wrote.
    var isEmpty: Bool {
        members.isEmpty
    }

    // MARK: - Reading

    /// Reads, from the JSON object `decoder` is at, every member whose name
    /// is not in `knownNames`: the coding keys of the type being decoded
    /// there (`CodingKey.names(of:)`).
    ///
    /// Never fails its object: a decoder that is not at an object gives no
    /// members, and a member that cannot be kept (one nested deeper than
    /// `JSONValue.maximumDepth`) is left out, as every unknown member was
    /// before they were kept.
    init(from decoder: Decoder, besides knownNames: Set<String>) {
        self.init(from: decoder) { knownNames.contains($0) }
    }

    /// Reads, from the JSON object `decoder` is at, every member whose name
    /// `isKnown` rejects. The form for a type with synthesized coding keys,
    /// which can say whether a name is one of them but cannot list them.
    ///
    /// A decoder told that its bytes hold no unknown key
    /// (`StoredKeyScan.userInfo(forDecoding:schema:)`) is believed, and
    /// nothing is looked for: opening a second container and listing its
    /// keys is the whole cost of keeping unknown keys, paid for every
    /// object of a library index unless the scan spares it.
    init(from decoder: Decoder, isKnown: (String) -> Bool) {
        members = [:]
        guard !StoredKeyScan.foundNoUnknownKeys(for: decoder),
              let container = try? decoder.container(keyedBy: AnyCodingKey.self) else { return }
        for key in container.allKeys where !isKnown(key.stringValue) {
            // `try?`: an unreadable member is left out (see above).
            if let value = try? container.decode(JSONValue.self, forKey: key) {
                members[key.stringValue] = value
            }
        }
    }

    // MARK: - Writing

    /// Writes the members into the JSON object `encoder` is at, beside the
    /// fields its type writes. Call it before the type's own fields are
    /// encoded, so a field written under the same name replaces the member
    /// (a known key always wins). With no members it does nothing at all,
    /// not even opening a container.
    func write(to encoder: Encoder) throws {
        guard !members.isEmpty else { return }
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        for (name, value) in members {
            try container.encode(value, forKey: AnyCodingKey(name))
        }
    }
}

// MARK: - Equality and Hashing

extension UnknownKeys: Hashable {
    /// Unknown members take part in equality: two rows that differ only in a
    /// key a later TextMouth wrote are different rows. Everything that asks
    /// whether stored state changed asks `==` (a save that writes only when
    /// the library differs from the one saved, a merge that takes another
    /// copy's row only when it differs, config.json's reload when the file
    /// differs from the settings in use), and each must notice such a
    /// change, or the newer value on disk would be written over with the
    /// older one held here. The library's views compare rows too, and are
    /// only asked to draw a row again that did change. Two empty sets
    /// compare in a few instructions.
    static func == (lhs: UnknownKeys, rhs: UnknownKeys) -> Bool {
        lhs.members == rhs.members
    }

    /// Unknown members add nothing to a hash, which is allowed (equal values
    /// still hash alike) and keeps hashing a row exactly as cheap as it was:
    /// a row is found by its fields, and two rows alike in every field but
    /// an unknown member are too rare to slow a table down.
    func hash(into hasher: inout Hasher) {}
}

// MARK: - A Key of Any Name

/// A coding key that can name any member of a JSON object, for reading and
/// writing members whose names are not known in advance.
struct AnyCodingKey: CodingKey {
    let stringValue: String

    /// Members are named by text, never by position.
    var intValue: Int? { nil }

    /// The key named `name`.
    init(_ name: String) {
        stringValue = name
    }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    /// Members are named by text, never by position.
    init?(intValue: Int) {
        nil
    }
}

extension CodingKey where Self: CaseIterable {
    /// The names of every key of this type: what a type that codes itself by
    /// hand passes to `UnknownKeys.init(from:besides:)`. Keep the result in
    /// a `static let`, so the set is built once.
    static var names: Set<String> {
        Set(allCases.map(\.stringValue))
    }
}

// MARK: - Types That Keep Them

/// A stored object that keeps the members it does not know.
protocol KeepsUnknownKeys {
    /// The members of the stored object that this TextMouth does not know.
    var unknownKeys: UnknownKeys { get set }
}

/// A stored object that keeps the members it does not know, and whose
/// `Codable` coding Swift synthesizes, in whole or in part. Its synthesized
/// coding passes `unknownKeys` over, so the object is read and written
/// through `WithUnknownKeys` wherever its unknown members matter.
protocol KeepsUnknownKeysBesideSynthesizedCoding: KeepsUnknownKeys, Codable {
    /// Whether `name` is one of the type's coding keys. Implement it inside
    /// the type as `CodingKeys(stringValue: name) != nil`: the synthesized
    /// keys are private to the type.
    static func isCodingKey(_ name: String) -> Bool
}

/// The name of the property every keeping type holds its unknown members
/// in. A synthesized `CodingKeys` has a case of this name, though nothing is
/// ever written under it, so a member of this name in a file is unknown too.
private let unknownKeysPropertyName = "unknownKeys"

extension KeepsUnknownKeysBesideSynthesizedCoding {
    /// Whether `name` is a member the type's own coding reads and writes:
    /// one of its coding keys, other than the name of the property that
    /// holds the unknown ones. What `WithUnknownKeys` keeps apart from the
    /// unknown members, and what the type's `StoredKeySchema` knows.
    static func isStoredKey(_ name: String) -> Bool {
        name != unknownKeysPropertyName && isCodingKey(name)
    }
}

/// A value read and written together with its unknown members: the value's
/// own coding, and beside it, in the same JSON object, the members it does
/// not know. For a `KeepsUnknownKeysBesideSynthesizedCoding` type; a type
/// that codes itself by hand needs no wrapper.
struct WithUnknownKeys<Value: KeepsUnknownKeysBesideSynthesizedCoding>: Codable {
    /// The value, holding its unknown members.
    var value: Value

    /// Wraps `value` for writing.
    init(_ value: Value) {
        self.value = value
    }

    /// Reads the value as its own coding reads it, then the members of the
    /// same object that are none of its coding keys.
    init(from decoder: Decoder) throws {
        value = try Value(from: decoder)
        value.unknownKeys = UnknownKeys(from: decoder, isKnown: Value.isStoredKey)
    }

    /// Writes the unknown members, then the value over them, so a field
    /// always wins.
    func encode(to encoder: Encoder) throws {
        try value.unknownKeys.write(to: encoder)
        try value.encode(to: encoder)
    }
}

// MARK: - Synthesized Coding Passes Them Over

// Swift's synthesized `init(from:)` and `encode(to:)` read and write every
// stored property through its keyed container, choosing the most specific
// `decode` and `encode` there is. These two are the most specific for an
// `UnknownKeys` property, and they read and write nothing: the members do
// not live under a key of their own but beside the object's fields, where
// `WithUnknownKeys` puts them. Without them a synthesized type would write
// an "unknownKeys" member into its file, which `UnknownKeysTests` and
// `OnDiskContractTests` would catch.

extension KeyedDecodingContainer {
    /// An `UnknownKeys` property of a type with synthesized decoding: none
    /// here; `WithUnknownKeys` reads them from the whole object.
    func decode(_ type: UnknownKeys.Type, forKey key: Key) throws -> UnknownKeys {
        UnknownKeys()
    }
}

extension KeyedEncodingContainer {
    /// An `UnknownKeys` property of a type with synthesized encoding:
    /// nothing is written under its key; `WithUnknownKeys` writes the
    /// members beside the fields.
    mutating func encode(_ value: UnknownKeys, forKey key: Key) throws {}
}

extension UnknownKeys: Codable {
    /// Required for a property of a synthesized `Codable` type, and reached
    /// only if something decodes an `UnknownKeys` on its own: every member
    /// of the object the decoder is at.
    init(from decoder: Decoder) throws {
        self.init(from: decoder, besides: [])
    }

    /// Required for a property of a synthesized `Codable` type: the members,
    /// into the object the encoder is at (`write(to:)`).
    func encode(to encoder: Encoder) throws {
        try write(to: encoder)
    }
}
