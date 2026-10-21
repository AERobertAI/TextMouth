import XCTest
@testable import TextMouth

/// The page marker written into content.md and the shared placement of
/// markers in converted Markdown (PG01): what a label becomes, how it is
/// escaped and read back, what is and is not a marker, and where a marker may
/// be written without hiding the words around it.
final class MarkdownPageMarkerTests: XCTestCase {
    // MARK: - Helpers

    /// The marker for `label` as a book's first page would be written.
    private func marker(_ label: String, ordinal: Int = 1) -> MarkdownPageMarker {
        MarkdownPageMarker(label: label, ordinal: ordinal)
    }

    /// `markdown` after writing page marker `<!-- page: 2 -->` into `start`.
    private func written(
        into start: String, inline: Bool, keepingWordsApart: Bool = false
    ) -> String {
        var markdown = start
        MarkdownMarkerWriter.write(
            "<!-- page: 2 -->", inline: inline, keepingWordsApart: keepingWordsApart, into: &markdown)
        return markdown
    }

    // MARK: - Writing

    func testOrdinaryLabelsAreWrittenAsTheyAre() {
        for label in ["12", "xii", "A-3", "S 4"] {
            XCTAssertEqual(marker(label).markdown, "<!-- page: \(label) -->")
        }
    }

    // MARK: - Normalizing

    func testALabelIsTrimmedAndItsWhitespaceRunsBecomeOneSpace() {
        XCTAssertEqual(marker("  12 \n").label, "12")
        XCTAssertEqual(marker("S \t\n 4").label, "S 4")
        XCTAssertEqual(marker("a\u{2028}b").label, "a b")
    }

    func testALongLabelIsCutToThirtyTwoCharacters() {
        let letters = String(repeating: "a", count: 40)
        XCTAssertEqual(marker(letters).label, String(repeating: "a", count: 32))
        // Characters count, not scalars or bytes: a book emoji is one.
        let books = String(repeating: "📖", count: 40)
        XCTAssertEqual(marker(books).label, String(repeating: "📖", count: 32))
        // A cut that ends just after spaces is trimmed again.
        let spaced = String(repeating: "a", count: 31) + "b" + "   more text"
        XCTAssertEqual(marker(spaced).label, String(repeating: "a", count: 31) + "b")
    }

    func testALabelWithNothingLeftIsTheOrdinal() {
        XCTAssertEqual(marker("", ordinal: 7).label, "7")
        XCTAssertEqual(marker(" \n\t ", ordinal: 7).label, "7")
        XCTAssertEqual(marker("", ordinal: 7).markdown, "<!-- page: 7 -->")
    }

    // MARK: - Escaping

    func testTheCharactersThatBreakACommentAreEscaped() {
        XCTAssertEqual(marker("50%").markdown, "<!-- page: 50%25 -->")
        XCTAssertEqual(marker("<b>").markdown, "<!-- page: %3Cb%3E -->")
        XCTAssertEqual(marker("a--b").markdown, "<!-- page: a-%2Db -->")
        XCTAssertEqual(marker("---").markdown, "<!-- page: -%2D%2D -->")
        XCTAssertEqual(marker("-").markdown, "<!-- page: - -->")
        XCTAssertEqual(marker("A-").markdown, "<!-- page: A- -->")
        XCTAssertEqual(marker("->").markdown, "<!-- page: -%3E -->")
        XCTAssertEqual(marker("x\u{0}y").markdown, "<!-- page: x%00y -->")
        XCTAssertEqual(marker("\u{7F}").markdown, "<!-- page: %7F -->")
    }

    func testAnEscapedMultiByteScalarIsWrittenOneByteAtATime() {
        // U+0080 is a control that normalizing keeps (it is not whitespace)
        // and that takes two UTF-8 bytes.
        XCTAssertEqual(marker("a\u{80}b").markdown, "<!-- page: a%C2%80b -->")
        XCTAssertEqual(MarkdownPageMarker.decode("<!-- page: a%C2%80b -->")?.label, "a\u{80}b")
        XCTAssertEqual(marker("é").markdown, "<!-- page: é -->")
    }

    // MARK: - Round trip

    func testEveryLabelReadsBackAsItWasWritten() {
        let labels = [
            "12", "xii", "A-3", "S 4", "50%", "100%25", "<b>", "a--b", "---", "-", "A-", "->",
            "x\u{0}y", "📖12", "é", "中文",
        ]
        for label in labels {
            let original = marker(label)
            XCTAssertEqual(MarkdownPageMarker.decode(original.markdown)?.label, original.label, label)
            // The text between "<!--" and "-->" must hold no "--", or a
            // Markdown parser would end or refuse the comment there.
            let inner = original.markdown.dropFirst(4).dropLast(3)
            XCTAssertFalse(inner.contains("--"), label)
        }
    }

    // MARK: - Reading

    func testAMarkerIsReadFromAComment() {
        XCTAssertEqual(MarkdownPageMarker.decode("<!-- page: 12 -->")?.label, "12")
        XCTAssertEqual(MarkdownPageMarker.decode("\n  <!-- page: 12 -->\n")?.label, "12")
        XCTAssertEqual(MarkdownPageMarker.decode("<!-- page: 50% -->")?.label, "50%")
        XCTAssertEqual(MarkdownPageMarker.decode("<!-- page: %41 -->")?.label, "A")
        XCTAssertEqual(MarkdownPageMarker.decode("<!-- page: %e4%b8%ad -->")?.label, "中")
    }

    /// A label that begins with a combining mark reads back: the mark and
    /// the space before it are one Character, so the marker is found by
    /// its Unicode scalars, not its Characters.
    func testALabelBeginningWithACombiningMarkReadsBack() {
        let marker = MarkdownPageMarker(label: "\u{301}x", ordinal: 1)
        XCTAssertEqual(marker.label, "\u{301}x")
        XCTAssertEqual(MarkdownPageMarker.decode(marker.markdown)?.label, "\u{301}x")
        XCTAssertEqual(MarkdownPageMarker.decode("<!-- page: x\u{301} -->")?.label, "x\u{301}")
    }

    func testAnythingElseIsNotAMarker() {
        let refused = [
            "<!--page: 12 -->",
            "<!-- page:12 -->",
            "<!-- page: 12-->",
            "<!-- Page: 12 -->",
            "<!-- page: 12 --> more",
            "<!-- page:  -->",
            "<!-- page: -->",
            "<!-- page: a--b -->",
            "<!-- page: <b> -->",
            "<!-- page: 12 --><!-- page: 13 -->",
            "<!-- page: %FF -->",
            "<!-- page: %20 -->",
            "",
        ]
        for comment in refused {
            XCTAssertNil(MarkdownPageMarker.decode(comment), comment)
        }
    }

    func testMarkersAndAnnotationsAreNotMistakenForEachOther() {
        let annotation = MarkdownHeadingAnnotation(level: 1, text: "x").markdown
        XCTAssertNil(MarkdownPageMarker.decode(annotation))
        XCTAssertNil(MarkdownPageMarker.decode("<!-- chapter: 12 -->"))
        XCTAssertNil(MarkdownHeadingAnnotation.decode(marker("12").markdown))
    }

    // MARK: - Placement

    func testLinePositionIsClassifiedFromTheEndOfTheMarkdown() {
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: ""), .blockStart)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "  "), .blockStart)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "text"), .withinLine)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "text  \n"), .continuationLine)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "text\n   "), .continuationLine)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "text\n\n"), .blockStart)
    }

    func testAnInlineMarkerStaysInTheLineItStandsIn() {
        let marker = "<!-- page: 2 -->"
        XCTAssertEqual(written(into: "text", inline: true), "text" + marker)
        XCTAssertEqual(written(into: "text", inline: true, keepingWordsApart: true), "text " + marker)
        // No second space where one already ends the text.
        XCTAssertEqual(written(into: "text ", inline: true, keepingWordsApart: true), "text " + marker)
        // After a hard break, four spaces keep the marker inside the paragraph.
        XCTAssertEqual(written(into: "text  \n", inline: true), "text  \n    " + marker)
    }

    func testAMarkerNeverBeginsALine() {
        let marker = "<!-- page: 2 -->"
        XCTAssertEqual(written(into: "text\n\n", inline: true), "text\n\n" + marker + "\n\n")
        XCTAssertEqual(written(into: "text", inline: false), "text\n\n" + marker + "\n\n")
        XCTAssertEqual(written(into: "text\n", inline: false), "text\n\n" + marker + "\n\n")
        XCTAssertEqual(written(into: "", inline: true), marker + "\n\n")
        XCTAssertEqual(written(into: "", inline: false), marker + "\n\n")
    }

    func testABlankLineIsEnsuredOnlyWhenMissing() {
        var markdown = ""
        MarkdownMarkerWriter.ensureBlankLine(&markdown)
        XCTAssertEqual(markdown, "")
        for (start, expected) in [("a", "a\n\n"), ("a\n", "a\n\n"), ("a\n\n", "a\n\n")] {
            markdown = start
            MarkdownMarkerWriter.ensureBlankLine(&markdown)
            XCTAssertEqual(markdown, expected)
        }
    }
}
