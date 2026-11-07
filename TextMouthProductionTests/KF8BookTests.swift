import XCTest
@testable import TextMouth

/// Kindle KF8 books built in code (`KF8Fixture`), to prove each part of the
/// KF8 reader against the format's specification and not only against the
/// few real files: the documents joined from skeletons and fragments, the
/// contents' titles and headings, the guide, the page breaks, the hybrid
/// file's two halves, the refusals, and the way a cancel is heard.
final class KF8BookTests: XCTestCase {

    // MARK: - Helpers

    /// The book `bytes` hold, opened in memory.
    private func opened(_ bytes: [UInt8], hybrid: MOBIBook.HybridChoice = .kf8) throws -> MOBIBook {
        try MOBIBook(bytes: bytes, hybrid: hybrid)
    }

    /// `fixture` read as a file named `book.azw3`, the way an import reads it.
    private func prepared(_ fixture: KF8Fixture) throws -> MOBIParser.PreparedBook {
        try MOBIParser.prepareBook(url: writeMOBI(fixture.data(), named: "book.azw3"))
    }

    /// The anchor id of the byte `offset` of the text.
    private func anchorID(_ offset: Int) -> String { MOBIMarkup.anchorID(forOffset: offset) }

    /// A body of three paragraphs, the second and third cut out as fragments.
    private func threeParagraphs() -> KF8Fixture {
        KF8Fixture(body: "<p>One of three.</p><p>Two of three.</p><p>Three of three.</p>",
                   cutting: ["<p>Two of three.</p>", "<p>Three of three.</p>"])
    }

    // MARK: - The documents

    func testADocumentIsJoinedFromItsSkeletonAndItsFragments() throws {
        let fixture = threeParagraphs()
        let book = try opened(fixture.data())
        XCTAssertEqual(book.sections.count, 1)
        XCTAssertEqual(book.sections[0].html, fixture.documents[0].html)
        XCTAssertTrue(book.includesPages)
    }

    func testEveryKindOfCutJoinsBackToTheDocument() throws {
        // Cuts at the start, in the middle, and at the end of a body; a cut that
        // is the whole body; one in front of the other; no cut at all.
        let body = "<h1>Head</h1><p>Alpha.</p><p>Beta.</p><p>Gamma.</p>"
        for cuts in [[], ["<h1>Head</h1>"], ["<p>Beta.</p>"], ["<p>Gamma.</p>"], [body],
                     ["<h1>Head</h1>", "<p>Alpha.</p>", "<p>Beta.</p>", "<p>Gamma.</p>"], ["<p>Alpha.</p>", "<p>Gamma.</p>"]] {
            let fixture = KF8Fixture(body: body, cutting: cuts)
            XCTAssertEqual(try opened(fixture.data()).sections.map(\.html), [fixture.documents[0].html], "cuts \(cuts)")
        }
    }

    func testEachDocumentIsASectionInTheOrderOfTheBook() throws {
        let fixture = KF8Fixture(documents: (1...4).map { number in
            KF8Fixture.Document(
                html: "<html><head><title>T</title></head><body><h2>Part \(number)</h2><p>Words of part \(number).</p></body></html>",
                cutting: number % 2 == 0 ? ["<p>Words of part \(number).</p>"] : [])
        })
        let book = try opened(fixture.data())
        XCTAssertEqual(book.sections.map(\.html), fixture.documents.map(\.html))
    }

    func testTheMarkupIsReadWhateverTheCompressionAndRecordSize() throws {
        var fixture = KF8Fixture(documents: [KF8Fixture.Document(
            html: "<html><head><title>T</title></head><body>"
                + (0..<80).map { "<p>Crossing \($0): the ferry leaves the Tallow Quay at seven.</p>" }.joined() + "</body></html>",
            cutting: ["<p>Crossing 30: the ferry leaves the Tallow Quay at seven.</p>", "<p>Crossing 31: the ferry leaves the Tallow Quay at seven.</p>"])])
        for (compression, recordSize) in [(1, 4096), (2, 4096), (2, 900), (1, 77)] {
            fixture.compression = compression
            fixture.recordSize = recordSize
            XCTAssertEqual(try opened(fixture.data()).sections[0].html, fixture.documents[0].html, "\(compression) \(recordSize)")
        }
    }

    // MARK: - The contents

    /// Two documents, the first cut so that its second heading is in a
    /// fragment of its own, with a contents of three entries.
    private func contentsBook() -> KF8Fixture {
        let first = "<html><head><title>One</title></head><body><h1>Alpha</h1><p>First words.</p><h2 id=\"b\">Beta</h2><p>Second words.</p></body></html>"
        let second = "<html><head><title>Two</title></head><body><h1>Gamma</h1><p>Third words.</p></body></html>"
        var fixture = KF8Fixture(documents: [
            KF8Fixture.Document(html: first, cutting: ["<h1>Alpha</h1><p>First words.</p>", "<h2 id=\"b\">Beta</h2><p>Second words.</p>"]),
            KF8Fixture.Document(html: second, cutting: ["<h1>Gamma</h1><p>Third words.</p>"]),
        ])
        fixture.entries = [
            KF8Fixture.Entry(label: "Part A", document: 0, fragment: 0, offset: 0, depth: 0),
            KF8Fixture.Entry(label: "Section Beta", document: 0, fragment: 1, offset: 0, depth: 1),
            KF8Fixture.Entry(label: "Part G", document: 1, fragment: 0, offset: 0, depth: 0),
        ]
        return fixture
    }

    func testAnEntryNamingAWholeDocumentTitlesItAndOneNamingAPlaceInsideItIsAHeading() throws {
        let book = try opened(contentsBook().data())
        XCTAssertEqual(book.sections.map(\.title), ["Part A", "Part G"])
        // The second entry names the start of the second fragment of the first document.
        let targets = book.sections[0].headingTargets
        XCTAssertEqual(targets.count, 1)
        let (id, annotation) = try XCTUnwrap(targets.first)
        XCTAssertEqual(annotation.text, "Section Beta")
        XCTAssertEqual(annotation.level, 2, "depth 1 is level 2")
        // The anchor is written in front of the heading it names.
        XCTAssertTrue(book.sections[0].html.contains("<a id=\"\(id)\"></a><h2 id=\"b\">"), book.sections[0].html)
    }

    func testTheChaptersAndHeadingsOfAContentsBookComeThroughTheConverter() throws {
        let book = try prepared(contentsBook())
        // A document that opens with a heading of its own is titled by it, as an EPUB's is.
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Alpha", "Gamma"])
        let first = book.chapters[0].chapter
        XCTAssertEqual(first.headings.map(\.text), ["Alpha", "Beta"])
        XCTAssertTrue(first.text.contains("First words."))
        XCTAssertTrue(first.text.contains("Second words."))
        XCTAssertTrue(book.chapters[1].chapter.text.contains("Third words."))
    }

    func testADocumentThatOpensWithNoHeadingTakesTheContentsLabelAsItsTitle() throws {
        var fixture = KF8Fixture(documents: [
            KF8Fixture.Document(
                html: "<html><head><title>Fixture KF8 Book</title></head><body><p>Words with no heading.</p></body></html>",
                cutting: ["<p>Words with no heading.</p>"]),
        ])
        fixture.entries = [KF8Fixture.Entry(label: "The Label", document: 0)]
        let chapter = try prepared(fixture).chapters[0].chapter
        XCTAssertEqual(chapter.title, "The Label")
        XCTAssertEqual(chapter.headings.map(\.text), ["The Label"])
    }

    func testAPlaceInTheMiddleOfATagTakesTheTagsStart() throws {
        var fixture = contentsBook()
        // Offset 3 of the second fragment of the first document is inside "<h2 id=...".
        fixture.entries[1].offset = 3
        let book = try opened(fixture.data())
        let id = try XCTUnwrap(book.sections[0].headingTargets.keys.first)
        XCTAssertTrue(book.sections[0].html.contains("<a id=\"\(id)\"></a><h2 id=\"b\">"), book.sections[0].html)
    }

    func testAnEntryPastItsFragmentOrWithoutALabelOrToNoFragmentIsPassedOver() throws {
        var fixture = contentsBook()
        fixture.entries += [
            KF8Fixture.Entry(label: "Far past", document: 0, fragment: 1, offset: 5000, depth: 1),
            KF8Fixture.Entry(label: "", document: 0, fragment: 1, offset: 2, depth: 1),
        ]
        let book = try opened(fixture.data())
        XCTAssertEqual(book.sections[0].headingTargets.values.map(\.text), ["Section Beta"])
        // An entry for a fragment number no fragment has.
        var missing = contentsBook()
        missing.entries.append(KF8Fixture.Entry(label: "Nowhere", document: 1, fragment: 5, offset: 0))
        let bytes = missing.data()
        // fid(document: 1, fragment: 5) is a number past the fragments, which names nothing.
        XCTAssertEqual(try opened(bytes).sections.count, 2)
    }

    func testALabelIsReadWithItsCharacterReferencesAndSingleSpaces() throws {
        var fixture = contentsBook()
        fixture.entries[0].label = "  Part &lt;A&gt; "
        fixture.entries[1].label = "Tom &amp;  Jerry\n"
        fixture.entries.append(KF8Fixture.Entry(label: " \n ", document: 0, fragment: 1, offset: 2, depth: 1))
        let book = try opened(fixture.data())
        XCTAssertEqual(book.sections[0].title, "Part <A>")
        XCTAssertEqual(book.sections[0].headingTargets.values.map(\.text), ["Tom & Jerry"])
    }

    func testTheFirstEntryToNameADestinationNamesIt() throws {
        var fixture = contentsBook()
        fixture.entries.append(KF8Fixture.Entry(label: "Second name for Beta", document: 0, fragment: 1, offset: 0, depth: 0))
        fixture.entries.append(KF8Fixture.Entry(label: "Second name for Part A", document: 0, fragment: 0, offset: 0, depth: 0))
        let book = try opened(fixture.data())
        XCTAssertEqual(book.sections[0].title, "Part A")
        XCTAssertEqual(book.sections[0].headingTargets.values.map(\.text), ["Section Beta"])
    }

    func testADocumentWithNoEntryIsTitledByItsOwnTitleUnlessThatRepeatsTheBooksTitle() throws {
        let documents = ["Chapter One", "Fixture KF8 Book", "FIXTURE  KF8   BOOK", "&amp; Co"].map { title in
            KF8Fixture.Document(html: "<html><head><title>\(title)</title></head><body><p>Words in \(title).</p></body></html>")
        }
        let book = try opened(KF8Fixture(documents: documents).data())
        XCTAssertEqual(book.sections.map(\.title), ["Chapter One", nil, nil, "& Co"])
    }

    func testABookWithNoContentsStillHasItsDocumentsAsChapters() throws {
        let fixture = KF8Fixture(documents: (1...3).map { number in
            KF8Fixture.Document(html: "<html><head><title>Fixture KF8 Book</title></head><body><p>Words \(number).</p></body></html>")
        })
        let book = try prepared(fixture)
        XCTAssertEqual(book.chapters.map(\.chapter.title), ["Chapter 1", "Chapter 2", "Chapter 3"])
    }

    // MARK: - The guide

    func testAContentsPageAtTheEndThatTheGuideNamesAsContentsIsLeftOut() throws {
        // Every document is cut into a fragment, as a real book's are: a guide or a contents names a fragment.
        let real = "<html><body><h1>Chapter</h1><p>Real words.</p></body></html>"
        let contents = "<html><body><h2>Table of Contents</h2><ul><li><a href=\"kindle:pos:fid:0000:off:0000000000\">Chapter</a></li></ul></body></html>"
        let afterword = "<html><body><p>Afterword.</p></body></html>"
        func document(_ html: String) throws -> KF8Fixture.Document {
            let start = try XCTUnwrap(html.range(of: "<body>")).upperBound
            let end = try XCTUnwrap(html.range(of: "</body>")).lowerBound
            return KF8Fixture.Document(html: html, cutting: [String(html[start..<end])])
        }
        var fixture = KF8Fixture(documents: [try document(real), try document(contents)])
        fixture.guide = [(type: "toc", document: 1)]
        XCTAssertEqual(try opened(fixture.data()).sections.count, 1)
        // The same page in the middle of the book is the author's, and is read.
        fixture.documents.append(try document(afterword))
        XCTAssertEqual(try opened(fixture.data()).sections.count, 3)
        // A guide that names no contents page leaves every document.
        fixture.guide = [(type: "text", document: 1)]
        fixture.documents.removeLast()
        XCTAssertEqual(try opened(fixture.data()).sections.count, 2)
    }

    func testAContentsPageThatTheBooksOwnContentsNamesIsKept() throws {
        let page = "<html><body><h2>Contents</h2><p>A list.</p></body></html>"
        var fixture = KF8Fixture(documents: [
            KF8Fixture.Document(html: "<html><body><p>Real words.</p></body></html>", cutting: ["<p>Real words.</p>"]),
            KF8Fixture.Document(html: page, cutting: ["<h2>Contents</h2><p>A list.</p>"]),
        ])
        fixture.guide = [(type: "toc", document: 1)]
        XCTAssertEqual(try opened(fixture.data()).sections.count, 1, "the guide alone leaves the page out")
        fixture.entries = [KF8Fixture.Entry(label: "Contents", document: 1)]
        XCTAssertEqual(try opened(fixture.data()).sections.count, 2, "the book's own contents names it, so it is read")
    }

    // MARK: - The words

    func testSoftHyphensAreNotRead() throws {
        let fixture = KF8Fixture(body: "<p>prod\u{AD}uct pro&shy;duct pro&#173;duct pro&#xAD;duct pro&#xad;duct</p>")
        let book = try opened(fixture.data())
        XCTAssertTrue(book.sections[0].html.contains("<p>product product product product product</p>"), book.sections[0].html)
        let chapter = try prepared(fixture).chapters[0].chapter
        XCTAssertEqual(chapter.text.split(separator: " ").map(String.init).filter { $0.contains("product") }.count, 5)
    }

    func testAPageBreakCalibreStrippedItsPrefixFromIsAPageAgain() throws {
        let body = "<p>First page text.<span type=\"pagebreak\" title=\"2\"></span> Second page text.</p>"
            + "<p>More. <span type='pagebreak' aria-label='3'></span>Third.</p>"
            + "<p>The words type=\"pagebreak\" are only words here.</p>"
            + "<p>A <span role=\"doc-pagebreak\">4</span>role.</p>"
        let book = try opened(KF8Fixture(body: body).data())
        let html = book.sections[0].html
        XCTAssertTrue(html.contains("<span epub:type=\"pagebreak\" title=\"2\">"), html)
        XCTAssertTrue(html.contains("<span epub:type='pagebreak' aria-label='3'>"), html)
        XCTAssertTrue(html.contains("<p>The words type=\"pagebreak\" are only words here.</p>"), html)
        let chapter = try prepared(KF8Fixture(body: body)).chapters[0].chapter
        XCTAssertEqual(chapter.pages.map(\.label), ["2", "3", "4"])
        // Pages are written only when they are asked for.
        let withoutPages = try MOBIParser.preparedBook(
            sections: book.sections, metadata: book.metadata, fallbackTitle: "x", includesPages: false)
        XCTAssertTrue(withoutPages.chapters[0].chapter.pages.isEmpty)
    }

    func testListsTablesAndEmphasisComeThrough() throws {
        let body = "<h1>Heading</h1><p>Some <em>slanted</em> and <strong>heavy</strong> words.</p>"
            + "<ul><li>First item</li><li>Second item</li></ul>"
            + "<table><tr><td>Cell one</td><td>Cell two</td></tr></table><p><img alt=\"A picture of a ferry\" src=\"kindle:embed:0001?mime=image/jpg\"/></p>"
        let markdown = try prepared(KF8Fixture(body: body, cutting: ["<ul><li>First item</li><li>Second item</li></ul>"])).chapters[0].markdown
        for expected in ["# Heading", "*slanted*", "**heavy**", "First item", "Second item", "Cell one", "Cell two", "A picture of a ferry"] {
            XCTAssertTrue(markdown.contains(expected), "\(expected) in \(markdown)")
        }
    }

    // MARK: - What the book says of itself

    func testTheMetadataComesFromTheHeaders() throws {
        let book = try opened(threeParagraphs().data())
        XCTAssertEqual(book.metadata, MOBIBook.Metadata(title: "Fixture KF8 Book", author: "Imre Falk", language: "en"))
        var bare = threeParagraphs()
        bare.title = nil
        bare.authors = []
        bare.language = nil
        let named = try opened(bare.data()).metadata
        XCTAssertEqual(named.title, "Fixture KF8 Book Full Name")
        XCTAssertEqual(named.author, "")
        XCTAssertNil(named.language)
        let prepared = try prepared(bare)
        XCTAssertEqual(prepared.author, Book.unknownAuthor)
    }

    // MARK: - A hybrid file

    /// A MOBI 6 half and a KF8 half that say different things, so a test can
    /// tell which was read.
    private func hybridBytes(kf8: KF8Fixture? = nil, mobi6: MOBIFixture? = nil) -> [UInt8] {
        var six = mobi6 ?? MOBIFixture()
        if mobi6 == nil { six.html = "<html><body><p>Words of the old half.</p></body></html>" }
        let eight = kf8 ?? KF8Fixture(body: "<p>Words of the new half.</p>")
        return eight.hybrid(mobi6: six)
    }

    func testAHybridIsReadFromItsKF8HalfOrItsMOBI6HalfAsAsked() throws {
        let bytes = hybridBytes()
        XCTAssertEqual(MOBIBook.hybridChoice, .kf8)
        let newer = try opened(bytes)
        XCTAssertTrue(newer.sections[0].html.contains("Words of the new half."))
        XCTAssertTrue(newer.includesPages)
        let older = try opened(bytes, hybrid: .mobi6)
        XCTAssertTrue(older.sections[0].html.contains("Words of the old half."))
        XCTAssertFalse(older.includesPages)
        // The default is the KF8 half.
        XCTAssertTrue(try MOBIBook(bytes: bytes).sections[0].html.contains("Words of the new half."))
    }

    func testTheKF8HalfOfAHybridNamesTheBookWhereItNamesNothing() throws {
        var kf8 = KF8Fixture(body: "<p>Words of the new half.</p>")
        kf8.title = nil
        kf8.authors = []
        kf8.language = nil
        kf8.fullName = ""
        var mobi6 = MOBIFixture()
        mobi6.title = "Title of the old half"
        mobi6.authors = ["Author Old"]
        mobi6.language = "fr"
        let book = try opened(hybridBytes(kf8: kf8, mobi6: mobi6))
        XCTAssertEqual(book.metadata, MOBIBook.Metadata(title: "Title of the old half", author: "Author Old", language: "fr"))
    }

    func testADamagedKF8HalfLeavesTheMOBI6HalfToBeRead() throws {
        var kf8 = KF8Fixture(body: "<p>Words of the new half.</p>")
        kf8.compression = 1
        var bytes = hybridBytes(kf8: kf8)
        // Damage the KF8 half's skeleton index so that its tables do not read.
        let offsets = MOBIFixture.recordOffsets(of: bytes)
        let boundary = offsets.count - kf8.records().count
        let skeleton = boundary + (try layoutRecordNumber(of: kf8))
        bytes[offsets[skeleton]] = 0x58   // "INDX" no longer begins the record
        let book = try opened(bytes)
        XCTAssertTrue(book.sections[0].html.contains("Words of the old half."))
        XCTAssertFalse(book.includesPages)
    }

    /// The record number of `fixture`'s skeleton index, from its record 0.
    private func layoutRecordNumber(of fixture: KF8Fixture) throws -> Int {
        let database = try MOBIPalmDatabase(bytes: fixture.data())
        let headers = try MOBIHeaders(record0: try database.record(0, "r0"), requiresMOBIHeader: true)
        return try XCTUnwrap(headers.skeletonIndexRecord)
    }

    func testAProtectedHalfMakesTheWholeFileProtected() throws {
        var protectedKF8 = KF8Fixture(body: "<p>Words of the new half.</p>")
        protectedKF8.encryption = 2
        var protectedDRM = KF8Fixture(body: "<p>Words of the new half.</p>")
        protectedDRM.drmOffset = 0x1234
        var protectedMOBI6 = MOBIFixture()
        protectedMOBI6.drmOffset = 0x1234
        for (name, bytes) in [
            ("the KF8 half's encryption", hybridBytes(kf8: protectedKF8)),
            ("the KF8 half's DRM offset", hybridBytes(kf8: protectedDRM)),
            ("the MOBI 6 half's DRM offset", hybridBytes(mobi6: protectedMOBI6)),
        ] {
            for choice in [MOBIBook.HybridChoice.kf8, .mobi6] {
                XCTAssertThrowsError(try opened(bytes, hybrid: choice), "\(name), read as \(choice)") {
                    XCTAssertEqual($0 as? MOBIError, .copyProtected, name)
                }
            }
        }
        // A KF8 book that is not a hybrid is checked the same way.
        for fixture in [protectedKF8, protectedDRM] {
            XCTAssertThrowsError(try opened(fixture.data())) { XCTAssertEqual($0 as? MOBIError, .copyProtected) }
        }
    }

    func testABoundaryThatNamesNoKF8HeaderLeavesTheMOBI6Book() throws {
        var mobi6 = MOBIFixture()
        // The record at the boundary is a text record, not a header.
        mobi6.extraEXTH[121] = MOBIFixture.be32(1)
        XCTAssertTrue(try opened(mobi6.data()).sections[0].html.contains("A short book for a test."))
        mobi6.extraEXTH[121] = MOBIFixture.be32(0xFFFF_FFFF)
        XCTAssertEqual(try opened(mobi6.data()).sections.count, 1)
        mobi6.extraEXTH[121] = MOBIFixture.be32(0)
        XCTAssertEqual(try opened(mobi6.data()).sections.count, 1)
    }

    // MARK: - The refusals

    func testAKF8BookWithoutItsIndexesIsDamagedWithASentenceToActOn() throws {
        var bytes = threeParagraphs().data()
        // Record 0's skeleton index field (252) says "none".
        let record0 = MOBIFixture.recordOffsets(of: bytes)[0]
        MOBIFixture.put32(&bytes, record0 + 252, 0xFFFF_FFFF)
        XCTAssertThrowsError(try opened(bytes)) {
            guard case .damaged? = $0 as? MOBIError else { return XCTFail("\($0)") }
            XCTAssertTrue($0.localizedDescription.hasPrefix("This Kindle book is damaged or incomplete: "), $0.localizedDescription)
            XCTAssertTrue($0.localizedDescription.hasSuffix("Get a fresh copy of the book, then import it again."))
        }
    }

    func testACompressionNoOneDefinedIsRefusedInAKF8BookToo() {
        for compression in [0, 3, 17479] {
            var fixture = threeParagraphs()
            fixture.compression = compression
            XCTAssertThrowsError(try opened(fixture.data()), "compression \(compression)") {
                XCTAssertEqual($0 as? MOBIError, .unsupportedCompression)
            }
        }
    }

    func testABookWithNoTextOrNoWordsHasNothingToRead() throws {
        let empty = KF8Fixture(documents: [KF8Fixture.Document(html: "<html><body></body></html>")])
        XCTAssertThrowsError(try prepared(empty)) { XCTAssertTrue($0 is FileImportError, "\($0)") }
    }

    // MARK: - Cancel

    func testACancelIsHeardBetweenTheDocumentsNotOnlyBeforeTheRead() throws {
        let fixture = KF8Fixture(documents: (1...12).map { number in
            KF8Fixture.Document(html: "<html><body><p>Document \(number).</p></body></html>")
        })
        // Not asked at all before the read: the check is called, and each call is counted.
        var calls = 0
        XCTAssertThrowsError(try MOBIBook(bytes: fixture.data(), checkCancellation: {
            calls += 1
            if calls == 5 { throw ImportCancelled() }
        })) { XCTAssertEqual($0 as? ImportCancelled, ImportCancelled()) }
        XCTAssertEqual(calls, 5, "the read stopped at the fifth of twelve documents")

        var all = 0
        _ = try MOBIBook(bytes: fixture.data(), checkCancellation: { all += 1 })
        XCTAssertEqual(all, 12)
        // A cancelled import is heard through the default check.
        let cancellation = ImportCancellation()
        cancellation.cancel()
        try ImportCancellation.$current.withValue(cancellation) {
            XCTAssertThrowsError(try MOBIBook(bytes: fixture.data())) { XCTAssertEqual($0 as? ImportCancelled, ImportCancelled()) }
        }
    }

    // MARK: - The whole path

    func testAnAZW3FileImportsWithItsNamesAndOpensAsItsChapters() throws {
        let url = try writeMOBI(contentsBook().data(), named: "Contents Book.azw3")
        let imported = try importedForTest(url)
        XCTAssertEqual(imported.book.format, .mobi)
        XCTAssertEqual(imported.book.title, "Fixture KF8 Book")
        XCTAssertEqual(imported.book.author, "Imre Falk")
        let content = try openedContent(of: imported.book)
        XCTAssertEqual(content.chapters.map(\.title), ["Part A", "Part G"])
        XCTAssertEqual(headingLines(of: content), ["1: Part A", "2: Section Beta", "1: Part G"])
        XCTAssertTrue(allText(of: content).contains("Second words."))
    }
}
