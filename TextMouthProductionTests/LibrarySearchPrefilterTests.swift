import XCTest
@testable import TextMouth

/// Search Library's prefilter (`LibrarySearchPrefilter`): which run of a
/// query it looks for, which lines of a chapter's bytes it hands on, and the
/// UTF-16 count it places them with. `LibrarySearchEngineTests` shows that a
/// search through it finds what Search in Book finds; these show each part.
final class LibrarySearchPrefilterTests: XCTestCase {

    // MARK: The Anchor

    /// The anchor is the query's longest run of ASCII none of whose
    /// characters stands beside a non-ASCII one, in lower case when case is
    /// ignored; none for a query with no such run, one holding a line feed
    /// or carriage return, or a regular expression.
    func testTheAnchorIsTheLongestUsableRunOfASCII() {
        let cases: [(query: String, ignoringCase: Bool, anchor: String?)] = [
            ("window", true, "window"),
            ("Window", true, "window"),
            ("Window", false, "Window"),
            ("Café au lait", true, "au lait"),
            ("cafe\u{301}", true, "caf"),
            ("na\u{EF}ve", true, "n"),
            ("STRAẞE", true, "str"),
            ("İstanbul", true, "tanbul"),
            ("\u{2BC}n", true, nil),
            ("1\u{2044}4", true, nil),
            ("λόγος", true, nil),
            ("日本", true, nil),
            ("a\nb", true, nil),
            ("a\rb", true, nil),
            ("=\u{338}x", true, nil),
            ("e\u{301}\u{302}abc", true, "bc"),
            ("1️⃣ go", true, "go"),
        ]
        for (query, ignoringCase, anchor) in cases {
            let found = LibrarySearchPrefilter.anchor(of: query, ignoringCase: ignoringCase).map { String(decoding: $0, as: UTF8.self) }
            XCTAssertEqual(found, anchor, "query \(query.debugDescription), ignoring case \(ignoringCase)")
        }
        XCTAssertNil(LibrarySearchPrefilter(query: "window", options: TextSearchOptions(matchCase: false, isRegularExpression: true)))
        XCTAssertNotNil(LibrarySearchPrefilter(query: "window", options: TextSearchOptions()))
    }

    // MARK: Candidate Lines

    /// The lines handed on are those holding the anchor's bytes, in either
    /// case when case is ignored, or a special character, and no others, in
    /// order and without their line feeds.
    func testTheLinesHandedOnHoldTheAnchorOrASpecialCharacter() throws {
        let lines = [
            "no match here",
            "a Window here",
            "",
            "plain words \u{2019}quoted\u{2019}",
            "the WINDOW at the end",
            "a ligature: \u{FB01}ne",
            "windo",
            "window",
        ]
        let text = lines.joined(separator: "\n")
        let ignoring = try XCTUnwrap(LibrarySearchPrefilter(query: "window", options: TextSearchOptions()))
        XCTAssertEqual(candidateLines(ignoring, in: text), ["a Window here", "the WINDOW at the end", "a ligature: \u{FB01}ne", "window"])

        let matching = try XCTUnwrap(LibrarySearchPrefilter(query: "window", options: TextSearchOptions(matchCase: true, isRegularExpression: false)))
        XCTAssertEqual(candidateLines(matching, in: text), ["window"], "case kept, and the ligature is no special character then")

        let kelvin = try XCTUnwrap(LibrarySearchPrefilter(query: "K", options: TextSearchOptions(matchCase: true, isRegularExpression: false)))
        XCTAssertEqual(candidateLines(kelvin, in: "no\n\u{212A}elvin\nKelvin"), ["\u{212A}elvin", "Kelvin"],
                       "the Kelvin sign is canonically K, matched with case kept")
    }

    /// A special character makes its line a candidate only for an anchor it
    /// can stand for: a superscript two for "Chapter 2", never for "window".
    func testASpecialCharacterCountsOnlyForAnAnchorItStandsFor() throws {
        let text = "footnote\u{B2} here\nthe window\nChapter 2\nlist \u{2461} item"
        let chapter = try XCTUnwrap(LibrarySearchPrefilter(query: "Chapter 2", options: TextSearchOptions()))
        XCTAssertEqual(candidateLines(chapter, in: text), ["footnote\u{B2} here", "Chapter 2", "list \u{2461} item"],
                       "the superscript two and the circled two may stand for the anchor's 2")
        let window = try XCTUnwrap(LibrarySearchPrefilter(query: "window", options: TextSearchOptions()))
        XCTAssertEqual(candidateLines(window, in: text), ["the window"], "no digit form stands for a letter of window")
    }

    /// A line feed at either end of the text, a line of only the anchor, and
    /// lines ending in CR LF are found as lines, the carriage return kept.
    func testLinesAtTheEdgesAndWithCarriageReturnsAreWhole() throws {
        let prefilter = try XCTUnwrap(LibrarySearchPrefilter(query: "fox", options: TextSearchOptions()))
        XCTAssertEqual(candidateLines(prefilter, in: "\nfox\n"), ["fox"])
        XCTAssertEqual(candidateLines(prefilter, in: "fox"), ["fox"])
        XCTAssertEqual(candidateLines(prefilter, in: "a fox\r\nno\r\nFOX\r\n"), ["a fox\r", "FOX\r"])
        XCTAssertEqual(candidateLines(prefilter, in: ""), [])
    }

    // MARK: Counting UTF-16

    /// The UTF-16 length counted from UTF-8 bytes is Swift's, for text of
    /// one, two, three, and four bytes a scalar.
    func testTheUTF16LengthFromBytesIsSwifts() {
        let samples = ["", "plain", "café", "ß ẞ", "日本語", "😀👍🏽👩‍💻", "e\u{301}\u{302}", "\u{10FFFF}a\u{80}"]
        for sample in samples + [samples.joined(separator: "\n")] {
            var text = sample
            let counted = text.withUTF8 { UTF8Counting.utf16Length(of: $0) }
            XCTAssertEqual(counted, sample.utf16.count, sample.debugDescription)
        }
    }

    // MARK: Helpers

    /// The lines of `text` that `prefilter` hands on.
    private func candidateLines(_ prefilter: LibrarySearchPrefilter, in text: String) -> [String] {
        var text = text
        return text.withUTF8 { bytes in
            var lines: [String] = []
            prefilter.forEachCandidateLine(in: bytes) { range in
                lines.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self))
                return true
            }
            return lines
        }
    }
}
