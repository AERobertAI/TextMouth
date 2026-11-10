import XCTest
@testable import TextMouth

/// What the review of the KF8 reader (B3 to B5, S1 to S5, and the minor
/// findings) asked of it, tried on books built in code (`KF8Fixture`): the
/// contents page a converter adds and the real last page it must not take,
/// documents that must lie end to end, one label shared by many rows, a
/// hybrid whose KF8 half fails in every way short of protection and a
/// cancel, SVG words, the navigation lists calibre strips the prefix from,
/// the chapters calibre cuts, a contents or guide that does not read, and
/// the tests the review's mutations showed to prove nothing.
final class KF8ReviewFixTests: XCTestCase {

    // MARK: - Helpers

    private func opened(_ bytes: [UInt8], hybrid: MOBIBook.HybridChoice = .kf8) throws -> MOBIBook {
        try MOBIBook(bytes: bytes, hybrid: hybrid)
    }

    /// The book read to its chapters, as an import reads it, from a file named `book.azw3`.
    private func prepared(_ fixture: KF8Fixture) throws -> MOBIParser.PreparedBook {
        try MOBIParser.prepareBook(url: writeMOBI(fixture.data(), named: "book.azw3"))
    }

    /// A document with a head and `body`, the whole body cut out as its one fragment, as every real
    /// document has one.
    private func document(title: String = "Fixture KF8 Book", body: String) throws -> KF8Fixture.Document {
        KF8Fixture.Document(
            html: "<html><head><title>\(title)</title></head><body>\(body)</body></html>",
            cutting: body.isEmpty ? [] : [body])
    }

    /// The words of the chapters, in order.
    private func words(_ book: MOBIParser.PreparedBook) -> [String] {
        book.chapters.flatMap { $0.chapter.text.split(whereSeparator: \.isWhitespace).map(String.init) }
    }

    private static let damagedSentence = "This Kindle book is damaged or incomplete. Get a fresh copy of the book, then import it again."

    /// A hybrid file whose MOBI 6 half says "Words of the old half." and whose KF8 half is `kf8`.
    private func hybrid(_ kf8: KF8Fixture) -> [UInt8] {
        var six = MOBIFixture()
        six.html = "<html><body><p>Words of the old half.</p></body></html>"
        return kf8.hybrid(mobi6: six)
    }

    private func reads(_ bytes: [UInt8], as half: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let book = try opened(bytes)
        XCTAssertTrue(book.sections.contains { $0.html.contains(half) }, "read from the wrong half", file: file, line: line)
    }

    // MARK: - B3: the contents page a converter adds

    /// Two documents: a chapter that the contents names, and a last page with `page` as its body, which the
    /// guide names as the contents page (at `guideOffset` in its first fragment).
    private func bookWithLastPage(
        _ page: String, title: String = "Table of Contents", guide: Bool = true, guideOffset: Int = 0,
        labels: [String] = ["Chapter"]
    ) throws -> KF8Fixture {
        var fixture = KF8Fixture(documents: [
            try document(body: "<h1>Chapter</h1><p>Real words.</p>"),
            try document(title: title, body: page),
        ])
        fixture.entries = labels.map { KF8Fixture.Entry(label: $0, document: 0) }
        // Only the first label can name the chapter as a whole; the others name its places.
        for index in fixture.entries.indices.dropFirst() { fixture.entries[index].offset = index }
        if guide { fixture.guide = [(type: "toc", document: 1)] }
        fixture.guideOffset = guideOffset
        return fixture
    }

    private static let generatedPage =
        "<h2>Table of Contents</h2><ul><li><a href=\"kindle:pos:fid:0000:off:0000000000\">Chapter</a></li></ul>"

    func testAGeneratedContentsPageIsLeftOut() throws {
        XCTAssertEqual(try opened(bookWithLastPage(Self.generatedPage).data()).sections.count, 1)
    }

    func testAGeneratedPageWhoseLinksComeInAnyOrderIsLeftOut() throws {
        let page = "<h2>Table of Contents</h2><ul><li><a href=\"kindle:pos:fid:0000:off:0000000001\">Second</a></li>"
            + "<li><a href=\"kindle:pos:fid:0000:off:0000000000\">First</a></li></ul>"
        let book = try bookWithLastPage(page, labels: ["First", "Second"])
        XCTAssertEqual(try opened(book.data()).sections.count, 1)
    }

    func testALastPageThatIsNotGeneratedIsRead() throws {
        // Each of these fails one of the three conditions, and so is the author's own page.
        let cases: [(String, KF8Fixture)] = [
            ("words of its own outside its links",
             try bookWithLastPage(Self.generatedPage + "<p>A note from the author.</p>")),
            ("a link out of the book",
             try bookWithLastPage("<h2>Table of Contents</h2><ul><li><a href=\"https://example.org/\">Chapter</a></li></ul>")),
            ("a link whose words are no label of the contents",
             try bookWithLastPage("<h2>Table of Contents</h2><ul><li><a href=\"kindle:pos:fid:0000:off:0000000000\">Elsewhere</a></li></ul>")),
            ("a guide that names a place inside the page", try bookWithLastPage(Self.generatedPage, guideOffset: 4)),
            ("no guide entry", try bookWithLastPage(Self.generatedPage, guide: false)),
        ]
        for (what, fixture) in cases {
            XCTAssertEqual(try opened(fixture.data()).sections.count, 2, what)
        }
    }

    func testAnAuthorsLastPageKeepsEveryWord() throws {
        // A last page with its own words, as the review's toc-last, whose guide names it.
        let page = "<h2>Table of Contents</h2><ul><li><a href=\"kindle:pos:fid:0000:off:0000000000\">Chapter</a></li></ul>"
            + "<p>Afterword uniqueword alpha beta.</p>"
        let book = try prepared(bookWithLastPage(page))
        XCTAssertTrue(words(book).contains("uniqueword"))
    }

    func testABookOfOneDocumentWhoseGuideNamesItIsNotRefused() throws {
        // The classic self-published recipe: one document, its guide naming itself as the contents.
        var fixture = KF8Fixture(documents: [try document(body: "<h1>All of it</h1><p>Uniquewords here.</p>")])
        fixture.guide = [(type: "toc", document: 0)]
        let book = try prepared(fixture)
        XCTAssertTrue(words(book).contains("Uniquewords"))
    }

    // MARK: - B4: documents lie end to end

    private func fiveParagraphs() -> KF8Fixture {
        let texts = (0..<5).map { "<p>Paragraph \($0).</p>" }
        let html = "<html><head><title>T</title></head><body>" + texts.joined() + "</body></html>"
        return KF8Fixture(documents: [KF8Fixture.Document(html: html, cutting: Array(texts.suffix(3)))])
    }

    private func assertDamagedPlainly(_ bytes: [UInt8], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try MOBIBook(bytes: bytes), what, file: file, line: line) {
            XCTAssertEqual($0 as? MOBIError, .damaged(""), what, file: file, line: line)
            XCTAssertEqual($0.localizedDescription, Self.damagedSentence, what, file: file, line: line)
        }
    }

    func testFragmentsThatGoBackwardOrLeaveAGapOrOverlapAreDamaged() {
        let sound = fiveParagraphs()
        let laid = sound.placed()
        let rows = sound.fragmentRows(laid)
        let first = rows[0].values[6] ?? [0, 0]
        let second = rows[1].values[6] ?? [0, 0]

        var backward = sound
        var changed = rows
        changed[0].values[6] = [second[0], first[1]]
        changed[1].values[6] = [first[0], second[1]]
        backward.fragmentRowsOverride = changed
        assertDamagedPlainly(backward.data(), "fragments in the wrong order")

        var gap = sound
        changed = rows
        changed[1].values[6] = [second[0] + 1, second[1]]
        gap.fragmentRowsOverride = changed
        assertDamagedPlainly(gap.data(), "a byte between two fragments")

        var repeated = sound
        changed = rows
        changed[1].values[6] = first
        repeated.fragmentRowsOverride = changed
        assertDamagedPlainly(repeated.data(), "a fragment that names the bytes of the one before")

        var overlapping = sound
        var skeletons = sound.skeletonRows(laid)
        skeletons[0].values[6] = [1, skeletons[0].values[6]?[1] ?? 0, 1, skeletons[0].values[6]?[1] ?? 0]
        overlapping.skeletonRowsOverride = skeletons
        assertDamagedPlainly(overlapping.data(), "a skeleton that does not begin where the markup does")
    }

    func testDocumentsThatDoNotFillTheMarkupFlowAreDamaged() throws {
        // A skeleton count that is too small (one fragment of three) would read part of the book and say nothing.
        let sound = fiveParagraphs()
        let laid = sound.placed()
        var fewer = sound
        var skeletons = sound.skeletonRows(laid)
        skeletons[0].values[1] = [1, 1]
        fewer.skeletonRowsOverride = skeletons
        assertDamagedPlainly(fewer.data(), "a count of one fragment for three")

        // The index cut short: the last document is missing.
        var cut = KF8Fixture(documents: [try document(body: "<p>One.</p>"), try document(body: "<p>Two.</p>")])
        cut.skeletonRowsOverride = Array(cut.skeletonRows(cut.placed()).prefix(1))
        cut.fragmentRowsOverride = Array(cut.fragmentRows(cut.placed()).prefix(1))
        assertDamagedPlainly(cut.data(), "the second of two documents missing")

        var none = sound
        none.skeletonRowsOverride = []
        none.fragmentRowsOverride = []
        assertDamagedPlainly(none.data(), "an empty skeleton index")
    }

    func testAThousandPlacesInsideOneTagWriteOneAnchorAndNoMoreHTMLThanTheText() throws {
        // The review's bomb: many contents rows inside one long tag, which an anchor cannot go inside, so
        // they all move to its start. Each used to get an anchor of its own there.
        let body = "<p class=\"" + String(repeating: "x", count: 4_000) + "\">Words.</p>"
        var fixture = KF8Fixture(documents: [try document(body: body)])
        fixture.entries = [KF8Fixture.Entry(label: "Top", document: 0)]
            + (1...2_000).map { KF8Fixture.Entry(label: "Place \($0)", document: 0, offset: 10 + $0, depth: 1) }
        let started = Date()
        let book = try opened(fixture.data())
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(book.sections[0].headingTargets.count, 1, "one anchor for the one place")
        XCTAssertEqual(book.sections[0].headingTargets.values.first?.text, "Place 1", "the first entry to name it names it")
        XCTAssertLessThan(book.sections[0].html.utf8.count, fixture.documents[0].html.utf8.count + 200)
    }

    // MARK: - B5: one long label

    func testALabelIsCutAtAKilobyteAndEachIsReadOnce() throws {
        let label = String(repeating: "L", count: 100_000)
        let texts = (0..<1_000).map { "<p>Paragraph \($0).</p>" }
        var fixture = KF8Fixture(documents: [KF8Fixture.Document(
            html: "<html><head><title>T</title></head><body>" + texts.joined() + "</body></html>", cutting: [texts.joined()])])
        var offset = 0
        // 1,000 rows all naming the one label (at place 0 of the strings), at 1,000 places of the one fragment.
        let rows = texts.enumerated().map { index, text -> KF8Fixture.Row in
            defer { offset += text.utf8.count }
            return KF8Fixture.Row(
                name: Array(String(format: "%04d", index).utf8),
                values: [1: [0], 2: [0], 3: [0], 4: [1], 6: [0, offset]])
        }
        fixture.contentsOverride = (rows: rows, strings: [label])
        let started = Date()
        let book = try opened(fixture.data())
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "the label was copied for every row")
        XCTAssertFalse(book.sections[0].headingTargets.isEmpty)
        for annotation in book.sections[0].headingTargets.values {
            XCTAssertLessThanOrEqual(annotation.text.utf8.count, MOBIIndex.maximumLabelBytes)
        }
        // The same cap on the contents of a MOBI 6 book, which shares the reader of labels.
        var six = MOBIFixture()
        six.html = "<html><body><p>Words.</p></body></html>"
        six.entries = [MOBIFixture.Entry(label: label, offset: 7, depth: 0)]
        let database = try MOBIPalmDatabase(bytes: six.data())
        let headers = try MOBIHeaders(record0: try database.record(0, "r0"), requiresMOBIHeader: true)
        let entries = try MOBIIndex.entries(startingAt: try XCTUnwrap(headers.indexRecord), in: database)
        XCTAssertEqual(entries.first?.label.utf8.count, MOBIIndex.maximumLabelBytes)
    }

    // MARK: - S1: a hybrid falls back on any failure of its KF8 half

    func testAHybridWhoseKF8HalfFailsInAnyWayShortOfProtectionReadsItsMOBI6Half() throws {
        let sound = KF8Fixture(body: "<p>Words of the new half.</p>")
        try reads(hybrid(sound), as: "Words of the new half.")

        var emptyIndex = sound
        emptyIndex.skeletonRowsOverride = []
        emptyIndex.fragmentRowsOverride = []
        try reads(hybrid(emptyIndex), as: "Words of the old half.")

        var unknownCompression = sound
        unknownCompression.compression = 3
        try reads(hybrid(unknownCompression), as: "Words of the old half.")

        var wrongCount = fiveParagraphs()
        var skeletons = wrongCount.skeletonRows(wrongCount.placed())
        skeletons[0].values[1] = [1, 1]
        wrongCount.skeletonRowsOverride = skeletons
        try reads(hybrid(wrongCount), as: "Words of the old half.")

        // No words: documents with nothing in them.
        let blank = KF8Fixture(documents: [KF8Fixture.Document(html: "<html><head><title>T</title></head><body></body></html>")])
        try reads(hybrid(blank), as: "Words of the old half.")

        // A declared length of zero, none, and one far past the limit, patched into the KF8 half's record 0.
        for declared in [0, 100_000_000] {
            var bytes = hybrid(sound)
            let database = try MOBIPalmDatabase(bytes: bytes)
            let boundary = try XCTUnwrap(try MOBIHeaders(record0: try database.record(0, "r0"), requiresMOBIHeader: true).kf8BoundaryRecord)
            MOBIFixture.put32(&bytes, MOBIFixture.recordOffsets(of: bytes)[boundary] + 4, declared)
            try reads(bytes, as: "Words of the old half.")
        }
    }

    func testAKF8BookThatIsNotAHybridStillSaysWhatIsWrong() throws {
        var unknownCompression = KF8Fixture(body: "<p>Words.</p>")
        unknownCompression.compression = 3
        XCTAssertThrowsError(try opened(unknownCompression.data())) { XCTAssertEqual($0 as? MOBIError, .unsupportedCompression) }
        let blank = KF8Fixture(documents: [KF8Fixture.Document(html: "<html><head><title>T</title></head><body></body></html>")])
        XCTAssertThrowsError(try opened(blank.data())) { XCTAssertTrue($0 is FileImportError, "\($0)") }
    }

    func testACancelOrProtectionIsNotAFailureOfTheHalf() throws {
        let bytes = hybrid(KF8Fixture(body: "<p>Words of the new half.</p>"))
        XCTAssertThrowsError(try MOBIBook(bytes: bytes, checkCancellation: { throw ImportCancelled() })) {
            XCTAssertEqual($0 as? ImportCancelled, ImportCancelled(), "a cancel read the MOBI 6 half instead")
        }
        var protected = KF8Fixture(body: "<p>Words.</p>")
        protected.encryption = 2
        XCTAssertThrowsError(try opened(hybrid(protected))) { XCTAssertEqual($0 as? MOBIError, .copyProtected) }
    }

    // MARK: - S2: words in SVG

    private static let svg = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"x\">\n"
        + "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"50\"><title>Chart title</title>"
        + "<desc>Chart description</desc><text x=\"1\" y=\"9\">Visible chart words</text></svg>"

    func testAnSVGFlowIsPutBackOnceAndItsWordsAreRead() throws {
        var fixture = KF8Fixture(
            body: "<p>Before.</p><img src=\"kindle:flow:0002?mime=image/svg+xml\"/><p>Middle.</p>"
                + "<img src=\"kindle:flow:0002?mime=image/svg+xml\"/><p>After.</p>")
        fixture.flows = ["p { margin: 0 }", Self.svg]
        let book = try opened(fixture.data())
        let html = book.sections[0].html
        XCTAssertEqual(html.components(separatedBy: "<text x=\"1\" y=\"9\">Visible chart words</text>").count - 1, 1, "put back once")
        XCTAssertEqual(html.components(separatedBy: "kindle:flow:0002").count - 1, 1, "the second naming of the flow stays a picture")
        XCTAssertFalse(html.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE svg"), "the flow's declaration comes along")
        XCTAssertTrue(html.contains("<desc>Chart description</desc>"))
        let chapter = try prepared(fixture).chapters[0].chapter.text
        XCTAssertTrue(chapter.contains("Visible chart words"), chapter)
    }

    func testAnSVGFlowPastTheLengthTheHeaderDeclaresIsStillRead() throws {
        // kindlegen's KF8 header declares the length of the markup only; its SVG flows follow in the same records.
        var fixture = KF8Fixture(body: "<p>Before.</p><img src=\"kindle:flow:0002?mime=image/svg+xml\"/><p>After.</p>")
        fixture.flows = ["p { margin: 0 }", Self.svg]
        fixture.declaresMarkupOnly = true
        for compression in [1, 2] {
            fixture.compression = compression
            let html = try opened(fixture.data()).sections[0].html
            XCTAssertTrue(html.contains("Visible chart words"), "compression \(compression): \(html)")
        }
        // The same book in a hybrid file.
        XCTAssertTrue(try opened(hybrid(fixture)).sections[0].html.contains("Visible chart words"))
        // A flow table that names more text than the records hold leaves those flows out and reads the book.
        var short = fixture
        short.flows = ["p { margin: 0 }"]
        var bytes = short.data()
        let offsets = MOBIFixture.recordOffsets(of: bytes)
        let flowRecord = (0..<4).reduce(0) { $0 << 8 | Int(bytes[offsets[0] + 192 + $1]) }
        MOBIFixture.put32(&bytes, offsets[flowRecord] + 12 + 8 + 4, 5_000)
        let book = try opened(bytes)
        XCTAssertTrue(book.sections[0].html.contains("Before."))
    }

    func testOnlyASmallSVGFlowThatIsOneIsPutBack() throws {
        var fixture = KF8Fixture(
            body: "<p>Words.</p><img src=\"kindle:flow:0001?mime=image/svg+xml\"/><img src=\"kindle:flow:0002?mime=image/png\"/>"
                + "<img src=\"kindle:flow:0009?mime=image/svg+xml\"/><img src=\"kindle:flow:0003?mime=image/svg+xml\"/>")
        // Flow 1 is a style sheet, not SVG; flow 2 is named as a png; flow 9 is no flow; flow 3 is too big.
        fixture.flows = ["p { margin: 0 }", Self.svg, "<svg>" + String(repeating: "x", count: 300_000) + "</svg>"]
        let html = try opened(fixture.data()).sections[0].html
        XCTAssertFalse(html.contains("Visible chart words"))
        XCTAssertFalse(html.contains("xxxxxxxxxx"))
        XCTAssertEqual(html.components(separatedBy: "<img src=").count - 1, 4)
    }

    // MARK: - S3: navigation lists calibre strips the prefix from

    func testNavigationListsAreNotReadAloudAndPageBreaksWithMoreTokensArePages() throws {
        let body = "<h1>Real heading</h1><p>Real words.</p>"
            + "<nav type=\"toc\" id=\"toc\"><ol><li><a href=\"#x\">Contents entry</a></li></ol></nav>"
            + "<nav type=\"page-list\"><ol><li><a href=\"#x\">Pages one two three</a></li></ol></nav>"
            + "<nav type=\"landmarks\"><ol><li><a href=\"#x\">Guide Begin Reading</a></li></ol></nav>"
            + "<p>More real words <span type=\"pagebreak bodymatter\" title=\"108\"></span>after the page.</p>"
        let chapter = try prepared(KF8Fixture(body: body)).chapters[0].chapter
        for unread in ["Contents entry", "Pages one", "Guide Begin"] {
            XCTAssertFalse(chapter.text.contains(unread), "\(unread) is read aloud")
        }
        XCTAssertEqual(chapter.pages.map(\.label), ["108"])
        XCTAssertEqual(chapter.headings.map(\.text), ["Real heading"])
    }

    /// An EPUB 3 navigation document in the spine, whose only headings are in its lists (so the duplicate-navigation
    /// rule cannot strip it by the headings outside): calibre writes its lists' `epub:type` as a bare `type`, and the
    /// book must read as the same book with the prefix, whose page list and landmarks are never read aloud.
    func testANavigationDocumentReadsAsItDoesWithTheEPUBTypePrefixCalibreStrips() throws {
        func book(typeAttribute: String) throws -> MOBIParser.PreparedBook {
            let navigation = "<nav \(typeAttribute)=\"toc\"><h1>Contents</h1><ol><li><a href=\"#x\">Entry one</a></li></ol></nav>"
                + "<nav \(typeAttribute)=\"page-list\"><h2>Pages</h2><ol><li><a href=\"#x\">Page label</a></li></ol></nav>"
                + "<nav \(typeAttribute)=\"landmarks\"><h2>Guide</h2><ol><li><a href=\"#x\">Begin Reading</a></li></ol></nav>"
            return try prepared(KF8Fixture(documents: [
                document(title: "Navigation", body: navigation),
                document(title: "Chapter", body: "<h1>Chapter One</h1><p>Real words.</p>"),
            ]))
        }
        let stripped = try book(typeAttribute: "type")
        let prefixed = try book(typeAttribute: "epub:type")
        XCTAssertEqual(words(stripped), words(prefixed))
        XCTAssertEqual(stripped.chapters.map(\.chapter.title), prefixed.chapters.map(\.chapter.title))
        XCTAssertEqual(stripped.chapters.flatMap { $0.chapter.headings.map(\.text) }, prefixed.chapters.flatMap { $0.chapter.headings.map(\.text) })
        for unread in ["Page label", "Begin Reading"] {
            XCTAssertFalse(words(stripped).joined(separator: " ").contains(unread), "\(unread) is read aloud")
        }
    }

    func testOnlyAWholeTypeAttributeOfThoseNamesIsPutBack() throws {
        let html = try opened(KF8Fixture(
            body: "<span data-type=\"pagebreak\">a</span><p xtype=\"toc\">b</p><ol type=\"1\"><li>c</li></ol>"
                + "<span\ttype='pagebreak'>d</span><span type=\"x pagebreak\">e</span><link type=\"text/css\"/>").data()).sections[0].html
        XCTAssertTrue(html.contains("<span data-type=\"pagebreak\">"), html)
        XCTAssertTrue(html.contains("<p xtype=\"toc\">"), html)
        XCTAssertTrue(html.contains("<ol type=\"1\">"), html)
        XCTAssertTrue(html.contains("<span\tepub:type='pagebreak'>"), html)
        XCTAssertTrue(html.contains("<span epub:type=\"x pagebreak\">"), html)
        XCTAssertTrue(html.contains("<link type=\"text/css\"/>"), html)
    }

    // MARK: - S4: the chapters calibre cuts

    /// Documents that share a title, as the pieces calibre cuts one document into do.
    private func pieces(_ bodies: [String], titles: [String]? = nil) throws -> KF8Fixture {
        KF8Fixture(documents: try bodies.enumerated().map { index, body in
            try document(title: titles?[index] ?? "Shared Title", body: body)
        })
    }

    /// The text of chapter `index` of `book`, or "" when it has fewer chapters: the count's own assertion reports that,
    /// where an index past the end would trap the test host.
    private func text(of book: MOBIParser.PreparedBook, _ index: Int) -> String {
        book.chapters.indices.contains(index) ? book.chapters[index].chapter.text : ""
    }

    /// The headings of chapter `index` of `book`, or none when it has fewer chapters (see `text(of:_:)`).
    private func headings(of book: MOBIParser.PreparedBook, _ index: Int) -> [String] {
        book.chapters.indices.contains(index) ? book.chapters[index].chapter.headings.map(\.text) : []
    }

    /// The chapters of `book` as a message: each one's title and the headings in it, so a failure shows what was found.
    private func chapters(of book: MOBIParser.PreparedBook) -> String {
        book.chapters.map { "\"\($0.chapter.title)\" \($0.chapter.headings.map(\.text))" }.joined(separator: "; ")
    }

    func testAPieceThatNothingNamesAndThatOpensWithNoHeadingContinuesTheChapterBefore() throws {
        let book = try prepared(pieces([
            "<h1>First</h1><p>Alpha one.</p>", "<p>Alpha two.</p>", "<h2>Second</h2><p>Beta.</p>", "<p>Beta two.</p>",
        ]))
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["First", "Second"], chapters(of: book))
        XCTAssertEqual(headings(of: book, 0), ["First"], "no heading is added for the piece: \(chapters(of: book))")
        XCTAssertTrue(text(of: book, 0).contains("Alpha one."))
        XCTAssertTrue(text(of: book, 0).contains("Alpha two."))
        XCTAssertTrue(text(of: book, 1).contains("Beta two."))
        XCTAssertEqual(words(book).joined(separator: " "), "First Alpha one. Alpha two. Second Beta. Beta two.")
    }

    func testAPieceIsNotAContinuationWhenItIsNamedOpensWithAHeadingOrHasAnotherTitle() throws {
        // Named by the contents, though its title repeats the piece before it.
        var named = try pieces(["<h1>First</h1><p>One.</p>", "<p>Two.</p>"])
        named.entries = [KF8Fixture.Entry(label: "First", document: 0), KF8Fixture.Entry(label: "Second part", document: 1)]
        let namedBook = try prepared(named)
        XCTAssertEqual(namedBook.chapters.count, 2, "named: \(chapters(of: namedBook))")
        // Opens with a heading, though its title repeats the piece before it.
        let headed = try prepared(pieces(["<h1>First</h1><p>One.</p>", "<h3>Heading</h3><p>Two.</p>"]))
        XCTAssertEqual(headed.chapters.count, 2, "opens with a heading: \(chapters(of: headed))")
        // Another title, which no neighbour shares.
        let other = try prepared(pieces(["<h1>First</h1><p>One.</p>", "<p>Two.</p>"], titles: ["One", "Two"]))
        XCTAssertEqual(other.chapters.count, 2, "another title: \(chapters(of: other))")
        // No title at all in either.
        let untitled = KF8Fixture(documents: [
            KF8Fixture.Document(html: "<html><head></head><body><h1>First</h1><p>One.</p></body></html>", cutting: ["<h1>First</h1><p>One.</p>"]),
            KF8Fixture.Document(html: "<html><head></head><body><p>Two.</p></body></html>", cutting: ["<p>Two.</p>"]),
        ])
        let untitledBook = try prepared(untitled)
        XCTAssertEqual(untitledBook.chapters.count, 2, "no title: \(chapters(of: untitledBook))")
        // The book's first piece has no chapter before it to go on with, with a heading or not.
        let headless = try prepared(pieces(["<p>One.</p>", "<p>Two.</p>"]))
        XCTAssertEqual(headless.chapters.count, 1, "the second piece shares the first's title, so it goes on: \(chapters(of: headless))")
        XCTAssertEqual(words(headless), ["One.", "Two."])
    }

    /// The first piece with words never continues, even when its title is the next piece's heading: a cover of
    /// pictures before it is no chapter to go on with.
    func testTheFirstPieceWithWordsNeverContinues() throws {
        let fixture = KF8Fixture(documents: try [
            ("Cover", "<img alt=\"\"/>"), ("Preface", "<p>Preface words.</p>"), ("Preface", "<h1>Preface</h1><p>Body words.</p>"),
        ].map { try document(title: $0.0, body: $0.1) })
        let book = try prepared(fixture)
        // Were the piece taken to go on with the cover, the first chapter would be titled "Cover".
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Preface", "Preface"], chapters(of: book))
        XCTAssertTrue(text(of: book, 0).contains("Preface words."), chapters(of: book))
        XCTAssertFalse(text(of: book, 0).contains("Body words."), chapters(of: book))
    }

    /// A piece that opens with no heading and that nothing names goes on with the chapter before it when its
    /// <title> is the heading the next piece opens with: calibre gave the first piece of a file the file's
    /// title, but the piece holds the end of the chapter before. (The Pride and Prejudice case: the words that
    /// end chapter X, titled "CHAPTER XI", before the piece that opens with the heading CHAPTER XI.)
    func testAPieceTitledForTheNextPiecesHeadingGoesOnWithTheChapterBefore() throws {
        let book = try prepared(pieces([
            "<h1>CHAPTER X</h1><p>Words of ten.</p>",
            "<p>The words that end chapter ten.</p>",
            "<h1>CHAPTER XI</h1><p>Words of eleven.</p>",
        ], titles: ["CHAPTER X", "CHAPTER XI", "CHAPTER XI"]))
        XCTAssertEqual(book.chapters.count, 2, chapters(of: book))
        XCTAssertEqual(book.chapters.flatMap { $0.chapter.headings.map(\.text) }, ["CHAPTER X", "CHAPTER XI"], "exactly two headings: \(chapters(of: book))")
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["CHAPTER X", "CHAPTER XI"], chapters(of: book))
        XCTAssertTrue(text(of: book, 0).contains("The words that end chapter ten."), "read under CHAPTER X: \(chapters(of: book))")
        XCTAssertFalse(text(of: book, 1).contains("The words that end chapter ten."), chapters(of: book))
    }

    /// The heading is compared with the title as titles are compared: character references read, soft hyphens
    /// left out, white space collapsed, tags inside the heading adding no words, case kept; and the heading must
    /// be what the next piece opens with.
    func testTheNextPiecesHeadingMustMatchTheTitleExactlyAndBeWhatThePieceOpensWith() throws {
        /// Whether the headless middle piece, titled `title`, went on with the first chapter in a book whose
        /// third piece begins with `third` (and has the title too); and what the book came to.
        func middleGoesOn(title: String, third: String) throws -> (goesOn: Bool, message: String) {
            let book = try prepared(pieces([
                "<h1>CHAPTER X</h1><p>Words of ten.</p>", "<p>The words that end chapter ten.</p>",
                third + "<p>Words of eleven.</p>",
            ], titles: ["CHAPTER X", title, title]))
            return (text(of: book, 0).contains("The words that end chapter ten."), chapters(of: book))
        }
        // The same words after reading: references, tags, a soft hyphen, a line break and spaces, a comment before it.
        for (title, third) in [
            ("Tom & Jerry", "<h1>Tom <i>&amp;</i>\n  Jerry</h1>"),
            ("CHAPTER XI", "<h1>CHAP&shy;TER XI</h1>"),
            ("CHAPTER XI", "<h1>CHAP\u{AD}TER XI</h1>"),
            ("CHAPTER XI", "<!-- a note --><div><h2>CHAPTER   XI</h2></div>"),
        ] {
            let found = try middleGoesOn(title: title, third: third)
            XCTAssertTrue(found.goesOn, "\(title) / \(third) should go on with the chapter before: \(found.message)")
        }
        // Not the same words, or not what the piece opens with: the piece keeps its own chapter.
        for (title, third) in [
            ("Chapter xi", "<h1>CHAPTER XI</h1>"),
            ("CHAPTER XI", "<h1>CHAPTER XII</h1>"),
            ("CHAPTER XI", "<p>Some words first.</p><h1>CHAPTER XI</h1>"),
            ("CHAPTER XI", "<div>CHAPTER XI</div>"),
        ] {
            let found = try middleGoesOn(title: title, third: third)
            XCTAssertFalse(found.goesOn, "\(title) / \(third) should keep its own chapter: \(found.message)")
        }
    }

    /// A headless piece whose title is no neighbour's keeps its own chapter, headed by its title (Project
    /// Gutenberg's "A Modest Proposal": the essay is a document with no heading tag, between the header page and
    /// the license).
    func testAHeadlessPieceTitledLikeNoNeighbourKeepsItsOwnChapterAndHeading() throws {
        let book = try prepared(pieces([
            "<h2>The Project Gutenberg eBook</h2><p>Header words.</p>",
            "<p>The essay words.</p>",
            "<h2>THE FULL LICENSE</h2><p>License words.</p>",
        ], titles: ["The Project Gutenberg eBook", "A Modest Proposal", "THE FULL LICENSE"]))
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["The Project Gutenberg eBook", "A Modest Proposal", "THE FULL LICENSE"], chapters(of: book))
        XCTAssertEqual(headings(of: book, 1), ["A Modest Proposal"], chapters(of: book))
        XCTAssertTrue(text(of: book, 1).contains("The essay words."))
        XCTAssertFalse(text(of: book, 0).contains("The essay words."))
    }

    /// Project Gutenberg's A Modest Proposal (ebook 1080) as calibre made it: the header page, which holds the book's
    /// title page too, in a `<header>`; the essay, a document with no heading, whose `<title>` is the same; and the
    /// license, cut in two inside one `<footer>` (the license's opening words, then its heading). The essay was read
    /// in the header's chapter, and the license's opening words at the end of the essay, so there were two chapters
    /// where the EPUB has three.
    func testAnEssayAfterAWholeHeaderIsItsOwnChapterAndALicenseKeepsItsOpeningWords() throws {
        var fixture = try pieces([
            "<header id=\"pg-header\"><h2>The Project Gutenberg eBook of A Modest Proposal</h2><p>Header words.</p></header>",
            "<div class=\"chapter\" id=\"calibre_pb_0\"><p>The essay words.</p></div>",
            "<footer id=\"pg-footer\"><div>The end marker of the eBook</div><p>The opening words of the license.</p></footer>",
            "<footer id=\"pg-footer\"><h2>THE FULL LICENSE</h2><p>The rest of the license.</p></footer>",
        ], titles: ["A Modest Proposal", "A Modest Proposal", "THE FULL LICENSE", "THE FULL LICENSE"])
        fixture.entries = [KF8Fixture.Entry(label: "THE FULL LICENSE", document: 3)]
        let book = try prepared(fixture)
        let found = chapters(of: book)
        XCTAssertEqual(
            book.chapters.map(\.chapter.title),
            ["The Project Gutenberg eBook of A Modest Proposal", "A Modest Proposal", "THE FULL LICENSE"], found)
        XCTAssertEqual(headings(of: book, 1), ["A Modest Proposal"], "the essay is headed by its title: \(found)")
        XCTAssertFalse(text(of: book, 0).contains("The essay words."), "the essay is read in the header's chapter: \(found)")
        XCTAssertTrue(text(of: book, 1).contains("The essay words."), found)
        XCTAssertFalse(text(of: book, 1).contains("opening words of the license"), "the license's opening is read at the essay's end: \(found)")
        // The license's chapter begins with its opening words and goes on to its heading and the rest.
        let license = text(of: book, 2)
        let order = ["The end marker of the eBook", "opening words of the license", "THE FULL LICENSE", "The rest of the license."]
        let places = order.map { license.range(of: $0)?.lowerBound }
        XCTAssertFalse(places.contains { $0 == nil }, "the license's chapter lacks a part: \(found)")
        XCTAssertEqual(places.compactMap { $0 }, places.compactMap { $0 }.sorted(), "the license's parts are out of order: \(license)")
        XCTAssertEqual(
            words(book).joined(separator: " "),
            "The Project Gutenberg eBook of A Modest Proposal Header words. The essay words. The end marker of the eBook "
                + "The opening words of the license. THE FULL LICENSE The rest of the license.")
    }

    /// What the container rules leave as it was: the second half of a section calibre opened again (in a document of
    /// one section, and of two cut inside the second), a back page after a footer, and a headless piece before a
    /// heading in another container are all still read in the chapter before; a plain piece after a section is its own.
    func testPiecesInTheSameSectionOrAfterAFooterOrBeforeAHeadingInAnotherSectionStillGoOn() throws {
        // A long chapter cut in two inside one `<section>`: the second half goes on.
        let halves = try prepared(pieces([
            "<section id=\"c1\"><h1>Chapter</h1><p>One.</p></section>", "<section id=\"c1\"><p>Two.</p></section>",
        ]))
        XCTAssertEqual(halves.chapters.count, 1, "the two halves of one section: \(chapters(of: halves))")
        // A document of two sections cut inside the second, which the cut opens again: the first piece opens in
        // the first section, the second in the second, and the second goes on with the chapter before, as the
        // EPUB reader reads the document whole (the outside review's case).
        let cutInTheSecond = try prepared(pieces([
            "<section id=\"c1\"><h1>One</h1><p>First.</p></section><section id=\"c2\"><h1>Two</h1><p>First half.</p></section>",
            "<section id=\"c2\"><p>Second half.</p></section>",
        ]))
        XCTAssertEqual(cutInTheSecond.chapters.count, 1, "a cut inside the second of two sections: \(chapters(of: cutInTheSecond))")
        XCTAssertTrue(text(of: cutInTheSecond, 0).contains("Second half."), chapters(of: cutInTheSecond))
        // The same, but the piece after a section opens in a plain element: the essay's shape, its own chapter.
        let afterASection = try prepared(pieces([
            "<section id=\"c1\"><h1>Chapter</h1><p>One.</p></section>", "<div><p>Two.</p></div>",
        ]))
        XCTAssertEqual(afterASection.chapters.count, 2, "a plain piece after a section: \(chapters(of: afterASection))")
        // A back page after a footer goes on with it, as Project Gutenberg's does after its license.
        let back = try prepared(pieces([
            "<h1>Chapter</h1><p>One.</p>", "<footer id=\"pg-footer\"><h2>The end</h2><p>Words.</p></footer>", "<div><p>back</p></div>",
        ], titles: ["Chapter", "The end", "The end"]))
        XCTAssertEqual(back.chapters.map(\.chapter.title), ["Chapter", "The end"], "a back page after a footer: \(chapters(of: back))")
        XCTAssertTrue(text(of: back, 1).contains("back"), chapters(of: back))
        // The end of a chapter, in a section of its own, before the next chapter's heading in another: it goes on
        // with the chapter before it, as the end of a chapter does.
        let tail = try prepared(pieces([
            "<h1>CHAPTER X</h1><p>Words of ten.</p>", "<section id=\"a\"><p>The end of ten.</p></section>",
            "<section id=\"b\"><h1>CHAPTER XI</h1><p>Words of eleven.</p></section>",
        ], titles: ["CHAPTER X", "CHAPTER XI", "CHAPTER XI"]))
        XCTAssertEqual(tail.chapters.count, 2, chapters(of: tail))
        XCTAssertTrue(text(of: tail, 0).contains("The end of ten."), chapters(of: tail))
        XCTAssertFalse(text(of: tail, 1).contains("The end of ten."), chapters(of: tail))
        // A section with no id names nothing: the same shape as the essay, but nothing says the pieces are not one.
        let anonymous = try prepared(pieces(["<header><h1>Chapter</h1><p>One.</p></header>", "<p>Two.</p>"]))
        XCTAssertEqual(anonymous.chapters.count, 1, chapters(of: anonymous))
    }

    /// The last document, with no heading and a title of its own, keeps its chapter, whether or not the guide
    /// names it (the review's toc-epilogue book: the guide names the epilogue). The guide does not decide it.
    func testAHeadlessLastPieceTheGuideNamesKeepsItsChapter() throws {
        for guided in [false, true] {
            var fixture = try pieces([
                "<h1>Heading 1</h1><p>First words.</p>", "<h1>Heading 2</h1><p>Second words.</p>", "<p>The epilogue words.</p>",
            ], titles: ["Heading 1", "Heading 2", "Epilogue"])
            fixture.entries = [KF8Fixture.Entry(label: "Heading 1", document: 0), KF8Fixture.Entry(label: "Heading 2", document: 1)]
            if guided { fixture.guide = [(type: "toc", document: 2)] }
            let book = try prepared(fixture)
            XCTAssertEqual(book.chapters.map(\.chapter.title), ["Heading 1", "Heading 2", "Epilogue"], "guide \(guided): \(chapters(of: book))")
            XCTAssertEqual(headings(of: book, 2), ["Epilogue"], "guide \(guided): \(chapters(of: book))")
        }
    }

    func testACutInTheMiddleOfAParagraphJoinsWithNoBreakAndOtherCutsBreakTheParagraph() throws {
        // calibre's cut leaves a space ending the first half and its marker opening the second.
        let mid = try prepared(pieces([
            "<h1>Chapter</h1><p class=\"c\">First half </p>",
            "<p class=\"c\"><span id=\"calibre_pb_3\">second half</span> goes on.</p>",
        ]))
        XCTAssertEqual(mid.chapters.count, 1)
        XCTAssertTrue(text(of: mid, 0).contains("First half second half goes on."), text(of: mid, 0))
        // A cut at a paragraph's end is a paragraph break.
        let between = try prepared(pieces([
            "<h1>Chapter</h1><p>First paragraph.</p>", "<p id=\"calibre_pb_0\">Second paragraph.</p>",
        ]))
        XCTAssertEqual(between.chapters.count, 1)
        XCTAssertFalse(text(of: between, 0).contains("First paragraph. Second paragraph."))
        XCTAssertTrue(text(of: between, 0).contains("Second paragraph."))
        // A space ending a paragraph, with no marker beginning the next: still a break.
        let spaced = try prepared(pieces(["<h1>Chapter</h1><p>First paragraph. </p>", "<p>Second paragraph.</p>"]))
        XCTAssertFalse(text(of: spaced, 0).contains("First paragraph. Second paragraph."))
    }

    func testAnUntitledChapterIsNumberedByItsDocumentAndUnknownIsNoHeading() throws {
        // The first document is a cover with no words, so the second is the book's first with words (it stands
        // alone, and is not a continuation of the cover); the third opens with a heading.
        let bodies = ["<img alt=\"\"/>", "<p>Words one.</p>", "<h2>Heading two</h2><p>Words two.</p>"]
        let fixture = KF8Fixture(documents: try bodies.enumerated().map { index, body in
            try document(title: ["Cover", "Unknown", "Fixture KF8 Book"][index], body: body)
        })
        let book = try prepared(fixture)
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Chapter 2", "Heading two"])
        XCTAssertEqual(headings(of: book, 0), ["Chapter 2"], "\"Unknown\" is not made a heading")
    }

    // MARK: - S5: a contents or guide that does not read

    func testADamagedContentsOrGuideIsReadWithout() throws {
        var fixture = KF8Fixture(documents: [
            try document(body: "<h1>Chapter</h1><p>Real words.</p>"),
            try document(title: "Table of Contents", body: Self.generatedPage),
        ])
        fixture.entries = [KF8Fixture.Entry(label: "Chapter", document: 0)]
        fixture.guide = [(type: "toc", document: 1)]
        let bytes = fixture.data()
        let database = try MOBIPalmDatabase(bytes: bytes)
        let headers = try MOBIHeaders(record0: try database.record(0, "r0"), requiresMOBIHeader: true)
        let offsets = MOBIFixture.recordOffsets(of: bytes)

        var noContents = bytes
        noContents[offsets[try XCTUnwrap(headers.indexRecord)]] = 0x58
        let withoutContents = try opened(noContents)
        XCTAssertEqual(withoutContents.sections.count, 2, "the book is read without its contents")
        XCTAssertNil(withoutContents.sections[0].title)

        var noGuide = bytes
        noGuide[offsets[try XCTUnwrap(headers.guideIndexRecord)]] = 0x58
        XCTAssertEqual(try opened(noGuide).sections.count, 2, "the book is read without its guide, and keeps its last page")
    }

    // MARK: - Minor

    func testEverySpellingOfASoftHyphenIsLeftOut() {
        let spellings = ["\u{AD}", "&shy;", "&#173;", "&#173", "&#xAD;", "&#xad;", "&#xAd;", "&#x00AD;", "&#00173;", "&#X0ad;"]
        for spelling in spellings {
            XCTAssertEqual(ParserUtilities.removingSoftHyphens("pro\(spelling)duct"), "product", spelling)
        }
        // The spellings the parser decodes that the first list lacked (the outside review's): &shy without its
        // semicolon where no letter or digit follows, and a reference with more than twelve leading zeros.
        XCTAssertEqual(ParserUtilities.removingSoftHyphens("hy&shy<i>phen</i> pro&shy duct end&shy"), "hy<i>phen</i> pro duct end")
        XCTAssertEqual(ParserUtilities.removingSoftHyphens("pro&#0000000000173;duct pro&#x0000000000000AD;duct"), "product product")
        // Spelled as no entity is: &SHY; and &Shy; stay (the parser keeps them as text), as does &shy before a
        // letter or digit, and a number past the soft hyphen's however many zeros come first.
        XCTAssertEqual(ParserUtilities.removingSoftHyphens("&SHY; &Shy; &shy1 &shyx &#0000000000174; &#99999999999999999999;"),
                       "&SHY; &Shy; &shy1 &shyx &#0000000000174; &#99999999999999999999;")
        // What is not one stays.
        XCTAssertEqual(ParserUtilities.removingSoftHyphens("&shyx; &#174; &#xAE; &#17 &amp; &#; \u{AE}"), "&shyx; &#174; &#xAE; &#17 &amp; &#; \u{AE}")
        XCTAssertEqual(ParserUtilities.removingSoftHyphens("plain"), "plain")
        XCTAssertEqual(ParserUtilities.removingSoftHyphens(""), "")
    }

    func testALabelLosesItsSoftHyphensToo() throws {
        var fixture = KF8Fixture(documents: [try document(body: "<h1>Chapter</h1><p>One.</p><h2>Two</h2><p>Words.</p>")])
        fixture.entries = [
            KF8Fixture.Entry(label: "Chap\u{AD}ter &#xAD;one", document: 0),
        ]
        XCTAssertEqual(try opened(fixture.data()).sections[0].title, "Chapter one")
    }

    func testAHybridIsNamedFromTheHalfItIsReadFrom() throws {
        var kf8 = KF8Fixture(body: "<p>Words.</p>")
        kf8.title = "Title of the KF8 half"
        var six = MOBIFixture()
        six.title = "Title of the MOBI 6 half"
        let bytes = kf8.hybrid(mobi6: six)
        XCTAssertEqual(try opened(bytes).metadata.title, "Title of the KF8 half")
        XCTAssertEqual(try MOBIBook.metadata(in: bytes).title, "Title of the KF8 half", "the import names the book as the reading does")
        XCTAssertEqual(try opened(bytes, hybrid: .mobi6).metadata.title, "Title of the MOBI 6 half")
        XCTAssertEqual(try MOBIBook.metadata(in: bytes, hybrid: .mobi6).title, "Title of the MOBI 6 half")
    }

    // MARK: - S7: the cap is on the text, not on the file

    func testAKindleFileOfPicturesIsReadByItsTextAndNotRefusedForItsSize() throws {
        // A kindlegen hybrid of a picture book is over 100 MB for a book of a megabyte of words. Here: 70 MB of
        // picture records after a small book, past the 64 MB that DocumentByteLimit holds a document's text to.
        var records = KF8Fixture(body: "<h1>Chapter</h1><p>Words of the picture book.</p>").records()
        records.append([UInt8](repeating: 0x5A, count: 70_000_000))
        let bytes = MOBIFixture.database(named: "Pictures", type: "BOOK", creator: "MOBI", records: records)
        XCTAssertGreaterThan(Int64(bytes.count), DocumentByteLimit.standard)
        let url = try writeMOBI(bytes, named: "pictures.azw3")
        let book = try MOBIParser.prepareBook(url: url)
        XCTAssertTrue(text(of: book, 0).contains("Words of the picture book."))
        XCTAssertEqual(try MOBIParser.readMetadata(url: url).title, "Fixture KF8 Book")
    }

    func testAKindleFileOfHalfAGigabyteIsRefusedBeforeItIsMapped() throws {
        // A sparse file: its size is 600 MB and it takes no room, so nothing is allocated or read.
        let url = try makeSandboxDirectory("HugeKindle").appendingPathComponent("huge.azw3")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data([0])))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 600 * 1_024 * 1_024)
        try handle.close()
        XCTAssertThrowsError(try MOBIParser.prepareBook(url: url)) {
            XCTAssertEqual($0 as? DocumentTooLargeError, DocumentTooLargeError(limit: MOBIParser.maximumFileBytes))
        }
        // The text cap stands: a book that declares more text than the limit is refused all the same.
        var big = KF8Fixture(body: "<p>Words.</p>")
        big.extraEXTH = [:]
        var bytes = big.data()
        MOBIFixture.put32(&bytes, MOBIFixture.recordOffsets(of: bytes)[0] + 4, Int(DocumentByteLimit.standard) + 1)
        XCTAssertThrowsError(try MOBIBook(bytes: bytes)) { XCTAssertTrue($0 is DocumentTooLargeError, "\($0)") }
    }

    // MARK: - Mutations the review found no test for

    func testAPlaceReachedByAWalkThroughManyPiecesIsCountedAndRefused() {
        // 1,500 fragments in order, then 5,000 that each go just inside the last of those, before
        // the one-byte tail: none goes to the front (so the shift is cheap), but each walk passes
        // all the pieces before it.
        let ins = 1_500
        let extra = 5_000
        let text = [UInt8](repeating: 0x61, count: 2 + (ins + extra) * 2)
        var fragments: [KF8Layout.Fragment] = []
        var length = 2
        for index in 0..<ins {
            fragments.append(KF8Layout.Fragment(insertOffset: 1 + 2 * index, identifier: index, range: (2 + 2 * index)..<(4 + 2 * index)))
            length += 2
        }
        for index in 0..<extra {
            let start = 2 + 2 * (ins + index)
            fragments.append(KF8Layout.Fragment(insertOffset: length - 2, identifier: ins + index, range: start..<(start + 2)))
            length += 2
        }
        let layout = KF8Layout(parts: [KF8Layout.Part(skeleton: 0..<2, fragments: fragments)])
        let started = Date()
        XCTAssertThrowsError(try layout.markup(of: layout.parts[0], in: text, anchors: [])) {
            guard case .damaged? = $0 as? MOBIError else { return XCTFail("\($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testTheFirstFragmentToHaveANumberIsTheOneItNames() {
        let layout = KF8Layout(parts: [
            KF8Layout.Part(skeleton: 0..<1, fragments: [
                KF8Layout.Fragment(insertOffset: 0, identifier: 7, range: 1..<2),
                KF8Layout.Fragment(insertOffset: 0, identifier: 7, range: 2..<3),
            ]),
            KF8Layout.Part(skeleton: 3..<4, fragments: [KF8Layout.Fragment(insertOffset: 3, identifier: 7, range: 4..<5)]),
        ])
        XCTAssertEqual(layout.locations[7]?.part, 0)
        XCTAssertEqual(layout.locations[7]?.fragment, 0)
    }

    func testADepthPastSixIsLevelSix() throws {
        var fixture = KF8Fixture(documents: [try document(body: "<h1>Chapter</h1><p>One.</p><h6>Deep</h6><p>Words.</p>")])
        fixture.entries = [
            KF8Fixture.Entry(label: "Chapter", document: 0),
            KF8Fixture.Entry(label: "Deep one", document: 0, offset: 24, depth: 9),
        ]
        let annotation = try XCTUnwrap(try opened(fixture.data()).sections[0].headingTargets.values.first)
        XCTAssertEqual(annotation.level, 6)
        XCTAssertEqual(annotation.text, "Deep one")
    }

    func testAnIndexOfMoreRowsThanAnyBookHasIsRefused() throws {
        let rows = (0...100_000).map { _ in KF8Fixture.Row(name: [0x30], values: [1: [0]]) }
        let records = KF8Fixture.index(tags: [KF8Fixture.Tag(number: 1, valuesPerCount: 1, mask: 1)], rows: rows, strings: [])
        let file = MOBIFixture.database(named: "Many_Rows", type: "BOOK", creator: "MOBI", records: [[0]] + records)
        let started = Date()
        XCTAssertThrowsError(try MOBIIndex.table(startingAt: 1, in: try MOBIPalmDatabase(bytes: file))) {
            guard case .damaged(let detail)? = $0 as? MOBIError else { return XCTFail("\($0)") }
            XCTAssertTrue(detail.contains("too many entries"), detail)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }

    func testAKF8FileThatNamesABoundaryIsReadAsItself() throws {
        // A book that is KF8 throughout, whose EXTH 121 names a record that holds another KF8 book: it is not
        // the first half of a hybrid, and is read as the book it opens as.
        let other = KF8Fixture(body: "<p>Words of the other book.</p>")
        var first = KF8Fixture(body: "<p>Words of the first book.</p>")
        let firstRecords = first.records()
        first.extraEXTH[121] = MOBIFixture.be32(firstRecords.count)
        let records = first.records() + other.records()
        let bytes = MOBIFixture.database(named: "Two_Books", type: "BOOK", creator: "MOBI", records: records)
        let book = try opened(bytes)
        XCTAssertTrue(book.sections[0].html.contains("Words of the first book."))
    }

    func testATitleIsFoundWhateverElementsComeBeforeIt() throws {
        let html = "<html><head><tt>x</tt><template>y</template><title>The Real Title</title></head><body><p>Words.</p></body></html>"
        let fixture = KF8Fixture(documents: [KF8Fixture.Document(html: html, cutting: ["<p>Words.</p>"])])
        XCTAssertEqual(try opened(fixture.data()).sections[0].title, "The Real Title")
    }
}
