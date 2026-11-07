import XCTest
@testable import TextMouth

/// The walk of a book's content.md into the `ExportDocument` every text
/// writer reads (FMT18), and the model's own helpers. Whole models are
/// pinned wherever the text is small enough to write them out; the real
/// samples prove what a reader of the exported text gets on real books.
@MainActor
final class ExportDocumentWalkerTests: XCTestCase {
    // MARK: - Helpers

    /// The document of `markdown` for a book titled `title`. The title is
    /// blank by default, so no title heading is added to what a test pins.
    private func walk(_ markdown: String, title: String = "") throws -> ExportDocument {
        try ExportDocumentWalker.document(fromMarkdown: markdown, book: ExportBookDetails(title: title))
    }

    /// `lines` as one Markdown text.
    private func text(_ lines: String...) -> String {
        lines.joined(separator: "\n")
    }

    /// A plain paragraph block of `words`.
    private func paragraph(_ words: String) -> ExportBlock {
        .paragraph([ExportRun(words)])
    }

    /// A heading block of `level` whose one plain run is `words`, with `id`.
    private func heading(_ level: Int, _ words: String, id: String) -> ExportBlock {
        .heading(ExportHeading(level: level, runs: [ExportRun(words)], id: id))
    }

    /// The runs of the first paragraph of `markdown`.
    private func runs(of markdown: String) throws -> [ExportRun] {
        let document = try walk(markdown)
        guard case .paragraph(let runs)? = document.blocks.first else {
            XCTFail("No paragraph in \(document.blocks)")
            return []
        }
        return runs
    }

    /// Every piece of text a document holds, block by block: heading and
    /// paragraph runs' texts, code, and table cells, inside quotes and list
    /// items too.
    private func pieces(of blocks: [ExportBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case .heading(let heading): return heading.runs.map(\.text)
            case .paragraph(let runs): return runs.map(\.text)
            case .codeBlock(let code): return [code]
            case .table(let table): return table.rows.flatMap { $0 }
            case .blockQuote(let quoted): return pieces(of: quoted)
            case .list(let list): return list.items.flatMap { pieces(of: $0.blocks) }
            case .thematicBreak, .pageBreak: return []
            }
        }
    }

    /// How many lists and quotes `blocks` open one inside another, at the
    /// deepest, and the largest `depth` of a list among them.
    private func deepest(_ blocks: [ExportBlock]) -> (nesting: Int, listDepth: Int) {
        var result = (nesting: 0, listDepth: 0)
        for block in blocks {
            switch block {
            case .blockQuote(let quoted):
                let inner = deepest(quoted)
                result = (max(result.nesting, inner.nesting + 1), max(result.listDepth, inner.listDepth))
            case .list(let list):
                var nesting = 0
                var listDepth = list.depth
                for item in list.items {
                    let inner = deepest(item.blocks)
                    nesting = max(nesting, inner.nesting)
                    listDepth = max(listDepth, inner.listDepth)
                }
                result = (max(result.nesting, nesting + 1), max(result.listDepth, listDepth))
            case .heading, .paragraph, .codeBlock, .thematicBreak, .table, .pageBreak:
                break
            }
        }
        return result
    }

    // MARK: - Chapters

    /// Two chapters made with TextMouth's markers: the markers reach no run,
    /// code, or cell, and the exact blocks are pinned.
    func testTwoChaptersWalkWithoutTheirMarkers() throws {
        let markdown = text(
            MarkdownCacheService.chapterMarker(title: "First Part"),
            "",
            "Some **bold** words.",
            "",
            MarkdownCacheService.chapterMarker(title: "Second Part"),
            "",
            "## Inside",
            "",
            "- one"
        )
        let document = try walk(markdown)

        XCTAssertEqual(document.blocks, [
            heading(1, "First Part", id: "first-part"),
            .paragraph([ExportRun("Some "), ExportRun("bold", isStrong: true), ExportRun(" words.")]),
            heading(2, "Inside", id: "inside"),
            .list(ExportList(isOrdered: false, start: 1, depth: 0, items: [ExportListItem(blocks: [paragraph("one")])]))
        ])
        XCTAssertNil(document.titleHeading)
        for piece in pieces(of: document.blocks) {
            XCTAssertFalse(piece.contains("<!--"), piece)
            XCTAssertFalse(piece.contains("chapter:"), piece)
        }
    }

    /// Text before the first marker is left out, as the reader leaves it out.
    func testTextBeforeTheFirstMarkerIsLeftOut() throws {
        let markdown = text("Stray words.", "", MarkdownCacheService.chapterMarker(title: "Real"), "", "Kept words.")
        XCTAssertEqual(try walk(markdown).blocks, [heading(1, "Real", id: "real"), paragraph("Kept words.")])
    }

    /// A chapter with no heading begins with its title as a level-1 heading;
    /// one that has a heading, even a level-2 one or one inside a quote,
    /// gets none.
    func testAChapterWithoutAHeadingBeginsWithItsTitle() throws {
        let marker = { MarkdownCacheService.chapterMarker(title: $0) }
        let markdown = text(
            marker("Bare"), "", "Words.", "",
            marker("Level Two"), "", "## Sub", "",
            marker("Quoted"), "", "> ## Inside a quote", "",
            marker("Listed"), "", "- ### Inside an item"
        )
        let headings = try walk(markdown).headings
        XCTAssertEqual(headings.map(\.plainText), ["Bare", "Sub", "Inside a quote", "Inside an item"])
        XCTAssertEqual(headings.map(\.level), [1, 2, 2, 3])
    }

    // MARK: - Headings and Ids

    /// Levels, runs, and ids of a run of headings.
    func testHeadingsKeepTheirLevelsRunsAndIds() throws {
        let document = try walk(text("# Top *Title*", "", "## Second", "", "###### Sixth"))
        XCTAssertEqual(document.blocks, [
            .heading(ExportHeading(level: 1, runs: [ExportRun("Top "), ExportRun("Title", isEmphasis: true)], id: "top-title")),
            heading(2, "Second", id: "second"),
            heading(6, "Sixth", id: "sixth")
        ])
    }

    /// Three headings "Notes" are "notes", "notes-2", and "notes-3"; and with
    /// "Notes", "Notes 2", "Notes" the third is "notes-3".
    func testRepeatedHeadingsGetNumberedIds() throws {
        let three = try walk(text("# Notes", "", "# Notes", "", "# Notes"))
        XCTAssertEqual(three.headings.map(\.id), ["notes", "notes-2", "notes-3"])

        let mixed = try walk(text("# Notes", "", "# Notes 2", "", "# Notes"))
        XCTAssertEqual(mixed.headings.map(\.id), ["notes", "notes-2", "notes-3"])
    }

    /// An annotation inside a heading (caches written before format 3.0.5)
    /// is not read: "Notes <!-- old annotation -->" reads "Notes".
    func testAnAnnotationInsideAHeadingIsNotRead() throws {
        let document = try walk("## Notes <!-- old annotation -->")
        XCTAssertEqual(document.blocks, [heading(2, "Notes", id: "notes")])
    }

    /// A heading with nothing to read is dropped, as the reader's list drops it.
    func testAHeadingWithNothingToReadIsDropped() throws {
        let document = try walk(text("## <!-- only a comment -->", "", "Words."))
        XCTAssertEqual(document.blocks, [paragraph("Words.")])
    }

    /// Slugs: accents folded, a number made a name, nothing left made
    /// "heading", length cut, and other scripts transliterated to a valid id.
    func testSlugs() {
        XCTAssertEqual(ExportHeadingIDs.slug("Café au lait"), "cafe-au-lait")
        XCTAssertEqual(ExportHeadingIDs.slug("1984"), "heading-1984")
        XCTAssertEqual(ExportHeadingIDs.slug("!!!"), "heading")
        XCTAssertEqual(ExportHeadingIDs.slug("  -- Hello,   World! --  "), "hello-world")
        XCTAssertLessThanOrEqual(ExportHeadingIDs.slug(String(repeating: "word ", count: 60)).count, 64)
        // The cut never leaves a hyphen at the end.
        let cut = ExportHeadingIDs.slug(String(repeating: "a", count: 63) + " b")
        XCTAssertEqual(cut, String(repeating: "a", count: 63))

        for heading in ["Ελληνικά κείμενο", "你好世界", "Привет, мир"] {
            let slug = ExportHeadingIDs.slug(heading)
            XCTAssertFalse(slug.isEmpty, heading)
            XCTAssertTrue(slug.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }, slug)
            XCTAssertTrue(slug.first?.isLetter == true, slug)
        }
    }

    /// A 300-character heading is read whole but its id is cut.
    func testALongHeadingGetsACutId() throws {
        let long = String(repeating: "abcdefghi ", count: 30)
        let document = try walk("# \(long)")
        let id = try XCTUnwrap(document.headings.first?.id)
        XCTAssertLessThanOrEqual(id.count, 64)
        XCTAssertFalse(id.hasSuffix("-"))
    }

    // MARK: - Runs

    /// Emphasis, strong, strong inside emphasis, and code.
    func testRunStyles() throws {
        XCTAssertEqual(try runs(of: "an *emphatic* word"),
                       [ExportRun("an "), ExportRun("emphatic", isEmphasis: true), ExportRun(" word")])
        XCTAssertEqual(try runs(of: "a **strong** word"),
                       [ExportRun("a "), ExportRun("strong", isStrong: true), ExportRun(" word")])
        XCTAssertEqual(try runs(of: "*a **b** c*"),
                       [ExportRun("a ", isEmphasis: true),
                        ExportRun("b", isEmphasis: true, isStrong: true),
                        ExportRun(" c", isEmphasis: true)])
        XCTAssertEqual(try runs(of: "use `code` here"),
                       [ExportRun("use "), ExportRun("code", isCode: true), ExportRun(" here")])
    }

    /// Only a web or mail address becomes a link; every other link is its
    /// words in plain text.
    func testOnlyWebAndMailAddressesBecomeLinks() throws {
        XCTAssertEqual(try runs(of: "[site](https://example.com/a?b=1&c=2)"),
                       [ExportRun("site", link: "https://example.com/a?b=1&c=2")])
        XCTAssertEqual(try runs(of: "[mail](mailto:a@example.com)"),
                       [ExportRun("mail", link: "mailto:a@example.com")])
        for address in ["javascript:alert(1)", "file:///etc/passwd", "#chapter-2", "chapter2.html"] {
            XCTAssertEqual(try runs(of: "[words](\(address))"), [ExportRun("words")], address)
        }
        // A refused link's words join the plain text around them.
        XCTAssertEqual(try runs(of: "see [this](javascript:1) now"), [ExportRun("see this now")])
    }

    /// An image is its alternative text, never its source.
    func testAnImageIsItsAlternativeText() throws {
        let found = try runs(of: "![a red barn](https://example.com/barn.png)")
        XCTAssertEqual(found, [ExportRun("a red barn")])
        XCTAssertFalse(found.plainText.contains("barn.png"))
    }

    /// A soft break is a space, a hard break a line feed; inline HTML is
    /// dropped and the words around it joined; neighbouring runs of one
    /// style are one run.
    func testBreaksInlineHTMLAndJoining() throws {
        XCTAssertEqual(try runs(of: "one\ntwo"), [ExportRun("one two")])
        XCTAssertEqual(try runs(of: "one  \ntwo"), [ExportRun("one\ntwo")])
        XCTAssertEqual(try runs(of: "a<span>b</span>c"), [ExportRun("abc")])
        XCTAssertEqual(try runs(of: "plain ~~struck~~ plain"), [ExportRun("plain struck plain")])
    }

    /// Runs are trimmed at both ends, and a run that trimming empties goes.
    func testRunsAreTrimmedAtBothEnds() throws {
        // White space left at an end by dropped inline HTML goes.
        XCTAssertEqual(try runs(of: "text <b></b>"), [ExportRun("text")])
        XCTAssertEqual(try runs(of: "<i></i> word"), [ExportRun("word")])
        // A run that trimming empties is dropped, and the run before it is trimmed in turn.
        XCTAssertEqual(try runs(of: "**bold** <b></b>"), [ExportRun("bold", isStrong: true)])
    }

    // MARK: - Lists

    /// An unordered list holding an ordered list that starts at 3, and an
    /// item of two paragraphs, with the plain text of both exact.
    func testListsKeepTheirKindsStartsDepthsAndItems() throws {
        let document = try walk(text(
            "- Fruit",
            "",
            "  3. Apple",
            "  4. Pear",
            "- Veg",
            "",
            "  More veg"
        ))
        let nested = ExportList(isOrdered: true, start: 3, depth: 1, items: [
            ExportListItem(blocks: [paragraph("Apple")]),
            ExportListItem(blocks: [paragraph("Pear")])
        ])
        let outer = ExportList(isOrdered: false, start: 1, depth: 0, items: [
            ExportListItem(blocks: [paragraph("Fruit"), .list(nested)]),
            ExportListItem(blocks: [paragraph("Veg"), paragraph("More veg")])
        ])
        XCTAssertEqual(document.blocks, [.list(outer)])

        XCTAssertEqual(outer.items.map(\.plainText), ["Fruit\nApple\nPear", "Veg\nMore veg"])
        XCTAssertEqual(ExportBlock.list(outer).plainText, "Fruit\nApple\nPear\nVeg\nMore veg")
    }

    /// An item's text stays in reading order around the list inside it: the
    /// item "Alpha", its list of "Xray" and "Yankee", then "Bravo" reads
    /// "Alpha", "Xray", "Yankee", "Bravo" (a reviewer's case: the paragraph
    /// after the inner list once moved ahead of it).
    func testAnItemReadsInOrderAroundTheListInsideIt() throws {
        let document = try walk(text("- Alpha", "", "  - Xray", "  - Yankee", "", "  Bravo"))
        let inner = ExportList(isOrdered: false, start: 1, depth: 1, items: [
            ExportListItem(blocks: [paragraph("Xray")]),
            ExportListItem(blocks: [paragraph("Yankee")])
        ])
        let item = ExportListItem(blocks: [paragraph("Alpha"), .list(inner), paragraph("Bravo")])
        XCTAssertEqual(document.blocks, [.list(ExportList(isOrdered: false, start: 1, depth: 0, items: [item]))])

        XCTAssertEqual(item.plainText, "Alpha\nXray\nYankee\nBravo")
        XCTAssertEqual(document.blocks.map(\.plainText), ["Alpha\nXray\nYankee\nBravo"])
    }

    /// A task-list checkbox is ignored; an ordered list keeps the largest
    /// start CommonMark allows, nine digits, exactly, and a longer number
    /// begins no list at all.
    func testTaskItemsAndHugeStarts() throws {
        let tasks = try walk("- [x] done\n- [ ] not yet")
        XCTAssertEqual(tasks.blocks, [.list(ExportList(isOrdered: false, start: 1, depth: 0, items: [
            ExportListItem(blocks: [paragraph("done")]),
            ExportListItem(blocks: [paragraph("not yet")])
        ]))])

        let huge = try walk("999999999. big")
        XCTAssertEqual(huge.blocks, [.list(ExportList(isOrdered: true, start: 999_999_999, depth: 0, items: [
            ExportListItem(blocks: [paragraph("big")])
        ]))])
        XCTAssertEqual(try walk("1234567890. big").blocks, [paragraph("1234567890. big")])
    }

    // MARK: - Quotes, Code, Breaks, and Tables

    /// A block quote holds its blocks.
    func testABlockQuote() throws {
        let document = try walk(text("> first line", ">", "> second"))
        XCTAssertEqual(document.blocks, [.blockQuote([paragraph("first line"), paragraph("second")])])
    }

    /// A code block is its lines exactly, the trailing line feed gone; an
    /// empty one is dropped.
    func testACodeBlock() throws {
        let document = try walk(text("```", "let x = 1", "  let y = 2", "```", "", "```", "```"))
        XCTAssertEqual(document.blocks, [.codeBlock("let x = 1\n  let y = 2")])
    }

    /// A thematic break stays between its neighbours.
    func testAThematicBreak() throws {
        XCTAssertEqual(try walk(text("above", "", "---", "", "below")).blocks,
                       [paragraph("above"), .thematicBreak, paragraph("below")])
    }

    /// A table with a header row, and one whose head cells are all empty,
    /// which has no header row and no empty first row.
    func testTables() throws {
        let withHeader = try walk(text("| Name | Qty |", "| --- | --- |", "| Apple | **3** |", "| Pear | 4 |"))
        XCTAssertEqual(withHeader.blocks, [.table(ExportTable(
            rows: [["Name", "Qty"], ["Apple", "3"], ["Pear", "4"]], hasHeaderRow: true))])

        let headless = try walk(text("|  |  |", "| --- | --- |", "| a | b |"))
        XCTAssertEqual(headless.blocks, [.table(ExportTable(rows: [["a", "b"]], hasHeaderRow: false))])
        XCTAssertEqual(ExportBlock.table(ExportTable(rows: [["a", "", "b"]], hasHeaderRow: false)).plainText, "a b")
    }

    // MARK: - What Never Reaches the Document

    /// An HTML block (its words too), a plain comment, and a heading
    /// annotation reach nothing.
    func testRawHTMLCommentsAndAnnotationsAreDropped() throws {
        let annotation = MarkdownHeadingAnnotation(level: 2, text: "Hidden").markdown
        let document = try walk(text(
            "before", "", "<div>raw</div>", "", "<!-- a plain comment -->", "", annotation, "", "after"
        ))
        XCTAssertEqual(document.blocks, [paragraph("before"), paragraph("after")])
        let all = document.blocks.map(\.plainText).joined(separator: " ")
        for word in ["raw", "Hidden", "plain comment", "textmouth"] {
            XCTAssertFalse(all.contains(word), word)
        }
    }

    /// Page markers (PG01) reach nothing: a block before the first paragraph,
    /// one between paragraphs, one inside a paragraph, one inside a word, and
    /// one after a hard break walk to the document the same Markdown gives
    /// without them. Export carries no pages until PG15.
    func testPageMarkersNeverReachExport() throws {
        // `marker(n)` is the page marker for page n, or nothing.
        func markdown(_ marker: (Int) -> String) -> String {
            [
                marker(1) + "\n\nFirst paragraph here.",
                marker(2) + "\n\nSecond has a mid " + marker(3) + "paragraph break and a wo" + marker(4) + "rd split.",
                "Line one  \n    " + marker(5) + "line two.",
            ].joined(separator: "\n\n")
        }
        let withPages = try walk(markdown { MarkdownPageMarker(label: String($0), ordinal: $0).markdown })
        let withoutPages = try walk(markdown { _ in "" })
        XCTAssertEqual(withPages, withoutPages)
        XCTAssertFalse(withPages.blocks.map(\.plainText).joined(separator: " ").contains("page"))
    }

    // MARK: - The Nesting Cap

    /// 20 nested quotes around a paragraph, and a list nested 12 deep: no
    /// quote or list in the model nests past the cap, no list's depth is
    /// above it, and every word survives.
    func testNestingIsCapped() throws {
        let quotes = try walk(String(repeating: "> ", count: 20) + "deep quoted words")
        let quoteDepth = deepest(quotes.blocks)
        XCTAssertEqual(quoteDepth.nesting, ExportDocument.maximumNesting)
        XCTAssertTrue(quotes.blocks.map(\.plainText).joined().contains("deep quoted words"))

        let lines = (0..<12).map { String(repeating: "  ", count: $0) + "- item\($0)" }
        let lists = try walk(lines.joined(separator: "\n"))
        let listDepth = deepest(lists.blocks)
        XCTAssertEqual(listDepth.nesting, ExportDocument.maximumNesting)
        XCTAssertLessThanOrEqual(listDepth.listDepth, ExportDocument.maximumNesting)
        // Every item, whole and in order: "item1" must not pass for "item10".
        let items = lists.blocks.map(\.plainText).joined(separator: "\n").split(separator: "\n").map(String.init)
        XCTAssertEqual(items, (0..<12).map { "item\($0)" })
    }

    // MARK: - The Title Heading

    /// Present with the book's title when the text has only level-2 headings,
    /// and its id differs from a level-2 heading of the same words; absent
    /// when a level-1 heading is anywhere, or when the title is blank.
    func testTheTitleHeading() throws {
        let levelTwo = try walk("## Part\n\nWords.", title: "My Book")
        XCTAssertEqual(levelTwo.titleHeading, ExportHeading(level: 1, runs: [ExportRun("My Book")], id: "my-book"))

        let sameWords = try walk("## My Book\n\nWords.", title: "My Book")
        XCTAssertEqual(sameWords.headings.map(\.id), ["my-book"])
        XCTAssertEqual(sameWords.titleHeading?.id, "my-book-2")

        XCTAssertNil(try walk("# Own Title\n\nWords.", title: "My Book").titleHeading)
        XCTAssertNil(try walk("> # Quoted Title\n\nWords.", title: "My Book").titleHeading)
        XCTAssertNil(try walk("## Part", title: "   ").titleHeading)
        // A chapter's own title heading counts as a level-1 heading.
        let chaptered = try walk(text(MarkdownCacheService.chapterMarker(title: "One"), "", "Words."), title: "My Book")
        XCTAssertNil(chaptered.titleHeading)
    }

    // MARK: - Entry Points

    /// Bytes that are not UTF-8 throw, and a cancellation made before the
    /// call stops both entry points.
    func testBadBytesAndCancellation() throws {
        let url = URL(fileURLWithPath: "/nowhere/content.md")
        let book = ExportBookDetails(title: "T")
        XCTAssertThrowsError(try ExportDocumentWalker.document(
            fromContentBytes: Data([0xFF, 0xFE, 0x41]), at: url, book: book))

        let good = try ExportDocumentWalker.document(fromContentBytes: Data("# Hi".utf8), at: url, book: book)
        XCTAssertEqual(good.blocks, [heading(1, "Hi", id: "hi")])

        let cancellation = BookExportCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try ExportDocumentWalker.document(
            fromMarkdown: "Words.", book: book, cancellation: cancellation)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try ExportDocumentWalker.document(
            fromContentBytes: Data("Words.".utf8), at: url, book: book, cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    // MARK: - The Model

    /// Language tags: trimmed, underscores read as hyphens, and anything
    /// that is not a tag refused.
    func testLanguageTags() {
        XCTAssertEqual(ExportBookDetails.languageTag("en"), "en")
        XCTAssertEqual(ExportBookDetails.languageTag(" fr-CA "), "fr-CA")
        XCTAssertEqual(ExportBookDetails.languageTag("en_US"), "en-US")
        XCTAssertEqual(ExportBookDetails.languageTag("zh-Hant-TW"), "zh-Hant-TW")

        let longest = "en" + String(repeating: "-abcdefgh", count: 3) + "-abcde"
        XCTAssertEqual(longest.count, 35)
        XCTAssertEqual(ExportBookDetails.languageTag(longest), longest)
        for refused in ["English", "e", "", "   ", longest + "f", "en--US", "en-ÜS"] {
            XCTAssertNil(ExportBookDetails.languageTag(refused), refused)
        }
    }

    /// The details of a book: no author for "Unknown", no language for a
    /// string that is no tag.
    func testBookDetails() {
        var book = Book(title: "A Title", author: "Unknown", format: .markdown, filePath: "/x.md", md5Hash: "abc")
        XCTAssertEqual(ExportBookDetails(book), ExportBookDetails(title: "A Title", author: nil, language: nil))

        book.author = "Jane Doe"
        book.epubLanguage = "fr_CA"
        XCTAssertEqual(ExportBookDetails(book), ExportBookDetails(title: "A Title", author: "Jane Doe", language: "fr-CA"))

        book.epubLanguage = "English"
        XCTAssertNil(ExportBookDetails(book).language)
    }

    /// Which addresses may be links.
    func testAllowedLinkAddresses() {
        for allowed in ["HTTPS://x", " mailto:a@b ", "http://example.com"] {
            XCTAssertTrue(ExportRun.isAllowedLinkAddress(allowed), allowed)
        }
        for refused in ["javascript:x", "ftp://x", "#x", "x", ""] {
            XCTAssertFalse(ExportRun.isAllowedLinkAddress(refused), refused)
        }
    }

    /// `ExportDocument.headings` finds a heading inside a quote inside a
    /// list item.
    func testHeadingsAreFoundAtAnyDepth() {
        let buried = ExportHeading(level: 3, runs: [ExportRun("Buried")], id: "buried")
        let document = ExportDocument(
            book: ExportBookDetails(title: "T"),
            blocks: [.list(ExportList(isOrdered: false, start: 1, depth: 0, items: [
                ExportListItem(blocks: [.blockQuote([.heading(buried)])])
            ]))]
        )
        XCTAssertEqual(document.headings, [buried])
    }

    // MARK: - Real Samples

    /// The walk of `name`'s content.md, imported from a copy of the sample in
    /// a sandbox folder: its document, and the reader's own words of the
    /// same file.
    private func walkAndReaderWords(ofSample name: String) throws -> (document: ExportDocument, readerWords: [String]) {
        let folder = try makeSandboxDirectory("WalkerSample")
        let copy = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: try requireFile(name), to: copy)
        let book = try importedForTest(copy).book

        let bytes = try Data(contentsOf: book.tmbDirectory.appendingPathComponent("content.md"))
        let url = book.tmbDirectory.appendingPathComponent("content.md")
        let document = try ExportDocumentWalker.document(
            fromContentBytes: bytes, at: url, book: ExportBookDetails(book))

        let markdown = try MarkdownCacheService.cacheText(from: bytes, at: url)
        let content = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: book.title, bookAuthor: "")
        let readerWords = content.chapters.map(\.text).joined(separator: "\n\n").split(whereSeparator: \.isWhitespace).map(String.init)
        return (document, readerWords)
    }

    /// On the real EPUB (chapters with markers) and Markdown file (none): no
    /// comment reaches the walk, and every word the reader has is in the
    /// walk, in order.
    func testRealSamplesKeepEveryWordTheReaderHasAndNoComment() throws {
        for name in ["alice.epub", "sample.md"] {
            let (document, readerWords) = try walkAndReaderWords(ofSample: name)
            XCTAssertFalse(document.blocks.isEmpty, name)
            // The samples are real books, so the comparison below is not empty.
            XCTAssertGreaterThan(readerWords.count, 50, name)
            XCTAssertGreaterThan(document.headings.count, 1, name)

            for piece in pieces(of: document.blocks) {
                XCTAssertFalse(piece.contains("<!--"), "\(name): \(piece)")
                XCTAssertFalse(piece.contains("-->"), "\(name): \(piece)")
            }

            let walkWords = document.blocks.map(\.plainText).joined(separator: "\n").split(whereSeparator: \.isWhitespace).map(String.init)
            XCTAssertNil(firstWordMissing(of: readerWords, from: walkWords), "\(name): a word of the reader is missing from the walk")

            // Ids are unique, and a valid XML name each.
            let ids = document.headings.map(\.id) + [document.titleHeading?.id].compactMap { $0 }
            XCTAssertEqual(Set(ids).count, ids.count, name)
            XCTAssertTrue(ids.allSatisfy { $0.first?.isLetter == true }, name)
        }
    }
}
