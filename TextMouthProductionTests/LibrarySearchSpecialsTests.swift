import XCTest
@testable import TextMouth

/// The characters Search Library's prefilter stops at (`LibrarySearchSpecials`):
/// every non-ASCII character Foundation's search can match against ASCII
/// alone must be special, and stand for every ASCII character of each query
/// Foundation finds in it, or the prefilter could pass over a chapter that
/// holds a match, and the library search find less than Search in Book. The
/// sweep asks Foundation itself, on the macOS running the suite, so a macOS
/// that matches more fails here rather than missing matches.
final class LibrarySearchSpecialsTests: XCTestCase {

    /// For every assigned scalar beyond ASCII and each way of handling case,
    /// every ASCII query Foundation finds in the scalar alone is made of
    /// characters the scalar stands for (`LibrarySearchSpecials.standsFor`),
    /// and no scalar is passed over between two ASCII letters.
    func testEveryCharacterFoundationMatchesAgainstASCIIStandsForWhatMatched() {
        var unsound: [String] = []
        var swept = 0
        for value in UInt32(0x80)...UInt32(0x10FFFF) {
            guard let scalar = Unicode.Scalar(value), Self.isAssigned(scalar) else { continue }
            swept += 1
            for ignoringCase in [true, false] {
                let options: NSString.CompareOptions = ignoringCase ? [.caseInsensitive] : []
                let name = String(format: "U+%04X %@", value, ignoringCase ? "ignoring case" : "matching case")
                if Self.found("ab", in: "a" + String(scalar) + "b", options) {
                    unsound.append("\(name) is passed over between two letters")
                }
                let matching = Self.queries(for: scalar).filter { Self.found($0, in: String(scalar), options) }
                guard !matching.isEmpty else { continue }
                guard let stands = LibrarySearchSpecials.standsFor(value, ignoringCase: ignoringCase) else {
                    unsound.append("\(name) matches \(matching) and is not special")
                    continue
                }
                for query in matching {
                    let bytes = Set(query.utf8.map { ignoringCase && (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 })
                    if !bytes.isSubset(of: stands) {
                        unsound.append("\(name) matches \(query.debugDescription), beyond what it stands for")
                    }
                }
            }
        }
        XCTAssertGreaterThan(swept, 100_000, "the sweep covered too few scalars")
        XCTAssertEqual(unsound, [], "\(unsound.count) scalars Foundation matches against ASCII that the prefilter would pass over")
    }

    /// The special characters with case kept are among those with case
    /// ignored, which a case-insensitive search matches at least as often.
    func testTheCharactersSpecialMatchingCaseAreSpecialIgnoringIt() {
        XCTAssertTrue(
            LibrarySearchSpecials.matchingCase.isSubset(of: LibrarySearchSpecials.ignoringCase),
            "\(LibrarySearchSpecials.matchingCase.subtracting(LibrarySearchSpecials.ignoringCase))"
        )
    }

    /// What a special character stands for is what Foundation finds in it:
    /// ß and the long s stand for "s", the Kelvin sign for "k", the fi
    /// ligature for "f" and "i", the Greek question mark for ";"; with case
    /// kept, the Kelvin sign for "K" alone. A character with a numeric value,
    /// in the tables or not (the circled one, an Arabic-Indic two), stands for
    /// the digits and the numbered forms' punctuation too. A letter that is
    /// in neither stands for nothing.
    func testEachSpecialCharacterStandsForTheASCIIFoundationFindsInIt() {
        let expectations: [(UInt32, Set<Character>)] = [
            (0x00DF, ["s"]), (0x017F, ["s"]), (0x212A, ["k"]), (0xFB01, ["f", "i"]), (0x037E, [";"]),
        ]
        for (value, characters) in expectations {
            let bytes = Set(characters.compactMap { $0.asciiValue })
            XCTAssertEqual(LibrarySearchSpecials.standsFor(value, ignoringCase: true), bytes, String(format: "U+%04X", value))
        }
        XCTAssertEqual(LibrarySearchSpecials.standsFor(0x212A, ignoringCase: false), Set([UInt8(ascii: "K")]))
        let numeric = LibrarySearchSpecials.numericStandsFor
        XCTAssertEqual(LibrarySearchSpecials.standsFor(0x2460, ignoringCase: true)?.isSuperset(of: numeric), true, "the circled one")
        XCTAssertEqual(LibrarySearchSpecials.standsFor(0x0662, ignoringCase: true), numeric, "an Arabic-Indic two")
        XCTAssertNil(LibrarySearchSpecials.standsFor(0x00E9, ignoringCase: true), "é stands for nothing")
        let everything = Set<UInt8>(0...0x7F)
        for value in LibrarySearchSpecials.ignoringCase {
            XCTAssertNotEqual(LibrarySearchSpecials.standsForIgnoringCase[value] ?? everything, everything,
                              String(format: "U+%04X ignoring case: no ASCII found in it", value))
        }
        for value in LibrarySearchSpecials.matchingCase {
            XCTAssertNotEqual(LibrarySearchSpecials.standsForMatchingCase[value] ?? everything, everything,
                              String(format: "U+%04X matching case: no ASCII found in it", value))
        }
    }

    // MARK: The Sweep's Rules

    /// Whether `scalar` is assigned and not for private use: the scalars
    /// with case mappings, decompositions, or numeric values, the only ones
    /// Foundation's search could take for ASCII.
    private static func isAssigned(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .unassigned, .privateUse, .surrogate: return false
        default: return true
        }
    }

    /// The ASCII queries asked of `scalar`: every printable character and
    /// every piece of its mappings' ASCII (`LibrarySearchSpecials.asciiQueries`)
    /// for a scalar whose mappings hold ASCII or that lives where look-alikes
    /// of ASCII live; the digits and the numbered forms' punctuation for one
    /// with a numeric value, wherever it lives; none for any other.
    private static func queries(for scalar: Unicode.Scalar) -> [String] {
        let pieces = LibrarySearchSpecials.asciiPieces(for: scalar)
        var queries = pieces.isEmpty && !isNearASCII(scalar) ? [] : LibrarySearchSpecials.printableASCII + pieces
        if LibrarySearchSpecials.hasNumericValue(scalar.value), queries.isEmpty {
            queries = "0123456789().,".map { String($0) }
        }
        return queries
    }

    /// Whether `scalar` is in a block where look-alikes of ASCII letters,
    /// digits, and punctuation live: Latin, IPA, Greek, general punctuation,
    /// letterlike symbols and number forms, enclosed alphanumerics, the Latin
    /// extensions, the alphabetic presentation forms, variation selectors,
    /// the halfwidth and fullwidth forms, the segmented digits, mathematical
    /// alphanumerics, the enclosed alphanumeric supplement, and tags.
    private static func isNearASCII(_ scalar: Unicode.Scalar) -> Bool {
        let blocks: [ClosedRange<UInt32>] = [
            0x80...0x3FF, 0x1E00...0x1EFF, 0x2000...0x218F, 0x2460...0x24FF, 0x2C60...0x2C7F, 0xA720...0xA7FF,
            0xFB00...0xFB4F, 0xFE00...0xFE0F, 0xFF00...0xFFEF, 0x1CC00...0x1CEBF, 0x1D400...0x1D7FF,
            0x1F100...0x1F1FF, 0x1FB00...0x1FBFF, 0xE0000...0xE007F,
        ]
        return blocks.contains { $0.contains(scalar.value) }
    }

    /// Whether `query` is found anywhere in `text` with `options`.
    private static func found(_ query: String, in text: String, _ options: NSString.CompareOptions) -> Bool {
        (text as NSString).range(of: query, options: options).location != NSNotFound
    }
}
