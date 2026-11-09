import XCTest
@testable import TextMouth

/// What a soft hyphen (U+00AD) left inside a word does to the things that read a book's words, measured on
/// November 9, 2026 (readers/kf8-followups). These tests pin the measurements that decided to leave soft hyphens out
/// of MOBI 6 books as well as KF8 books (`ParserUtilities.removingSoftHyphens`); if one fails, the platform
/// changed how it treats the character and the decision should be looked at again.
///
/// - Search in Book: the word is not found (this class).
/// - Braille: the soft hyphen becomes a hyphen cell, dots 3-6 (this class, through the real liblouis helper).
/// - Speech: the engine reads it as it reads a hyphen, a longer word with a break in it; that was measured offline
///   by `Scripts/agents/probes/speech-soft-hyphen-probe.swift`, which renders audio and plays nothing, and its results
///   are recorded at the end of that file (no test renders speech here, so the host is never asked to).
final class SoftHyphenEffectTests: XCTestCase {

    /// The hyphen-minus cell of Unicode braille: dots 3 and 6.
    private let hyphenCell = "\u{2824}"

    // MARK: - Search in Book

    /// Book search is a case-insensitive literal lookup, or a regular expression: neither sees through a soft hyphen.
    func testAWordWithASoftHyphenInItIsNotFoundBySearch() throws {
        let withShy = "A word, hy\u{AD}phenation, is split."
        let plain = "A word, hyphenation, is split."
        for useRegex in [false, true] {
            let found = try BookTextSearch.ranges(in: withShy, query: "hyphenation", useRegex: useRegex)
            XCTAssertEqual(found.count, 0, "regex \(useRegex): 'hyphenation' found \(found) in \(withShy.debugDescription)")
            XCTAssertEqual(
                try BookTextSearch.ranges(in: plain, query: "hyphenation", useRegex: useRegex).count, 1,
                "regex \(useRegex): the same word without the soft hyphen must be found")
        }
        // The halves are found, as two words would be, which is how a soft hyphen splits the word for a search.
        XCTAssertEqual(try BookTextSearch.ranges(in: withShy, query: "phenation", useRegex: false).count, 1)
        // And a query that holds a soft hyphen finds no word that has none.
        XCTAssertEqual(try BookTextSearch.ranges(in: plain, query: "hy\u{AD}phenation", useRegex: false).count, 0)
    }

    // MARK: - Braille

    /// The braille of `texts` through the real helper, in a scratch folder that is checked empty afterwards.
    private func braille(_ texts: [String], table: String) throws -> [String] {
        let work = try makeSandboxDirectory("SoftHyphenBraille")
        let result = try BrailleTranslator.translate(texts, table: table, direction: .printToBraille, workingIn: work)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? ["<unreadable>"], [])
        return result
    }

    /// In uncontracted and in contracted English braille, a soft hyphen in a word is written as a hyphen cell,
    /// and nothing else of the word changes (so a listener of a braille display reads "hy-phenation").
    func testASoftHyphenInAWordIsAHyphenInBraille() throws {
        // Each word with the place a publisher would put the soft hyphen (between syllables, where no contraction spans it).
        let halves = [("hy", "phenation"), ("extra", "ordinary"), ("pro", "duct")]
        let words = halves.map { $0.0 + $0.1 }
        for table in ["en-ueb-g1.ctb", "en-ueb-g2.ctb"] {
            let plain = try braille(words, table: table)
            let split = try braille(halves.map { $0.0 + "\u{AD}" + $0.1 }, table: table)
            XCTAssertEqual(plain.count, words.count, table)
            XCTAssertEqual(split.count, words.count, table)
            for (index, word) in words.enumerated() where plain.indices.contains(index) && split.indices.contains(index) {
                XCTAssertFalse(plain[index].contains(hyphenCell), "\(table) \(word): plain braille \(plain[index]) has a hyphen cell")
                XCTAssertTrue(split[index].contains(hyphenCell), "\(table) \(word): braille \(split[index]) has no hyphen cell for the soft hyphen")
                XCTAssertEqual(
                    split[index].replacingOccurrences(of: hyphenCell, with: ""), plain[index],
                    "\(table) \(word): braille with the soft hyphen \(split[index]), without \(plain[index])")
            }
        }
    }
}
