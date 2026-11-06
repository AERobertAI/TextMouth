import XCTest
@testable import TextMouth

/// The walk of the KFX reader (FMT52, layer 3) on books built in code: the
/// HTML each node becomes, the words the listener hears, and the books it
/// refuses. Real files are read in `KFXEPUBComparisonTests`.
final class KFXWalkTests: XCTestCase {

    // MARK: - Helpers

    /// The sections of the book as HTML, joined.
    private func htmlOf(_ book: KFXTestBook) throws -> String {
        var book = book
        return try KFXBook(bytes: book.build()).sections.map(\.html).joined(separator: "\n")
    }

    /// A book of one section holding `nodes`.
    private func single(_ nodes: [KFXNodeSpec]) -> KFXTestBook {
        var book = KFXTestBook()
        book.sections = [("c0", nodes)]
        return book
    }

    /// The prepared book (chapters and all) of `book`.
    private func prepare(_ book: KFXTestBook) throws -> MOBIParser.PreparedBook {
        var book = book
        return try KFXParser.prepareBook(bytes: book.build(), fallbackTitle: "Fallback")
    }

    /// The words a listener hears of the book, chapters joined.
    private func words(_ book: KFXTestBook) throws -> [String] {
        try prepare(book).chapters.flatMap { $0.chapter.text.split(whereSeparator: \.isWhitespace).map(String.init) }
    }

    // MARK: - Paragraphs and headings

    func testParagraphsAreReadInTheOrderOfTheirNodes() throws {
        let book = single([.text("First."), .container([.text("Second."), .text("Third.")]), .text("Fourth.")])
        XCTAssertEqual(try words(book), ["First.", "Second.", "Third.", "Fourth."])
        XCTAssertEqual(try htmlOf(book), "<p>First.</p><p>Second.</p><p>Third.</p><p>Fourth.</p>")
    }

    func testAHeadingNodeIsAHeadingOfItsLevel() throws {
        for level in 1...6 {
            let html = try htmlOf(single([.text("Title", heading: level), .text("Body.")]))
            XCTAssertTrue(html.hasPrefix("<h\(level)>Title</h\(level)><p>Body.</p>"), html)
        }
        // A level past 6 is the deepest heading.
        XCTAssertTrue(try htmlOf(single([.text("Deep", heading: 9)])).hasPrefix("<h6>"))
    }

    func testAHeadingBecomesAHeadingOfTheChapterAndAddsNoWords() throws {
        let prepared = try prepare(single([.text("The Title", heading: 1), .text("Body words here.")]))
        XCTAssertEqual(prepared.chapters.count, 1)
        let chapter = prepared.chapters[0].chapter
        XCTAssertEqual(chapter.headings.map(\.text), ["The Title"])
        XCTAssertEqual(chapter.headings.map(\.level), [1])
        XCTAssertEqual(chapter.text.split(whereSeparator: \.isWhitespace).joined(separator: " "), "The Title Body words here.")
    }

    func testALineBreakInAHeadingReadsAsWordsWithASpace() throws {
        let prepared = try prepare(single([.text("CHAPTER I.\nDown the Rabbit-Hole", heading: 2), .text("Alice was beginning.")]))
        let chapter = prepared.chapters[0].chapter
        XCTAssertEqual(chapter.headings.map(\.text), ["CHAPTER I. Down the Rabbit-Hole"])
        XCTAssertTrue(chapter.text.contains("CHAPTER I. Down the Rabbit-Hole"), chapter.text)
    }

    func testALineBreakInAParagraphIsALineBreak() throws {
        let html = try htmlOf(single([.text("The saw goes out,\nthe saw comes back.")]))
        XCTAssertEqual(html, "<p>The saw goes out,<br/>the saw comes back.</p>")
    }

    func testTextIsEscapedAndControlCharactersDropped() throws {
        let html = try htmlOf(single([.text("a < b & c > \"d\"\u{1}\u{0}e")]))
        XCTAssertEqual(html, "<p>a &lt; b &amp; c &gt; &quot;d&quot;e</p>")
    }

    func testWhitespaceOnlyTextWritesNothingAndNoWordsAreAdded() throws {
        let book = single([.text("   "), .text("Words."), .text("\n")])
        XCTAssertEqual(try htmlOf(book), "<p>Words.</p>")
    }

    // MARK: - Emphasis and links: offsets are code points

    func testBoldItalicAndBothComeFromStyleRuns() throws {
        let book = single([.text("one two three", runs: [
            .init(start: 0, length: 3, style: "bold"), .init(start: 4, length: 3, style: "italic"),
            .init(start: 8, length: 5, style: "both"),
        ])])
        XCTAssertEqual(
            try htmlOf(book),
            "<p><strong>one</strong> <em>two</em> <strong><em>three</em></strong></p>")
    }

    func testEmphasisMarksAreNeverSpoken() throws {
        let book = single([.text("Mark my words please", runs: [.init(start: 0, length: 4, style: "bold"), .init(start: 8, length: 5, style: "italic")])])
        XCTAssertEqual(try words(book), ["Mark", "my", "words", "please"])
    }

    func testOffsetsCountCodePointsNotUTF16OrCharacters() throws {
        // The emoji is one code point (two UTF-16 units); the e with a
        // combining acute is two code points (one Character). The run is
        // the word "bold" after both.
        let text = "\u{1F600} e\u{301} bold end"
        let book = single([.text(text, runs: [.init(start: 5, length: 4, style: "bold")])])
        XCTAssertEqual(try htmlOf(book), "<p>\u{1F600} e\u{301} <strong>bold</strong> end</p>")
    }

    func testEmphasisMayStartInsideAWordAndRunsMayOverlap() throws {
        let book = single([.text("unbelievable", runs: [
            .init(start: 2, length: 6, style: "bold"), .init(start: 5, length: 5, style: "italic"),
        ])])
        // Cut at every boundary: bold over 2..<5, both over 5..<8, italic over 8..<10.
        XCTAssertEqual(
            try htmlOf(book),
            "<p>un<strong>bel</strong><strong><em>iev</em></strong><em>ab</em>le</p>")
        XCTAssertEqual(try words(book), ["unbelievable"])
    }

    func testARunOutOfRangeIsClampedOrIgnoredAndNoWordIsLost() throws {
        let book = single([.text("short", runs: [
            .init(start: 3, length: 100, style: "bold"),       // past the end: clamped
            .init(start: 50, length: 2, style: "bold"),        // wholly past: ignored
            .init(start: -1, length: 2, style: "italic"),      // negative: ignored
            .init(start: 0, length: 0, style: "italic"),       // empty: ignored
        ])])
        XCTAssertEqual(try htmlOf(book), "<p>sho<strong>rt</strong></p>")
    }

    func testAnUnknownStyleOrNoStyleAddsNoEmphasis() throws {
        let book = single([.text("plain words", runs: [.init(start: 0, length: 5, style: "no-such-style"), .init(start: 6, length: 5, style: nil)])])
        XCTAssertEqual(try htmlOf(book), "<p>plain words</p>")
    }

    func testLinksGoToWebAddressesAndToPositionsInTheBook() throws {
        var book = single([.text("see the rules or the start", runs: [
            .init(start: 8, length: 5, style: nil, link: "web"), .init(start: 17, length: 9, style: nil, link: "inside"),
        ])])
        book.anchors = ["web": (url: "https://example.org/a?b=1&c=2", node: nil, offset: 0), "inside": (url: nil, node: 801, offset: 4)]
        XCTAssertEqual(
            try htmlOf(book),
            // The place the second link points at, offset 4 of the first node, is marked with an anchor.
            "<p>see <a id=\"kfx-801-4\"></a>the <a href=\"https://example.org/a?b=1&amp;c=2\">rules</a> or <a href=\"#kfx-801-4\">the start</a></p>")
        XCTAssertEqual(try words(book), ["see", "the", "rules", "or", "the", "start"])
    }

    func testALinkWhoseAnchorIsMissingIsPlainText() throws {
        let book = single([.text("a b c", runs: [.init(start: 2, length: 1, style: nil, link: "nowhere")])])
        XCTAssertEqual(try htmlOf(book), "<p>a b c</p>")
    }

    func testTooManyRunsLeaveTheBlockWithoutEmphasisButWithAllItsWords() throws {
        let runs = (0..<(KFXInlineText.maximumRuns + 1)).map { _ in KFXNodeSpec.Run(start: 0, length: 3, style: "bold") }
        XCTAssertEqual(try htmlOf(single([.text("abc def", runs: runs)])), "<p>abc def</p>")
    }

    // MARK: - Lists, tables, images, rules

    func testNestedListsKeepTheirKindAndOrder() throws {
        let book = single([.list(ordered: true, [
            .item(nil, [.text("First shelf"), .list(ordered: false, [
                .item("Hammers"),
                .item(nil, [.text("Mallets"), .list(ordered: true, [.item("Rubber"), .item("Wooden")])]),
            ])]),
            .item("Second shelf"),
        ])])
        XCTAssertEqual(
            try htmlOf(book),
            "<ol><li><p>First shelf</p><ul><li>Hammers</li><li><p>Mallets</p><ol><li>Rubber</li><li>Wooden</li></ol></li></ul></li><li>Second shelf</li></ol>")
        XCTAssertEqual(try words(book), ["First", "shelf", "Hammers", "Mallets", "Rubber", "Wooden", "Second", "shelf"])
    }

    func testATableReadsItsCaptionHeaderAndRowsInOrderAsSeparateWords() throws {
        let book = single([
            .text("Before."),
            .table(caption: "Loans by season", header: ["Season", "Loans"], rows: [["Spring", "Forty"], ["Autumn", "Thirty"]]),
            .text("After."),
        ])
        let html = try htmlOf(book)
        XCTAssertTrue(html.contains("<table><caption><p>Loans by season</p></caption><thead><tr><td>Season</td>"), html)
        XCTAssertEqual(
            try words(book),
            ["Before.", "Loans", "by", "season", "Season", "Loans", "Spring", "Forty", "Autumn", "Thirty", "After."])
    }

    func testAnImageReadsItsAltTextAndAnImageWithoutAltAddsNothing() throws {
        let book = single([.text("Before."), .image(alt: "A floor plan"), .image(alt: nil), .image(alt: "  "), .text("After.")])
        XCTAssertEqual(try htmlOf(book), "<p>Before.</p><p><img alt=\"A floor plan\"/></p><p>After.</p>")
        XCTAssertEqual(try words(book), ["Before.", "A", "floor", "plan", "After."])
    }

    func testARuleWritesNoWords() throws {
        XCTAssertEqual(try words(single([.text("Above."), .rule, .text("Below.")])), ["Above.", "Below."])
    }

    func testInlineChildrenFormOneParagraph() throws {
        let book = single([.inlineParent(["A line with ", "an inline", " piece."]), .text("Next.")])
        XCTAssertEqual(try htmlOf(book), "<p>A line with an inline piece.</p><p>Next.</p>")
    }

    func testHiddenContentVectorsAndPluginsAreSkippedWithTheirChildren() throws {
        let book = single([
            .text("Kept."), .typed(439, [.text("Hidden words.")]), .typed(272, [.text("Vector words.")]),
            .typed(274, [.text("Plugin words.")]), .text("Also kept."),
        ])
        XCTAssertEqual(try words(book), ["Kept.", "Also", "kept."])
    }

    // MARK: - Chapters

    func testEachSectionThatHoldsWordsIsAChapterInReadingOrder() throws {
        var book = KFXTestBook()
        book.sections = [
            ("c0", [.text("Cover", heading: 1)]),
            ("c1", [.image(alt: nil)]),
            ("c2", [.text("Chapter Two", heading: 1), .text("Words.")]),
        ]
        let prepared = try prepare(book)
        XCTAssertEqual(prepared.chapters.map(\.chapter.title), ["Cover", "Chapter Two"])
    }

    func testASectionWithNoHeadingIsTitledByItsNumber() throws {
        var book = KFXTestBook()
        book.sections = [("c0", [.text("No heading here.")]), ("c1", [.text("Nor here.")])]
        XCTAssertEqual(try prepare(book).chapters.map(\.chapter.title), ["Chapter 1", "Chapter 2"])
    }

    func testTheTitleAuthorAndLanguageAreTheBooks() throws {
        var book = single([.text("Words.")])
        book.title = "The Tool Library"
        book.authors = ["First Author", "Second Author"]
        book.language = "en-GB"
        let prepared = try prepare(book)
        XCTAssertEqual(prepared.title, "The Tool Library")
        XCTAssertEqual(prepared.author, "First Author, Second Author")
        XCTAssertEqual(prepared.language, "en-GB")
    }

    func testABookThatNamesNothingTakesTheFallbackTitleAndTheUnknownAuthor() throws {
        var book = single([.text("Words.")])
        book.title = nil
        book.authors = []
        book.language = nil
        let prepared = try prepare(book)
        XCTAssertEqual(prepared.title, "Fallback")
        XCTAssertEqual(prepared.author, Book.unknownAuthor)
        XCTAssertNil(prepared.language)
    }

    func testTheDefaultReadingOrderIsReadAndRepeatsAreSkipped() throws {
        var test = KFXTestBook()
        test.sections = [("c0", [.text("Alpha.")]), ("c1", [.text("Beta.")])]
        let bytes = test.build { builder in
            // Two reading orders: the first is not the default; and a repeat in the default.
            let c0 = builder.id(of: "c0"), c1 = builder.id(of: "c1")
            builder.entities.removeAll { $0.type == 538 }
            builder.add(type: 538, .structure([(169, .list([
                .structure([(178, .symbol(900)), (170, .list([.symbol(c1)]))]),
                .structure([(178, .symbol(351)), (170, .list([.symbol(c1), .symbol(c0), .symbol(c1)]))]),
            ]))]))
        }
        let book = try KFXBook(bytes: bytes)
        XCTAssertEqual(book.sections.map(\.html), ["<p>Beta.</p>", "<p>Alpha.</p>"])
    }

    func testAnOlderBooksReadingOrderIsInItsFlatMetadata() throws {
        var test = KFXTestBook()
        test.sections = [("c0", [.text("Alpha.")])]
        let bytes = test.build { builder in
            let c0 = builder.id(of: "c0")
            builder.entities.removeAll { $0.type == 538 }
            builder.add(type: 258, .structure([(169, .list([.structure([(178, .symbol(351)), (170, .list([.symbol(c0)]))])]))]))
        }
        XCTAssertEqual(try KFXBook(bytes: bytes).sections.map(\.html), ["<p>Alpha.</p>"])
    }

    // MARK: - Books it refuses

    func testABookWithNoFlowingTextIsRefusedBeforeItsTextIsWalked() throws {
        let sentence = "This Kindle book has no flowing text to read, such as a comic or a print replica, so TextMouth can't read it."
        for (key, value): (String, IonOut) in [
            ("yj_fixed_layout", .int(1)), ("yj_fixed_layout", .int(2)), ("yj_fixed_layout", .int(3)),
            ("yj_textbook", .bool(true)), ("yj_publisher_panels", .int(1)), ("yj_facing_page", .int(1)),
            ("yj_double_page_spread", .string("1")), ("continuous_popup_progression", .int(1)),
            ("yj_has_text_popups", .bool(true)), ("is_dictionary", .int(1)), ("dictionary_lookup", .string("en-en")),
        ] {
            var book = single([.text("Words that would be read.")])
            book.capabilities = [(key, value)]
            XCTAssertThrowsError(try KFXParser.prepareBook(bytes: book.build(), fallbackTitle: "T"), key) {
                XCTAssertEqual($0 as? KFXError, .noFlowingText, key)
                XCTAssertEqual($0.localizedDescription, sentence)
            }
        }
    }

    func testACapabilityThatIsSwitchedOffDoesNotRefuseTheBook() throws {
        var book = single([.text("Words.")])
        book.capabilities = [("yj_fixed_layout", .int(0)), ("yj_textbook", .bool(false)), ("yj_facing_page", .string("false"))]
        XCTAssertEqual(try words(book), ["Words."])
    }

    func testMagazinesComicPanelsAndNotebooksAreRefused() throws {
        var magazine = single([.text("Words.")])
        let magazineBytes = magazine.build { builder in
            // cde_content_type MAGZ in the title category.
            builder.entities.removeAll { $0.type == 490 }
            builder.add(type: 490, .structure([(491, .list([.structure([
                (495, .string("kindle_title_metadata")), (258, .list([.structure([(492, .string("cde_content_type")), (307, .string("MAGZ"))])])),
            ])]))]))
        }
        XCTAssertThrowsError(try KFXBook(bytes: magazineBytes)) { XCTAssertEqual($0 as? KFXError, .noFlowingText) }

        var comic = single([.text("Words.")])
        comic.documentData = [(665, .int(1))]
        XCTAssertThrowsError(try KFXBook(bytes: comic.build())) { XCTAssertEqual($0 as? KFXError, .noFlowingText) }

        // A notebook's section carries a field named nmdl.canvas_width: a local symbol.
        var notebook = KFXTestBook()
        notebook.sections = [("c0", [.text("Words.")])]
        let noteBytes = notebook.build { out in
            out.localSymbols.append("nmdl.canvas_width")
            let fieldID = out.id(of: "nmdl.canvas_width")
            let index = out.entities.firstIndex { $0.type == 260 }!
            out.entities[index].value = .structure([
                (174, .symbol(out.id(of: "c0"))), (fieldID, .int(100)),
                (141, .list([.structure([(155, .int(1)), (176, .symbol(out.id(of: "story_c0"))), (159, .symbol(269))])])),
            ])
        }
        XCTAssertThrowsError(try KFXBook(bytes: noteBytes)) { XCTAssertEqual($0 as? KFXError, .noFlowingText) }
    }

    func testABookOfOnlyPicturesIsRefusedAsHavingNoFlowingText() throws {
        var book = KFXTestBook()
        book.sections = [("c0", [.image(alt: nil)]), ("c1", [.container([.image(alt: nil)])])]
        XCTAssertThrowsError(try KFXBook(bytes: book.build())) { XCTAssertEqual($0 as? KFXError, .noFlowingText) }
    }

    func testAContainerWithNoTextOfItsOwnIsPartOfABook() throws {
        var builder = KFXContainerBuilder()
        builder.localSymbols = ["e0"]
        builder.add(type: 490, .structure([(491, .list([]))]))
        builder.addResource(name: "e0", [1, 2, 3])
        XCTAssertThrowsError(try KFXBook(bytes: builder.build())) {
            XCTAssertEqual($0 as? KFXError, .partOfABook)
            XCTAssertEqual($0.localizedDescription, "This file holds only part of a Kindle book. Open the book's main .kfx file.")
        }
    }

    // MARK: - A book that lies

    func testTextThatIsNotInTheBookIsDamageNotASilentGap() throws {
        for pointer in [
            IonOut.structure([(4, .symbol(860)), (403, .int(99))]),     // index past the end
            IonOut.structure([(4, .symbol(860)), (403, .int(-1))]),     // negative
            IonOut.structure([(4, .symbol(5000)), (403, .int(0))]),     // a content fragment that is not there
            IonOut.structure([(403, .int(0))]),                         // no name
        ] {
            var book = KFXTestBook()
            book.sections = [("c0", [.text("Real.")])]
            let bytes = book.build { builder in
                let section = builder.entities.firstIndex { $0.type == 259 }!
                builder.entities[section].value = .structure([
                    (176, .symbol(builder.id(of: "story_c0"))),
                    (146, .list([.structure([(155, .int(1)), (159, .symbol(269)), (145, pointer)])])),
                ])
            }
            assertRefusedQuickly("pointer \(pointer)") { try KFXBook(bytes: bytes) }
        }
    }

    func testASectionOrStorylineThatIsNotInTheBookIsDamage() throws {
        var book = single([.text("Words.")])
        let missingSection = book.build { builder in builder.entities.removeAll { $0.type == 260 } }
        assertRefusedQuickly("no section") { try KFXBook(bytes: missingSection) }
        let missingStoryline = book.build { builder in builder.entities.removeAll { $0.type == 259 } }
        assertRefusedQuickly("no storyline") { try KFXBook(bytes: missingStoryline) }
    }

    func testAStorylineThatNamesItselfIsDamageNotALoop() throws {
        var book = single([.text("Words.")])
        let bytes = book.build { builder in
            let index = builder.entities.firstIndex { $0.type == 259 }!
            let name = builder.id(of: "story_c0")
            // A node that expands the storyline it is in.
            builder.entities[index].value = .structure([
                (176, .symbol(name)),
                (146, .list([.structure([(155, .int(1)), (159, .symbol(270)), (176, .symbol(name))])])),
            ])
        }
        assertRefusedQuickly("self") { try KFXBook(bytes: bytes) }
    }

    func testTwoStorylinesThatNameEachOtherAreDamage() throws {
        var book = KFXTestBook()
        book.sections = [("c0", [.text("A.")])]
        let bytes = book.build { builder in
            builder.localSymbols.append("other")
            let first = builder.id(of: "story_c0"), other = builder.id(of: "other")
            let index = builder.entities.firstIndex { $0.type == 259 }!
            builder.entities[index].value = .structure([
                (176, .symbol(first)), (146, .list([.structure([(155, .int(1)), (159, .symbol(270)), (176, .symbol(other))])])),
            ])
            builder.entities.append(.init(id: other, type: 259, value: .structure([
                (176, .symbol(other)), (146, .list([.structure([(155, .int(2)), (159, .symbol(270)), (176, .symbol(first))])])),
            ])))
        }
        assertRefusedQuickly("cycle") { try KFXBook(bytes: bytes) }
    }

    func testAnInlineFragmentThatNamesItselfIsDamage() throws {
        var book = KFXTestBook()
        book.sections = [("c0", [.text("A.")])]
        let bytes = book.build { builder in
            builder.localSymbols.append("loop")
            let loop = builder.id(of: "loop")
            let index = builder.entities.firstIndex { $0.type == 259 }!
            builder.entities[index].value = .structure([
                (176, .symbol(builder.id(of: "story_c0"))), (146, .list([.symbol(loop)])),
            ])
            builder.entities.append(.init(id: loop, type: 608, value: .structure([
                (155, .int(5)), (159, .symbol(270)), (146, .list([.symbol(loop)])),
            ])))
        }
        assertRefusedQuickly("inline cycle") { try KFXBook(bytes: bytes) }
    }

    func testNodesNestedPastTheDepthLimitAreDamageAndANormalDepthIsRead() throws {
        func nested(_ depth: Int) -> KFXNodeSpec {
            var node = KFXNodeSpec.text("Deep words.")
            for _ in 0..<depth { node = .container([node]) }
            return node
        }
        XCTAssertEqual(try words(single([nested(40)])), ["Deep", "words."])
        // Ion itself is cut at its own depth: nesting past either is refused, quickly.
        var deep = single([nested(KFXWalk.maximumDepth + 20)])
        let bytes = deep.build()
        assertRefusedQuickly("deep") { try KFXBook(bytes: bytes) }
    }

    func testTheFirstOfTwoFragmentsWithTheSameNameIsTheOneRead() throws {
        var test = single([.text("The real words.")])
        let bytes = test.build { builder in
            let index = builder.entities.firstIndex { $0.type == 145 }!
            var copy = builder.entities[index]
            copy.value = .structure([(4, .symbol(copy.id)), (146, .list([.string("Forged words.")]))])
            builder.entities.append(copy)
        }
        XCTAssertEqual(try KFXBook(bytes: bytes).sections.map(\.html), ["<p>The real words.</p>"])
    }

    func testAnUnknownSymbolIdIsHandledNotATrap() throws {
        // A node type and a style that are symbols past the table.
        var test = KFXTestBook()
        test.sections = [("c0", [.raw(.structure([(155, .int(1)), (159, .symbol(99_999)), (157, .symbol(88_888)),
                                                  (145, .string("Odd node text."))]))])]
        let bytes = test.build()
        XCTAssertEqual(try KFXBook(bytes: bytes).sections.map(\.html), ["<p>Odd node text.</p>"])
    }
}
