import XCTest
@testable import TextMouth

// MARK: - A Chapter That Holds No Text

/// A spine document whose Markdown holds nothing but white space and page
/// markers is blank, and is left out of the book with its pages
/// (`EPUBParser.holdsOnlyWhitespaceAndPageMarkers`). It was judged by removing
/// every marker with a regular expression, trimming, and asking whether
/// anything was left; it is now judged by reading from the start until the
/// first other character (the November 14, 2026 import speed-up, H5). The
/// answer must be the same for every text.
final class EPUBBlankChapterTests: XCTestCase {

    /// The way a chapter was judged blank: markers removed by the regular
    /// expression, the rest trimmed.
    private func referenceIsBlank(_ markdown: String) -> Bool {
        markdown.replacingOccurrences(of: "<!-- page: [^<>]+ -->", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Checks `markdown` against the reference.
    private func assertSame(_ markdown: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            EPUBParser.holdsOnlyWhitespaceAndPageMarkers(markdown), referenceIsBlank(markdown),
            "\(markdown.debugDescription)", file: file, line: line
        )
    }

    /// The cases that matter, spelled out, and each checked against the reference.
    func testBlankAndNotBlankChapters() {
        let blank = ["", " ", "\n\n", "\u{A0}\u{3000}\t", "<!-- page: 1 -->", "  <!-- page: 1 -->\n\n<!-- page: 2 -->  ", "<!-- page: x\u{E9} -->",
                     "<!-- page: a --b -->", "<!-- page: -- -->", "<!-- page:  -->  -->"]
        let words = ["words", "<!-- page: 1 -->\n\nwords", "word <!-- page: 1 -->", "<!-- page: 1 --> .", "<!-- page: -->", "<!-- page:  -->",
                     "<!-- page: 1", "<!-- page: 1 --", "<!-- page: <!-- page: 1 --> 2 -->", "<!-- page: a>b -->", "<!-- page: 1 --> <!-- other -->",
                     "<!--page: 1 -->", "<!-- Page: 1 -->", "<!-- page: 1 -->\u{200B}", "\u{FEFF}", "<", "<!--", "<!-- page: ",
                     "<!-- page: " + String(repeating: "x", count: 5_000), "# Heading", "<!-- heading: 1 -->"]
        for markdown in blank + words { assertSame(markdown) }
        // The ones that are blank say so, and the ones with words do not.
        for markdown in ["", " ", "<!-- page: 1 -->", "  <!-- page: 1 -->\n\n<!-- page: 2 -->  ", "<!-- page: x\u{E9} -->", "<!-- page: a --b -->"] {
            XCTAssertTrue(EPUBParser.holdsOnlyWhitespaceAndPageMarkers(markdown), markdown.debugDescription)
        }
        for markdown in ["words", "<!-- page: 1 -->\n\nwords", "<!-- page: -->", "<!-- page: 1", "<!-- page: 1 --> <!-- other -->"] {
            XCTAssertFalse(EPUBParser.holdsOnlyWhitespaceAndPageMarkers(markdown), markdown.debugDescription)
        }
    }

    /// A long chapter is judged by its first characters: the answer is the
    /// reference's, whether its words are first or last.
    func testALongChapter() {
        let body = String(repeating: "A sentence of the chapter.\n\n", count: 20_000)
        assertSame(body)
        assertSame("<!-- page: 1 -->\n\n" + body)
        let markers = String(repeating: "<!-- page: 12 -->\n", count: 5_000)
        assertSame(markers)
        assertSame(markers + "x")
        assertSame(String(repeating: " \n", count: 50_000))
    }

    /// Thousands of random chapters made of the pieces markers and text are
    /// made of are judged as the reference judges them.
    func testRandomChapters() {
        let pieces = [
            "<!-- page: 1 -->", "<!-- page: ", " -->", "<!-- page: iv -->", "<!-- page: ", "-->", " ", "\n", "\t", "\u{A0}", "\u{2028}", "\u{3000}",
            "<", ">", "!", "--", "page:", "x", "\u{E9}", "\u{1F600}", "a b", "<!-- page: a<b -->", "<!--", "\u{200B}", "\u{FEFF}", "\r\n",
        ]
        var generator = KFXSeededGenerator(seed: 515)
        for _ in 0..<20_000 {
            let count = Int.random(in: 0...12, using: &generator)
            assertSame((0..<count).map { _ in pieces.randomElement(using: &generator)! }.joined())
        }
    }
}
