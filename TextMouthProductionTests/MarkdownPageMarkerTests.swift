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
        into start: String, inline: Bool, keepingWordsApart: Bool = false, continuationAtMargin: Bool = false
    ) -> String {
        var markdown = start
        MarkdownMarkerWriter.write(
            "<!-- page: 2 -->", inline: inline, keepingWordsApart: keepingWordsApart,
            continuationAtMargin: continuationAtMargin, into: &markdown)
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

    // MARK: - Page numbers and real words (ST02)

    /// The one rule EPUB and DAISY share for text found where a page begins.
    func testNoMoreThanLabel() {
        let rows: [(text: String, label: String, expected: Bool)] = [
            ("", "12", true),
            ("  ", "12", true),
            ("12", "12", true),
            ("Page 12", "12", true),
            ("12", "Page 12", true),
            ("p. XII", "xii", true),
            ("Hello there", "12", false),
            ("Chapter One", "", true),
            (String(repeating: "a", count: 33), "", false),
            ("12\n  ", "12", true),
            ("Page\n12", "Page 12", true),
            // A number in another numbering than its label's is still a number.
            ("V", "5", true),
            ("xiv", "14", true),
            ("[12]", "twelve", true),
            ("Hello", "5", false),
            ("A-3", "4", false),
        ]
        for row in rows {
            XCTAssertEqual(
                MarkdownPageMarker.isNoMoreThanLabel(row.text, label: row.label), row.expected,
                "row (text: \(String(reflecting: row.text)), label: \(String(reflecting: row.label)))"
            )
        }
    }

    // MARK: - A marker at a line's start (ST05)

    /// The chapter `markdown` parses to, with markers read when `navigation`.
    private func chapter(_ markdown: String, navigation: Bool = true) throws -> Chapter {
        try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: navigation)
    }

    /// The UTF-16 offset at which `words` first stands in `chapter`'s text, or -1.
    private func offset(of words: String, in chapter: Chapter) -> Int {
        let range = (chapter.text as NSString).range(of: words)
        return range.location == NSNotFound ? -1 : range.location
    }

    /// CommonMark makes the whole line an HTML block when it begins with a
    /// comment, so the words after the marker were once lost.
    func testWordsAfterAPageMarkerAtALineStartAreRead() throws {
        let result = try chapter("First line.\n<!-- page: 12 -->Second line words.\n")

        XCTAssertTrue(result.text.contains("First line."), result.text)
        XCTAssertTrue(result.text.contains("Second line words."), result.text)
        XCTAssertEqual(result.pages.map(\.label), ["12"])
        XCTAssertEqual(result.pages.first?.characterOffset, offset(of: "Second", in: result))
    }

    func testWordsAfterAHeadingAnnotationAtALineStartAreRead() throws {
        let annotation = MarkdownHeadingAnnotation(level: 2, text: "Part Two").markdown
        let result = try chapter("Before.\n" + annotation + "Words after.\n")

        XCTAssertTrue(result.text.contains("Words after."), result.text)
        let heading = result.headings.first { $0.text == "Part Two" }
        XCTAssertNotNil(heading, "\(result.headings)")
        XCTAssertEqual(heading?.characterOffset, offset(of: "Words", in: result))
    }

    func testWordsAfterTwoMarkersAreRead() throws {
        let result = try chapter("<!-- page: 3 --> <!-- page: 4 -->Both pages here.\n")

        XCTAssertTrue(result.text.contains("Both pages here."), result.text)
        XCTAssertEqual(result.pages.map(\.label), ["3", "4"])
        XCTAssertEqual(result.pages.map(\.characterOffset), [0, 0])
    }

    /// The words are the book's, so they are read where the markers are not.
    func testWordsAfterAMarkerAreReadWithoutNavigation() throws {
        let result = try chapter("First line.\n<!-- page: 12 -->Second line words.\n", navigation: false)

        XCTAssertTrue(result.text.contains("Second line words."), result.text)
        XCTAssertTrue(result.pages.isEmpty)
    }

    func testWordsAfterAMarkerInAListItemAreRead() throws {
        let result = try chapter("- <!-- page: 3 -->Item words\n")

        XCTAssertTrue(result.text.contains("Item words"), result.text)
        XCTAssertEqual(result.pages.map(\.label), ["3"])
        XCTAssertEqual(result.pages.first?.characterOffset, offset(of: "Item", in: result))
    }

    func testEmphasisAfterAMarkerIsRead() throws {
        let result = try chapter("<!-- page: 4 -->Some *emphasised* words\n")

        XCTAssertTrue(result.text.contains("Some emphasised words"), result.text)
        XCTAssertEqual(result.pages.map(\.label), ["4"])
    }

    /// A marker on a line of its own reads as it did before this change:
    /// the text and the page are fixed.
    func testAMarkerAloneOnItsLineReadsAsBefore() throws {
        let result = try chapter("Alpha.\n\n<!-- page: 5 -->\n\nBeta.\n")

        XCTAssertEqual(result.text, "Alpha.\n\nBeta.")
        XCTAssertEqual(result.pages.map(\.label), ["5"])
        XCTAssertEqual(result.pages.map(\.characterOffset), [8])
    }

    /// A comment of the source's own keeps its words hidden, as ever, and a
    /// very long line of markers is peeled without deepening the stack.
    func testOtherCommentsStayHiddenAndManyMarkersAreSafe() throws {
        let other = try chapter("<!-- note --> hidden words\n")
        XCTAssertFalse(other.text.contains("hidden"), other.text)

        let markers = String(repeating: "<!-- page: 1 -->", count: 10_000)
        let many = try chapter(markers + "Words.\n")
        XCTAssertTrue(many.text.contains("Words."), many.text)
        XCTAssertEqual(many.pages.count, 10_000)
    }

    // MARK: - Placement

    func testLinePositionIsClassifiedFromTheEndOfTheMarkdown() {
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: ""), .blockStart)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "  "), .blockStart)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "text"), .withinLine)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "text  \n"), .continuationLine)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "text\n   "), .continuationLine)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "text\n\n"), .blockStart)
        // The opening of a list item, quote, or heading, before its words.
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "- "), .containerStart(continuation: "  "))
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "a\n- \n  "), .containerStart(continuation: "  "))
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "12. "), .containerStart(continuation: "    "))
        // Four columns in, the opening may be code in a list broken apart.
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "    12. "), .blockStart)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "a\n\t- \n  "), .blockStart)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "a\n    words\n"), .blockStart)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "> - "), .containerStart(continuation: ">   "))
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "## \n  "), .headingStart)
        // Lines no paragraph continues are followed by a block.
        for ended in ["## Heading\n  ", "Title\n---\n", "***\n", "```\n", "a\n*\n"] {
            XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: ended), .blockStart, ended)
        }
        // A list marker without the whitespace after it opens nothing.
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "*Roses\n*"), .withinLine)
    }

    func testAnInlineMarkerStaysInTheLineItStandsIn() {
        let marker = "<!-- page: 2 -->"
        XCTAssertEqual(written(into: "text", inline: true), "text" + marker)
        XCTAssertEqual(written(into: "text", inline: true, keepingWordsApart: true), "text " + marker)
        // No second space where one already ends the text.
        XCTAssertEqual(written(into: "text ", inline: true, keepingWordsApart: true), "text " + marker)
        // After a line break, at the end of the line before, where the hard
        // break's two spaces stay last.
        XCTAssertEqual(written(into: "text  \n", inline: true), "text" + marker + "  \n")
        // The space a page that joined words brings never completes a list
        // item's marker: it goes after the marker instead.
        XCTAssertEqual(written(into: "*Roses\n*", inline: true, keepingWordsApart: true), "*Roses\n*" + marker + " ")
    }

    /// A caller that writes each line at its block's own margin, as the HTML
    /// converter does, has its markers placed by indentation alone, as before
    /// list items, quotes, and headings were read: after a hard break, four
    /// spaces begin the marker's line. Its heading annotations, whose places
    /// are exact, so stay where cache format 3.0.7 wrote them.
    func testAMarginCallersMarkersArePlacedByIndentationAlone() {
        let marker = "<!-- page: 2 -->"
        XCTAssertEqual(written(into: "text  \n", inline: true, continuationAtMargin: true), "text  \n    " + marker)
        XCTAssertEqual(written(into: "text\n   ", inline: true, continuationAtMargin: true), "text\n   " + "    " + marker)
        XCTAssertEqual(written(into: "text", inline: true, continuationAtMargin: true), "text" + marker)
        XCTAssertEqual(written(into: "text\n\n", inline: true, continuationAtMargin: true), "text\n\n" + marker + "\n\n")
        XCTAssertEqual(written(into: "", inline: true, continuationAtMargin: true), marker + "\n\n")
    }

    /// A marker written at the end of `before`, with `after` then written as
    /// the next words, in every block context a converter writes: the
    /// reader's parse keeps every word (`spoken`, whitespace runs made one
    /// space) and reads no marker aloud, and the page begins at `opening`.
    /// Before the writer knew list items, quotes, and headings, every case
    /// but the first two and the hard break in a list item lost words or read
    /// the marker as code.
    func testAMarkerKeepsEveryWordInEveryBlockContext() {
        let cases: [(before: String, after: String, joinsWords: Bool, spoken: String, opening: String)] = [
            ("one two", " three", false, "one two three", "three"),
            ("Para one\n", "after break", false, "Para one after break", "after"),
            // A list item's opening, also with the source's whitespace after it.
            ("- First item words.\n- ", "Second item words.", false, "First item words. Second item words.", "Second"),
            ("- First item words.\n- \n  ", "Second item words.", false, "First item words. Second item words.", "Second"),
            ("- a\n    - b\n    - ", "c words", false, "a b c words", "c words"),
            ("10. Ten\n11. ", "Eleven words.", false, "Ten Eleven words.", "Eleven"),
            // A block quote's opening, alone or around a list item.
            ("> ", "Quoted words.", false, "Quoted words.", "Quoted"),
            ("> Quoted\n> \n      ", "Quoted words.", false, "Quoted Quoted words.", "Quoted words."),
            ("> - ", "Quoted item words.", false, "Quoted item words.", "Quoted"),
            // A heading's opening, and the line after a heading.
            ("## \n  ", "Chapter Two", false, "Chapter Two", "Chapter"),
            ("## Heading\n    ", "After.", false, "Heading After.", "After."),
            ("Title\n---\n", "more", false, "Title more", "more"),
            // After a line break in a list item, and after a hard break.
            ("- Item\n", "more words", false, "Item more words", "more"),
            ("1. Item\n", "more words", false, "Item more words", "more"),
            ("- First item\n ", "more words", false, "First item more words", "more"),
            ("- Item  \n  ", "more words", false, "Item more words", "more"),
            // An italic line whose line break is inside the emphasis, then a
            // page that joined two words.
            ("*Roses\n*", "are red.", true, "*Roses * are red.", "are red."),
        ]
        for testCase in cases {
            let content = parsedAfterWritingAMarker(
                into: testCase.before, then: testCase.after, keepingWordsApart: testCase.joinsWords
            )
            let markdown = content.markdown
            let text = content.document.chapters.map(\.text).joined(separator: "\n\n")
            XCTAssertEqual(text.split(whereSeparator: \.isWhitespace).joined(separator: " "), testCase.spoken, markdown)
            XCTAssertFalse(text.contains("<!--"), markdown)
            XCTAssertEqual(content.document.pages.breaks.map(\.label), ["2"], markdown)
            if let page = content.document.pages.breaks.first,
               content.document.chapters.indices.contains(page.chapterIndex) {
                let chapter = content.document.chapters[page.chapterIndex].text as NSString
                let opening = chapter.substring(from: min(page.characterOffset, chapter.length))
                XCTAssertTrue(opening.hasPrefix(testCase.opening), "\(markdown): the page opens at \"\(opening)\"")
            }
        }

        // A hard break stays one: the marker is written before its spaces.
        let hardBreak = parsedAfterWritingAMarker(into: "- Item  \n  ", then: "more words")
        XCTAssertEqual(hardBreak.document.chapters.first?.text, "Item\nmore words", hardBreak.markdown)
    }

    /// The Markdown made by writing page marker `<!-- page: 2 -->` inline at
    /// the end of `before` and then `after`, and the reader's parse of it.
    private func parsedAfterWritingAMarker(
        into before: String, then after: String, keepingWordsApart: Bool = false
    ) -> (markdown: String, document: DocumentContent) {
        var markdown = before
        MarkdownMarkerWriter.write("<!-- page: 2 -->", inline: true, keepingWordsApart: keepingWordsApart, into: &markdown)
        markdown += after
        return (markdown, MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: "Pages", bookAuthor: "Test"))
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
