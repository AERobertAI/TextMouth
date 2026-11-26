import Foundation

/// How a value of the library becomes a `JSONValue` in a sync entry, and
/// back (FR43). One place holds it, so the projection, the applier, and the
/// change files agree on every byte: sorted keys, and dates written to the
/// second as ISO 8601 text.
enum SyncValueCoding {
    /// An encoder with the formats' fixed settings: sorted keys, dates to the second.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// A decoder that reads what `makeEncoder()` wrote.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The value of `thing`, or `.null` when it cannot be encoded (which a
    /// value of the library's own types never fails to be). A caller that makes
    /// many values passes one `encoder` for all.
    static func json<Thing: Encodable>(_ thing: Thing, using encoder: JSONEncoder? = nil) -> JSONValue {
        guard let data = try? (encoder ?? makeEncoder()).encode(thing),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return value
    }

    /// The `Thing` that `value` holds, or nil when it holds none.
    static func decode<Thing: Decodable>(_ type: Thing.Type, from value: JSONValue) -> Thing? {
        guard let data = try? makeEncoder().encode(value) else { return nil }
        return try? makeDecoder().decode(type, from: data)
    }

    /// A date as the text a value holds it in, to the second.
    static func json(date: Date?, using encoder: JSONEncoder? = nil) -> JSONValue {
        date.map { json($0, using: encoder) } ?? .null
    }

    /// The date a value holds, or nil for `.null` or text that is no date.
    static func date(from value: JSONValue) -> Date? {
        decode(Date.self, from: value)
    }

    /// A number as a value: a whole number is an integer, as a file reads it
    /// back, so a value compares equal to one read from a file.
    static func number(_ number: Double?) -> JSONValue {
        guard let number, number.isFinite else { return .null }
        if number == number.rounded(), abs(number) < 1e15 { return .integer(Int64(number)) }
        return .number(number)
    }

    /// The number a value holds, whole or not; nil for any other value.
    static func double(from value: JSONValue) -> Double? {
        switch value {
        case .integer(let whole): return Double(whole)
        case .number(let fraction): return fraction
        default: return nil
        }
    }

    /// A string, or `.null` for none.
    static func string(_ text: String?) -> JSONValue {
        text.map { .string($0) } ?? .null
    }

    /// An ID as the lower-case text a file holds, or `.null` for none.
    static func id(_ id: UUID?) -> JSONValue {
        id.map { .string($0.uuidString.lowercased()) } ?? .null
    }

    /// The ID a value holds as text; nil for `.null` or text that is no ID.
    static func uuid(from value: JSONValue) -> UUID? {
        value.stringValue.flatMap { UUID(uuidString: $0) }
    }

    /// `value` as JSON text with sorted keys: the same text for equal
    /// values on every device, which breaks a tie between two entries.
    static func canonicalText(of value: JSONValue) -> String {
        guard let data = try? makeEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A bookmark as a sync entry holds it: everything but its `id`, which is in
/// the key, and its `number`, which removals renumber.
struct SyncBookmarkValue: Codable, Equatable, Sendable {
    var chapterIndex: Int
    var characterOffset: Int
    var label: String
    var dateCreated: Date
    var anchor: TextAnchor?

    /// The value of `bookmark`.
    init(_ bookmark: Bookmark) {
        chapterIndex = bookmark.chapterIndex
        characterOffset = bookmark.characterOffset
        label = bookmark.label
        dateCreated = bookmark.dateCreated
        anchor = bookmark.anchor
    }

    /// The bookmark this value makes, numbered `number`.
    func bookmark(id: UUID, number: Int) -> Bookmark {
        Bookmark(
            id: id, number: number, chapterIndex: chapterIndex, characterOffset: characterOffset,
            label: label, dateCreated: dateCreated, anchor: anchor
        )
    }
}

/// A book's three lists of skipped headings as one value (the plan's
/// `skippedHeadings` key): the headings skipped by their place, the heading
/// IDs older builds read, and the skips that wait for a heading to come back.
struct SyncSkippedHeadingsValue: Codable, Equatable, Sendable {
    var skipped: [SkippedHeading]
    var ids: [String]
    var waiting: [SkippedHeading]

    /// The value of `book`'s three lists; none is an empty list.
    init(_ book: Book) {
        skipped = book.skippedHeadings ?? []
        ids = book.skippedHeadingIDs ?? []
        waiting = book.waitingSkippedHeadings ?? []
    }

    /// Writes the three lists to `book`, an empty one as none.
    func write(to book: inout Book) {
        if !skipped.isEmpty {
            // The headings make the IDs, in step.
            book.setSkippedHeadings(skipped)
        } else if !ids.isEmpty {
            // A row that holds IDs alone, as an older build wrote it.
            book.skippedHeadingIDs = ids
        } else {
            book.setSkippedHeadings(nil)
        }
        book.waitingSkippedHeadings = waiting.isEmpty ? nil : waiting
    }
}
