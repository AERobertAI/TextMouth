import XCTest
@testable import TextMouth

// MARK: - Plain Text Split into Lines by Bytes

/// The plain-text reader cuts a text into trimmed lines in one pass over its
/// bytes (the November 14, 2026 import speed-up, H4). It must cut where
/// `components(separatedBy: .newlines)` cut and trim what
/// `trimmingCharacters(in: .whitespaces)` trimmed, for every text: so each
/// edge has a case by name, with the lines spelled out, and thousands of
/// random texts are compared with the Foundation way.
final class PlainTextLinesTests: XCTestCase {

    // MARK: - Helpers

    /// The lines `text` is cut into.
    private func lines(_ text: String) -> [String] {
        PlainTextLines.trimmedLines(of: text)
    }

    /// Checks that `text` is cut as Foundation cuts it, whether the string
    /// is held natively or bridged, and returns the lines for a closer look.
    @discardableResult
    private func checkedLines(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let expected = PlainTextLines.referenceLines(of: text)
        XCTAssertEqual(lines(text), expected, "\(Array(text.unicodeScalars))", file: file, line: line)
        XCTAssertEqual(lines((text as NSString) as String), expected, "bridged", file: file, line: line)
        return expected
    }

    // MARK: - The edges, spelled out

    /// A text with no line ending is one line; an empty text is one empty line.
    func testATextOfOneLineWithNoEnding() {
        XCTAssertEqual(checkedLines("just one line"), ["just one line"])
        XCTAssertEqual(checkedLines(""), [""])
        XCTAssertEqual(checkedLines("   "), [""])
    }

    /// A line feed ends a line; an ending at the end leaves an empty last
    /// line, and one at the start an empty first line.
    func testALoneLineFeedAndTheEmptyLinesAroundIt() {
        XCTAssertEqual(checkedLines("a\nb"), ["a", "b"])
        XCTAssertEqual(checkedLines("a\n"), ["a", ""])
        XCTAssertEqual(checkedLines("\na"), ["", "a"])
        XCTAssertEqual(checkedLines("\n"), ["", ""])
        XCTAssertEqual(checkedLines("a\n\nb"), ["a", "", "b"])
        XCTAssertEqual(checkedLines("a\n\n\n"), ["a", "", "", ""])
    }

    /// Each carriage return is a line ending of its own, as the reader's
    /// normalization (which makes CR LF one line feed) left alone is cut:
    /// two endings with an empty line between.
    func testCarriageReturnsAreLineEndings() {
        XCTAssertEqual(checkedLines("a\rb"), ["a", "b"])
        XCTAssertEqual(checkedLines("a\r\nb"), ["a", "", "b"])
        XCTAssertEqual(checkedLines("a\r\r\nb"), ["a", "", "", "b"])
        XCTAssertEqual(checkedLines("\r"), ["", ""])
    }

    /// Vertical tab, form feed, next line, line separator, and paragraph
    /// separator end a line too, and no other character does.
    func testTheOtherLineEndings() {
        XCTAssertEqual(checkedLines("a\u{0B}b"), ["a", "b"])
        XCTAssertEqual(checkedLines("a\u{0C}b"), ["a", "b"])
        XCTAssertEqual(checkedLines("a\u{85}b"), ["a", "b"])
        XCTAssertEqual(checkedLines("a\u{2028}b"), ["a", "b"])
        XCTAssertEqual(checkedLines("a\u{2029}b"), ["a", "b"])
        // Neighbours of those characters that are not line endings.
        XCTAssertEqual(checkedLines("a\u{2027}b\u{202A}c"), ["a\u{2027}b\u{202A}c"])
        XCTAssertEqual(checkedLines("a\u{84}b\u{86}c"), ["a\u{84}b\u{86}c"])
        XCTAssertEqual(checkedLines("a\u{0E}b\u{1C}c\u{1E}d"), ["a\u{0E}b\u{1C}c\u{1E}d"])
        XCTAssertEqual(checkedLines("\u{C2}\u{85}"), ["\u{C2}", ""])
    }

    /// Spaces and tabs are trimmed at both ends and kept inside; so is each
    /// other whitespace character (no-break space, ideographic space, the
    /// en and em spaces, the narrow no-break space).
    func testTrimmingAtBothEnds() {
        XCTAssertEqual(checkedLines("  a  b  "), ["a  b"])
        XCTAssertEqual(checkedLines("\t a \t"), ["a"])
        XCTAssertEqual(checkedLines("\u{A0}a\u{A0}"), ["a"])
        XCTAssertEqual(checkedLines("\u{3000}a\u{3000}"), ["a"])
        XCTAssertEqual(checkedLines(" \u{A0} \u{2003}\u{202F}a b\u{1680} \u{2000}"), ["a b"])
        XCTAssertEqual(checkedLines("a\u{A0}b"), ["a\u{A0}b"])
        XCTAssertEqual(checkedLines("   \u{3000}  \n\t\t"), ["", ""])
        // Foundation's set holds the zero-width space, so it is trimmed; a
        // control character is not in it, so it is kept at an edge.
        XCTAssertEqual(checkedLines("\u{200B}a\u{200B}"), ["a"])
        XCTAssertEqual(checkedLines("\u{1}a\u{1}"), ["\u{1}a\u{1}"])
    }

    /// A byte order mark that was not removed stays at the start of the first
    /// line, and is never taken for white space.
    func testAByteOrderMarkIsKept() {
        XCTAssertEqual(checkedLines("\u{FEFF}Title\nBody"), ["\u{FEFF}Title", "Body"])
        XCTAssertEqual(checkedLines("\u{FEFF} Title"), ["\u{FEFF} Title"])
        XCTAssertEqual(checkedLines(" \u{FEFF}Title"), ["\u{FEFF}Title"])
    }

    /// A mark that joins the character before or after a space does not change
    /// where the trim stops: Foundation decides every edge past ASCII.
    func testCombiningMarksAtTheEdges() {
        XCTAssertEqual(checkedLines(" \u{0301}x"), PlainTextLines.referenceLines(of: " \u{0301}x"))
        XCTAssertEqual(checkedLines("x \u{0301}"), PlainTextLines.referenceLines(of: "x \u{0301}"))
        checkedLines("\n\u{0301}x")
        XCTAssertEqual(checkedLines("e\u{0301} \n e\u{0301}"), ["e\u{0301}", "e\u{0301}"])
    }

    /// Text beyond ASCII is kept whole, with its lines cut where they end.
    func testTextBeyondASCII() {
        XCTAssertEqual(checkedLines("\u{E9}t\u{E9}\n\u{6F22}\u{5B57}\u{2028}\u{1F600}"), ["\u{E9}t\u{E9}", "\u{6F22}\u{5B57}", "\u{1F600}"])
        XCTAssertEqual(checkedLines("  \u{E9}  \n  \u{1F600}  "), ["\u{E9}", "\u{1F600}"])
    }

    /// A long text, cut as Foundation cuts it.
    func testALongText() {
        let paragraph = "A line of words, with \u{E9}t\u{E9} and tabs\t\n  indented\n\n\u{3000}wide\u{3000}\n"
        let text = String(repeating: paragraph, count: 4_000)
        XCTAssertEqual(lines(text), PlainTextLines.referenceLines(of: text))
        XCTAssertEqual(lines(text).count, 4_000 * 4 + 1)
    }

    // MARK: - Against Foundation, on random text

    /// The pieces random text is made of: letters, every line ending, every
    /// kind of space, marks, and characters of two, three, and four bytes.
    private let pieces: [String] = [
        "a", "b", "word", " ", " ", "  ", "\t", "\n", "\n", "\r", "\r\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}", "\u{A0}",
        "\u{3000}", "\u{2003}", "\u{1680}", "\u{202F}", "\u{0301}", "\u{E9}", "e\u{0301}", "\u{6F22}", "\u{1F600}", "\u{FEFF}", "\u{200B}",
        "\u{1}", "\u{0}", "\u{C2}", "\u{E2}", "\u{200D}",
    ]

    /// Thousands of random texts are cut as Foundation cuts them, held
    /// natively and bridged.
    func testRandomTextIsCutAsFoundationCutsIt() {
        var generator = KFXSeededGenerator(seed: 1114)
        for _ in 0..<20_000 {
            let count = Int.random(in: 0...30, using: &generator)
            let text = (0..<count).map { _ in pieces.randomElement(using: &generator)! }.joined()
            checkedLines(text)
        }
    }
}
