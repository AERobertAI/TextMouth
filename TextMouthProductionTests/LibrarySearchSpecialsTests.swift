import XCTest
@testable import TextMouth

/// The characters Search Library's prefilter stops at (`LibrarySearchSpecials`)
/// are every non-ASCII character Foundation's search can match against ASCII
/// alone: a scalar missing from them would let the prefilter pass over a line
/// that holds a match, and the library search would find less than Search in
/// Book. The sweep asks Foundation itself, on the macOS running the suite, so
/// a macOS that matches more fails here rather than missing matches.
final class LibrarySearchSpecialsTests: XCTestCase {

    /// Every assigned scalar beyond ASCII that Foundation's search, ignoring
    /// case or matching it, finds an ASCII query in (`asciiQueries(for:)`),
    /// or passes over between two ASCII letters, is a special character for
    /// that search.
    func testEveryCharacterFoundationMatchesAgainstASCIIIsSpecial() {
        var missingIgnoringCase: [String] = []
        var missingMatchingCase: [String] = []
        var swept = 0
        for value in UInt32(0x80)...UInt32(0x10FFFF) {
            guard let scalar = Unicode.Scalar(value), Self.isAssigned(scalar) else { continue }
            swept += 1
            let (ignoringCase, matchingCase) = Self.foundationMatchesASCII(against: scalar)
            if ignoringCase, !LibrarySearchSpecials.ignoringCase.contains(value) {
                missingIgnoringCase.append(String(format: "U+%04X", value))
            }
            if matchingCase, !LibrarySearchSpecials.matchingCase.contains(value) {
                missingMatchingCase.append(String(format: "U+%04X", value))
            }
        }
        XCTAssertGreaterThan(swept, 100_000, "the sweep covered too few scalars")
        XCTAssertEqual(missingIgnoringCase, [], "matched against ASCII ignoring case, and not special")
        XCTAssertEqual(missingMatchingCase, [], "matched against ASCII matching case, and not special")
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
    /// ligature for "f" and "i", the circled one for "1", the Greek question
    /// mark for ";"; with case kept, the Kelvin sign for "K" alone. Every
    /// special character stands for ASCII Foundation finds in it on this
    /// macOS, so none needs the fallback of standing for every character.
    func testEachSpecialCharacterStandsForTheASCIIFoundationFindsInIt() {
        let ignoring = LibrarySearchSpecials.standsForIgnoringCase
        let matching = LibrarySearchSpecials.standsForMatchingCase
        let expectations: [(UInt32, Set<Character>)] = [
            (0x00DF, ["s"]), (0x017F, ["s"]), (0x212A, ["k"]), (0xFB01, ["f", "i"]), (0x2460, ["1"]), (0x037E, [";"]),
        ]
        for (value, characters) in expectations {
            let bytes = Set(characters.compactMap { $0.asciiValue })
            XCTAssertEqual(ignoring[value], bytes, String(format: "U+%04X ignoring case", value))
        }
        XCTAssertEqual(matching[0x212A], Set([UInt8(ascii: "K")]), "the Kelvin sign with case kept")
        let everything = Set<UInt8>(0...0x7F)
        for value in LibrarySearchSpecials.ignoringCase {
            XCTAssertNotEqual(ignoring[value] ?? everything, everything, String(format: "U+%04X ignoring case: no ASCII found in it", value))
        }
        for value in LibrarySearchSpecials.matchingCase {
            XCTAssertNotEqual(matching[value] ?? everything, everything, String(format: "U+%04X matching case: no ASCII found in it", value))
        }
    }

    // MARK: The Sweep's Rules

    /// Whether `scalar` is assigned and not for private use: the scalars
    /// with case mappings or decompositions, the only ones Foundation's
    /// search could take for ASCII.
    private static func isAssigned(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .unassigned, .privateUse, .surrogate: return false
        default: return true
        }
    }

    /// Whether Foundation's search, ignoring case and matching it, finds an
    /// ASCII query in the text that is `scalar` alone, or passes over it
    /// between "a" and "b". The queries are `LibrarySearchSpecials.asciiQueries`,
    /// asked of a scalar whose mappings hold ASCII and of every scalar in the
    /// blocks where look-alikes of ASCII live; any other scalar is asked only
    /// whether it is passed over.
    private static func foundationMatchesASCII(against scalar: Unicode.Scalar) -> (ignoringCase: Bool, matchingCase: Bool) {
        let text = String(scalar)
        let between = "a" + text + "b"
        var ignoringCase = found("ab", in: between, [.caseInsensitive])
        var matchingCase = found("ab", in: between, [])
        let pieces = LibrarySearchSpecials.asciiPieces(for: scalar)
        let queries = pieces.isEmpty && !isNearASCII(scalar) ? [] : LibrarySearchSpecials.printableASCII + pieces
        for query in queries where !(ignoringCase && matchingCase) {
            if !ignoringCase, found(query, in: text, [.caseInsensitive]) { ignoringCase = true }
            if !matchingCase, found(query, in: text, []) { matchingCase = true }
        }
        return (ignoringCase, matchingCase)
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
