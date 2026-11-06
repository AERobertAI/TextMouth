import XCTest
@testable import TextMouth

// MARK: - Emphasis in Word Documents

/// Emphasis is never spoken. The DOCX reader writes a paragraph's runs through
/// `MarkdownEmphasis`, which writes only delimiters that Markdown pairs, a
/// stretch of touching runs at a time, so a mark of bold or italic is never
/// read aloud as an asterisk. These tests ask what a listener hears (the
/// reading text swift-markdown makes of the Markdown), not the Markdown string.
final class DOCXEmphasisTests: XCTestCase {

    private func bold(_ text: String) -> String { docxRun(text, "<w:b/>") }
    private func italic(_ text: String) -> String { docxRun(text, "<w:i/>") }
    private func boldItalic(_ text: String) -> String { docxRun(text, "<w:b/><w:i/>") }

    // MARK: - The cases that were read aloud

    /// White space at the edge of a bold run stays outside its marks: "See the
    /// **important **note." was read with its asterisks.
    func testWhiteSpaceAtARunsEdgeIsOutsideItsMarks() throws {
        let body = docxParagraph(docxRun("See the ") + bold("important ") + docxRun("note."))
        XCTAssertEqual(try docxMarkdown(body: body), "See the **important** note\\.")
        XCTAssertEqual(try docxReadingText(body: body), "See the important note.")
    }

    /// Runs that touch are one stretch: two bold runs with nothing between are
    /// one bold word, and two italic runs one italic word ("Bold****stays",
    /// "Slant**ed").
    func testRunsThatTouchAreWrittenTogether() throws {
        XCTAssertEqual(try docxMarkdown(body: docxParagraph(bold("Bold") + bold("stays"))), "**Boldstays**")
        XCTAssertEqual(try docxMarkdown(body: docxParagraph(italic("Slant") + italic("ed"))), "*Slanted*")
        XCTAssertEqual(try docxReadingText(body: docxParagraph(bold("Bold") + bold("stays"))), "Boldstays")
        XCTAssertEqual(try docxReadingText(body: docxParagraph(italic("Slant") + italic("ed"))), "Slanted")
        // A word whose letters change from one emphasis straight to another
        XCTAssertEqual(try docxReadingText(body: docxParagraph(bold("a") + boldItalic("b") + italic("c"))), "abc")
    }

    /// Hidden words between bold runs leave nothing behind: the bold runs on
    /// either side of them are one stretch.
    func testHiddenRunsLeaveNoMarks() throws {
        let body = docxParagraph(bold("Bold ") + docxRun("gone ", "<w:b/><w:vanish/>") + bold("stays"))
        XCTAssertEqual(try docxReadingText(body: body), "Bold stays")
    }

    /// Punctuation at the edge of an emphasis speaks no mark: a bold colon
    /// straight after a word, and bold punctuation around words.
    func testPunctuationAtAnEdgeSpeaksNoMark() throws {
        XCTAssertEqual(try docxReadingText(body: docxParagraph(docxRun("Note") + bold(":") + docxRun(" next"))), "Note: next")
        XCTAssertEqual(try docxReadingText(body: docxParagraph(bold("Note:") + docxRun(" next"))), "Note: next")
        XCTAssertEqual(try docxReadingText(body: docxParagraph(bold("(") + bold("aside") + bold(")") + docxRun(" next"))), "(aside) next")
        XCTAssertEqual(try docxReadingText(body: docxParagraph(italic("\u{201C}Quote,\u{201D}") + docxRun(" he said"))), "\u{201C}Quote,\u{201D} he said")
    }

    /// Strikethrough is written as plain text: a struck word is read as it is,
    /// and no tilde is ever spoken.
    func testStrikethroughIsWrittenPlain() throws {
        let body = docxParagraph(docxRun("A ") + docxRun("struck", "<w:strike/>") + docxRun(" word and ") + docxRun("both", "<w:strike/><w:b/>"))
        XCTAssertEqual(try docxReadingText(body: body), "A struck word and both")
        XCTAssertFalse(try docxMarkdown(body: body).contains("~"))
    }

    // MARK: - Seams

    /// A page mark, a line break, a link, and a heading end a stretch of runs and
    /// leave no mark spoken.
    func testSeamsLeaveNoMarksSpoken() throws {
        // A page break inside a bold stretch
        let paged = docxParagraph(bold("alpha ") + "<w:r><w:rPr><w:b/></w:rPr><w:br w:type=\"page\"/></w:r>" + bold(" beta"))
        let markdown = try docxMarkdown(body: paged, includesPages: true)
        XCTAssertEqual(try pageLabels(of: markdown), ["1", "2"])
        XCTAssertEqual(try MarkdownDocParser.parseChapter(markdown: markdown).text, "alpha beta")
        // A line break inside a bold stretch
        let broken = docxParagraph(bold("one") + "<w:r><w:rPr><w:b/></w:rPr><w:br/></w:r>" + bold("two"))
        XCTAssertFalse(try docxReadingText(body: broken).contains("*"))
        // A link with a bold label, next to bold words
        let linked = docxParagraph(bold("Go ") + "<w:hyperlink r:id=\"rId9\">" + bold("here") + "</w:hyperlink>" + bold(" now"))
        XCTAssertEqual(try docxReadingText(body: linked), "Go here now")
        // A heading with a bold word
        let styles = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
            </w:styles>
            """
        let heading = docxParagraph(docxRun("Chapter ") + bold("One"), style: "Heading1")
        XCTAssertEqual(try docxReadingText(body: heading, styles: styles), "Chapter One")
    }

    // MARK: - Every combination

    /// Every sequence of two runs, in every emphasis, of words, white space,
    /// punctuation, and a phrase, and of three runs of a word, a space, and a
    /// colon, reads exactly its characters, with no mark of emphasis. One
    /// paragraph for each.
    func testNoCombinationOfRunsSpeaksAMark() throws {
        let emphases: [(String, String)] = [("", ""), ("<w:b/>", "b"), ("<w:i/>", "i"), ("<w:b/><w:i/>", "bi")]
        struct Run { let piece: String; let emphasis: Int }
        func sequences(of pieces: [String], length: Int) -> [[Run]] {
            var result: [[Run]] = [[]]
            for _ in 0..<length {
                result = result.flatMap { sequence in
                    pieces.flatMap { piece in emphases.indices.map { sequence + [Run(piece: piece, emphasis: $0)] } }
                }
            }
            return result
        }
        let all = sequences(of: ["ab", " ", ":", "c d", "."], length: 2) + sequences(of: ["ab", " ", ":"], length: 3)
        let body = all.map { sequence in
            docxParagraph(sequence.map { docxRun($0.piece, emphases[$0.emphasis].0) }.joined())
        }.joined()
        let spoken = try docxReadingText(body: body)
        XCTAssertFalse(spoken.contains("*"), "an asterisk is spoken")
        XCTAssertFalse(spoken.contains("~"), "a tilde is spoken")
        // Every character comes through, in order (white space aside)
        let expected = all.map { $0.map(\.piece).joined() }.joined()
        XCTAssertEqual(spoken.filter { !$0.isWhitespace }, expected.filter { !$0.isWhitespace })
    }
}
