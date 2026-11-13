import XCTest
@testable import TextMouth

/// The characters Search Library's prefilter stops at (`LibrarySearchSpecials`)
/// are every non-ASCII character Foundation's search can match against ASCII:
/// a scalar missing from them would let the prefilter pass over a line that
/// holds a match, and the library search would find less than Search in Book.
/// The sweep asks Foundation itself, on the macOS running the suite, so a
/// macOS that matches more fails here rather than missing matches.
final class LibrarySearchSpecialsTests: XCTestCase {

    /// Every assigned scalar beyond ASCII that Foundation's search, ignoring
    /// case or matching it, finds an ASCII query in, or passes over between
    /// two ASCII letters, is among the special characters for that search.
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
    /// between "a" and "b". The queries tried are every printable ASCII
    /// character, and every piece of the ASCII runs of the scalar's case
    /// mappings, case folding, and decompositions (so "ss" for ß and "ffi"
    /// for its ligature): those are how a scalar could stand for ASCII.
    private static func foundationMatchesASCII(against scalar: Unicode.Scalar) -> (ignoringCase: Bool, matchingCase: Bool) {
        let text = String(scalar)
        let between = "a" + text + "b"
        var ignoringCase = found("ab", in: between, [.caseInsensitive])
        var matchingCase = found("ab", in: between, [])
        let properties = scalar.properties
        let mappings = [
            properties.lowercaseMapping, properties.uppercaseMapping, properties.titlecaseMapping,
            text.folding(options: [.caseInsensitive], locale: nil),
            text.decomposedStringWithCanonicalMapping, text.decomposedStringWithCompatibilityMapping,
        ]
        let pieces = Set(mappings.flatMap(asciiRuns).flatMap(allPieces))
        // A scalar whose mappings hold no ASCII is tried with single ASCII
        // characters only in the blocks where look-alikes of ASCII live.
        let queries = pieces.isEmpty && !isNearASCII(scalar) ? [] : Array(pieces) + printableASCII
        for query in queries where !(ignoringCase && matchingCase) {
            if !ignoringCase, found(query, in: text, [.caseInsensitive]) { ignoringCase = true }
            if !matchingCase, found(query, in: text, []) { matchingCase = true }
        }
        return (ignoringCase, matchingCase)
    }

    /// The printable ASCII characters, each a query.
    private static let printableASCII = (0x20...0x7E).map { String(UnicodeScalar(UInt8($0))) }

    /// Whether `scalar` is in a block where look-alikes of ASCII letters,
    /// digits, and punctuation live: Latin, IPA, Greek, general punctuation,
    /// letterlike symbols, enclosed alphanumerics, the Latin extensions,
    /// the alphabetic presentation forms, variation selectors, the
    /// halfwidth and fullwidth forms, mathematical alphanumerics, and tags.
    private static func isNearASCII(_ scalar: Unicode.Scalar) -> Bool {
        let blocks: [ClosedRange<UInt32>] = [
            0x80...0x3FF, 0x1E00...0x1EFF, 0x2000...0x218F, 0x2460...0x24FF, 0x2C60...0x2C7F, 0xA720...0xA7FF,
            0xFB00...0xFB4F, 0xFE00...0xFE0F, 0xFF00...0xFFEF, 0x1D400...0x1D7FF, 0xE0000...0xE007F,
        ]
        return blocks.contains { $0.contains(scalar.value) }
    }

    /// Whether `query` is found anywhere in `text` with `options`.
    private static func found(_ query: String, in text: String, _ options: NSString.CompareOptions) -> Bool {
        (text as NSString).range(of: query, options: options).location != NSNotFound
    }

    /// The runs of ASCII characters in `text`.
    private static func asciiRuns(_ text: String) -> [String] {
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

    /// Every contiguous piece of `run`.
    private static func allPieces(_ run: String) -> [String] {
        let characters = Array(run)
        var pieces: [String] = []
        for start in characters.indices {
            for end in (start + 1)...characters.count {
                pieces.append(String(characters[start..<end]))
            }
        }
        return pieces
    }
}
