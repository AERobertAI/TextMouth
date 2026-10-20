import XCTest
@testable import TextMouth

/// The RTF writer (FMT19): its exact text, its escaping, its outline levels
/// read back by Apple's reader and by TextMouth's own, and the file it writes.
final class RTFExportWriterTests: XCTestCase {

    // MARK: - Escaping

    /// A backslash and the two braces get a backslash before them.
    func testBackslashAndBracesAreEscaped() {
        XCTAssertEqual(RTFExportWriter.escaped(#"a\b{c}d"#), #"a\\b\{c\}d"#)
    }

    /// A line feed is `\line `, a tab `\tab `; a vertical tab, a form feed,
    /// and a carriage return, which are white space, are a space; the other
    /// controls and DEL are left out.
    func testControlCharactersAreTurnedIntoControlWordsSpacesOrLeftOut() {
        XCTAssertEqual(RTFExportWriter.escaped("a\nb\tc"), #"a\line b\tab c"#)
        XCTAssertEqual(RTFExportWriter.escaped("page\u{0C}Start"), "page Start")
        for value: UInt32 in [0x0B, 0x0C, 0x0D] {
            guard let scalar = Unicode.Scalar(value) else {
                XCTFail("U+\(String(value, radix: 16)) is not a scalar")
                continue
            }
            XCTAssertEqual(RTFExportWriter.escaped("a\(Character(scalar))b"), "a b", "U+\(String(value, radix: 16))")
        }
        let others: [UInt32] = Array(0x00...0x08) + Array(0x0E...0x1F) + [0x7F]
        for value in others {
            guard let scalar = Unicode.Scalar(value) else {
                XCTFail("U+\(String(value, radix: 16)) is not a scalar")
                continue
            }
            XCTAssertEqual(RTFExportWriter.escaped("a\(Character(scalar))b"), "ab", "U+\(String(value, radix: 16))")
        }
    }

    /// Printable ASCII, the space and the tilde at either end of it included, stays as it is.
    func testPrintableASCIIStaysAsItIs() {
        // The three characters RTF reserves are escaped (see the test above), so they are left out here.
        let printable = String((UInt8(0x20)...UInt8(0x7E)).filter { ![0x5C, 0x7B, 0x7D].contains($0) }.map { Character(Unicode.Scalar($0)) })
        XCTAssertEqual(RTFExportWriter.escaped(printable), printable)
    }

    /// Every character above ASCII is `\uN?` once for each UTF-16 unit, N signed 16-bit.
    func testNonASCIICharactersAreUnicodeEscapes() {
        XCTAssertEqual(RTFExportWriter.escaped("\u{E9}"), #"\u233?"#)
        XCTAssertEqual(RTFExportWriter.escaped("\u{20AC}"), #"\u8364?"#)
        XCTAssertEqual(RTFExportWriter.escaped("\u{AC00}"), #"\u-21504?"#)
        XCTAssertEqual(RTFExportWriter.escaped("\u{1F600}"), #"\u-10179?\u-8704?"#)
        // The unit just under and just over the signed limit.
        XCTAssertEqual(RTFExportWriter.escaped("\u{7FFF}"), #"\u32767?"#)
        XCTAssertEqual(RTFExportWriter.escaped("\u{8000}"), #"\u-32768?"#)
        // A combining mark is its own escape after its letter; the file stays ASCII.
        XCTAssertEqual(RTFExportWriter.escaped("e\u{301}"), #"e\u769?"#)
        XCTAssertEqual(RTFExportWriter.escaped("\u{2022}"), #"\u8226?"#)
        XCTAssertTrue(RTFExportWriter.escaped("Caf\u{E9} \u{1F469}\u{200D}\u{1F4BB}").allSatisfy(\.isASCII))
    }

    // MARK: - The Whole Text

    /// A fixture with every kind of block and every style, pinned whole.
    func testTheWholeTextOfAFullDocument() throws {
        let text = try RTFExportWriter.rtf(of: fullDocument())
        let expected = joined([
            #"{\rtf1\ansi\ansicpg1252\deff0\uc1"#,
            #"{\fonttbl{\f0\fswiss\fcharset0 Helvetica;}{\f1\fmodern\fcharset0 Courier New;}}"#,
            #"{\stylesheet"#,
            #"{\s0\sa120\f0\fs24 Normal;}"#,
            #"{\s1\sb240\sa120\keepn\outlinelevel0\b\f0\fs44\sbasedon0\snext0 heading 1;}"#,
            #"{\s2\sb240\sa120\keepn\outlinelevel1\b\f0\fs38\sbasedon0\snext0 heading 2;}"#,
            #"{\s3\sb240\sa120\keepn\outlinelevel2\b\f0\fs34\sbasedon0\snext0 heading 3;}"#,
            #"{\s4\sb240\sa120\keepn\outlinelevel3\b\f0\fs30\sbasedon0\snext0 heading 4;}"#,
            #"{\s5\sb240\sa120\keepn\outlinelevel4\b\f0\fs28\sbasedon0\snext0 heading 5;}"#,
            #"{\s6\sb240\sa120\keepn\outlinelevel5\b\f0\fs26\sbasedon0\snext0 heading 6;}"#,
            "}",
            #"{\info{\title Harbour Pilots}{\author Odette Varga}}"#,
            #"\pard\plain\s1\sb240\sa120\keepn\outlinelevel0\b\f0\fs44 Harbour Pilots\par"#,
            #"\pard\plain\s1\sb240\sa120\keepn\outlinelevel0\b\f0\fs44 Arrivals\par"#,
            #"\pard\plain\s0\sa120\f0\fs24 Plain {\i em} {\b st} {\f1 cd} {\b\i\f1 all} and "#
                + #"{\field{\*\fldinst{HYPERLINK "https://example.com/a"}}{\fldrslt{\ul see {\b here}}}}, "#
                + #"then\line new line. Caf\u233? \u8364?5 \u-21504? \u-10179?\u-8704? back\\slash \{braces\}\par"#,
            #"\pard\plain\s2\sb240\sa120\keepn\outlinelevel1\b\f0\fs38 Berths\par"#,
            #"\pard\plain\s0\sa60\li360\fi-360\f0\fs24 \u8226?\tab First\par"#,
            #"\pard\plain\s0\sa60\li720\fi-360\f0\fs24 3.\tab Three\par"#,
            #"\pard\plain\s0\sa60\li720\fi-360\f0\fs24 4.\tab Four\par"#,
            #"\pard\plain\s0\sa60\li360\fi-360\f0\fs24 \u8226?\tab Second one\par"#,
            #"\pard\plain\s0\sa60\li360\f0\fs24 Second two\par"#,
            #"\pard\plain\s3\sb240\sa120\keepn\outlinelevel2\b\f0\fs34 Tides\par"#,
            #"\pard\plain\s0\sa120\li720\f0\fs24 Quoted.\par"#,
            #"\pard\plain\s0\sa120\f1\fs24 let x = 1\line let y = 2\par"#,
            #"\pard\plain\s0\sa120\brdrb\brdrs\brdrw10\brsp20\f0\fs24\par"#,
            #"\trowd\trgaph108\trleft0\trhdr\cellx4680\cellx9360"#
                + #"\pard\plain\intbl\s0\f0\fs24 {\b Port}\cell\pard\plain\intbl\s0\f0\fs24 {\b Depth}\cell\row"#,
            #"\trowd\trgaph108\trleft0\cellx4680\cellx9360"#
                + #"\pard\plain\intbl\s0\f0\fs24 Hull\cell\pard\plain\intbl\s0\f0\fs24 9\cell\row"#,
            "}",
        ])
        XCTAssertEqual(text, expected)
        XCTAssertTrue(text.allSatisfy(\.isASCII), "the file is pure ASCII")
    }

    /// A title with markup characters is escaped, and a book with no author writes no author group.
    func testTheInfoGroupEscapesTheTitleAndLeavesOutAMissingAuthor() throws {
        let document = ExportDocument(book: ExportBookDetails(title: #"A {Brace} \ Title \#u{E9}"#), blocks: [])
        let lines = try RTFExportWriter.rtf(of: document).components(separatedBy: "\n")
        XCTAssertTrue(lines.contains(#"{\info{\title A \{Brace\} \\ Title \u233?}}"#), "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains(#"\author"#) })
        XCTAssertEqual(lines.last, "", "the text ends with a line feed")
        XCTAssertEqual(lines.dropLast().last, "}")
    }

    // MARK: - Outline Levels

    /// The style sheet and the heading paragraphs carry `\sN` and `\outlinelevel(N-1)` for each level.
    func testEachLevelCarriesItsStyleAndOutlineLevel() throws {
        let sizes = [44, 38, 34, 30, 28, 26]
        let document = documentOf((1...6).map { heading($0, "Level \($0)") })
        let lines = try RTFExportWriter.rtf(of: document).components(separatedBy: "\n")

        for level in 1...6 {
            let controls = #"\s\#(level)\sb240\sa120\keepn\outlinelevel\#(level - 1)\b\f0\fs\#(sizes[level - 1])"#
            XCTAssertTrue(
                lines.contains("{" + controls + #"\sbasedon0\snext0 heading \#(level);}"#),
                "the style sheet defines heading \(level)"
            )
            XCTAssertTrue(
                lines.contains(#"\pard\plain"# + controls + " Level \(level)" + #"\par"#),
                "the paragraph of level \(level)"
            )
        }
        // Each level is larger than the body (12 points) and than the next.
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        XCTAssertTrue(sizes.allSatisfy { $0 > 24 })
    }

    /// A level outside 1 to 6 is held to RTF's six styles.
    func testAHeadingLevelStaysWithinSix() throws {
        let lines = try RTFExportWriter.rtf(of: documentOf([heading(9, "Deep"), heading(0, "Flat")]))
            .components(separatedBy: "\n")
        XCTAssertTrue(lines.contains { $0.hasPrefix(#"\pard\plain\s6\sb240\sa120\keepn\outlinelevel5"#) && $0.contains(" Deep") })
        XCTAssertTrue(lines.contains { $0.hasPrefix(#"\pard\plain\s1\sb240\sa120\keepn\outlinelevel0"#) && $0.contains(" Flat") })
    }

    // MARK: - Read Back by Apple's Reader

    /// Apple's reader gives the fixture's words in the fixture's order, a
    /// list item's mark before its words.
    func testApplesReaderReadsTheFixtureWordForWord() throws {
        let string = try applesReading(of: try RTFExportWriter.rtf(of: fullDocument())).string
        let words = string.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        let expected = [
            "Harbour", "Pilots", "Arrivals",
            "Plain", "em", "st", "cd", "all", "and", "see", "here,", "then", "new", "line.",
            "Café", "€5", "가", "😀", #"back\slash"#, "{braces}",
            "Berths",
            "•", "First", "3.", "Three", "4.", "Four", "•", "Second", "one", "Second", "two",
            "Tides", "Quoted.", "let", "x", "=", "1", "let", "y", "=", "2",
            "Port", "Depth", "Hull", "9",
        ]
        XCTAssertEqual(words, expected)
    }

    /// A heading and a paragraph read back as two lines, as Apple's reader gives them.
    func testApplesReaderReadsAHeadingAndAParagraphAsTwoLines() throws {
        let document = documentOf([heading(1, "HEADING"), .paragraph([ExportRun("PARAGRAPH")])])
        XCTAssertEqual(try applesReading(of: try RTFExportWriter.rtf(of: document)).string, "HEADING\nPARAGRAPH\n")
    }

    /// Apple's reader keeps a link and the styles of a run.
    func testApplesReaderKeepsLinksAndStyles() throws {
        let document = documentOf([.paragraph([
            ExportRun("plain "), ExportRun("bold", isStrong: true), ExportRun(" "),
            ExportRun("site", link: "https://example.com/a"),
        ])])
        let read = try applesReading(of: try RTFExportWriter.rtf(of: document))
        let string = read.string as NSString
        let boldFont = try XCTUnwrap(read.attribute(.font, at: string.range(of: "bold").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
        let link = read.attribute(.link, at: string.range(of: "site").location, effectiveRange: nil)
        XCTAssertEqual((link as? URL)?.absoluteString ?? link as? String, "https://example.com/a")
    }

    // MARK: - Read Back by TextMouth's Own Reader

    /// Headings of levels 1, 2, 3, 2, 3, and 1, each followed by a body of
    /// thirty words, written to a file and read by `textutil` and TextMouth's
    /// reader, come back as exactly those headings at those levels.
    func testTextMouthsOwnReaderFindsTheHeadingLevels() throws {
        let headings = [(1, "Arrivals at Dawn"), (2, "The Harbour Pilots"), (3, "Morning Tides"),
                        (2, "Signal Flags"), (3, "Evening Berths"), (1, "Departures at Dusk")]
        let body = Array(repeating: "the ferry leaves at seven and the cranes wave", count: 4).joined(separator: " ")
        XCTAssertGreaterThanOrEqual(body.split(separator: " ").count, 30)
        let blocks = headings.flatMap { [heading($0.0, $0.1), ExportBlock.paragraph([ExportRun(body + ".")])] }

        let url = try makeSandboxDirectory("RTFRoundTrip").appendingPathComponent("Round Trip.rtf")
        try RTFExportWriter().write(
            documentOf(blocks), options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation()
        )
        let parsed = try TextutilDocumentReader.parse(url: url, bookFormat: .rtf)

        XCTAssertEqual(headingLines(of: parsed), headings.map { "\($0.0): \($0.1)" })
    }

    // MARK: - Links

    /// A link whose address holds a quote is a HYPERLINK field with the quote as `%22`.
    func testALinkWithAQuoteIsAFieldWithPercentTwentyTwo() throws {
        let address = #"https://example.com/a"b"#
        let text = try RTFExportWriter.rtf(of: documentOf([.paragraph([ExportRun("go", link: address)])]))
        XCTAssertTrue(text.contains(#"{\field{\*\fldinst{HYPERLINK "https://example.com/a%22b"}}{\fldrslt{\ul go}}}"#), text)
    }

    /// Neighbouring runs of one link share one field; a different link starts another.
    func testNeighbouringRunsOfOneLinkShareAField() throws {
        let one = "https://example.com/one"
        let two = "mailto:a@example.com"
        let text = try RTFExportWriter.rtf(of: documentOf([.paragraph([
            ExportRun("a ", link: one), ExportRun("b", isEmphasis: true, link: one), ExportRun("c", link: two),
        ])]))
        XCTAssertEqual(text.components(separatedBy: "HYPERLINK").count - 1, 2)
        XCTAssertTrue(text.contains(#"{\fldrslt{\ul a {\i b}}}}"#), text)
        XCTAssertTrue(text.contains(#"HYPERLINK "mailto:a@example.com""#))
    }

    /// An address that may not be a link, given by hand, is written as the plain text of its run.
    func testADisallowedAddressIsPlainText() throws {
        let text = try RTFExportWriter.rtf(of: documentOf([.paragraph([
            ExportRun("click", link: "javascript:alert(1)"), ExportRun(" or "), ExportRun("here", link: "page.html"),
        ])]))
        XCTAssertFalse(text.contains("HYPERLINK"))
        XCTAssertTrue(text.contains(#" click or here\par"#), text)
    }

    /// Line breaks and tabs in an address are left out of the field's instruction.
    func testWhiteSpaceInAnAddressIsLeftOut() throws {
        let text = try RTFExportWriter.rtf(of: documentOf([.paragraph([
            ExportRun("x", link: "https://example.com/a\nb\tc"),
        ])]))
        XCTAssertTrue(text.contains(#"HYPERLINK "https://example.com/abc""#), text)
    }

    // MARK: - Lists, Quotes, and Code

    /// An item that begins with something other than a paragraph has its mark alone, and its blocks after it.
    func testAnItemThatDoesNotBeginWithAParagraph() throws {
        let list = ExportList(isOrdered: true, start: 7, depth: 0, items: [
            ExportListItem(blocks: [.codeBlock("code"), .paragraph([ExportRun("after")])]),
        ])
        let lines = try RTFExportWriter.rtf(of: documentOf([.list(list)])).components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex(of: #"\pard\plain\s0\sa60\li360\fi-360\f0\fs24 7.\tab\par"#), "\(lines)")
        XCTAssertEqual(lines[start + 1], #"\pard\plain\s0\sa120\li360\f1\fs24 code\par"#)
        XCTAssertEqual(lines[start + 2], #"\pard\plain\s0\sa60\li360\f0\fs24 after\par"#)
    }

    /// Quotes add 720 twips each, and a list in a quote adds its own steps to the quotes'.
    func testQuotesAndListsAddTheirIndents() throws {
        let list = ExportList(isOrdered: false, start: 1, depth: 0, items: [
            ExportListItem(blocks: [.paragraph([ExportRun("item")])]),
        ])
        let quoted = ExportBlock.blockQuote([.blockQuote([.paragraph([ExportRun("deep")]), .list(list)])])
        let lines = try RTFExportWriter.rtf(of: documentOf([quoted])).components(separatedBy: "\n")
        XCTAssertTrue(lines.contains(#"\pard\plain\s0\sa120\li1440\f0\fs24 deep\par"#), "\(lines)")
        XCTAssertTrue(lines.contains(#"\pard\plain\s0\sa60\li1800\fi-360\f0\fs24 \u8226?\tab item\par"#), "\(lines)")
    }

    // MARK: - Tables

    /// A table of 64 columns is written as paragraphs with tabs, since Word allows 63.
    func testATableOfSixtyFourColumnsIsWrittenAsParagraphs() throws {
        let row = (1...64).map { "c\($0)" }
        let text = try RTFExportWriter.rtf(of: documentOf([
            .table(ExportTable(rows: [row, row], hasHeaderRow: true)),
        ]))
        XCTAssertFalse(text.contains(#"\trowd"#))
        XCTAssertFalse(text.contains(#"\cell"#))
        let line = row.joined(separator: #"\tab "#)
        XCTAssertEqual(text.components(separatedBy: #"\f0\fs24 "# + line + #"\par"#).count - 1, 2, text)
    }

    /// A table of 63 columns is a table, every column at least one twip wide.
    func testATableOfSixtyThreeColumnsIsATable() throws {
        let row = (1...63).map { "c\($0)" }
        let text = try RTFExportWriter.rtf(of: documentOf([.table(ExportTable(rows: [row], hasHeaderRow: false))]))
        XCTAssertEqual(text.components(separatedBy: #"\trowd"#).count - 1, 1)
        // 9360 / 63 = 148 twips (rounded down), the last edge 63 * 148.
        XCTAssertTrue(text.contains(#"\cellx148\cellx296"#))
        XCTAssertTrue(text.contains(#"\cellx9324\pard"#), text)
    }

    /// A short row is padded to the table's width; a table in a quote starts at the quote's indent.
    func testAShortRowIsPaddedAndATableFollowsItsIndent() throws {
        let table = ExportTable(rows: [["a", "b", "c"], ["d"]], hasHeaderRow: false)
        let lines = try RTFExportWriter.rtf(of: documentOf([.blockQuote([.table(table)])])).components(separatedBy: "\n")
        // (9360 - 720) / 3 = 2880 twips a column, counted from 720.
        let edges = #"\cellx3600\cellx6480\cellx9360"#
        let cell = { (text: String) in #"\pard\plain\intbl\s0\f0\fs24 "# + text + #"\cell"# }
        XCTAssertTrue(lines.contains(#"\trowd\trgaph108\trleft720"# + edges + cell("a") + cell("b") + cell("c") + #"\row"#), "\(lines)")
        XCTAssertTrue(lines.contains(#"\trowd\trgaph108\trleft720"# + edges + cell("d") + cell("") + cell("") + #"\row"#), "\(lines)")
    }

    /// A table with no cells writes nothing at all.
    func testATableWithNoCellsWritesNothing() throws {
        let with = try RTFExportWriter.rtf(of: documentOf([.table(ExportTable(rows: [[], []], hasHeaderRow: true))]))
        XCTAssertEqual(with, try RTFExportWriter.rtf(of: documentOf([])))
    }

    // MARK: - Writing the File

    /// The file holds the text; a second write to the same place throws and leaves the first file as it was.
    func testWriteMakesTheFileAndNeverWritesOverIt() throws {
        let url = try makeFolder().appendingPathComponent("book.rtf")
        let first = documentOf([.paragraph([ExportRun("First \u{1F600} & more")])])
        let second = documentOf([.paragraph([ExportRun("Second")])])
        let writer = RTFExportWriter()
        let firstBytes = Data(try RTFExportWriter.rtf(of: first).utf8)

        try writer.write(first, options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation())
        XCTAssertEqual(try Data(contentsOf: url), firstBytes)

        XCTAssertThrowsError(
            try writer.write(second, options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation())
        )
        XCTAssertEqual(try Data(contentsOf: url), firstBytes, "the first file is as it was")
    }

    /// A cancelled export writes no file, with or without blocks, and a text being made stops at its next block.
    func testACancelledExportWritesNothing() throws {
        let folder = try makeFolder()
        let cancellation = BookExportCancellation()
        cancellation.cancel()
        let writer = RTFExportWriter()

        for (index, document) in [documentOf([]), documentOf([.thematicBreak])].enumerated() {
            let url = folder.appendingPathComponent("cancelled-\(index).rtf")
            XCTAssertThrowsError(
                try writer.write(document, options: NoTextExportOptions(), to: url, cancellation: cancellation)
            ) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertThrowsError(try RTFExportWriter.rtf(of: documentOf([.thematicBreak]), cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    // MARK: - The Writer's Words

    /// The writer's id, name, hint, and extension are exactly these words.
    func testTheWritersWords() {
        let writer = RTFExportWriter()
        XCTAssertEqual(writer.id, "rtf")
        XCTAssertEqual(writer.name, "RTF")
        XCTAssertEqual(writer.fileExtension, "rtf")
        XCTAssertEqual(writer.hint, "Rich text, with each heading at its outline level, for Word, Pages, and TextEdit.")
        XCTAssertEqual(TextExportWriters.writer(id: "rtf")?.name, "RTF")
    }

    // MARK: - Word 97-2003

    /// The file begins with the signature of a compound file, the container of Word 97-2003.
    func testTheWordFileIsACompoundFile() throws {
        let url = try makeFolder().appendingPathComponent("book.doc")
        try WordDocExportWriter().write(
            fullDocument(), options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation()
        )
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(Array(bytes.prefix(8)), [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    }

    /// Read back as Word 97-2003, the file's text is exactly the text Apple's reader makes of the RTF.
    func testTheWordFileReadsBackAsTheRTFDoes() throws {
        let document = fullDocument()
        let url = try makeFolder().appendingPathComponent("book.doc")
        try WordDocExportWriter().write(
            document, options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation()
        )
        let read = try NSAttributedString(
            data: try Data(contentsOf: url),
            options: [.documentType: NSAttributedString.DocumentType.docFormat],
            documentAttributes: nil
        )
        XCTAssertEqual(read.string, try applesReading(of: try RTFExportWriter.rtf(of: document)).string)
        XCTAssertTrue(read.string.contains("Harbour Pilots"))
    }

    /// The title and author are in the file's properties.
    func testTheWordFileCarriesTheTitleAndAuthor() throws {
        let url = try makeFolder().appendingPathComponent("book.doc")
        try WordDocExportWriter().write(
            fullDocument(), options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation()
        )
        var attributes: NSDictionary?
        _ = try NSAttributedString(
            data: try Data(contentsOf: url),
            options: [.documentType: NSAttributedString.DocumentType.docFormat],
            documentAttributes: &attributes
        )
        XCTAssertEqual(attributes?[NSAttributedString.DocumentAttributeKey.title] as? String, "Harbour Pilots")
        XCTAssertEqual(attributes?[NSAttributedString.DocumentAttributeKey.author] as? String, "Odette Varga")
    }

    /// A book with no text still makes a Word file.
    func testAnEmptyBookStillMakesAWordFile() throws {
        let url = try makeFolder().appendingPathComponent("empty.doc")
        try WordDocExportWriter().write(
            documentOf([]), options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation()
        )
        XCTAssertEqual(Array(try Data(contentsOf: url).prefix(4)), [0xD0, 0xCF, 0x11, 0xE0])
    }

    /// A second write to the same place throws and leaves the first file as it was.
    func testTheWordWriterNeverWritesOverAFile() throws {
        let url = try makeFolder().appendingPathComponent("book.doc")
        let writer = WordDocExportWriter()
        try writer.write(fullDocument(), options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation())
        let firstBytes = try Data(contentsOf: url)

        XCTAssertThrowsError(
            try writer.write(documentOf([]), options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation())
        )
        XCTAssertEqual(try Data(contentsOf: url), firstBytes, "the first file is as it was")
    }

    /// A cancelled export writes no Word file, whether it was stopped before the call or is stopped partway.
    func testACancelledWordExportWritesNothing() throws {
        let folder = try makeFolder()
        let cancellation = BookExportCancellation()
        cancellation.cancel()
        for (index, document) in [documentOf([]), documentOf([.thematicBreak])].enumerated() {
            let url = folder.appendingPathComponent("cancelled-\(index).doc")
            XCTAssertThrowsError(
                try WordDocExportWriter().write(document, options: NoTextExportOptions(), to: url, cancellation: cancellation)
            ) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// The Word writer's words are exactly these, and the writers are listed in the picker's order.
    func testTheWordWritersWordsAndTheListOfWriters() {
        let writer = WordDocExportWriter()
        XCTAssertEqual(writer.id, "doc")
        XCTAssertEqual(writer.name, "Word 97-2003 (.doc)")
        XCTAssertEqual(writer.fileExtension, "doc")
        XCTAssertEqual(
            writer.hint,
            "Word 97-2003 document. Its headings are plain text, so Word's navigation pane does not list them."
        )
        XCTAssertEqual(TextExportWriters.all.map(\.id), ["html", "rtf", "doc"])
        XCTAssertEqual(TextExportWriters.writer(id: "doc")?.name, "Word 97-2003 (.doc)")
    }

    /// When Apple's reader or writer refuses the book's text, the Word
    /// writer fails with its own sentence, word for word.
    func testARefusedWordFileFailsWithItsSentence() {
        XCTAssertEqual(
            WordDocExportWriter.failureSentence,
            "The book's text could not be made into a Word 97-2003 document."
        )
        // Apple's RTF reader refuses text that is not RTF.
        XCTAssertThrowsError(
            try WordDocExportWriter.wordData(
                ofRTF: "not RTF at all",
                book: ExportBookDetails(title: "Book"),
                cancellation: BookExportCancellation()
            )
        ) { error in
            XCTAssertEqual(error as? TextExportError, TextExportError(WordDocExportWriter.failureSentence))
            XCTAssertEqual(error.localizedDescription, "The book's text could not be made into a Word 97-2003 document.")
        }
    }

    // MARK: - Lists in Reading Order

    /// A list item's paragraph after the list inside it stays after it, and
    /// at the item's indent: the walk of "Alpha", an inner list of "Xray"
    /// and "Yankee", and "Bravo" is written in that order (a reviewer's case).
    func testAnItemsParagraphAfterItsInnerListStaysAfterIt() throws {
        let markdown = "- Alpha\n\n  - Xray\n  - Yankee\n\n  Bravo"
        let document = try ExportDocumentWalker.document(fromMarkdown: markdown, book: ExportBookDetails(title: ""))
        let paragraphs = try RTFExportWriter.rtf(of: document).components(separatedBy: "\n").filter { $0.hasPrefix(#"\pard"#) }

        let bullet = #"\u8226?\tab "#
        XCTAssertEqual(paragraphs, [
            #"\pard\plain\s0\sa60\li360\fi-360\f0\fs24 "# + bullet + #"Alpha\par"#,
            #"\pard\plain\s0\sa60\li720\fi-360\f0\fs24 "# + bullet + #"Xray\par"#,
            #"\pard\plain\s0\sa60\li720\fi-360\f0\fs24 "# + bullet + #"Yankee\par"#,
            #"\pard\plain\s0\sa60\li360\f0\fs24 Bravo\par"#,
        ])
    }

    // MARK: - Helpers

    /// `lines` as a text: each ended by a line feed.
    private func joined(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    /// A heading block of `level` reading `text`.
    private func heading(_ level: Int, _ text: String) -> ExportBlock {
        .heading(ExportHeading(level: level, runs: [ExportRun(text)], id: "h-\(level)-\(text.count)"))
    }

    /// A document of `blocks` for a book with only a title.
    private func documentOf(_ blocks: [ExportBlock]) -> ExportDocument {
        ExportDocument(book: ExportBookDetails(title: "Book"), blocks: blocks)
    }

    /// `rtf` as Apple's reader makes an attributed string of it.
    private func applesReading(of rtf: String) throws -> NSAttributedString {
        try NSAttributedString(
            data: Data(rtf.utf8),
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
    }

    /// A document with an author, a title heading, headings of levels 1 to 3,
    /// a paragraph in every style with a link, accents, a euro sign, a
    /// Korean syllable, an emoji, a backslash and braces, a list holding a
    /// numbered list that starts at 3, a quote, a code block of two lines, a
    /// thematic break, and a table with a header row.
    private func fullDocument() -> ExportDocument {
        let address = "https://example.com/a"
        let paragraph: [ExportRun] = [
            ExportRun("Plain "),
            ExportRun("em", isEmphasis: true), ExportRun(" "),
            ExportRun("st", isStrong: true), ExportRun(" "),
            ExportRun("cd", isCode: true), ExportRun(" "),
            ExportRun("all", isEmphasis: true, isStrong: true, isCode: true), ExportRun(" and "),
            ExportRun("see ", link: address), ExportRun("here", isStrong: true, link: address),
            ExportRun(", then\nnew line. Caf\u{E9} \u{20AC}5 \u{AC00} \u{1F600} back\\slash {braces}"),
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
        return ExportDocument(
            book: ExportBookDetails(title: "Harbour Pilots", author: "Odette Varga", language: "en-GB"),
            titleHeading: ExportHeading(level: 1, runs: [ExportRun("Harbour Pilots")], id: "harbour-pilots"),
            blocks: [
                heading(1, "Arrivals"),
                .paragraph(paragraph),
                heading(2, "Berths"),
                .list(list),
                heading(3, "Tides"),
                .blockQuote([.paragraph([ExportRun("Quoted.")])]),
                .codeBlock("let x = 1\nlet y = 2"),
                .thematicBreak,
                .table(ExportTable(rows: [["Port", "Depth"], ["Hull", "9"]], hasHeaderRow: true)),
            ]
        )
    }

    /// A new folder of the test's own, removed when the test ends.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RTFExportWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}
