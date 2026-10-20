import XCTest
@testable import TextMouth

/// The HTML writer (FMT18) and the XML escaping every XML writer shares.
///
/// The documents are built by hand, with the ids the walker would make, so
/// these tests stand beside the walker's. Every page a test makes goes
/// through `page(of:)`, which fails the test unless an XML parser accepts it.
final class HTMLExportWriterTests: XCTestCase {

    // MARK: - XMLEscaping

    /// Text escapes `&`, `<`, and `>`, and leaves quotes and white space.
    func testTextEscapesTheThreeMarkupCharacters() {
        XCTAssertEqual(XMLEscaping.text("a & b < c > d"), "a &amp; b &lt; c &gt; d")
        XCTAssertEqual(XMLEscaping.text("say \"hi\"\tnow\r\nplease"), "say \"hi\"\tnow\r\nplease")
    }

    /// An attribute also escapes the quote, tab, line feed, and carriage return.
    func testAttributeEscapesQuotesAndWhiteSpace() {
        XCTAssertEqual(XMLEscaping.attribute("a & b < c > d \"e\""), "a &amp; b &lt; c &gt; d &quot;e&quot;")
        XCTAssertEqual(XMLEscaping.attribute("a\tb\nc\rd"), "a&#9;b&#10;c&#13;d")
    }

    /// "\r\n" is one Character, and still two escapes in an attribute.
    func testAttributeEscapesACarriageReturnLineFeedPair() {
        XCTAssertEqual(XMLEscaping.attribute("x\r\ny"), "x&#13;&#10;y")
    }

    /// Every scalar XML 1.0 forbids is left out of both, but vertical tab and
    /// form feed, which are white space, are a space; the neighbours stay.
    func testEveryForbiddenScalarIsLeftOutAndForbiddenWhiteSpaceIsASpace() {
        let forbidden: [UInt32] = Array(0x00...0x08) + [0x0B, 0x0C] + Array(0x0E...0x1F) + [0xFFFE, 0xFFFF]
        for value in forbidden {
            guard let scalar = Unicode.Scalar(value) else {
                XCTFail("U+\(String(value, radix: 16)) is not a scalar")
                continue
            }
            let input = "a\(Character(scalar))b"
            let expected = value == 0x0B || value == 0x0C ? "a b" : "ab"
            XCTAssertEqual(XMLEscaping.text(input), expected, "U+\(String(value, radix: 16)) in text")
            XCTAssertEqual(XMLEscaping.attribute(input), expected, "U+\(String(value, radix: 16)) in an attribute")
        }
        // The white space XML allows, and the scalars next to the forbidden ranges, stay.
        XCTAssertEqual(XMLEscaping.text("\t\n\r\u{20}\u{7F}\u{FFFD}"), "\t\n\r\u{20}\u{7F}\u{FFFD}")
    }

    /// An emoji, with its joiners and modifiers, passes through whole.
    func testAnEmojiIsKeptWhole() {
        let emoji = "I \u{1F469}\u{200D}\u{1F4BB} & \u{1F44D}\u{1F3FD} e\u{301}"
        XCTAssertEqual(XMLEscaping.text(emoji), "I \u{1F469}\u{200D}\u{1F4BB} &amp; \u{1F44D}\u{1F3FD} e\u{301}")
        XCTAssertEqual(XMLEscaping.attribute(emoji), XMLEscaping.text(emoji))
    }

    // MARK: - The Whole Page

    /// A fixture with every kind of block and every style, pinned whole.
    func testTheWholePageOfAFullDocument() throws {
        let address = "https://example.com/a"
        let paragraph: [ExportRun] = [
            ExportRun("Plain "),
            ExportRun("em", isEmphasis: true), ExportRun(" "),
            ExportRun("st", isStrong: true), ExportRun(" "),
            ExportRun("cd", isCode: true), ExportRun(" "),
            ExportRun("all", isEmphasis: true, isStrong: true, isCode: true), ExportRun(" and "),
            ExportRun("see ", link: address), ExportRun("here", isStrong: true, link: address),
            ExportRun(", then\nnew line."),
        ]
        let list = ExportList(isOrdered: false, start: 1, depth: 0, items: [
            ExportListItem(blocks: [
                .paragraph([ExportRun("First")]),
                .list(ExportList(isOrdered: true, start: 3, depth: 1, items: [
                    ExportListItem(blocks: [.paragraph([ExportRun("Three")])]),
                    ExportListItem(blocks: [.paragraph([ExportRun("Four")])]),
                ])),
            ]),
            ExportListItem(blocks: [
                .paragraph([ExportRun("Second one")]),
                .paragraph([ExportRun("Second two")]),
            ]),
        ])
        let document = ExportDocument(
            book: ExportBookDetails(title: "Harbour Pilots", author: "Odette Varga", language: "en-GB"),
            titleHeading: ExportHeading(level: 1, runs: [ExportRun("Harbour Pilots")], id: "harbour-pilots"),
            blocks: [
                heading(1, "Arrivals", id: "arrivals"),
                .paragraph(paragraph),
                heading(2, "Berths", id: "berths"),
                .list(list),
                heading(3, "Tides", id: "tides"),
                .blockQuote([.paragraph([ExportRun("Quoted.")])]),
                .codeBlock("let x = 1\nlet y = 2"),
                .thematicBreak,
                .table(ExportTable(rows: [["Port", "Depth"], ["Hull", "9"]], hasHeaderRow: true)),
            ]
        )

        let expected = joined([
            "<!DOCTYPE html>",
            "<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en-GB\" xml:lang=\"en-GB\">",
            "<head>",
            "<meta charset=\"utf-8\"/>",
            "<title>Harbour Pilots</title>",
            "<meta name=\"author\" content=\"Odette Varga\"/>",
            "</head>",
            "<body>",
            "<h1 id=\"harbour-pilots\">Harbour Pilots</h1>",
            "<nav aria-label=\"Contents\">",
            "<ol>",
            "<li><a href=\"#arrivals\">Arrivals</a>",
            "<ol>",
            "<li><a href=\"#berths\">Berths</a>",
            "<ol>",
            "<li><a href=\"#tides\">Tides</a></li>",
            "</ol>",
            "</li>",
            "</ol>",
            "</li>",
            "</ol>",
            "</nav>",
            "<h1 id=\"arrivals\">Arrivals</h1>",
            "<p>Plain <em>em</em> <strong>st</strong> <code>cd</code> <strong><em><code>all</code></em></strong>"
                + " and <a href=\"https://example.com/a\">see <strong>here</strong></a>, then<br/>new line.</p>",
            "<h2 id=\"berths\">Berths</h2>",
            "<ul>",
            "<li>First",
            "<ol start=\"3\">",
            "<li>Three</li>",
            "<li>Four</li>",
            "</ol>",
            "</li>",
            "<li>Second one",
            "<p>Second two</p>",
            "</li>",
            "</ul>",
            "<h3 id=\"tides\">Tides</h3>",
            "<blockquote>",
            "<p>Quoted.</p>",
            "</blockquote>",
            "<pre><code>let x = 1",
            "let y = 2</code></pre>",
            "<hr/>",
            "<table>",
            "<thead>",
            "<tr><th>Port</th><th>Depth</th></tr>",
            "</thead>",
            "<tbody>",
            "<tr><td>Hull</td><td>9</td></tr>",
            "</tbody>",
            "</table>",
            "</body>",
            "</html>",
        ])
        XCTAssertEqual(try page(of: document), expected)
    }

    // MARK: - Escaping in the Page

    /// Markup characters in every place text goes are escaped, and an address
    /// with all of them in is written whole in the attribute.
    func testMarkupCharactersAreEscapedEverywhere() throws {
        let document = ExportDocument(
            book: ExportBookDetails(title: "Fish & <Chips>", author: "A&B \"C\"", language: nil),
            blocks: [
                heading(2, "R&D <x>", id: "r-d-x"),
                .paragraph([ExportRun("a < b && c > d")]),
                .codeBlock("if a<b && c>d {}"),
                .table(ExportTable(rows: [["x<y", "p&q"]], hasHeaderRow: false)),
                .paragraph([ExportRun("go", link: "https://example.com/?a=1&b=<2>\"")]),
            ]
        )

        let result = try page(of: document)

        XCTAssertTrue(result.contains("<title>Fish &amp; &lt;Chips&gt;</title>\n"))
        XCTAssertTrue(result.contains("<meta name=\"author\" content=\"A&amp;B &quot;C&quot;\"/>\n"))
        XCTAssertTrue(result.contains("<h2 id=\"r-d-x\">R&amp;D &lt;x&gt;</h2>\n"))
        XCTAssertTrue(result.contains("<li><a href=\"#r-d-x\">R&amp;D &lt;x&gt;</a></li>\n"), "the contents link")
        XCTAssertTrue(result.contains("<p>a &lt; b &amp;&amp; c &gt; d</p>\n"))
        XCTAssertTrue(result.contains("<pre><code>if a&lt;b &amp;&amp; c&gt;d {}</code></pre>\n"))
        XCTAssertTrue(result.contains("<tr><td>x&lt;y</td><td>p&amp;q</td></tr>\n"))
        XCTAssertTrue(
            result.contains("href=\"https://example.com/?a=1&amp;b=&lt;2&gt;&quot;\""),
            "the address is escaped as an attribute"
        )
    }

    /// Three headings with the same words keep the ids they were given, and
    /// each has its contents link.
    func testHeadingsWithTheSameWordsKeepTheirOwnIDs() throws {
        let document = documentOf([
            heading(2, "Notes", id: "notes"),
            heading(2, "Notes", id: "notes-2"),
            heading(2, "Notes", id: "notes-3"),
        ])

        let result = try page(of: document)

        for id in ["notes", "notes-2", "notes-3"] {
            XCTAssertTrue(result.contains("<h2 id=\"\(id)\">Notes</h2>\n"), id)
            XCTAssertTrue(result.contains("<li><a href=\"#\(id)\">Notes</a></li>\n"), id)
        }
    }

    /// Characters XML forbids are left out of the title, a heading, a
    /// paragraph, and a code block, a form feed (white space) as a space, and
    /// the page still parses.
    func testForbiddenCharactersAreLeftOutAndThePageParses() throws {
        let dirty = "a\u{01}b\u{0C}c\u{FFFF}d"
        let document = ExportDocument(
            book: ExportBookDetails(title: dirty, author: dirty, language: nil),
            blocks: [
                heading(2, dirty, id: "ab-cd"),
                .paragraph([ExportRun(dirty)]),
                .codeBlock(dirty),
                .paragraph([ExportRun("page\u{0C}Start")]),
            ]
        )

        let result = try page(of: document)

        XCTAssertTrue(result.contains("<title>ab cd</title>\n"))
        XCTAssertTrue(result.contains("content=\"ab cd\""))
        XCTAssertTrue(result.contains("<h2 id=\"ab-cd\">ab cd</h2>\n"))
        XCTAssertTrue(result.contains("<p>ab cd</p>\n"))
        XCTAssertTrue(result.contains("<pre><code>ab cd</code></pre>\n"))
        XCTAssertTrue(result.contains("<p>page Start</p>\n"), "a form feed between two words keeps them apart")
        XCTAssertFalse(result.unicodeScalars.contains { [0x01, 0x0C, 0xFFFF].contains($0.value) })
    }

    // MARK: - Lists in Reading Order

    /// A list item's paragraph after the list inside it stays after it: the
    /// walk of "Alpha", an inner list of "Xray" and "Yankee", and "Bravo" is
    /// written in that order (a reviewer's case).
    func testAnItemsParagraphAfterItsInnerListStaysAfterIt() throws {
        let markdown = "- Alpha\n\n  - Xray\n  - Yankee\n\n  Bravo"
        let document = try ExportDocumentWalker.document(fromMarkdown: markdown, book: ExportBookDetails(title: ""))

        XCTAssertEqual(try bodyLines(of: document), [
            "<ul>", "<li>Alpha", "<ul>", "<li>Xray</li>", "<li>Yankee</li>", "</ul>", "<p>Bravo</p>", "</li>", "</ul>",
        ])
    }

    // MARK: - Links

    /// A link whose address may not be one is plain text; a mail link is a link.
    func testOnlyAllowedAddressesBecomeLinks() throws {
        let document = documentOf([
            .paragraph([ExportRun("click", link: "javascript:alert(1)")]),
            .paragraph([ExportRun("click", link: "JavaScript:alert(1)")]),
            .paragraph([ExportRun("write", link: "mailto:reader@example.com")]),
        ])

        let lines = try bodyLines(of: document)

        XCTAssertEqual(lines, [
            "<p>click</p>",
            "<p>click</p>",
            "<p><a href=\"mailto:reader@example.com\">write</a></p>",
        ])
    }

    /// Neighbours with one address are one link, runs with different
    /// addresses are two, and an unlinked run between two links ends the first.
    func testNeighbouringRunsShareALinkOnlyWhenTheirAddressesMatch() throws {
        let one = "https://example.com/one"
        let two = "https://example.com/two"
        let document = documentOf([
            .paragraph([
                ExportRun("a", link: one), ExportRun("b", isEmphasis: true, link: one),
                ExportRun("c", link: two),
                ExportRun("d"),
                ExportRun("e", link: two),
            ]),
        ])

        let lines = try bodyLines(of: document)

        XCTAssertEqual(lines, [
            "<p><a href=\"https://example.com/one\">a<em>b</em></a><a href=\"https://example.com/two\">c</a>d"
                + "<a href=\"https://example.com/two\">e</a></p>",
        ])
    }

    // MARK: - The Contents List

    /// Levels 1, 3, 2: the deeper list closes before a list for the shallower one opens.
    func testTheContentsListForLevelsOneThreeTwo() throws {
        let document = documentOf([heading(1, "A", id: "a"), heading(3, "C", id: "c"), heading(2, "B", id: "b")])

        XCTAssertEqual(try navLines(of: document), [
            "<nav aria-label=\"Contents\">",
            "<ol>",
            "<li><a href=\"#a\">A</a>",
            "<ol>",
            "<li><a href=\"#c\">C</a></li>",
            "</ol>",
            "<ol>",
            "<li><a href=\"#b\">B</a></li>",
            "</ol>",
            "</li>",
            "</ol>",
            "</nav>",
        ])
    }

    /// Levels 1, 2, 2, 1: one nested list, then the next top-level item.
    func testTheContentsListForLevelsOneTwoTwoOne() throws {
        let document = documentOf([
            heading(1, "A", id: "a"), heading(2, "B", id: "b"), heading(2, "C", id: "c"), heading(1, "D", id: "d"),
        ])

        XCTAssertEqual(try navLines(of: document), [
            "<nav aria-label=\"Contents\">",
            "<ol>",
            "<li><a href=\"#a\">A</a>",
            "<ol>",
            "<li><a href=\"#b\">B</a></li>",
            "<li><a href=\"#c\">C</a></li>",
            "</ol>",
            "</li>",
            "<li><a href=\"#d\">D</a></li>",
            "</ol>",
            "</nav>",
        ])
    }

    /// Levels 2, 1: a heading above the first stays in the one flat list.
    func testTheContentsListForLevelsTwoOneIsFlat() throws {
        let document = documentOf([heading(2, "A", id: "a"), heading(1, "B", id: "b")])

        XCTAssertEqual(try navLines(of: document), [
            "<nav aria-label=\"Contents\">",
            "<ol>",
            "<li><a href=\"#a\">A</a></li>",
            "<li><a href=\"#b\">B</a></li>",
            "</ol>",
            "</nav>",
        ])
    }

    /// A heading inside a quote and inside a list item is in the contents too.
    func testTheContentsListIncludesHeadingsInsideQuotesAndListItems() throws {
        let document = documentOf([
            .blockQuote([heading(2, "Quoted", id: "quoted")]),
            .list(ExportList(isOrdered: false, start: 1, depth: 0, items: [
                ExportListItem(blocks: [heading(2, "Listed", id: "listed")]),
            ])),
        ])

        let nav = try navLines(of: document)

        XCTAssertTrue(nav.contains("<li><a href=\"#quoted\">Quoted</a></li>"))
        XCTAssertTrue(nav.contains("<li><a href=\"#listed\">Listed</a></li>"))
    }

    /// A document with no headings has no contents, even with a title heading.
    func testNoContentsWithoutHeadings() throws {
        let document = ExportDocument(
            book: ExportBookDetails(title: "T"),
            titleHeading: ExportHeading(level: 1, runs: [ExportRun("T")], id: "t"),
            blocks: [.paragraph([ExportRun("Text.")])]
        )

        let result = try page(of: document)

        XCTAssertFalse(result.contains("<nav"))
        XCTAssertFalse(result.contains("</nav>"))
        XCTAssertTrue(result.contains("<h1 id=\"t\">T</h1>\n"), "the title heading is still written")
    }

    // MARK: - The Frame

    /// The language is in both attributes when there is one, and in neither when there is none.
    func testLanguageAttributesComeAndGoTogether() throws {
        let with = try page(of: ExportDocument(book: ExportBookDetails(title: "T", language: "fr-CA"), blocks: []))
        let without = try page(of: ExportDocument(book: ExportBookDetails(title: "T"), blocks: []))

        XCTAssertTrue(with.contains(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"fr-CA\" xml:lang=\"fr-CA\">\n"
        ))
        XCTAssertTrue(without.contains("<html xmlns=\"http://www.w3.org/1999/xhtml\">\n"))
        XCTAssertFalse(without.contains("lang"))
    }

    /// The author's meta line is there only with an author; the title and
    /// the title heading follow their own rules.
    func testAuthorTitleAndTitleHeadingLines() throws {
        let bare = try page(of: ExportDocument(book: ExportBookDetails(title: ""), blocks: []))
        let full = try page(of: ExportDocument(
            book: ExportBookDetails(title: "Ledger", author: "Ines Okafor"),
            titleHeading: ExportHeading(level: 1, runs: [ExportRun("Ledger")], id: "ledger"),
            blocks: []
        ))

        XCTAssertFalse(bare.contains("name=\"author\""))
        XCTAssertTrue(bare.contains("<title></title>\n"), "the title is always there")
        XCTAssertFalse(bare.contains("<h1"))
        XCTAssertTrue(full.contains("<meta name=\"author\" content=\"Ines Okafor\"/>\n"))
        XCTAssertTrue(full.contains("<body>\n<h1 id=\"ledger\">Ledger</h1>\n</body>\n"))
    }

    // MARK: - The Shape of Blocks

    /// An ordered list that starts at 1 says nothing of where it starts.
    func testAnOrderedListFromOneHasNoStart() throws {
        let list = ExportList(isOrdered: true, start: 1, depth: 0, items: [
            ExportListItem(blocks: [.paragraph([ExportRun("One")])]),
        ])

        XCTAssertEqual(try bodyLines(of: documentOf([.list(list)])), ["<ol>", "<li>One</li>", "</ol>"])
    }

    /// An item with no blocks, and an item whose first block is not a paragraph.
    func testListItemsWithNoParagraphToLeadThem() throws {
        let list = ExportList(isOrdered: false, start: 1, depth: 0, items: [
            ExportListItem(blocks: []),
            ExportListItem(blocks: [.codeBlock("x")]),
        ])

        XCTAssertEqual(try bodyLines(of: documentOf([.list(list)])), [
            "<ul>", "<li></li>", "<li>", "<pre><code>x</code></pre>", "</li>", "</ul>",
        ])
    }

    /// A quote holds its blocks, quotes within quotes included.
    func testQuotesNest() throws {
        let document = documentOf([
            .blockQuote([.paragraph([ExportRun("Outer")]), .blockQuote([.paragraph([ExportRun("Inner")])])]),
        ])

        XCTAssertEqual(try bodyLines(of: document), [
            "<blockquote>", "<p>Outer</p>", "<blockquote>", "<p>Inner</p>", "</blockquote>", "</blockquote>",
        ])
    }

    /// A table of a header row alone has no body; one without a header row
    /// has every row in its body; a short row writes the cells it has.
    func testTableShapes() throws {
        let headerOnly = ExportTable(rows: [["A", "B"]], hasHeaderRow: true)
        let noHeader = ExportTable(rows: [["1", "2"], ["3"]], hasHeaderRow: false)

        XCTAssertEqual(try bodyLines(of: documentOf([.table(headerOnly)])), [
            "<table>", "<thead>", "<tr><th>A</th><th>B</th></tr>", "</thead>", "</table>",
        ])
        XCTAssertEqual(try bodyLines(of: documentOf([.table(noHeader)])), [
            "<table>", "<tbody>", "<tr><td>1</td><td>2</td></tr>", "<tr><td>3</td></tr>", "</tbody>", "</table>",
        ])
    }

    /// A level outside 1 to 6 is held to HTML's range rather than written as `<h9>`.
    func testAHeadingLevelStaysWithinHTMLs() throws {
        let lines = try bodyLines(of: documentOf([heading(9, "Deep", id: "deep"), heading(0, "Flat", id: "flat")]))

        XCTAssertTrue(lines.contains("<h6 id=\"deep\">Deep</h6>"))
        XCTAssertTrue(lines.contains("<h1 id=\"flat\">Flat</h1>"))
    }

    // MARK: - Writing the File

    /// The file holds the page's UTF-8 bytes; a second write to the same
    /// place throws and leaves the first file as it was.
    func testWriteMakesTheFileAndNeverWritesOverIt() throws {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent("book.html")
        let first = documentOf([.paragraph([ExportRun("First \u{1F600} & more")])])
        let second = documentOf([.paragraph([ExportRun("Second")])])
        let writer = HTMLExportWriter()
        let firstBytes = Data(try HTMLExportWriter.page(of: first).utf8)

        try writer.write(first, options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation())
        XCTAssertEqual(try Data(contentsOf: url), firstBytes)

        XCTAssertThrowsError(
            try writer.write(second, options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation())
        )
        XCTAssertEqual(try Data(contentsOf: url), firstBytes, "the first file is as it was")
    }

    /// A cancelled export writes no file, with or without blocks, and a page
    /// being made stops at its next block.
    func testACancelledExportWritesNothing() throws {
        let folder = try makeFolder()
        let cancellation = BookExportCancellation()
        cancellation.cancel()
        let writer = HTMLExportWriter()

        for (index, document) in [documentOf([]), documentOf([.thematicBreak])].enumerated() {
            let url = folder.appendingPathComponent("cancelled-\(index).html")
            XCTAssertThrowsError(
                try writer.write(document, options: NoTextExportOptions(), to: url, cancellation: cancellation)
            ) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertThrowsError(try HTMLExportWriter.page(of: documentOf([.thematicBreak]), cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    // MARK: - The Writer's Words

    /// The writer's id, name, hint, and extension are exactly these words,
    /// and the list of writers holds it once, apart from Markdown's tag.
    func testTheWritersWordsAndPlaceInTheList() {
        let writer = HTMLExportWriter()
        XCTAssertEqual(writer.id, "html")
        XCTAssertEqual(writer.name, "HTML")
        XCTAssertEqual(writer.fileExtension, "html")
        XCTAssertEqual(writer.hint, "A web page of the book's text, with a contents list linking each heading.")

        XCTAssertEqual(TextExportWriters.writer(id: "html")?.name, "HTML")
        let ids = TextExportWriters.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "the ids are unique")
        XCTAssertFalse(ids.contains(TextExportWriters.markdownID))
    }

    // MARK: - Helpers

    /// `lines` as a page's text: each ended by a line feed.
    private func joined(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    /// A heading block of `level` reading `text` with `id`.
    private func heading(_ level: Int, _ text: String, id: String) -> ExportBlock {
        .heading(ExportHeading(level: level, runs: [ExportRun(text)], id: id))
    }

    /// A document of `blocks` for a book with only a title.
    private func documentOf(_ blocks: [ExportBlock]) -> ExportDocument {
        ExportDocument(book: ExportBookDetails(title: "Book"), blocks: blocks)
    }

    /// The page of `document`, failing the test unless an XML parser accepts it.
    private func page(of document: ExportDocument, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let result = try HTMLExportWriter.page(of: document)
        let parser = XMLParser(data: Data(result.utf8))
        XCTAssertTrue(parser.parse(), "the page does not parse: \(String(describing: parser.parserError))", file: file, line: line)
        XCTAssertNil(parser.parserError, file: file, line: line)
        XCTAssertTrue(result.hasSuffix("\n"), "the last line ends with a line feed", file: file, line: line)
        return result
    }

    /// The lines of the page's body, without the contents (which these
    /// tests read through `navLines(of:)`).
    private func bodyLines(of document: ExportDocument, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let lines = try page(of: document, file: file, line: line).components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "<body>"), let end = lines.firstIndex(of: "</body>"), start < end else {
            XCTFail("the page has no body", file: file, line: line)
            return []
        }
        let body = Array(lines[(start + 1)..<end])
        guard let navStart = body.firstIndex(of: "<nav aria-label=\"Contents\">"),
              let navEnd = body.firstIndex(of: "</nav>"),
              navStart < navEnd
        else { return body }
        return Array(body[..<navStart]) + Array(body[(navEnd + 1)...])
    }

    /// The lines of the page's contents, `<nav>` and `</nav>` included.
    private func navLines(of document: ExportDocument, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let lines = try page(of: document, file: file, line: line).components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "<nav aria-label=\"Contents\">"), let end = lines.firstIndex(of: "</nav>"),
              start < end else {
            XCTFail("the page has no contents", file: file, line: line)
            return []
        }
        return Array(lines[start...end])
    }

    /// A new folder of the test's own, removed when the test ends.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLExportWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}
