import XCTest
import ZIPFoundation
@testable import TextMouth

/// The EPUB 3 writer (FMT28): the structure of the file it writes, the
/// metadata it states, the contents and page list it builds, and what it
/// does with hostile text, an empty book, a stop, and a failing destination.
///
/// Every file is written into a folder of the test's own, with the export's
/// date and the book's identifier fixed, so the bytes are the same every
/// time. No test needs `epubcheck`: the real files go through it in
/// `EPUBExportRealBooksTests`, which skips it where it is not installed.
final class EPUBExportWriterTests: XCTestCase {

    // MARK: - Helpers

    /// A book with every detail the package states.
    static let book = ExportBookDetails(
        title: "Harbour Notes",
        author: "Tamsin Orrel",
        language: "en",
        identifier: UUID(uuidString: "9B2E5C1A-3D4F-4A6B-8C7D-0E1F2A3B4C5D")
    )

    /// The export's date, 2026-11-06 at 17:30:00 UTC.
    static let exportDate = Date(timeIntervalSince1970: 1_793_986_200)

    /// The writer, dated by `exportDate`.
    static func writer(maximumFileBytes: Int = EPUBExportWriter.defaultMaximumFileBytes) -> EPUBExportWriter {
        EPUBExportWriter(modified: { exportDate }, maximumFileBytes: maximumFileBytes)
    }

    /// The EPUB of `markdown` for `book`, written by `writer` into a folder
    /// of this test's own, walked as the export walks it.
    func export(
        _ markdown: String,
        book: ExportBookDetails = EPUBExportWriterTests.book,
        writer: EPUBExportWriter = EPUBExportWriterTests.writer()
    ) throws -> URL {
        let document = try ExportDocumentWalker.document(
            fromMarkdown: markdown, book: book, options: writer.walkOptions
        )
        let url = try makeSandboxDirectory("EPUB Export").appendingPathComponent("book.epub")
        try writer.write(document, options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation())
        return url
    }

    /// The paths of the files in the EPUB at `url`, in the order the ZIP holds them.
    func paths(of url: URL) throws -> [String] {
        try Archive(url: url, accessMode: .read).map(\.path)
    }

    /// The text of the file `path` in the EPUB at `url`.
    func text(_ path: String, in url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive[path] else {
            XCTFail("\(path) is not in the file", file: file, line: line)
            return ""
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Fails unless every XML file of the EPUB parses; returns how many it parsed.
    @discardableResult
    func assertWellFormed(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        var count = 0
        for path in try paths(of: url) where path != "mimetype" {
            let parser = XMLParser(data: Data(try text(path, in: url, file: file, line: line).utf8))
            XCTAssertTrue(parser.parse(), "\(path) is not well-formed: \(String(describing: parser.parserError))", file: file, line: line)
            count += 1
        }
        return count
    }

    /// The chapter files of the EPUB at `url`, in the order of the spine.
    func chapterPaths(of url: URL) throws -> [String] {
        try paths(of: url).filter { $0.hasPrefix("OEBPS/chapter-") }
    }

    /// The body lines of the chapter file `path`.
    func bodyLines(_ path: String, in url: URL) throws -> [String] {
        let lines = try text(path, in: url).components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "<body>"), let end = lines.firstIndex(of: "</body>") else {
            XCTFail("\(path) has no body")
            return []
        }
        return Array(lines[(start + 1)..<end])
    }

    /// The package document of the EPUB at `url`.
    func package(of url: URL) throws -> String {
        try text("OEBPS/content.opf", in: url)
    }

    /// The content of every `<meta property="name">` in `package`, in order.
    func metas(_ name: String, in package: String) -> [String] {
        Self.captures(of: "<meta property=\"\(name)\"[^>]*>([^<]*)</meta>", in: package)
    }

    /// Every capture of group 1 of `pattern` in `text`, in order.
    static func captures(of pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// The links of the navigation document's `nav` of `kind` ("toc" or
    /// "page-list"), each with the depth of lists it is in and its text.
    func navLinks(_ kind: String, in url: URL) throws -> [NavLink] {
        let reader = NavReader(kind: kind)
        let parser = XMLParser(data: Data(try text("OEBPS/nav.xhtml", in: url).utf8))
        parser.delegate = reader
        XCTAssertTrue(parser.parse(), String(describing: parser.parserError))
        return reader.links
    }

    // MARK: - The Structure

    /// `mimetype` is the first file, stored (not compressed), with no extra
    /// field, holding exactly "application/epub+zip": the bytes at fixed
    /// places in the ZIP, which is how a reading system recognises an EPUB.
    func testMimetypeIsFirstStoredAndHoldsTheMediaType() throws {
        let url = try export("Words.")
        XCTAssertEqual(try paths(of: url).first, "mimetype")

        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(bytes.count, 58, "a header and the media type")
        /// The little-endian 16-bit number at `offset` of the file's first bytes.
        func number(at offset: Int) -> Int {
            bytes.count >= offset + 2 ? Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 : -1
        }
        XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "a ZIP local file header")
        XCTAssertEqual(number(at: 8), 0, "stored, not deflated")
        XCTAssertEqual(number(at: 28), 0, "no extra field")
        XCTAssertEqual(number(at: 26), 8, "the name is 8 bytes long")
        XCTAssertEqual(String(decoding: bytes.dropFirst(30).prefix(8), as: UTF8.self), "mimetype")
        XCTAssertEqual(String(decoding: bytes.dropFirst(38).prefix(20), as: UTF8.self), "application/epub+zip")
        XCTAssertEqual(try text("mimetype", in: url), "application/epub+zip")
    }

    /// The files, in order: `mimetype`, the container, the chapters, the
    /// navigation document, and the package document; every one well-formed.
    func testTheFilesAndTheirOrder() throws {
        let url = try export("# One\n\nWords.")
        XCTAssertEqual(try paths(of: url), [
            "mimetype", "META-INF/container.xml", "OEBPS/chapter-1.xhtml", "OEBPS/nav.xhtml", "OEBPS/content.opf",
        ])
        XCTAssertEqual(try assertWellFormed(url), 4)
        let container = try text("META-INF/container.xml", in: url)
        XCTAssertTrue(container.contains("full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\""))
    }

    /// The manifest lists the navigation document (so marked) and every
    /// chapter, and the spine every chapter, in order.
    func testTheManifestAndTheSpineListTheChaptersInOrder() throws {
        let url = try export("<!-- chapter: A -->\nOne.\n\n<!-- chapter: B -->\nTwo.\n\n<!-- chapter: C -->\nThree.")
        let package = try package(of: url)
        XCTAssertEqual(try chapterPaths(of: url), ["OEBPS/chapter-1.xhtml", "OEBPS/chapter-2.xhtml", "OEBPS/chapter-3.xhtml"])
        XCTAssertTrue(package.contains("<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"))
        XCTAssertEqual(
            Self.captures(of: "<item id=\"(chapter-\\d+)\" href=\"chapter-\\d+.xhtml\" media-type=\"application/xhtml\\+xml\"/>", in: package),
            ["chapter-1", "chapter-2", "chapter-3"]
        )
        XCTAssertEqual(Self.captures(of: "<itemref idref=\"([^\"]+)\"/>", in: package), ["chapter-1", "chapter-2", "chapter-3"])
    }

    // MARK: - The Package Document

    /// The metadata states the identifier, title, creator, language, and the
    /// export's own modified date, and no more.
    func testThePackageStatesTheBooksDetailsAndTheExportsDate() throws {
        let package = try package(of: export("Words."))
        XCTAssertTrue(package.contains("<dc:identifier id=\"book-id\">urn:uuid:9b2e5c1a-3d4f-4a6b-8c7d-0e1f2a3b4c5d</dc:identifier>"))
        XCTAssertTrue(package.contains("<dc:title>Harbour Notes</dc:title>"))
        XCTAssertTrue(package.contains("<dc:creator>Tamsin Orrel</dc:creator>"))
        XCTAssertTrue(package.contains("<dc:language>en</dc:language>"))
        XCTAssertEqual(metas("dcterms:modified", in: package), ["2026-11-06T17:30:00Z"])
        XCTAssertTrue(package.contains("unique-identifier=\"book-id\""))
        XCTAssertTrue(package.contains("version=\"3.0\""))
    }

    /// The accessibility metadata is exactly what is true of a book with
    /// headings and no pages, and claims no standard.
    func testTheAccessibilityMetadataStatesWhatIsTrue() throws {
        let package = try package(of: export("# Heading\n\nWords."))
        XCTAssertEqual(metas("schema:accessMode", in: package), ["textual"])
        XCTAssertEqual(metas("schema:accessModeSufficient", in: package), ["textual"])
        XCTAssertEqual(
            metas("schema:accessibilityFeature", in: package),
            ["tableOfContents", "readingOrder", "structuralNavigation"],
            "no pageNavigation for a book without pages"
        )
        XCTAssertEqual(metas("schema:accessibilityHazard", in: package), ["none"])
        let summary = try XCTUnwrap(metas("schema:accessibilitySummary", in: package).first)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertFalse(summary.contains("page list"), "no pages, no page list in the summary: \(summary)")
        XCTAssertFalse(package.contains("conformsTo"), "no conformance is claimed")
        XCTAssertFalse(package.lowercased().contains("wcag"))
    }

    /// A book with pages also states page navigation, and its summary says so;
    /// a book with no heading does not state structural navigation.
    func testPageNavigationIsStatedOnlyWithPagesAndStructureOnlyWithHeadings() throws {
        let paged = try package(of: export("<!-- page: 1 -->\nWords.\n\n<!-- page: 2 -->\nMore words."))
        XCTAssertEqual(
            metas("schema:accessibilityFeature", in: paged),
            ["tableOfContents", "readingOrder", "pageNavigation", "pageBreakMarkers"]
        )
        XCTAssertTrue(try XCTUnwrap(metas("schema:accessibilitySummary", in: paged).first).contains("page list"))

        let plain = try package(of: export("Words."))
        XCTAssertEqual(metas("schema:accessibilityFeature", in: plain), ["tableOfContents", "readingOrder"])
    }

    /// A book whose language is unknown says "und" in the package and puts
    /// no `lang` on its documents, rather than a language it may not be in;
    /// a book with a language puts it on both attributes of every document.
    func testTheLanguageIsTheBooksOrUndeterminedAndNeverGuessed() throws {
        let known = try export("Words.", book: ExportBookDetails(title: "T", language: "fr-CA"))
        XCTAssertTrue(try package(of: known).contains("<dc:language>fr-CA</dc:language>"))
        for path in ["OEBPS/chapter-1.xhtml", "OEBPS/nav.xhtml"] {
            XCTAssertTrue(try text(path, in: known).contains("lang=\"fr-CA\" xml:lang=\"fr-CA\""), path)
        }

        let unknown = try export("Words.", book: ExportBookDetails(title: "T"))
        XCTAssertTrue(try package(of: unknown).contains("<dc:language>und</dc:language>"))
        for path in ["OEBPS/chapter-1.xhtml", "OEBPS/nav.xhtml"] {
            XCTAssertFalse(try text(path, in: unknown).contains("xml:lang=\"und\""), path)
            XCTAssertFalse(try text(path, in: unknown).contains("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang"), path)
        }
    }

    /// A book with no author states no creator.
    func testABookWithNoAuthorStatesNoCreator() throws {
        let package = try package(of: export("Words.", book: ExportBookDetails(title: "T", language: "en")))
        XCTAssertFalse(package.contains("dc:creator"))
    }

    // MARK: - The Identifier and the Date

    /// The same book exported twice has the same identifier, and with the
    /// same date the same bytes; a later date changes only the date.
    func testTheSameBookExportedTwiceHasTheSameIdentifier() throws {
        let first = try export("# One\n\nWords.")
        let second = try export("# One\n\nWords.")
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second), "the same date, the same bytes")

        let later = try export(
            "# One\n\nWords.",
            writer: EPUBExportWriter(modified: { Self.exportDate.addingTimeInterval(86_400) })
        )
        let identifiers = try [first, later].map { Self.captures(of: "<dc:identifier id=\"book-id\">([^<]*)</dc:identifier>", in: try package(of: $0)) }
        XCTAssertEqual(identifiers.count, 2)
        XCTAssertEqual(identifiers.first, identifiers.last)
        XCTAssertEqual(metas("dcterms:modified", in: try package(of: later)), ["2026-11-07T17:30:00Z"])
    }

    /// A book made without an identity (only a test's details are) gets a
    /// valid lower-case UUID of its own for each export; one with an identity
    /// gets that identity, whatever its title.
    func testTheIdentifierIsTheBooksOrANewUUID() {
        let id = UUID()
        XCTAssertEqual(
            EPUBExportWriter.identifier(of: ExportBookDetails(title: "Tide Tables", identifier: id)),
            "urn:uuid:" + id.uuidString.lowercased()
        )
        let first = EPUBExportWriter.identifier(of: ExportBookDetails(title: "Tide Tables"))
        let second = EPUBExportWriter.identifier(of: ExportBookDetails(title: "Tide Tables"))
        XCTAssertNotEqual(first, second)
        for identifier in [first, second] {
            XCTAssertTrue(identifier.hasPrefix("urn:uuid:"))
            let uuid = String(identifier.dropFirst("urn:uuid:".count))
            XCTAssertNotNil(UUID(uuidString: uuid))
            XCTAssertEqual(uuid, uuid.lowercased())
        }
    }

    // MARK: - The Contents

    /// The contents list links every heading, nested by level, and stays
    /// correct when levels skip: no list is deeper than one level below the
    /// list around it, and every heading is there once, in reading order.
    func testTheContentsNestByLevelAndSurviveSkippedLevels() throws {
        let url = try export("# A\n\nx\n\n### B\n\nx\n\n## C\n\nx\n\n#### D\n\nx\n\n# E\n\nx")
        let links = try navLinks("toc", in: url)
        XCTAssertEqual(links.map(\.text), ["A", "B", "C", "D", "E"])
        XCTAssertEqual(links.map(\.depth), [1, 2, 2, 3, 1])
        XCTAssertEqual(links.map(\.address), [
            "chapter-1.xhtml#a", "chapter-1.xhtml#b", "chapter-1.xhtml#c", "chapter-1.xhtml#d", "chapter-1.xhtml#e",
        ])
        // Each link goes to a heading of that id in that file.
        let body = try bodyLines("OEBPS/chapter-1.xhtml", in: url)
        for id in ["a", "b", "c", "d", "e"] {
            XCTAssertEqual(body.filter { $0.contains("id=\"\(id)\"") }.count, 1, id)
        }
    }

    /// The first heading may be deeper than the next: the list stays flat
    /// rather than closing past its outermost list.
    func testAFirstHeadingDeeperThanTheNextStaysOneFlatList() throws {
        let url = try export("## First\n\nx\n\n# Second\n\nx")
        let links = try navLinks("toc", in: url)
        XCTAssertEqual(links.map(\.text), ["First", "Second"])
        XCTAssertEqual(links.map(\.depth), [1, 1])
    }

    /// A heading that is only punctuation is a heading, linked by its
    /// punctuation, with an id made from nothing ("heading").
    func testAHeadingOfOnlyPunctuationIsLinkedByIt() throws {
        let url = try export("## !?!\n\nWords.")
        XCTAssertEqual(try navLinks("toc", in: url).map(\.text), ["!?!"])
        XCTAssertEqual(try navLinks("toc", in: url).map(\.address), ["chapter-1.xhtml#heading"])
        XCTAssertTrue(try bodyLines("OEBPS/chapter-1.xhtml", in: url).contains("<h2 id=\"heading\">!?!</h2>"))
    }

    /// A book with no heading has one entry in its contents, the book's
    /// title, linking its first file, because a contents list needs one; and
    /// its chapter holds no heading the book did not have.
    func testABookWithNoHeadingsHasOneEntryForTheWholeBook() throws {
        let url = try export("First paragraph.\n\nSecond paragraph.")
        let links = try navLinks("toc", in: url)
        XCTAssertEqual(links.map(\.text), ["Harbour Notes"])
        XCTAssertEqual(links.map(\.address), ["chapter-1.xhtml"])
        XCTAssertEqual(try bodyLines("OEBPS/chapter-1.xhtml", in: url), ["<p>First paragraph.</p>", "<p>Second paragraph.</p>"])
    }

    /// A chapter with a title and no heading is named in the contents,
    /// linking its file, and holds no words the book does not have: no heading
    /// is added to it. The book then states no structural navigation, since
    /// it has no heading of its own.
    func testAChapterWithATitleAndNoHeadingIsNamedInTheContentsAndGainsNoWords() throws {
        let url = try export("<!-- chapter: Departure -->\nPlain words.\n\n<!-- chapter: Arrival -->\nMore words.")
        XCTAssertEqual(try bodyLines("OEBPS/chapter-1.xhtml", in: url), ["<p>Plain words.</p>"])
        XCTAssertEqual(try bodyLines("OEBPS/chapter-2.xhtml", in: url), ["<p>More words.</p>"])
        let links = try navLinks("toc", in: url)
        XCTAssertEqual(links.map(\.text), ["Departure", "Arrival"])
        XCTAssertEqual(links.map(\.address), ["chapter-1.xhtml", "chapter-2.xhtml"])
        XCTAssertEqual(
            metas("schema:accessibilityFeature", in: try package(of: url)),
            ["tableOfContents", "readingOrder"],
            "the chapters are in the contents, but no heading is"
        )
    }

    /// A chapter with a heading of its own is not also named in the contents.
    func testAChapterWithAHeadingIsNotNamedBesidesIt() throws {
        let url = try export("<!-- chapter: Departure -->\n# Leaving\n\nWords.")
        XCTAssertEqual(try navLinks("toc", in: url).map(\.text), ["Leaving"])
    }

    /// One chapter of many: each chapter is a file whose `<title>` is its
    /// title, and a heading's link goes to the file that holds it.
    func testEachChapterIsAFileTitledByItAndTheContentsLinkTheRightFile() throws {
        let url = try export("<!-- chapter: Alpha -->\n# Alpha\n\nOne.\n\n<!-- chapter: Beta -->\n# Beta\n\n## Inner\n\nTwo.")
        XCTAssertTrue(try text("OEBPS/chapter-1.xhtml", in: url).contains("<title>Alpha</title>"))
        XCTAssertTrue(try text("OEBPS/chapter-2.xhtml", in: url).contains("<title>Beta</title>"))
        XCTAssertEqual(
            try navLinks("toc", in: url).map(\.address),
            ["chapter-1.xhtml#alpha", "chapter-2.xhtml#beta", "chapter-2.xhtml#inner"]
        )
    }

    // MARK: - Pages

    /// The pages: a page list that links each start of a page, and an
    /// element at each start of a page with the roles and the label, between
    /// blocks and inside a paragraph, in a file of the right chapter.
    func testEveryPageMarkerIsATargetAndTheListLinksIt() throws {
        let url = try export("""
        <!-- chapter: One -->
        # One

        <!-- page: 1 -->
        First words <!-- page: ii --> then more.

        <!-- chapter: Two -->
        <!-- page: A-3 -->
        Second chapter.
        """)
        let first = try text("OEBPS/chapter-1.xhtml", in: url)
        let second = try text("OEBPS/chapter-2.xhtml", in: url)
        func target(_ id: String, _ label: String) -> String {
            "<span epub:type=\"pagebreak\" role=\"doc-pagebreak\" id=\"\(id)\" aria-label=\"\(label)\" title=\"\(label)\"></span>"
        }
        XCTAssertTrue(first.contains("\n\(target("page_1", "1"))\n"), "between blocks")
        XCTAssertTrue(first.contains("<p>First words \(target("page_2", "ii")) then more.</p>"), "inside a paragraph")
        XCTAssertTrue(second.contains(target("page_3", "A-3")))
        let pageList = try navLinks("page-list", in: url)
        XCTAssertEqual(pageList.map(\.text), ["1", "ii", "A-3"])
        XCTAssertEqual(pageList.map(\.address), ["chapter-1.xhtml#page_1", "chapter-1.xhtml#page_2", "chapter-2.xhtml#page_3"])
        XCTAssertEqual(pageList.map(\.depth), [1, 1, 1])
        let nav = try text("OEBPS/nav.xhtml", in: url)
        XCTAssertTrue(nav.contains("<nav epub:type=\"page-list\" role=\"doc-pagelist\" id=\"page-list\" hidden=\"hidden\">"))
    }

    /// A book with no page marker has no page list and no page element.
    func testABookWithoutPagesHasNoPageList() throws {
        let url = try export("# One\n\nWords.")
        XCTAssertFalse(try text("OEBPS/nav.xhtml", in: url).contains("page-list"))
        XCTAssertFalse(try text("OEBPS/chapter-1.xhtml", in: url).contains("pagebreak"))
    }

    /// A page marker at the very start and one at the very end of the book
    /// are both targets, in the first and the last place, and every marker in
    /// a heading or a table's cell is kept too.
    func testAMarkerAtTheVeryStartAndTheVeryEndAreKept() throws {
        let url = try export("<!-- page: 1 -->\nFirst.\n\nLast.\n\n<!-- page: 9 -->")
        let body = try bodyLines("OEBPS/chapter-1.xhtml", in: url)
        XCTAssertTrue(try XCTUnwrap(body.first).contains("id=\"page_1\""))
        XCTAssertTrue(try XCTUnwrap(body.last).contains("id=\"page_2\""))
        XCTAssertEqual(try navLinks("page-list", in: url).map(\.text), ["1", "9"])
    }

    /// Two pages in a row, with the same label, are two targets with two ids.
    func testTwoPagesInARowAreTwoTargets() throws {
        let url = try export("<!-- page: 5 -->\n<!-- page: 5 -->\nWords.")
        XCTAssertEqual(try navLinks("page-list", in: url).map(\.address), ["chapter-1.xhtml#page_1", "chapter-1.xhtml#page_2"])
        let ids = Self.captures(of: "id=\"(page_\\d+)\"", in: try text("OEBPS/chapter-1.xhtml", in: url))
        XCTAssertEqual(ids, ["page_1", "page_2"])
    }

    /// A label with markup in it is escaped in both places it goes.
    func testAPageLabelIsEscaped() throws {
        let marker = MarkdownPageMarker(label: "a&b\"c", ordinal: 1).markdown
        let url = try export("\(marker)\nWords.")
        let chapter = try text("OEBPS/chapter-1.xhtml", in: url)
        XCTAssertTrue(chapter.contains("aria-label=\"a&amp;b&quot;c\" title=\"a&amp;b&quot;c\""))
        XCTAssertEqual(try navLinks("page-list", in: url).map(\.text), ["a&b\"c"])
    }

    // MARK: - The Text

    /// Headings, lists, tables, emphasis, links, and code are real elements.
    func testTheTextIsWrittenAsRealElements() throws {
        let url = try export("""
        # Title

        Some *emphasis*, some **strength**, a [link](https://example.com/a), and `code`.

        - one
        - two

        1. first
        2. second

        | Port | Depth |
        |------|-------|
        | Alder | 12 |

        ```
        a < b
        ```
        """)
        let body = try bodyLines("OEBPS/chapter-1.xhtml", in: url).joined(separator: "\n")
        XCTAssertTrue(body.contains("<h1 id=\"title\">Title</h1>"))
        XCTAssertTrue(body.contains("<em>emphasis</em>"))
        XCTAssertTrue(body.contains("<strong>strength</strong>"))
        XCTAssertTrue(body.contains("<a href=\"https://example.com/a\">link</a>"))
        XCTAssertTrue(body.contains("<code>code</code>"))
        XCTAssertTrue(body.contains("<ul>\n<li>one</li>\n<li>two</li>\n</ul>"))
        XCTAssertTrue(body.contains("<ol>\n<li>first</li>\n<li>second</li>\n</ol>"))
        XCTAssertTrue(body.contains("<thead>\n<tr><th>Port</th><th>Depth</th></tr>\n</thead>"))
        XCTAssertTrue(body.contains("<pre><code>a &lt; b</code></pre>"))
        try assertWellFormed(url)
    }

    // MARK: - Hostile Text

    /// A title, author, chapter title, heading, and text full of markup
    /// characters and characters XML forbids: every file parses, the
    /// markup characters arrive escaped, and the forbidden ones are gone.
    func testHostileTitlesAndTextAreEscapedAndForbiddenCharactersDropped() throws {
        let book = ExportBookDetails(
            title: "Tom & <Jerry> \"Quoted\" \u{1}x\u{FFFE}",
            author: "O'Neil & <Co>\u{0}",
            language: "en"
        )
        let url = try export("""
        <!-- chapter: Rock & <Roll> \u{2} -->
        # Head & <b>bold</b> \u{3}

        Body & <i>raw</i> text\u{C}after\u{B}that \u{7}bell ]]> and &amp; done.
        """, book: book)
        try assertWellFormed(url)
        let package = try package(of: url)
        XCTAssertTrue(package.contains("<dc:title>Tom &amp; &lt;Jerry&gt; \"Quoted\" x</dc:title>"), package)
        XCTAssertTrue(package.contains("<dc:creator>O'Neil &amp; &lt;Co&gt;</dc:creator>"))
        let chapter = try text("OEBPS/chapter-1.xhtml", in: url)
        XCTAssertTrue(chapter.contains("<title>Rock &amp; &lt;Roll&gt;</title>"), chapter)
        XCTAssertTrue(chapter.contains("Head &amp; "))
        // `&amp;` in the book is the text "&", which the file writes as `&amp;`; the
        // bell is dropped, the word after it is kept.
        XCTAssertTrue(chapter.contains("bell ]]&gt; and &amp; done."), chapter)
        for forbidden in 0..<32 where ![9, 10, 13].contains(forbidden) {
            XCTAssertFalse(
                [package, chapter].contains { $0.unicodeScalars.contains(Unicode.Scalar(UInt8(forbidden))) },
                "U+\(String(forbidden, radix: 16)) was written"
            )
        }
        XCTAssertEqual(try navLinks("toc", in: url).count, 1)
    }

    /// A title made only of characters XML forbids is not written empty:
    /// the package and the documents say "Untitled".
    func testATitleOfOnlyForbiddenCharactersBecomesUntitled() throws {
        let url = try export("Words.", book: ExportBookDetails(title: "\u{1}\u{2}", language: "en"))
        try assertWellFormed(url)
        XCTAssertTrue(try package(of: url).contains("<dc:title>Untitled</dc:title>"))
        XCTAssertTrue(try text("OEBPS/chapter-1.xhtml", in: url).contains("<title>Untitled</title>"))
        XCTAssertEqual(try navLinks("toc", in: url).map(\.text), ["Untitled"])
    }

    /// A heading of only forbidden characters is linked by a name, not by
    /// nothing, so the contents link has words, and no empty heading is
    /// written for a screen reader to meet: the target stays, with the id.
    func testAHeadingOfOnlyForbiddenCharactersIsLinkedByANameAndWritesNoEmptyHeading() throws {
        let url = try export("# \u{1}\u{2}\n\nWords.")
        try assertWellFormed(url)
        XCTAssertEqual(try navLinks("toc", in: url).map(\.text), ["Untitled"])
        XCTAssertEqual(try navLinks("toc", in: url).map(\.address), ["chapter-1.xhtml#heading"])
        XCTAssertEqual(
            try bodyLines("OEBPS/chapter-1.xhtml", in: url),
            ["<span id=\"heading\"></span>", "<p>Words.</p>"]
        )
    }

    /// A link that is not a web or mail address is plain text, a hostile
    /// scheme included, and no attribute breaks out of its quotes: a quote in
    /// a web address is percent-encoded, which EPUB's validator accepts.
    func testOnlyWebAndMailLinksBecomeLinks() throws {
        let url = try export("[a](javascript:alert(1)) [b](https://x.example/\"onmouseover=\"y) [c](mailto:z@example.com)")
        let body = try bodyLines("OEBPS/chapter-1.xhtml", in: url).joined(separator: "\n")
        XCTAssertFalse(body.contains("javascript"))
        XCTAssertFalse(body.contains("onmouseover=\"y"))
        XCTAssertTrue(body.contains("<a href=\"https://x.example/%22onmouseover=%22y\">b</a>"), body)
        XCTAssertTrue(body.contains("<a href=\"mailto:z@example.com\">c</a>"))
        try assertWellFormed(url)
    }

    // MARK: - Empty and Odd Books

    /// A book with no text at all is still a valid package: one empty
    /// chapter in the spine, and a contents list of one entry.
    func testAnEmptyBookIsStillAPackage() throws {
        let url = try export("")
        try assertWellFormed(url)
        XCTAssertEqual(try chapterPaths(of: url), ["OEBPS/chapter-1.xhtml"])
        XCTAssertEqual(try bodyLines("OEBPS/chapter-1.xhtml", in: url), [])
        XCTAssertEqual(try navLinks("toc", in: url).count, 1)
        XCTAssertEqual(Self.captures(of: "<itemref idref=\"([^\"]+)\"/>", in: try package(of: url)), ["chapter-1"])
    }

    /// A chapter with no text is left out (the book still has the others);
    /// the title of the book alone, with no title heading added.
    func testAChapterWithNoTextIsLeftOut() throws {
        let url = try export("<!-- chapter: Empty -->\n\n<!-- chapter: Full -->\nWords.")
        XCTAssertEqual(try chapterPaths(of: url), ["OEBPS/chapter-1.xhtml"])
        XCTAssertTrue(try text("OEBPS/chapter-1.xhtml", in: url).contains("<title>Full</title>"))
    }

    /// The book's title is not written into the text as a heading the book
    /// did not have (the title is in the package).
    func testTheBooksTitleIsNotAddedToTheText() throws {
        let url = try export("Words only.")
        XCTAssertFalse(try text("OEBPS/chapter-1.xhtml", in: url).contains("Harbour Notes</h1>"))
    }

    // MARK: - Long Books

    /// A chapter past the file size goes on in another file, ending a file
    /// where a heading begins: the text is the same, in order, no file but the
    /// last is much past the limit, each file after the first begins with a
    /// heading, every heading's link goes to the file that holds it, and the
    /// spine lists them all.
    func testALongChapterGoesOnInAnotherFile() throws {
        var markdown = "# Start\n\n"
        for number in 1...60 {
            markdown += "## Part \(number)\n\nParagraph \(number) with some words in it to give it weight.\n\n"
        }
        let url = try export(markdown, writer: Self.writer(maximumFileBytes: 1_000))
        let files = try chapterPaths(of: url)
        XCTAssertGreaterThan(files.count, 5)
        XCTAssertEqual(files, (1...files.count).map { "OEBPS/chapter-\($0).xhtml" })
        XCTAssertEqual(Self.captures(of: "<itemref idref=\"([^\"]+)\"/>", in: try package(of: url)).count, files.count)

        var words: [String] = []
        for file in files {
            let size = try text(file, in: url).utf8.count
            if file != files.last { XCTAssertLessThan(size, 1_000 + 600, "\(file) is far past the limit") }
            if file != files.first {
                XCTAssertTrue(try XCTUnwrap(bodyLines(file, in: url).first).hasPrefix("<h2 "), "\(file) begins with a heading")
            }
            let body = try bodyLines(file, in: url).joined(separator: " ")
            words += body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).map(String.init)
        }
        let expected = markdown.replacingOccurrences(of: "#", with: "").split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertEqual(words, expected)

        // Every contents link goes to a heading of that id in that file.
        let links = try navLinks("toc", in: url)
        XCTAssertEqual(links.count, 61)
        for link in links {
            let parts = link.address.components(separatedBy: "#")
            let file = try text("OEBPS/\(parts[0])", in: url)
            XCTAssertTrue(file.contains("id=\"\(parts[1])\""), "\(link.address) is not in its file")
        }
        try assertWellFormed(url)
    }

    /// Text with no heading to end a file at goes on in another file only
    /// past four times the limit, and every word is kept in order.
    func testTextWithNoHeadingIsSplitOnlyPastTheHardLimit() throws {
        let paragraphs = (1...40).map { "Paragraph \($0) has a few plain words in it." }
        let url = try export(paragraphs.joined(separator: "\n\n"), writer: Self.writer(maximumFileBytes: 100))
        let files = try chapterPaths(of: url)
        XCTAssertGreaterThan(files.count, 2)
        var words: [String] = []
        for file in files {
            XCTAssertLessThan(try text(file, in: url).utf8.count, 4 * 100 + 600, "\(file) is far past four times the limit")
            words += try bodyLines(file, in: url).joined(separator: " ")
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).map(String.init)
        }
        XCTAssertEqual(words, paragraphs.joined(separator: " ").split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// A long run of page markers with no text between is written in a
    /// moment, every page is in the list, and the files stay near the hard
    /// limit: 60,000 pages with a quadratic scan for what follows each would
    /// take minutes. The clock's bound is generous so a busy Mac does not
    /// fail it; the count of files is what notices a file never ended.
    func testALongRunOfPagesIsWrittenQuicklyInFilesNearTheLimit() throws {
        let markers = (1...60_000).map { "<!-- page: \($0) -->" }.joined(separator: "\n\n")
        let started = ContinuousClock.now
        let url = try export("Words.\n\n\(markers)\n\n# End\n\nMore.", writer: Self.writer(maximumFileBytes: 20_000))
        XCTAssertLessThan(started.duration(to: .now), .seconds(90))
        XCTAssertEqual(try navLinks("page-list", in: url).count, 60_000)
        // About 8.4 MB of page elements, in files of about 80 KB.
        let files = try chapterPaths(of: url).count
        XCTAssertGreaterThan(files, 50)
        XCTAssertLessThan(files, 400)
    }

    // MARK: - Stop and Failure

    /// Stop pressed before the first file writes nothing.
    func testAStoppedExportBeforeItBeginsWritesNothing() throws {
        let folder = try makeSandboxDirectory("EPUB Stop Before")
        let url = folder.appendingPathComponent("book.epub")
        let cancellation = BookExportCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(
            try Self.writer().write(ExportDocument(book: Self.book, blocks: []), options: NoTextExportOptions(), to: url, cancellation: cancellation)
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Stop pressed after the first chapter file is in the ZIP removes the
    /// file the writer had begun, and the error is the stop.
    func testStopPartwayRemovesTheFileItBegan() throws {
        let folder = try makeSandboxDirectory("EPUB Stop Partway")
        let url = folder.appendingPathComponent("book.epub")
        let cancellation = BookExportCancellation()
        let writer = EPUBExportWriter(modified: { Self.exportDate }, afterEachFile: { path in
            if path == "OEBPS/chapter-1.xhtml" { cancellation.cancel() }
        })
        let document = try ExportDocumentWalker.document(
            fromMarkdown: "<!-- chapter: A -->\nOne.\n\n<!-- chapter: B -->\nTwo.", book: Self.book, options: writer.walkOptions
        )
        XCTAssertThrowsError(
            try writer.write(document, options: NoTextExportOptions(), to: url, cancellation: cancellation)
        ) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    /// A write that fails partway removes the file it began, and throws the
    /// error it failed with, as every other writer's failure does, so the
    /// export names the system's words.
    func testAFailurePartwayRemovesTheFileAndThrowsTheFailure() throws {
        struct Boom: Error {}
        let folder = try makeSandboxDirectory("EPUB Failure Partway")
        let url = folder.appendingPathComponent("book.epub")
        let writer = EPUBExportWriter(modified: { Self.exportDate }, afterEachFile: { path in
            if path == "META-INF/container.xml" { throw Boom() }
        })
        let document = ExportDocument(book: Self.book, blocks: [.paragraph([ExportRun("Words.")])])
        XCTAssertThrowsError(
            try writer.write(document, options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation())
        ) { XCTAssertTrue($0 is Boom, "\($0)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    /// A destination that cannot be written (its folder does not exist)
    /// fails with words to name, and creates nothing.
    func testADestinationThatCannotBeWrittenFailsAndCreatesNothing() throws {
        let folder = try makeSandboxDirectory("EPUB Bad Destination")
        let url = folder.appendingPathComponent("missing").appendingPathComponent("book.epub")
        let document = ExportDocument(book: Self.book, blocks: [.paragraph([ExportRun("Words.")])])
        XCTAssertThrowsError(
            try Self.writer().write(document, options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation())
        ) {
            XCTAssertFalse($0 is CancellationError)
            XCTAssertFalse($0.localizedDescription.isEmpty)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "no folder was made")
    }

    /// A file already at the destination is an error and is left as it was.
    func testAFileAlreadyThereIsAnErrorAndLeftAsItWas() throws {
        let folder = try makeSandboxDirectory("EPUB Existing")
        let url = folder.appendingPathComponent("book.epub")
        try Data("not an epub".utf8).write(to: url)
        let document = ExportDocument(book: Self.book, blocks: [.paragraph([ExportRun("Words.")])])
        XCTAssertThrowsError(
            try Self.writer().write(document, options: NoTextExportOptions(), to: url, cancellation: BookExportCancellation())
        )
        XCTAssertEqual(try Data(contentsOf: url), Data("not an epub".utf8))
    }

    // MARK: - The Choice in the Dialog

    /// EPUB is a writer of its own: named "EPUB", extension "epub", offered
    /// after Word and before the braille writers, asking the walk for the
    /// book's chapters and pages, and its hint is a sentence that says what
    /// it holds and leaves out.
    func testEPUBIsOfferedLikeItsNeighbours() throws {
        let writer = try XCTUnwrap(TextExportWriters.writer(id: "epub"))
        XCTAssertEqual(writer.name, "EPUB")
        XCTAssertEqual(writer.fileExtension, "epub")
        XCTAssertEqual(writer.walkOptions, .bookStructure)
        XCTAssertTrue(writer.hint.hasSuffix("."))
        XCTAssertTrue(writer.hint.contains("pictures"))
        let ids = TextExportWriters.all.map(\.id)
        XCTAssertEqual(ids.firstIndex(of: "html"), 0)
        XCTAssertLessThan(try XCTUnwrap(ids.firstIndex(of: "epub")), try XCTUnwrap(ids.firstIndex(of: "brf")))
        XCTAssertEqual(ids.filter { $0 == "epub" }.count, 1)
        XCTAssertNotEqual(writer.id, TextExportWriters.markdownID)
        for neighbour in TextExportWriters.all where neighbour.id != "epub" {
            XCTAssertEqual(neighbour.walkOptions, .plain, "\(neighbour.id) asks the walk for nothing more")
        }
    }

    /// The conversion made from the writer carries what the walk keeps, so
    /// the export hands the walk the right options.
    func testTheConversionCarriesTheWalkOptions() {
        XCTAssertEqual(TextExportConversion(EPUBExportWriter(), options: NoTextExportOptions()).walkOptions, .bookStructure)
        XCTAssertEqual(TextExportConversion(HTMLExportWriter(), options: NoTextExportOptions()).walkOptions, .plain)
    }
}

// MARK: - Reading the Navigation Document

/// A link of a navigation list: how many `ol` it is inside, its words, and
/// its address.
struct NavLink: Equatable {
    var depth: Int
    var text: String
    var address: String
}

/// Collects the links inside the `nav` whose `epub:type` is `kind`.
private final class NavReader: NSObject, XMLParserDelegate {
    private let kind: String
    private var insideNav = false
    private var depth = 0
    private var current: NavLink?
    private(set) var links: [NavLink] = []

    init(kind: String) {
        self.kind = kind
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "nav":
            insideNav = attributes["epub:type"] == kind
            depth = 0
        case "ol" where insideNav:
            depth += 1
        case "a" where insideNav:
            current = NavLink(depth: depth, text: "", address: attributes["href"] ?? "")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current?.text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "nav":
            insideNav = false
        case "ol" where insideNav:
            depth -= 1
        case "a" where insideNav:
            if let link = current { links.append(link) }
            current = nil
        default:
            break
        }
    }
}
