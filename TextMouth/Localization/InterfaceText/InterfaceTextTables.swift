import Foundation

/// A problem in a pack or a table of interface text, in English, for the debug log and for tests. It never reaches a
/// person: the lookup falls back to English.
struct InterfaceTextFailure: Error, CustomStringConvertible, Equatable {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Where the lookup finds a language's lines: the IDs, and one entry for each ID in each language. The real source is
/// `InterfaceTextPack`, read from `Strings.pack`; tests make one in memory.
///
/// Decoding is separate from keeping: a source decodes what it is asked for and keeps nothing, and the engine
/// keeps the language in use, so a source's methods are plain and a lookup after the first decodes nothing.
protocol InterfaceTextTables: Sendable {
    /// The IDs of every line, in code-point order.
    func idList() throws -> InterfaceTextIDList

    /// One entry for each ID of `idList()`, in its order, for `language`; throws when the source has no such language
    /// or its entries are malformed.
    func entries(language: String) throws -> [InterfaceTextEntry]

    /// The translators' note of each ID, in the order of `idList()` ("" for none). Read only to write the person's file
    /// of own lines (Edit and Export Interface Text); a source with no notes answers none, and every note is then "".
    func notes() throws -> [String]
}

extension InterfaceTextTables {
    /// A source with no notes (a test's, in memory) has none.
    func notes() throws -> [String] { [] }
}

/// One entry of a language's table, as the pack writes it: nothing (English is used), a text, or the forms of a plural
/// line in the language's category order (`PluralRules.categories`).
enum InterfaceTextEntry: Sendable, Equatable {
    /// No text in this language: the line shows its English.
    case absent
    /// A text for every count.
    case plain(String)
    /// The forms of a plural line, one for each of the language's plural categories.
    case plural([String])

    /// The character that opens a plural entry and separates its forms.
    private static let pluralMark: Unicode.Scalar = "\u{1}"

    /// An entry from its raw text: empty is `absent`; U+0001 and the forms joined by U+0001 is a plural; anything else is
    /// a plain text. Nil when the raw text is not well formed: a control character the format keeps for itself
    /// (U+0001 inside a plain text, a NUL anywhere), or a plural whose form count is not `formCount` (nil when the
    /// language has no rule, which no plural can match).
    init?(raw: String, formCount: Int?) {
        let scalars = raw.unicodeScalars
        guard !scalars.contains("\u{0}") else { return nil }
        guard let first = scalars.first else {
            self = .absent
            return
        }
        guard first == Self.pluralMark else {
            guard !scalars.contains(Self.pluralMark) else { return nil }
            self = .plain(raw)
            return
        }
        let forms = scalars.dropFirst()
            .split(separator: Self.pluralMark, omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        guard forms.count == formCount else { return nil }
        self = .plural(forms)
    }

    /// Every entry of a decoded table blob: `bytes` hold the entries, each ended by a NUL (the last included). Throws
    /// when the entry count is not `count`, when bytes follow the last NUL, when an entry is not valid UTF-8, or when
    /// an entry is not well formed (`init?(raw:formCount:)`), so a damaged blob is refused whole.
    static func decodeAll(_ bytes: [UInt8], count: Int, formCount: Int?) throws -> [InterfaceTextEntry] {
        guard bytes.last == 0 || bytes.isEmpty else { throw InterfaceTextFailure("the last entry has no terminator") }  // l10n: no (English text for the debug log, never shown)
        var entries: [InterfaceTextEntry] = []
        entries.reserveCapacity(count)
        var start = 0
        for (index, byte) in bytes.enumerated() where byte == 0 {
            guard entries.count < count else { throw InterfaceTextFailure("more than \(count) entries") }  // l10n: no (English text for the debug log, never shown)
            let text = try validText(bytes[start..<index])
            guard let entry = InterfaceTextEntry(raw: text, formCount: formCount) else {
                throw InterfaceTextFailure("entry \(entries.count) is not well formed")  // l10n: no (English text for the debug log, never shown)
            }
            entries.append(entry)
            start = index + 1
        }
        guard entries.count == count else { throw InterfaceTextFailure("\(entries.count) entries, not \(count)") }  // l10n: no (English text for the debug log, never shown)
        return entries
    }

    /// The text of `bytes`, which must be valid UTF-8: decoding repairs a bad sequence with U+FFFD, so a text that
    /// does not encode back to the same bytes was not valid.
    static func validText(_ bytes: ArraySlice<UInt8>) throws -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.utf8.elementsEqual(bytes) else { throw InterfaceTextFailure("a text is not valid UTF-8") }  // l10n: no (English text for the debug log, never shown)
        return text
    }
}

/// The IDs of the lines, in code-point order, kept as one run of bytes so that a lookup finds an ID by binary search
/// over a `StaticString`'s own bytes, with no allocation.
struct InterfaceTextIDList: Sendable {
    /// Every ID's bytes, one after another, with no separators.
    private let bytes: [UInt8]
    /// Where each ID starts, and one more: the end of the last. `starts.count == count + 1`.
    private let starts: [Int]

    /// How many IDs there are.
    var count: Int { starts.count - 1 }

    /// The list of `ids`, which must be valid (an ID holds ASCII letters, digits, and dots, and is not empty) and in
    /// strictly ascending byte order, which is code-point order for ASCII: a binary search needs it, and an ID given
    /// twice would be ambiguous. Nil when they are not.
    init?(ids: [String]) {
        self.init(idBytes: ids.map { Array($0.utf8) })
    }

    /// The list of a decoded `ids` blob: IDs ended by a NUL or a line feed (the last one's terminator may be missing),
    /// exactly `count` of them, valid and ascending as `init?(ids:)` requires. Nil when they are not.
    init?(blob: [UInt8], count: Int) {
        var ids: [[UInt8]] = []
        var start = 0
        for (index, byte) in blob.enumerated() where byte == 0 || byte == UInt8(ascii: "\n") {
            ids.append(Array(blob[start..<index]))
            start = index + 1
        }
        if start < blob.count { ids.append(Array(blob[start...])) }
        guard ids.count == count else { return nil }
        self.init(idBytes: ids)
    }

    /// The shared tail of both initializers: validates each ID and keeps them as one run.
    private init?(idBytes: [[UInt8]]) {
        var bytes: [UInt8] = []
        var starts = [0]
        for (position, id) in idBytes.enumerated() {
            guard Self.isValid(id) else { return nil }
            // Strictly ascending: each ID sorts after the one before it, so none is given twice.
            if position > 0, !idBytes[position - 1].lexicographicallyPrecedes(id) { return nil }
            bytes.append(contentsOf: id)
            starts.append(bytes.count)
        }
        self.bytes = bytes
        self.starts = starts
    }

    /// Whether `id` is non-empty and holds only ASCII letters, digits, and dots.
    private static func isValid(_ id: [UInt8]) -> Bool {
        !id.isEmpty && id.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: ".")
        }
    }

    /// The position of `id` among the IDs, or nil when it is not one: a binary search that compares the bytes in place.
    func index(of id: StaticString) -> Int? {
        id.withUTF8Buffer { index(ofUTF8: $0) }
    }

    /// The position of the ID whose UTF-8 bytes are `target`, or nil: the search `index(of:)` makes, for a caller that
    /// holds the bytes already (a runtime ID: `InterfaceTextEngine.text(runtimeID:...)`).
    func index(ofUTF8 target: UnsafeBufferPointer<UInt8>) -> Int? {
        var low = 0
        var high = count - 1
        while low <= high {
            let middle = low + (high - low) / 2
            switch compare(middle, with: target) {
            case .orderedSame: return middle
            case .orderedAscending: low = middle + 1
            case .orderedDescending: high = middle - 1
            }
        }
        return nil
    }

    /// How the ID at `position` orders against `target`, byte by byte.
    private func compare(_ position: Int, with target: UnsafeBufferPointer<UInt8>) -> ComparisonResult {
        let start = starts[position]
        let length = starts[position + 1] - start
        for offset in 0..<min(length, target.count) {
            let mine = bytes[start + offset]
            let theirs = target[offset]
            if mine != theirs { return mine < theirs ? .orderedAscending : .orderedDescending }
        }
        if length == target.count { return .orderedSame }
        return length < target.count ? .orderedAscending : .orderedDescending
    }

    /// The ID at `position` as a string (for a report, never for a lookup).
    func id(at position: Int) -> String {
        String(decoding: bytes[starts[position]..<starts[position + 1]], as: UTF8.self)
    }
}
