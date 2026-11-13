import Foundation

/// The non-ASCII characters Foundation's search can match against ASCII text
/// (LIBRARY-SEARCH-RESEARCH-2026-11-13.md, section 3): a line holding one of
/// them may hold a match of a query's ASCII anchor though the anchor's bytes
/// are not there, so `LibrarySearchPrefilter` searches such a line whenever
/// the character can stand for one of the anchor's characters.
///
/// The sets are what a sweep of every scalar against Foundation found on
/// November 13, 2026 (macOS 26.3), asking whether an ASCII query, any
/// printable character or any piece of the ASCII the scalar's case mappings,
/// folding, and decompositions hold, is found in the scalar alone:
/// - **Ignoring case**: the long s (s), ß and the capital ß (ss), the
///   Kelvin sign (k), the Latin ligatures (ff, fi, fl, ffi, ffl, st), the
///   Greek question mark (;) and varia (`), and, as Foundation's
///   case-insensitive search counts a digit's compatibility forms as the
///   digit, the superscript and subscript digits, the circled, parenthesized,
///   and stopped numbers, the fullwidth, mathematical, and segmented digits,
///   and the late Roman numeral six.
/// - **Matching case**: those canonically equivalent to one ASCII character
///   (the Kelvin sign, the Greek question mark and varia) and the late Roman
///   numeral six.
///
/// A character that stands for ASCII only together with a non-ASCII
/// character of the query (ŉ for "ʼn", ẚ for "aʾ") needs no place here: the
/// anchor leaves out an ASCII character beside a non-ASCII one
/// (`LibrarySearchPrefilter.anchor(of:ignoringCase:)`). Foundation matches no
/// part of a character (s finds nothing in ß), never takes a precomposed
/// letter for its base (e finds nothing in é), and ignores no character
/// (a soft hyphen or a zero-width space parts the letters around it).
///
/// `LibrarySearchSpecialsTests` sweeps every assigned scalar against
/// Foundation on each run of the suite, so a macOS that matches more fails
/// there rather than missing matches.
enum LibrarySearchSpecials {
    /// The characters that can match ASCII when case is ignored.
    static let ignoringCase: Set<UInt32> = Set(
        [0x00B2, 0x00B3, 0x00B9, 0x00DF, 0x017F, 0x037E, 0x1E9E, 0x1FEF, 0x2070, 0x212A, 0x2185, 0x24EA, 0x24FF]
            + Array(0x2074...0x2089) + Array(0x2460...0x249B) + Array(0x24F5...0x24FD)
            + Array(0x3251...0x325F) + Array(0x32B1...0x32BF) + Array(0xFB00...0xFB06) + Array(0xFF10...0xFF19)
            + Array(0x1CCF0...0x1CCF9) + Array(0x1D7CE...0x1D7FF) + Array(0x1F100...0x1F10A) + Array(0x1FBF0...0x1FBF9)
    )

    /// The characters that can match ASCII when case must match.
    static let matchingCase: Set<UInt32> = [
        0x037E, // Greek question mark: ";"
        0x1FEF, // Greek varia: "`"
        0x212A, // Kelvin sign: "K"
        0x2185, // late Roman numeral six
    ]

    /// The special characters for a search that ignores case or matches it.
    static func characters(ignoringCase: Bool) -> Set<UInt32> {
        ignoringCase ? Self.ignoringCase : matchingCase
    }

    // MARK: What Each Stands For

    /// For each special character ignoring case, the ASCII characters (small
    /// letters for capitals) it can stand for: those of every ASCII query
    /// Foundation finds in it. Worked out once a run, in a few milliseconds.
    static let standsForIgnoringCase: [UInt32: Set<UInt8>] = standsFor(ignoringCase, ignoringCase: true)

    /// For each special character matching case, the ASCII characters it can
    /// stand for.
    static let standsForMatchingCase: [UInt32: Set<UInt8>] = standsFor(matchingCase, ignoringCase: false)

    /// The ASCII characters each of `characters` stands for, by asking
    /// Foundation's search, as the sweep did, which ASCII queries it finds in
    /// the character: letters as small ones when case is ignored. A character
    /// for which none is found stands for every ASCII character, so that a
    /// macOS that matches it otherwise never makes a line be passed over.
    private static func standsFor(_ characters: Set<UInt32>, ignoringCase: Bool) -> [UInt32: Set<UInt8>] {
        let options: NSString.CompareOptions = ignoringCase ? [.caseInsensitive] : []
        var table: [UInt32: Set<UInt8>] = [:]
        for value in characters {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let text = String(scalar) as NSString
            var found = Set<UInt8>()
            for query in asciiQueries(for: scalar) where text.range(of: query, options: options).location != NSNotFound {
                for byte in query.utf8 {
                    found.insert(ignoringCase && (0x41...0x5A).contains(byte) ? byte | 0x20 : byte)
                }
            }
            table[value] = found.isEmpty ? Set(0...0x7F) : found
        }
        return table
    }

    /// The ASCII queries that could stand for `scalar`: every printable ASCII
    /// character, and every piece of its mappings' ASCII (`asciiPieces`). The
    /// sweep that found the special characters asks these, and so does
    /// `standsFor`.
    static func asciiQueries(for scalar: Unicode.Scalar) -> [String] {
        printableASCII + asciiPieces(for: scalar)
    }

    /// Every piece of the ASCII runs of `scalar`'s case mappings, case
    /// folding, and canonical and compatibility decompositions, in order: "s"
    /// and "ss" for ß, "f", "ff", "ffi", "fi", and "i" for its ligature; none
    /// for a scalar whose mappings hold no ASCII.
    static func asciiPieces(for scalar: Unicode.Scalar) -> [String] {
        let text = String(scalar)
        let properties = scalar.properties
        let mappings = [
            properties.lowercaseMapping, properties.uppercaseMapping, properties.titlecaseMapping,
            text.folding(options: [.caseInsensitive], locale: nil),
            text.decomposedStringWithCanonicalMapping, text.decomposedStringWithCompatibilityMapping,
        ]
        var pieces = Set<String>()
        for mapping in mappings {
            for run in asciiRuns(of: mapping) {
                let characters = Array(run)
                for start in characters.indices {
                    for end in (start + 1)...characters.count {
                        pieces.insert(String(characters[start..<end]))
                    }
                }
            }
        }
        return pieces.sorted()
    }

    /// The printable ASCII characters, each a query.
    static let printableASCII: [String] = (0x20...0x7E).map { String(UnicodeScalar(UInt8($0))) }

    /// The runs of ASCII characters in `text`.
    private static func asciiRuns(of text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}
