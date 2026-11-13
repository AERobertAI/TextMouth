import Foundation

// MARK: - The Lines That May Hold a Match

/// What a literal search looks for among a chapter's UTF-8 bytes before
/// Foundation's search decides (LIBRARY-SEARCH-RESEARCH-2026-11-13.md,
/// section 3): the lines that may hold a match. A chapter with none is passed
/// over without being decoded; any other is searched whole by
/// `BookTextSearch.Matcher`, with Search in Book's own calls, so the prefilter
/// changes how fast a search is and never what it finds. (No line is searched
/// on its own: Foundation does not answer a short range as it answers the
/// same text inside a longer one.)
///
/// It is sound because of three facts, each pinned by a test:
/// - A literal query that holds no line feed or carriage return matches no
///   line feed, so every match lies within one line, and a chapter with no
///   line a match can lie in can be passed over.
/// - The query's anchor, a run of its ASCII characters none of which stands
///   beside a non-ASCII one, is matched by Foundation's search either by the
///   same bytes, letters in either case when case is ignored, or by text
///   that holds one of the few non-ASCII characters Foundation can match
///   against ASCII alone (`LibrarySearchSpecials`: the Kelvin sign, the long
///   s, ß, the Latin ligatures, a digit's compatibility forms, ...) standing
///   for one of the anchor's characters. No ASCII byte is ever part of a
///   longer UTF-8 sequence, so the anchor's bytes are found only where those
///   characters are.
/// - An ASCII character beside a non-ASCII one in the query is left out of
///   the anchor, since the two may stand together for one character of the
///   text that holds neither's bytes: e and a combining acute for é, ʼ and n
///   for ŉ, 1, the fraction slash, and 4 for ¼.
///
/// So a line is a candidate when it holds the anchor's bytes, or a special
/// character that can stand for one of them. A query with no ASCII to anchor
/// on, a regular expression, and a query holding a line feed or carriage
/// return have no prefilter: their chapters are searched whole.
struct LibrarySearchPrefilter: Sendable {
    /// The bytes to find: the query's longest usable run of ASCII
    /// characters, its letters in lower case when case is ignored.
    let anchor: [UInt8]
    /// Whether letters match in either case.
    let ignoresCase: Bool
    /// Which byte of the anchor the scan looks for: its rarest in English
    /// prose, so the fewest positions need the whole anchor checked.
    let keyIndex: Int
    /// For each byte value: `keyFlag` for the key byte (in both cases when
    /// case is ignored), `specialFlag` for the first byte of a special
    /// character's UTF-8, and zero for every other byte.
    private let byteFlags: [UInt8]
    /// The special characters a candidate line may hold instead of the
    /// anchor: those of the tables, for this search's handling of case, that
    /// can stand for one of the anchor's characters.
    private let specials: Set<UInt32>
    /// Whether the anchor holds a digit or the punctuation of numbered forms,
    /// so that any character with a numeric value may stand for part of it
    /// (`LibrarySearchSpecials.hasNumericValue`).
    private let numericFormsMatter: Bool

    /// The flag of the anchor's key byte.
    private static let keyFlag: UInt8 = 1
    /// The flag of a byte that begins a special character.
    private static let specialFlag: UInt8 = 2

    /// The prefilter for `query` searched with `options`, or nil when it has
    /// none: a regular expression, a query that holds a line feed or a
    /// carriage return, and one with no ASCII character to anchor on.
    init?(query: String, options: TextSearchOptions) {
        guard !options.isRegularExpression,
              let anchor = Self.anchor(of: query, ignoringCase: !options.matchCase) else { return nil }
        self.anchor = anchor
        ignoresCase = !options.matchCase
        // A special character matters only where it can stand for one of the
        // anchor's characters: a circled digit for a query with no digit
        // makes no line a candidate.
        let anchorCharacters = Set(anchor)
        let ignoring = !options.matchCase
        specials = LibrarySearchSpecials.characters(ignoringCase: ignoring).filter { value in
            !(LibrarySearchSpecials.standsFor(value, ignoringCase: ignoring) ?? Set(0...0x7F)).isDisjoint(with: anchorCharacters)
        }
        numericFormsMatter = !LibrarySearchSpecials.numericStandsFor.isDisjoint(with: anchorCharacters)
        keyIndex = Self.rarestIndex(in: anchor)

        var flags = [UInt8](repeating: 0, count: 256)
        let key = anchor[keyIndex]
        flags[Int(key)] |= Self.keyFlag
        if ignoresCase, let upper = Self.upperCase(of: key) {
            flags[Int(upper)] |= Self.keyFlag
        }
        // Each special character's first UTF-8 byte; every one is non-ASCII.
        // Characters with a numeric value are found in every script, so
        // when they matter every byte that begins a character is looked at.
        for value in specials {
            if let scalar = Unicode.Scalar(value), let lead = String(scalar).utf8.first, lead >= 0x80 {
                flags[Int(lead)] |= Self.specialFlag
            }
        }
        if numericFormsMatter {
            for lead in 0xC2...0xF4 {
                flags[lead] |= Self.specialFlag
            }
        }
        byteFlags = flags
    }

    // MARK: Choosing the Anchor

    /// The anchor of `query`: its longest run of ASCII characters none of
    /// which stands beside a non-ASCII character, its letters in lower case
    /// when case is ignored; the first of the longest when several are as
    /// long. Nil when the query holds a line feed or carriage return, or no
    /// ASCII character to anchor on.
    static func anchor(of query: String, ignoringCase: Bool) -> [UInt8]? {
        let scalars = Array(query.unicodeScalars)
        guard !scalars.contains(where: { $0 == "\n" || $0 == "\r" }) else { return nil }
        var best: [UInt8] = []
        var run: [UInt8] = []
        for (index, scalar) in scalars.enumerated() {
            let before = index > 0 ? scalars[index - 1] : nil
            let after = index + 1 < scalars.count ? scalars[index + 1] : nil
            let besideNonASCII = !(before?.isASCII ?? true) || !(after?.isASCII ?? true)
            if scalar.isASCII, !besideNonASCII {
                let byte = UInt8(scalar.value)
                run.append(ignoringCase ? lowerCase(byte) : byte)
            } else {
                if run.count > best.count { best = run }
                run = []
            }
        }
        if run.count > best.count { best = run }
        return best.isEmpty ? nil : best
    }

    /// The index of the byte of `anchor` least frequent in English prose.
    private static func rarestIndex(in anchor: [UInt8]) -> Int {
        var best = 0
        for index in anchor.indices where frequencyRank(anchor[index]) > frequencyRank(anchor[best]) {
            best = index
        }
        return best
    }

    /// How rare `byte` is in English prose: higher is rarer. Letters by
    /// their frequency; the space and the commonest punctuation as common
    /// as the commonest letters; digits and other symbols rarer than any.
    private static func frequencyRank(_ byte: UInt8) -> Int {
        let byLetterFrequency = Array("etaoinshrdlcumwfgypbvkjxqz".utf8)
        if let index = byLetterFrequency.firstIndex(of: lowerCase(byte)) {
            return index + 10
        }
        switch byte {
        case UInt8(ascii: " "): return 0
        case UInt8(ascii: ","), UInt8(ascii: "."), UInt8(ascii: "\t"): return 5
        default: return 100
        }
    }

    /// `byte` with an ASCII capital made small.
    private static func lowerCase(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte | 0x20 : byte
    }

    /// The capital of the ASCII small letter `byte`, or nil for any other byte.
    private static func upperCase(of byte: UInt8) -> UInt8? {
        (0x61...0x7A).contains(byte) ? byte & ~0x20 : nil
    }

    // MARK: Finding Candidate Lines

    /// Calls `visit` with the byte range of each line of `bytes`, a chapter's
    /// UTF-8 text, that may hold a match, in order and without its line
    /// feed, until `visit` returns false. A line is a candidate when it holds
    /// the anchor's bytes (letters in either case when case is ignored) or a
    /// special character; every other line holds no match.
    func forEachCandidateLine(in bytes: UnsafeBufferPointer<UInt8>, _ visit: (Range<Int>) -> Bool) {
        let count = bytes.count
        var index = 0
        while index < count {
            guard let hit = nextHit(in: bytes, from: index) else { return }
            let lineStart = Self.lineStart(in: bytes, before: hit)
            let lineEnd = Self.lineEnd(in: bytes, after: hit)
            guard visit(lineStart..<lineEnd) else { return }
            index = lineEnd + 1
        }
    }

    /// The position of the next byte at or after `start` that makes its line
    /// a candidate: the key byte of an occurrence of the anchor, or the first
    /// byte of a special character. Nil when there is none.
    private func nextHit(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        let count = bytes.count
        var index = start
        while index < count {
            let flags = byteFlags[Int(bytes[index])]
            if flags != 0 {
                if flags & Self.keyFlag != 0, anchorOccurs(in: bytes, at: index - keyIndex) {
                    return index
                }
                if flags & Self.specialFlag != 0, isSpecial(in: bytes, at: index) {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    /// Whether the anchor's bytes begin at `start` of `bytes`, letters in
    /// either case when case is ignored.
    private func anchorOccurs(in bytes: UnsafeBufferPointer<UInt8>, at start: Int) -> Bool {
        guard start >= 0, start + anchor.count <= bytes.count else { return false }
        for offset in anchor.indices {
            let byte = bytes[start + offset]
            if (ignoresCase ? Self.lowerCase(byte) : byte) != anchor[offset] { return false }
        }
        return true
    }

    /// Whether the UTF-8 sequence that begins at `index` of `bytes` encodes a
    /// special character that can stand for part of the anchor: one of the
    /// tables', or, for an anchor holding a digit or the numbered forms'
    /// punctuation, any character with a numeric value.
    private func isSpecial(in bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        guard let scalar = Self.scalar(in: bytes, at: index) else { return false }
        return specials.contains(scalar) || (numericFormsMatter && LibrarySearchSpecials.hasNumericValue(scalar))
    }

    /// The scalar whose UTF-8 sequence begins at `index` of `bytes`, or nil
    /// for a byte that begins none or a sequence cut short.
    static func scalar(in bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> UInt32? {
        let lead = bytes[index]
        let length: Int
        var value: UInt32
        switch lead {
        case 0xC2...0xDF: length = 2; value = UInt32(lead & 0x1F)
        case 0xE0...0xEF: length = 3; value = UInt32(lead & 0x0F)
        case 0xF0...0xF4: length = 4; value = UInt32(lead & 0x07)
        default: return nil
        }
        guard index + length <= bytes.count else { return nil }
        for offset in 1..<length {
            let continuation = bytes[index + offset]
            guard continuation & 0xC0 == 0x80 else { return nil }
            value = value << 6 | UInt32(continuation & 0x3F)
        }
        return value
    }

    /// Where the line holding position `index` of `bytes` begins: just
    /// after the line feed before it, or at the start. (macOS's C library has
    /// no `memrchr`; a line is short, and is looked back over once.)
    private static func lineStart(in bytes: UnsafeBufferPointer<UInt8>, before index: Int) -> Int {
        var position = index
        while position > 0, bytes[position - 1] != 0x0A {
            position -= 1
        }
        return position
    }

    /// Where the line holding position `index` of `bytes` ends: at the line
    /// feed after it, or at the end.
    private static func lineEnd(in bytes: UnsafeBufferPointer<UInt8>, after index: Int) -> Int {
        let count = bytes.count
        guard index < count, let base = bytes.baseAddress,
              let found = memchr(base + index, 0x0A, count - index) else { return count }
        return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
    }
}

// MARK: - Counting UTF-16

/// The UTF-16 length of UTF-8 text, from its bytes: one unit for each byte
/// that begins a scalar, and a second for each scalar of four bytes, which
/// UTF-16 writes as a surrogate pair. For valid UTF-8, as every search text
/// is, the length `String.utf16.count` gives.
enum UTF8Counting {
    /// The UTF-16 length of the UTF-8 bytes `bytes`.
    static func utf16Length(of bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var units = 0
        for byte in bytes {
            // Not a continuation byte: it begins a scalar.
            units &+= byte & 0xC0 != 0x80 ? 1 : 0
            // A lead byte of four: a second unit.
            units &+= byte >= 0xF0 ? 1 : 0
        }
        return units
    }
}
