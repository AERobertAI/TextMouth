import XCTest
@testable import TextMouth

/// Books that were read before their format had pages gain them at the next
/// launch (PG09, `PageReaderVersions`): every EPUB, HTML, PDF, Word, and
/// DAISY book whose content.md was written by no page reader, or an older
/// one, is read again, with the saved places, bookmarks, and skipped
/// headings moved onto the same words. A book whose text was changed by hand
/// is left as it is, without pages, and its row is stamped so that the check
/// runs once (`PAGES_SKIPPED_CHANGED_TEXT: <title>`); only Redo Text
/// Extraction reads such a book again.
///
/// Every book here is imported from a copy of a sample, then put back into
/// the state before pages: content.md as the book's file gives it without
/// page markers, committed to a record that names no page reader.
///
/// The app ships with the re-read switched off until the review's safety
/// findings are fixed (`PageReaderVersions.launchRereadIsOn`), so every test
/// switches it on to keep its code working, and puts it back after; one
/// test switches it off, as the app has it, and finds no book read again.
@MainActor
final class PagesUpgradeTests: XCTestCase {
    /// The launch re-read's switch as each test found it.
    private var launchRereadBefore = PageReaderVersions.launchRereadIsOn

    override func setUp() async throws {
        launchRereadBefore = PageReaderVersions._setLaunchRereadForTesting(true)
    }

    override func tearDown() async throws {
        PageReaderVersions._setLaunchRereadForTesting(launchRereadBefore)
    }

    // MARK: - The Versions

    /// Only the formats that gained pages have a page reader; every other
    /// format has none, so no book of it is ever read again for pages.
    func testOnlyTheFormatsWithPagesHaveAPageReader() {
        let withPages: Set<BookFormat> = [.epub, .html, .pdf, .docx, .daisy, .rtf, .rtfd, .doc, .odt, .wordml]
        for format in BookFormat.allCases {
            XCTAssertEqual(
                PageReaderVersions.current(for: format),
                withPages.contains(format) ? "1.0.0" : nil,
                format.rawValue
            )
        }
    }

    /// A book is outdated when its format has a page reader and the book
    /// recorded none or an older one; never for a format without pages.
    func testABookIsOutdatedOnlyWhenItsFormatHasANewerPageReader() {
        let epub = Book(title: "Outdated", format: .epub, filePath: "/tmp/outdated.epub", md5Hash: "m", folderPath: "")
        XCTAssertTrue(PageReaderVersions.isOutdated(epub), "no page reader recorded")
        for (stored, outdated) in [("0.9.0", true), ("1", false), ("1.0.0", false), ("1.2.0", false), ("", true)] {
            var book = epub
            book.pageReaderVersion = stored
            XCTAssertEqual(PageReaderVersions.isOutdated(book), outdated, "stored \"\(stored)\"")
        }
        let text = Book(title: "Plain", format: .txt, filePath: "/tmp/plain.txt", md5Hash: "m", folderPath: "")
        XCTAssertFalse(PageReaderVersions.isOutdated(text))
    }

    // MARK: - The Record

    /// The page reader is an analysis field: it is read and written with the
    /// row and the package record, older ones decode with none, and an
    /// unreadable one counts as none instead of failing the book.
    func testThePageReaderRoundTripsAndOlderRecordsDecodeWithNone() throws {
        var book = Book(title: "Round Trip", format: .epub, filePath: "/tmp/round-trip.epub", md5Hash: "m", folderPath: "")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(book)) as? [String: Any])
        XCTAssertNil(row["pageReaderVersion"])
        XCTAssertNil(try decoder.decode(Book.self, from: JSONSerialization.data(withJSONObject: row)).pageReaderVersion)

        book.pageReaderVersion = "1.0.0"
        XCTAssertEqual(try decoder.decode(Book.self, from: encoder.encode(book)).pageReaderVersion, "1.0.0")
        let info = try decoder.decode(BookInfo.self, from: encoder.encode(book.makeBookInfo()))
        XCTAssertEqual(info.state.pageReaderVersion, "1.0.0")
        XCTAssertEqual(info.state.contentAnalysisFields.pageReaderVersion, "1.0.0")
        XCTAssertEqual(Book(record: info, filePath: book.filePath, folderPath: "", tmbDirectoryName: "").pageReaderVersion, "1.0.0")

        row = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(book)) as? [String: Any])
        row["pageReaderVersion"] = 17
        let damaged = try decoder.decode(Book.self, from: JSONSerialization.data(withJSONObject: row))
        XCTAssertNil(damaged.pageReaderVersion)
        XCTAssertEqual(damaged.title, "Round Trip")
    }

    /// An analysis committed with no page reader keeps the record's own,
    /// with a version sets it, and with `.some(nil)` clears it.
    func testAnAnalysisKeepsSetsOrClearsThePageReader() throws {
        let world = try makeIntegrationWorld("Pages Upgrade Stamp")
        let fixture = try makeBookBeforePages(sample: Self.epubSample, in: world)
        let index = try XCTUnwrap(BookInfo.load(from: fixture.book.tmbDirectory).contentIndex)

        func stamped(_ version: String??) throws -> String? {
            let committed = try LibraryPersistenceService.saveContentAnalysis(
                for: fixture.book, index: index, cacheFormatVersion: nil, pageReaderVersion: version
            )
            return try XCTUnwrap(committed).pageReaderVersion
        }

        XCTAssertNil(try stamped(nil), "the record had none")
        XCTAssertEqual(try stamped(.some("1.0.0")), "1.0.0")
        XCTAssertEqual(try stamped(nil), "1.0.0", "nil keeps the record's own")
        XCTAssertNil(try stamped(.some(nil)))
        XCTAssertNil(try BookInfo.load(from: fixture.book.tmbDirectory).state.pageReaderVersion)
    }

    /// A record from before pages is not recovered, so the batch reads its
    /// book again; stamped with the page reader it is recovered as before.
    func testARecordFromBeforePagesIsNotRecovered() throws {
        let world = try makeIntegrationWorld("Pages Upgrade Recovery")
        let fixture = try makeBookBeforePages(sample: Self.epubSample, in: world)
        func recovered() throws -> BookContentAnalysisService.RecoveredTextCache? {
            try BookContentAnalysisService.recoveredTextCache(for: fixture.book, hasher: .md5, isDataless: { _ in false })
        }

        XCTAssertNil(try recovered())

        let index = try XCTUnwrap(BookInfo.load(from: fixture.book.tmbDirectory).contentIndex)
        _ = try LibraryPersistenceService.saveContentAnalysis(
            for: fixture.book, index: index, cacheFormatVersion: nil, pageReaderVersion: .some("1.0.0")
        )
        XCTAssertNotNil(try recovered())
    }

    // MARK: - The Launch Batch

    /// An EPUB read before pages is chosen by the batch and read again: its
    /// pages appear, its page reader is recorded, and its position,
    /// bookmark, and skipped heading are on the same words in the text with
    /// pages, in the row and the record, none lost.
    func testAnEPUBBeforePagesIsReadAgainAndItsPlacesFollowTheirWords() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade EPUB")
        let fixture = try makeBookBeforePages(sample: Self.epubSample, in: world)
        XCTAssertTrue(PageReaderVersions.isOutdated(fixture.book))
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([fixture.book], access: .live).map(\.id), [fixture.book.id])
        XCTAssertTrue(fixture.oldText.pages.isEmpty, "the fixture should start without pages")

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        let record = Book(
            record: try BookInfo.load(from: fixture.book.tmbDirectory),
            filePath: fixture.book.filePath,
            folderPath: fixture.book.folderPath,
            tmbDirectoryName: fixture.book.tmbDirectoryName
        )
        let content = try MarkdownCacheService.loadFromCache(for: row)
        XCTAssertFalse(content.pages.isEmpty, "the book gained no pages")
        for book in [row, record] {
            XCTAssertEqual(book.pageReaderVersion, "1.0.0")
            XCTAssertEqual(book.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
            assertPlaces(of: book, areAt: Self.epubPlaces, in: content)
        }
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [], "the next launch would read it again")
    }

    /// A book whose text was changed by hand (a word replaced), and which no
    /// edit recorded, keeps content.md byte for byte and gains no pages; the
    /// log says so once, its row is stamped, and a second pass picks nothing.
    func testChangedTextIsKeptWithoutPagesAndTheCheckRunsOnce() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Changed")
        let fixture = try makeBookBeforePages(
            sample: Self.epubSample, changingText: { $0.replacingOccurrences(of: "crate", with: "carton") }, in: world
        )
        let skippedLine = "PAGES_SKIPPED_CHANGED_TEXT: \(fixture.book.title)"
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([fixture.book], access: .live).map(\.id), [fixture.book.id])

        await runBatch(in: world)

        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: fixture.book)), fixture.bytes, "the text was read over")
        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        XCTAssertEqual(row.pageReaderVersion, "1.0.0", "the row was not stamped")
        XCTAssertEqual(try BookInfo.load(from: fixture.book.tmbDirectory).state.pageReaderVersion, "1.0.0")
        XCTAssertTrue(try MarkdownCacheService.loadFromCache(for: row).pages.isEmpty)
        XCTAssertEqual(debugLogLines(containing: skippedLine).count, 1)
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [])
        // The places did not move: the text did not.
        XCTAssertEqual(row.readingPosition?.characterOffset, fixture.book.readingPosition?.characterOffset)

        await runBatch(in: world)

        XCTAssertEqual(debugLogLines(containing: skippedLine).count, 1, "the second pass looked at the book again")
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: fixture.book)), fixture.bytes)
    }

    /// A book with a recorded edit (Edit Text took it) is kept the same way,
    /// whether or not its text still equals its file's: its page reader is
    /// stamped, and the log says both that the edit was kept and that pages
    /// were skipped.
    func testARecordedEditIsKeptWithoutPages() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Edit")
        // The edit changes nothing the file's reading text would not give,
        // so only the record protects it.
        let fixture = try makeBookBeforePages(sample: Self.epubSample, recordingEdit: true, in: world)
        let title = fixture.book.title
        XCTAssertNotNil(fixture.book.editedText)

        await runBatch(in: world)

        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: fixture.book)), fixture.bytes, "the edit was read over")
        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        XCTAssertEqual(row.pageReaderVersion, "1.0.0")
        XCTAssertEqual(row.editedText?.cacheDigest, fixture.book.editedText?.cacheDigest)
        XCTAssertTrue(try MarkdownCacheService.loadFromCache(for: row).pages.isEmpty)
        XCTAssertEqual(debugLogLines(containing: "PAGES_SKIPPED_CHANGED_TEXT: \(title)").count, 1)
        XCTAssertEqual(debugLogLines(containing: "TEXT_EDIT_KEPT: \(title):").count, 1)
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [])
    }

    /// A PDF read before pages is read again with every place exactly where
    /// it was, since its pages add only markers, and gains its five labelled
    /// pages. The comparison with the file read without pages is timed for
    /// each PDF in TestData and printed.
    func testAPDFKeepsItsPlacesExactlyAndGainsItsPages() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade PDF")
        let fixture = try makeBookBeforePages(sample: "pdf/labelled-pages.pdf", places: Self.pdfPlaces, in: world)
        let before = try XCTUnwrap(fixture.book.readingPosition)
        let bookmarkBefore = try XCTUnwrap(fixture.book.bookmarks.first)

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        let content = try MarkdownCacheService.loadFromCache(for: row)
        XCTAssertEqual(content.pages.breaks.map(\.label), ["i", "ii", "1", "2", "A-1"])
        XCTAssertEqual(row.pageReaderVersion, "1.0.0")
        // Not a number moved.
        XCTAssertEqual(row.readingPosition?.chapterIndex, before.chapterIndex)
        XCTAssertEqual(row.readingPosition?.characterOffset, before.characterOffset)
        XCTAssertEqual(row.bookmarks.first?.chapterIndex, bookmarkBefore.chapterIndex)
        XCTAssertEqual(row.bookmarks.first?.characterOffset, bookmarkBefore.characterOffset)
        assertPlaces(of: row, areAt: Self.pdfPlaces, in: content)

        // How long the comparison with the file takes, for the report.
        for name in ["test_formatted.pdf", "test_with_outline.pdf"] {
            let copy = try makeSandboxDirectory("Pages Upgrade Timing").appendingPathComponent(name)
            try FileManager.default.copyItem(at: requireFile(name), to: copy)
            let book = try world.importBook(from: copy)
            let started = Date()
            _ = try MarkdownCacheService.readingTextsWithoutPages(for: book)
            print("PAGES_COMPARISON_SECONDS: \(name): \(Date().timeIntervalSince(started))")
        }
    }

    // MARK: - The Switch

    /// With the launch re-read switched off, as the app ships it, the batch
    /// reads no book again for its pages. An EPUB from before pages is not
    /// chosen at all; a PDF from before pages whose row lags its record (as
    /// a crash leaves it) is chosen for its cache format and recovered from
    /// its record, as before PG09. Both keep content.md byte for byte, with
    /// no pages, no page reader, and their places, and the log names
    /// neither. A book read from its file now still gains its pages and
    /// records its page reader.
    func testWithTheSwitchOffTheBatchReadsNoBookAgainForPages() async throws {
        PageReaderVersions._setLaunchRereadForTesting(false)
        let world = try makeIntegrationWorld("Pages Upgrade Switched Off")
        let untouched = try makeBookBeforePages(sample: Self.epubSample, in: world)
        let behind = try makeBookBeforePages(sample: "pdf/labelled-pages.pdf", places: Self.pdfPlaces, in: world)
        var behindRow = behind.book
        behindRow.cacheFormatVersion = "3.0.3"
        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: behindRow.cacheFormatVersion))
        world.library.library.books = [untouched.book, behindRow]
        XCTAssertEqual(
            LibraryViewModel.booksNeedingCacheUpdate([untouched.book, behindRow], access: .live).map(\.id),
            [behindRow.id],
            "only the row behind its record is chosen"
        )

        await runBatch(in: world)

        for fixture in [untouched, behind] {
            let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
            let cacheURL = MarkdownCacheService.cacheURL(for: row)
            XCTAssertEqual(try Data(contentsOf: cacheURL), fixture.bytes, "\(row.format) was read again for pages")
            XCTAssertTrue(try MarkdownCacheService.loadFromCache(for: row).pages.isEmpty, "\(row.format)")
            XCTAssertNil(row.pageReaderVersion, "\(row.format)")
            XCTAssertNil(try BookInfo.load(from: row.tmbDirectory).state.pageReaderVersion, "\(row.format)")
            XCTAssertEqual(row.cacheFormatVersion, MarkdownCacheService.currentCacheVersion, "\(row.format)")
            XCTAssertEqual(row.readingPosition?.characterOffset, fixture.book.readingPosition?.characterOffset, "\(row.format)")
            XCTAssertEqual(debugLogLines(containing: "PAGES_SKIPPED_CHANGED_TEXT: \(row.title)").count, 0)
            XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [], "\(row.format)")
        }

        let readNow = try world.importBook(from: copyOfFormatSample(Self.epubSample, named: "Read Now.epub"))
        XCTAssertEqual(readNow.pageReaderVersion, PageReaderVersions.current(for: .epub))
        XCTAssertFalse(try MarkdownCacheService.loadFromCache(for: readNow).pages.isEmpty, "a book read now gained no pages")
    }

    /// A book of a format without pages is never chosen for them.
    func testABookWithoutPagesIsNeverChosen() throws {
        let world = try makeIntegrationWorld("Pages Upgrade Text")
        let source = try makeSandboxDirectory("Pages Upgrade Text Source").appendingPathComponent("Plain Notes.txt")
        try Data("Lamps were lit along the quay.\n".utf8).write(to: source)
        let book = try world.importBook(from: source)

        XCTAssertEqual(book.format, .txt)
        XCTAssertNil(book.pageReaderVersion)
        XCTAssertFalse(PageReaderVersions.isOutdated(book))
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([book], access: .live), [])
    }

    // MARK: - Fixtures

    /// The EPUB sample with page-break elements, a TOC, and a page list.
    private static let epubSample = "epub3-pages/page-list.epub"

    /// The places the EPUB fixture saves, each by the words it begins at:
    /// after the page break "1", where the batch's second reading removes
    /// that number from the text.
    private static let epubPlaces = FixturePlaces(position: "somebody signed", bookmark: "coil of cable", skippedHeading: "Opening the Crate")

    /// The places the PDF fixture saves.
    private static let pdfPlaces = FixturePlaces(position: "This is page four.", bookmark: "This is page five.", skippedHeading: nil)

    /// Where a fixture saves its position, its bookmark, and, when it has
    /// one, the heading it skips, each by the words there.
    private struct FixturePlaces {
        let position: String
        let bookmark: String
        let skippedHeading: String?
    }

    /// A book as it was before its format had pages.
    private struct BookBeforePages {
        /// The book as its record holds it: no page reader, content.md
        /// without pages, and places saved in that text.
        let book: Book
        /// The text content.md holds.
        let oldText: DocumentContent
        /// The bytes of content.md.
        let bytes: Data
    }

    /// Imports a copy of `sample` and puts the book back into the state
    /// before pages: content.md is what the file gives without page markers
    /// (with `changingText` applied, for a text changed by hand), committed
    /// to a record that names no page reader (and, with `recordingEdit`,
    /// names the content.md as an edit Edit Text took), with a position, a
    /// bookmark, and a skipped heading saved at `places` in that text. The
    /// book's title is made unique so that its log lines can be counted.
    private func makeBookBeforePages(
        sample: String,
        places: FixturePlaces? = nil,
        changingText: ((String) -> String)? = nil,
        recordingEdit: Bool = false,
        in world: IntegrationWorld
    ) throws -> BookBeforePages {
        let places = places ?? Self.epubPlaces
        var book = try world.importBook(from: copyOfFormatSample(sample))
        book.title = "Pages Upgrade \(UUID().uuidString)"
        let cacheURL = MarkdownCacheService.cacheURL(for: book)

        // The text as it was written before pages.
        var markdown = try XCTUnwrap(MarkdownCacheService.markdownWithoutPages(for: book))
        if let changingText {
            let changed = changingText(markdown)
            XCTAssertNotEqual(changed, markdown, "the change should alter the text")
            markdown = changed
        }
        let bytes = Data(markdown.utf8)
        try bytes.write(to: cacheURL, options: .atomic)
        let oldText = try MarkdownCacheService.loadFromCache(for: book)
        let chapters = oldText.chapters.map(\.text)

        // The places, saved in that text with their words.
        let measure = TextAnchor.measure(ofTextCachedBy: MarkdownCacheService.currentCacheVersion)
        let position = try Self.place(of: places.position, in: chapters)
        let bookmark = try Self.place(of: places.bookmark, in: chapters)
        book.readingPosition = ReadingPosition(
            chapterIndex: position.chapter,
            characterOffset: position.offset,
            globalCharacterOffset: oldText.globalOffset(chapterIndex: position.chapter, localOffset: position.offset),
            anchor: oldText.anchor(at: position, measuredIn: measure)
        )
        book.bookmarks = [Bookmark(
            number: 1, chapterIndex: bookmark.chapter, characterOffset: bookmark.offset,
            label: "Marked", anchor: oldText.anchor(at: bookmark, measuredIn: measure)
        )]
        if let label = places.skippedHeading {
            let heading = try XCTUnwrap(oldText.allHeadings.first { $0.text == label }, "no heading \"\(label)\"")
            let start = TextPlace(chapter: heading.chapterIndex, offset: heading.characterOffset)
            book.setSkippedHeadings([SkippedHeading(heading, anchor: oldText.anchor(at: start, measuredIn: measure))])
        }

        // The record describes that content.md as current, written by no
        // page reader.
        var index = oldText.contentIndex.replacingFormat(book.format)
        index.textCacheFingerprint = TextCacheFingerprint(
            source: try XCTUnwrap(FileFingerprint(of: book.bookFileURL, hasher: .md5)),
            cache: try XCTUnwrap(FileFingerprint(of: cacheURL, hasher: .md5))
        )
        book.applyContentAnalysis(index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion)
        book.pageReaderVersion = nil
        book.editedText = recordingEdit
            ? index.textCacheFingerprint.map { EditedText(cacheDigest: $0.cache.digest, takenAt: Date()) }
            : nil
        try book.saveBookInfoThrowing(contentIndex: index)
        LibraryPersistenceService.flushPendingSave()

        // The book as the record holds it, which is the library's row.
        let recorded = Book(
            record: try BookInfo.load(from: book.tmbDirectory),
            filePath: book.filePath,
            folderPath: book.folderPath,
            tmbDirectoryName: book.tmbDirectoryName
        )
        world.library.library.books = [recorded]
        return BookBeforePages(book: recorded, oldText: oldText, bytes: bytes)
    }

    /// Where `phrase` begins in the first chapter of `chapters` that holds it.
    private static func place(of phrase: String, in chapters: [String]) throws -> TextPlace {
        let chapter = try XCTUnwrap(chapters.firstIndex { $0.contains(phrase) }, "no chapter holds \"\(phrase)\"")
        return try Phrase.place(of: phrase, inChapter: chapter, of: chapters)
    }

    /// Asserts that `book`'s position and bookmark begin at the words of
    /// `places` in `content`, and that it skips the heading it names, there.
    private func assertPlaces(
        of book: Book, areAt places: FixturePlaces, in content: DocumentContent,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        assertText(
            in: content, chapter: book.readingPosition?.chapterIndex, offset: book.readingPosition?.characterOffset,
            begins: places.position, "position", file: file, line: line
        )
        XCTAssertEqual(book.bookmarks.count, 1, "the bookmark was lost", file: file, line: line)
        assertText(
            in: content, chapter: book.bookmarks.first?.chapterIndex, offset: book.bookmarks.first?.characterOffset,
            begins: places.bookmark, "bookmark", file: file, line: line
        )
        if let label = places.skippedHeading {
            let heading = content.allHeadings.first { $0.text == label }
            XCTAssertNotNil(heading, "no heading \"\(label)\"", file: file, line: line)
            XCTAssertEqual(book.skippedHeadings?.count, 1, "the skipped heading was lost", file: file, line: line)
            XCTAssertEqual(book.skippedHeadings?.first?.chapterIndex, heading?.chapterIndex, "skipped heading's chapter", file: file, line: line)
            XCTAssertEqual(book.skippedHeadings?.first?.characterOffset, heading?.characterOffset, "skipped heading's offset", file: file, line: line)
        }
    }

    /// Asserts that `content`'s chapter `chapter` holds `phrase` at `offset`
    /// (UTF-16), checked without a subscript that could trap.
    private func assertText(
        in content: DocumentContent, chapter: Int?, offset: Int?, begins phrase: String, _ what: String,
        file: StaticString, line: UInt
    ) {
        guard let chapter, let offset, content.chapters.indices.contains(chapter) else {
            XCTFail("the \(what) is gone", file: file, line: line)
            return
        }
        let text = content.chapters[chapter].text as NSString
        guard offset >= 0, offset + phrase.utf16.count <= text.length else {
            XCTFail("the \(what) is past the end of its chapter", file: file, line: line)
            return
        }
        XCTAssertEqual(
            text.substring(with: NSRange(location: offset, length: phrase.utf16.count)), phrase,
            "the \(what) is not on its words", file: file, line: line
        )
    }

    /// Runs the launch's cache batch over the world's library until it ends,
    /// then writes every pending save.
    private func runBatch(in world: IntegrationWorld) async {
        let finished = expectation(description: "The cache batch finished")
        // The batch reports once; a second report must not abort the host.
        finished.assertForOverFulfill = false
        world.library.extractMissingContentCaches { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 120)
        LibraryPersistenceService.flushPendingSave()
    }
}
