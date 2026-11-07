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

    /// A label that is only the word "Page", which a generator writes when
    /// it has no number for the page (`aria-label="Page "`), names no page,
    /// so the marker takes the ordinal, and the reader never says "Page Page
    /// of 1". A label holding anything besides the word is a name.
    func testALabelOfOnlyTheWordPageIsTheOrdinal() {
        for label in ["Page", "Page ", "PAGE", " page. ", "Page\n", "Page:", "Page page"] {
            XCTAssertEqual(marker(label, ordinal: 3).label, "3", label)
        }
        for label in ["Pages", "Pg", "Page-1"] {
            XCTAssertEqual(marker(label, ordinal: 3).label, label, label)
        }
    }

    /// A label that begins with the word "Page" names the page after it, as
    /// the reader says "Page" itself (the user's choice, November 4, 2026):
    /// "Page 12" is the page "12", not one the reader shows as "Page Page 12
    /// of 300". The word may end in a period or a colon, and the name follows
    /// a space or begins with a digit. A word that only begins with the
    /// letters stays a name of its own.
    func testALeadingWordPageIsTakenOff() {
        let expected = [
            ("Page 12", "12"), ("page xii", "xii"), ("PAGE: 3", "3"), ("Page. 4", "4"), ("Page12", "12"),
            ("Page:12", "12"), ("  Page   A-3 ", "A-3"), ("Page iv.", "iv."), ("Pages 4", "Pages 4"),
            ("Pageant", "Pageant"), ("Page-1", "Page-1"), ("page_12", "page_12"),
        ]
        for (label, page) in expected {
            XCTAssertEqual(marker(label).label, page, "\"\(label)\"")
        }
        // A content.md written before reads its "Page 12" as the page "12".
        XCTAssertEqual(MarkdownPageMarker.decode("<!-- page: Page 12 -->")?.label, "12")
        XCTAssertEqual(marker("Page 12").markdown, "<!-- page: 12 -->")
        // A name longer than a label is cut after the word is taken off.
        let long = "Page " + String(repeating: "x", count: 40)
        XCTAssertEqual(marker(long).label, String(repeating: "x", count: MarkdownPageMarker.maximumLabelLength))
    }

    /// Which labels name no page (`namesNoPage`): blank ones, a lone period,
    /// and the word "Page" alone in any capitals, with a period or a colon,
    /// even before another "page"; any other text names one.
    func testWhichLabelsNameNoPage() {
        for label in ["", "  ", "\n\t", ".", "Page", "page ", " PAGE.", "Page\n", "Page:", "Page page", "Page ."] {
            XCTAssertTrue(MarkdownPageMarker.namesNoPage(label), "\"\(label)\"")
        }
        for label in ["1", "xii", "A-3", "Page 1", "Pages", "Pg", "-", "pagenum_000000"] {
            XCTAssertFalse(MarkdownPageMarker.namesNoPage(label), "\"\(label)\"")
        }
    }

    /// Which labels are page numbers (`isPageNumber`), by the rule
    /// `isNoMoreThanLabel` reads them with: ASCII digits, or a canonical
    /// Roman numeral, with case, white space, one trailing period, and a
    /// leading word "Page" set aside.
    func testWhichLabelsArePageNumbers() {
        for label in ["1", "12", " 300 ", "xii", "XIV", "iv.", "MCMLXXXIV", "Page 12", "page xii"] {
            XCTAssertTrue(MarkdownPageMarker.isPageNumber(label), "\"\(label)\"")
        }
        for label in ["", "A-3", "pagenum_000000", "p12", "IIII", "Page A-3", "1.5", "12a", "\u{0661}\u{0662}"] {
            XCTAssertFalse(MarkdownPageMarker.isPageNumber(label), "\"\(label)\"")
        }
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

    /// A row of the rule's table: the text found where a page begins, the
    /// page's label, and whether the text is no more than that label.
    private typealias LabelRow = (text: String, label: String, expected: Bool)

    /// Asserts `MarkdownPageMarker.isNoMoreThanLabel` gives each row's answer,
    /// naming the row that does not.
    private func assertNoMoreThanLabel(_ rows: [LabelRow], file: StaticString = #filePath, line: UInt = #line) {
        for row in rows {
            XCTAssertEqual(
                MarkdownPageMarker.isNoMoreThanLabel(row.text, label: row.label), row.expected,
                "row (text: \(String(reflecting: row.text)), label: \(String(reflecting: row.label)))",
                file: file, line: line
            )
        }
    }

    /// The one rule EPUB and DAISY share for text found where a page begins:
    /// only the page's own label is dropped, ignoring case, spaces, and a
    /// trailing period, or its twin in the other numbering.
    func testNoMoreThanLabel() {
        assertNoMoreThanLabel([
            ("", "12", true),
            ("  ", "12", true),
            ("12", "12", true),
            ("12.", "12", true),
            ("12", "12.", true),
            ("XII", "xii", true),
            ("Page 12", "page12", true),
            ("Hello there", "12", false),
            ("Chapter One", "", true),
            (String(repeating: "a", count: 33), "", false),
            ("12\n  ", "12", true),
            ("Page\n12", "Page 12", true),
            // A caption, or a longer label, is not the page's own label: its
            // words are read (stable020 review, finding 2).
            ("Page 12", "12", false),
            ("12", "Page 12", false),
            ("p. XII", "xii", false),
            ("[12]", "12", false),
            ("[12]", "twelve", false),
            // A number in the other numbering is the label's twin, either way.
            ("V", "5", true),
            ("5", "V", true),
            ("v.", "5", true),
            ("xiv", "14", true),
            ("14", "XIV", true),
            ("MCMLXXXIV", "1984", true),
            // Only a canonical Roman numeral is a twin, and only of its value.
            ("IIII", "4", false),
            ("4", "IIII", false),
            ("VI", "5", false),
            ("Hello", "5", false),
            ("A-3", "4", false),
        ])
    }

    /// The headings ST02 dropped under a page's label (stable020 review,
    /// finding 2), each tested both ways: read under any label it is not
    /// ("5", one it holds, one that holds it, and with the two swapped), and
    /// dropped only under its own label, however spelled, or that label's
    /// twin.
    func testAHeadingThatLooksLikeANumberIsReadUnlessItIsThePagesLabel() {
        assertNoMoreThanLabel([
            ("IV", "5", false), ("5", "IV", false),
            ("IV", "V", false), ("IV", "XIV", false),
            ("IV", "iv", true), ("IV", "4", true),

            ("XII.", "5", false), ("5", "XII.", false),
            ("XII.", "XI", false), ("XII.", "XIII", false),
            ("XII.", "xii", true), ("XII.", "12", true),

            ("I", "5", false), ("5", "I", false),
            ("I", "II", false), ("I", "XI", false),
            ("I", "i", true), ("I", "1", true),

            ("1984", "5", false), ("5", "1984", false),
            ("1984", "9", false), ("1984", "19845", false),
            ("1984", "1984.", true), ("1984", "MCMLXXXIV", true),

            ("1, 2, 3.", "5", false), ("5", "1, 2, 3.", false),
            ("1, 2, 3.", "1", false), ("1, 2, 3.", "1, 2, 3, 4", false),
            ("1, 2, 3.", "1,2,3", true),
        ])
    }

    /// Words made only of Roman numeral letters are words under another
    /// page's label (finding 2, as EPUB's page-break elements met them), and
    /// are dropped only as their own label or as the twin of the one number
    /// a canonical numeral writes ("MIX" is 1009).
    func testWordsOfRomanNumeralLettersAreReadUnderAnotherLabel() {
        assertNoMoreThanLabel([
            ("Mix", "5", false),
            ("Civil", "5", false),
            ("Mix", "XV", false),
            ("Civil", "civil", true),
            ("Mix", "1009", true),
            ("Civil", "100", false),
        ])
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

    /// A crafted line whose rest is a block quote holding another marker-led
    /// block, 5,000 levels deep, once re-parsed the rest of the line at every
    /// level. The re-parsing now goes one level deep: the first marker and
    /// the first level are read, and an HTML block inside the first level's
    /// rest reads as it did before ST05 (so the markers and words from the
    /// second level on are not read). The test asserts only that the parse
    /// returns and finds the first page.
    func testNestedMarkerLedBlocksAreReadOneLevelDeep() throws {
        let line = String(repeating: "<!-- page: 1 -->> ", count: 5_000) + "Deep words.\n"
        let result = try chapter(line)

        XCTAssertEqual(result.pages.first?.label, "1")
        XCTAssertFalse(result.pages.isEmpty)
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

    /// A line of one repeated mark ends its paragraph only when it is a setext
    /// underline or a thematic break, wherever its spaces are.
    func testOnlyLinesOfOneRepeatedMarkEndAParagraph() {
        for ended in ["a\n===\n", "a\n= =\n", "a\n=\n", "a\n* * *\n", "a\n___\n", "a\n- - -\n", "a\n~~~\n"] {
            XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: ended), .blockStart, ended)
        }
        for continued in ["a\n**\n", "a\n__\n", "a\n-*-\n", "a\n---x\n", "a\n\u{2014}\u{2014}\u{2014}\n"] {
            XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: continued), .continuationLine, continued)
        }
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

    // MARK: - A Long Last Line

    /// A line of many thousands of scalars is not walked back to its start for
    /// every marker written in it: a book's paragraph holding 20,000 pages
    /// took 116 s to write (2 MB), where it now takes a few milliseconds. The
    /// limit is thirty seconds, which the quadratic walk passes at about half
    /// the pages (it is checked as the pages are written, so a regression
    /// fails in half a minute and does not wait for the end), and which a
    /// busy machine cannot make the linear walk reach.
    func testManyMarkersInOneLongParagraphAreWrittenInLinearTime() {
        let pages = 20_000
        let words = String(repeating: "word ", count: 20)
        let limit: Duration = .seconds(30)
        // Every way a caller writes an inline marker.
        let callers: [(keepingWordsApart: Bool, continuationAtMargin: Bool)] = [
            (false, true), (true, false), (false, false),
        ]
        for caller in callers {
            var markdown = ""
            let clock = ContinuousClock()
            let start = clock.now
            var written = 0
            while written < pages, clock.now - start < limit {
                markdown += words
                MarkdownMarkerWriter.write(
                    "<!-- page: \(written + 1) -->", inline: true,
                    keepingWordsApart: caller.keepingWordsApart,
                    continuationAtMargin: caller.continuationAtMargin, into: &markdown)
                written += 1
            }
            XCTAssertEqual(written, pages, "\(caller): \(written) pages were written in \(limit)")
            // The words and markers are all there, one paragraph still.
            XCTAssertEqual(markdown.filter { $0 == "\n" }.count, 0, "\(caller)")
            XCTAssertTrue(markdown.hasSuffix("<!-- page: \(pages) -->"), "\(caller)")
        }
    }

    /// Where a marker is written is the same however long the last line is:
    /// the scan back stops at a scalar only words hold, and reads on through
    /// a tail of marker characters, indentation, and openings to the start.
    func testAMarkerInALongLineIsPlacedAsInAShortOne() {
        let marker = "<!-- page: 2 -->"
        let long = 5_000
        // Words far back, then a long tail of delimiters and marker
        // characters: the line holds words, so the space goes before.
        for tail in ["-", "*", "_", "~", "#", "+", "1.", " ", "\t", ">"] {
            let line = "words " + String(repeating: tail, count: long)
            XCTAssertEqual(
                written(into: line, inline: true, keepingWordsApart: true),
                line + (line.last?.isWhitespace == true ? "" : " ") + marker, "tail \(tail.debugDescription)")
        }
        // A line made only of emphasis delimiters, or only of a list
        // marker's or heading's characters, is read to its start, and the
        // space goes after the marker, as it does in a short one.
        let delimiters = String(repeating: "*", count: long)
        XCTAssertEqual(written(into: delimiters, inline: true, keepingWordsApart: true), delimiters + marker + " ")
        XCTAssertEqual(written(into: "*Roses\n" + delimiters, inline: true, keepingWordsApart: true),
                       "*Roses\n" + delimiters + marker + " ")
        XCTAssertEqual(written(into: "1.", inline: true, keepingWordsApart: true), "1." + marker + " ")
        XCTAssertEqual(written(into: "##", inline: true, keepingWordsApart: true), "##" + marker + " ")
        // The same delimiters after a word are words: the space goes before.
        XCTAssertEqual(written(into: "a" + delimiters, inline: true, keepingWordsApart: true),
                       "a" + delimiters + " " + marker)
        // A scalar outside ASCII, a carriage return, and punctuation prove words too.
        for word in ["\u{E9}", "\r", "`", "<", "!", "\u{2028}"] {
            XCTAssertEqual(written(into: "-" + word + "--", inline: true, keepingWordsApart: true),
                           "-" + word + "-- " + marker, word.debugDescription)
        }
        // A long line indented four columns or more may be code, wherever
        // its words are: the marker is a block of its own, at the margin.
        let indented = "    " + String(repeating: "word ", count: long)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: indented), .withinLine)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "text\n" + indented + "\n"), .blockStart)
        // After a long line's break, the marker goes at its end, as after a short one.
        let longLine = String(repeating: "word ", count: long)
        XCTAssertEqual(written(into: longLine + "\n", inline: true),
                       String(longLine.dropLast()) + marker + " \n")
    }

    /// The characters a line's openings and list markers are made of prove
    /// nothing about its words: a tab is indentation, ")" ends a list marker
    /// ("1)"), and a carriage return is a word scalar. A tail of them is read
    /// to the line's start, as a short line is. (The expected values are what
    /// the writer gave before the long-line scan; the scan is meant to change none.)
    func testTabsAndParenthesesProveNoWordsAndACarriageReturnDoes() {
        let marker = "<!-- page: 2 -->"
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "1.\t"), .containerStart(continuation: "   "))
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "2) "), .containerStart(continuation: "   "))
        XCTAssertEqual(written(into: "1.\t", inline: true), "1. " + marker + "\n   ")
        XCTAssertEqual(written(into: "- \t", inline: true), "- " + marker + "\n  ")
        // A list marker with a ")" alone puts the space after the marker; words after it, before.
        XCTAssertEqual(written(into: "1)", inline: true, keepingWordsApart: true), "1)" + marker + " ")
        XCTAssertEqual(written(into: "w 1)", inline: true, keepingWordsApart: true), "w 1) " + marker)
        XCTAssertEqual(written(into: "w\t1)", inline: true, keepingWordsApart: true), "w\t1) " + marker)
        XCTAssertEqual(written(into: "1.\ta", inline: true, keepingWordsApart: true), "1.\ta " + marker)
        // White space before the marker is enough: none is added after a tab or a carriage return.
        XCTAssertEqual(written(into: "a\t", inline: true, keepingWordsApart: true), "a\t" + marker)
        XCTAssertEqual(written(into: "-\r", inline: true, keepingWordsApart: true), "-\r" + marker)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "\r"), .withinLine)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "\t"), .blockStart)
        // The same after a long line, where the scan stops early: the long tail is read to the start.
        let long = String(repeating: "\t", count: 5_000)
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "1." + long), .containerStart(continuation: "   "))
        XCTAssertEqual(MarkdownMarkerWriter.linePosition(of: "w" + long + "1)"), .withinLine)
    }

    // MARK: - Runs of Page Anchors in the Converters

    /// Eight thousand empty page anchors in a row, a space between each, are
    /// converted in a fraction of a second. Each text node asked where the
    /// page markers that end the Markdown begin, by walking back over all of
    /// them (5,000 took 24 s in the review of `readers/followups-1106`, and
    /// 8,000 would take 61 s): the converter now remembers where they begin. The
    /// limit is twenty seconds.
    func testManyPageAnchorsInARowAreConvertedInLinearTime() throws {
        let count = 8_000
        let anchors = (0..<count).map { "<span epub:type=\"pagebreak\" id=\"p\($0)\" title=\"\($0)\"></span> " }.joined()
        let html = "<html xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><p>word \(anchors)</p><p>after the pages.</p></body></html>"
        let clock = ContinuousClock()
        let start = clock.now
        let markdown = try HTMLToMarkdownConverter.convert(html)
        XCTAssertLessThan(clock.now - start, .seconds(20))
        XCTAssertEqual(markdown.components(separatedBy: "<!-- page:").count - 1, count)
        XCTAssertTrue(markdown.hasPrefix("word<!-- page: 0 --><!-- page: 1 -->"), String(markdown.prefix(60)))
        XCTAssertTrue(markdown.hasSuffix("after the pages\\."), String(markdown.suffix(60)))
    }

    /// Page anchors among words, breaks, quotes, and lists are written where
    /// they stood (the comparison with main's converter on 600 random
    /// documents is in the report).
    func testPageAnchorsAmongWordsAreWrittenWhereTheyStood() throws {
        let html = """
            <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
            <p>One <span epub:type="pagebreak" id="a1" title="1"></span> <span epub:type="pagebreak" id="a2" title="2"></span> two</p>
            <p>Three <span epub:type="pagebreak" id="a3" title="3"></span><br/><span epub:type="pagebreak" id="a4" title="4"></span> four</p>
            <blockquote>Five <span epub:type="pagebreak" id="a5" title="5"></span> <span epub:type="pagebreak" id="a6" title="6"></span> </blockquote>
            <ul><li>Six <span epub:type="pagebreak" id="a7" title="7"></span> <span epub:type="pagebreak" id="a8" title="8"></span></li></ul>
            </body></html>
            """
        let markdown = try HTMLToMarkdownConverter.convert(html)
        XCTAssertTrue(markdown.contains("One <!-- page: 1 --><!-- page: 2 -->two"), markdown)
        XCTAssertTrue(markdown.contains("Three<!-- page: 3 -->  \n    <!-- page: 4 -->four"), markdown)
        XCTAssertTrue(markdown.contains("> Five <!-- page: 5 --><!-- page: 6 -->"), markdown)
        XCTAssertTrue(markdown.contains("- Six<!-- page: 7 --><!-- page: 8 -->"), markdown)
        XCTAssertEqual(markdown.components(separatedBy: "<!-- page:").count - 1, 8)
    }

    /// Ten thousand page numbers in a row after a line of 2 MB, each placed
    /// at the end of that line, are written in a fraction of a second in a
    /// DTBook (5,000 took 15.7 s in the review): the converter remembers where
    /// the last went. The limit is thirty seconds.
    func testManyPageNumbersAfterALongLineAreConvertedInLinearTime() throws {
        let count = 10_000
        let numbers = (0..<count).map { "<pagenum>\($0)</pagenum> " }.joined()
        let line = String(repeating: "word ", count: 400_000)
        let dtbook = "<?xml version=\"1.0\"?><dtbook xmlns=\"http://www.daisy.org/z3986/2005/dtbook/\"><book><bodymatter><level1><poem>"
            + "<line>\(line)</line>\(numbers)</poem></level1></bodymatter></book></dtbook>"
        let clock = ContinuousClock()
        let start = clock.now
        let conversion = try DTBookToMarkdownConverter(data: Data(dtbook.utf8), file: "book.xml").convert()
        XCTAssertLessThan(clock.now - start, .seconds(30))
        XCTAssertEqual(conversion.markdown.components(separatedBy: "<!-- page:").count - 1, count)
        XCTAssertNil(conversion.diagnostic)
    }

    // MARK: - A Run of Markers After a Line Break

    /// A run of markers written after a line break, each at the end of the line
    /// before, with the memo a caller keeps (`RunMemo`), is the same
    /// Markdown as writing them one by one from the line, for every way a line
    /// can end (a hard break of spaces or a backslash, a plain break, and a
    /// break followed by indentation), with other text written between,
    /// with and without words kept apart.
    func testARunOfMarkersAfterALineBreakIsWrittenAsOneByOne() {
        for tail in ["  \n", "\\\n", "\n", "  \n  ", "\n    ", "\n\t", "\n\n"] {
            for apart in [false, true] {
                var plain = "line one words" + tail
                var remembered = plain
                var memo = MarkdownMarkerWriter.RunMemo()
                for page in 1...60 {
                    let marker = "<!-- page: \(page) -->"
                    MarkdownMarkerWriter.write(marker, inline: true, keepingWordsApart: apart, into: &plain)
                    MarkdownMarkerWriter.write(
                        marker, inline: true, keepingWordsApart: apart, remembering: &memo, into: &remembered)
                    // Now and then something else is written: the run is placed from the line again.
                    if page % 7 == 0 {
                        plain += "more words" + tail
                        remembered += "more words" + tail
                    }
                    XCTAssertEqual(remembered, plain, "tail \(tail.debugDescription) page \(page)")
                }
            }
        }
    }

    /// Markers that cannot be remembered (a block, a marker that ends in white
    /// space or holds no word) are written from the line, and forget the memo.
    func testAMarkerThatCannotBeRememberedForgetsTheRun() {
        var plain = "words  \n"
        var remembered = plain
        var memo = MarkdownMarkerWriter.RunMemo()
        for marker in ["<!-- page: 1 -->", "<!-- page: 2 -->", "x ", "<!-- page: 3 -->", "-", "<!-- page: 4 -->", "<!-- page: 5 -->"] {
            MarkdownMarkerWriter.write(marker, inline: true, into: &plain)
            MarkdownMarkerWriter.write(marker, inline: true, remembering: &memo, into: &remembered)
            XCTAssertEqual(remembered, plain, marker)
        }
        MarkdownMarkerWriter.write("<!-- page: 6 -->", inline: false, into: &plain)
        MarkdownMarkerWriter.write("<!-- page: 6 -->", inline: false, remembering: &memo, into: &remembered)
        XCTAssertEqual(remembered, plain)
    }

    /// Twenty thousand markers after a line of 2 MB and a break, which each
    /// read the line to place themselves (5,000 took 15.7 s in the review of
    /// `readers/followups-1106`), are written in a few milliseconds with the
    /// memo. The limit is thirty seconds, checked as they are written: the walk
    /// of the line passes it at about half of them.
    func testManyMarkersAfterALongLineAreWrittenInLinearTime() {
        var markdown = String(repeating: "word ", count: 400_000) + "  \n"
        var memo = MarkdownMarkerWriter.RunMemo()
        let limit: Duration = .seconds(30)
        let clock = ContinuousClock()
        let start = clock.now
        var written = 0
        while written < 20_000, clock.now - start < limit {
            MarkdownMarkerWriter.write(
                "<!-- page: \(written + 1) -->", inline: true, keepingWordsApart: true, remembering: &memo, into: &markdown)
            written += 1
        }
        XCTAssertEqual(written, 20_000, "\(written) markers were written in \(limit)")
        // The markers stand together at the end of the line's words, before the three spaces
        // (the one that ended "word " and the hard break's two) that end the line.
        XCTAssertTrue(markdown.hasSuffix("word<!-- page: 19999 --><!-- page: 20000 -->   \n"), String(markdown.suffix(80)))
        XCTAssertEqual(markdown.filter { $0 == "\n" }.count, 1)
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
