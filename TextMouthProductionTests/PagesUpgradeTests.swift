import XCTest
@testable import TextMouth

/// Books that were read before their format had pages gain them at the next
/// launch (PG09, `PageReaderVersions`): every EPUB, HTML, PDF, Word, DAISY,
/// braille, and plain text book whose content.md was written by no page reader, or an older
/// one, is read again, with the saved places, bookmarks, and skipped
/// headings moved onto the same words. A book whose text an edit record
/// names is left as it is, without pages, and its row is stamped so that the
/// check runs once (`PAGES_SKIPPED_CHANGED_TEXT: <title>`); a book whose text
/// differs from its file's but no record names is read again once a copy of
/// that text is kept beside it (`PAGES_REPLACED_TEXT`).
///
/// Every book here is imported from a copy of a sample, then put back into
/// the state before pages: content.md as the book's file gives it without
/// page markers, committed to a record that names no page reader. The V05
/// tests put it into the state an earlier page reader left instead, or a
/// stamp noting a failure: content.md as that reader wrote it, committed to
/// a record that names it.
///
/// The app ships with the re-read switched on since PG16 made it safe
/// (`PageReaderVersions.launchRereadIsOn`), and every test runs it so, as
/// the app does; one test switches it off and finds no book read again,
/// and each test leaves the switch as the app has it.
@MainActor
final class PagesUpgradeTests: XCTestCase {
    override func tearDown() async throws {
        PageReaderVersions._setLaunchRereadForTesting(PageReaderVersions.launchRereadIsOn)
    }

    // MARK: - The Versions

    /// The page reader's version each format with pages is at: EPUB at 1.0.3,
    /// HTML at 1.0.4 (the text decoder's unmarked Unicode and ISO-2022-JP
    /// declarations), plain text at 1.0.1 (the same), rich text (.rtf and .rtfd), read by TextMouth's own reader
    /// since FMT47 and with its follow-ups since, at 1.2.0, Word (.doc: 97-2003
    /// since FMT47, and Word 6 and Word 95 with it since) at 1.3.0, Word (.docx,
    /// with its table styles and document defaults, and its symbols by font,
    /// since) and Word 2003 XML (.wordml, read by its own reader since FMT53,
    /// with hidden row marks and symbols by font since) at 1.3.0, OpenDocument
    /// text (.odt) at 1.1.0, and the rest at 1.0.0.
    private static func expectedVersion(of format: BookFormat) -> String {
        switch format {
        case .epub: return "1.0.3"
        case .html: return "1.0.4"
        case .txt: return "1.0.1"
        case .rtf, .rtfd: return "1.2.0"
        case .doc, .docx, .wordml: return "1.3.0"
        case .odt: return "1.1.0"
        default: return "1.0.0"
        }
    }

    /// Only the formats that gained pages have a page reader; every other
    /// format has none, so no book of it is ever read again for pages. EPUB
    /// and HTML, whose shared converter changed a heading's label, then
    /// stopped taking "Page" alone for a page's label, and then took a
    /// leading "Page" off every label, are at 1.0.3 (HTML went on to 1.0.4 and
    /// plain text to 1.0.1 with the text decoder's new steps); the others have not
    /// changed since they gained pages, except rich text and Word 97-2003, which
    /// went to TextMouth's own readers at 1.1.0.
    func testOnlyTheFormatsWithPagesHaveAPageReader() {
        let withPages: Set<BookFormat> = [.epub, .html, .pdf, .docx, .daisy, .rtf, .rtfd, .doc, .odt, .wordml, .braille, .txt, .kfx, .mobi]
        for format in BookFormat.allCases {
            XCTAssertEqual(
                PageReaderVersions.current(for: format),
                withPages.contains(format) ? Self.expectedVersion(of: format) : nil,
                format.rawValue
            )
        }
    }

    /// A book is outdated when its format has a page reader and the book
    /// recorded none or an older one; never for a format without pages.
    func testABookIsOutdatedOnlyWhenItsFormatHasANewerPageReader() {
        // A PDF's page reader is 1.0.0, as it was when every format gained pages.
        let pdf = Book(title: "Outdated", format: .pdf, filePath: "/tmp/outdated.pdf", md5Hash: "m", folderPath: "")
        XCTAssertTrue(PageReaderVersions.isOutdated(pdf), "no page reader recorded")
        for (stored, outdated) in [("0.9.0", true), ("1", false), ("1.0.0", false), ("1.2.0", false), ("", true)] {
            var book = pdf
            book.pageReaderVersion = stored
            XCTAssertEqual(PageReaderVersions.isOutdated(book), outdated, "stored \"\(stored)\"")
        }
        // An EPUB's is 1.0.3, so a book any earlier reader stamped is
        // behind it.
        let epub = Book(title: "Outdated", format: .epub, filePath: "/tmp/outdated.epub", md5Hash: "m", folderPath: "")
        XCTAssertTrue(PageReaderVersions.isOutdated(epub), "no page reader recorded")
        for (stored, outdated) in [
            ("0.9.0", true), ("1", true), ("1.0.0", true), ("1.0.1", true), ("1.0.2", true), ("1.0.3", false),
            ("1.2.0", false),
        ] {
            var book = epub
            book.pageReaderVersion = stored
            XCTAssertEqual(PageReaderVersions.isOutdated(book), outdated, "stored \"\(stored)\" of an EPUB")
        }
        let notes = Book(title: "Notes", format: .markdown, filePath: "/tmp/notes.md", md5Hash: "m", folderPath: "")
        XCTAssertFalse(PageReaderVersions.isOutdated(notes))
    }

    /// A stamp's failure note is read with its version (PG16): a first
    /// failure is read once more, by this page reader or a newer one, never
    /// an older; a second is not, until a newer reader comes. A failed run
    /// stamps the first note, then the second, and a run that reads the
    /// pages stamps the version alone.
    func testAFailureNoteIsReadWithItsVersion() {
        // PDF stands for any format still at page reader 1.0.0 (this test
        // used .odt before OpenDocument text went to its own reader at 1.1.0);
        // the rule is the same for every format with pages.
        for (stored, outdated) in [
            ("1.0.0+failed-once", true), ("1.0.0+failed", false), ("9.0.0+failed-once", false), ("0.9.0+failed", true),
        ] {
            XCTAssertEqual(PageReaderVersions.isOutdated(format: .pdf, stored: stored), outdated, "stored \"\(stored)\"")
        }
        XCTAssertEqual(PageReaderVersions.stamp(for: .pdf, pageRunFailed: true, previous: nil), "1.0.0+failed-once")
        XCTAssertEqual(PageReaderVersions.stamp(for: .pdf, pageRunFailed: true, previous: "1.0.0+failed-once"), "1.0.0+failed")
        XCTAssertEqual(PageReaderVersions.stamp(for: .pdf, pageRunFailed: false, previous: "1.0.0+failed-once"), "1.0.0")
        XCTAssertNil(PageReaderVersions.stamp(for: .markdown, pageRunFailed: true, previous: nil))
        XCTAssertTrue(PageReaderVersions.notesFailure("1.0.0+failed"))
        XCTAssertFalse(PageReaderVersions.notesFailure("1.0.0"))
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
            for: fixture.book, index: index, cacheFormatVersion: nil, pageReaderVersion: .some(Self.epubReader)
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
            XCTAssertEqual(book.pageReaderVersion, Self.epubReader)
            XCTAssertEqual(book.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
            assertPlaces(of: book, areAt: Self.epubPlaces, in: content)
        }
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [], "the next launch would read it again")
    }

    /// A book whose text differs from its file's (a word replaced), which no
    /// edit record names, could hold an edit made before B12 or an older
    /// extraction, and nothing tells which (PG16 review): a copy of its
    /// content.md is kept as content.md.edited-<time>, and the book is read
    /// again with its pages, its places following their words. The log says
    /// so once, and a second pass picks nothing.
    func testAHybridKindleBookStoredFromItsMOBI6HalfIsReadAgainWithoutACopyAndItsPlacesFollow() async throws {
        // A Kindle book stored before .mobi had a page reader holds the MOBI 6 half's reading of a hybrid file. Read
        // from its KF8 half now, the same words are in other chapters with other headings: that is TextMouth's own
        // earlier text, not an edit, so no copy of it is kept (S6), and the places follow their words across the
        // two halves' different chapters.
        let world = try makeIntegrationWorld("Pages Upgrade Hybrid")
        let fixture = try makeBookBeforePages(
            sample: "mobi/pg8121-ghosts-hybrid.mobi", places: Self.ghostsPlaces, kindleHalf: .mobi6, in: world)
        XCTAssertEqual(fixture.oldText.chapters.count, 9, "the fixture holds the MOBI 6 half's chapters")
        XCTAssertEqual(try LibraryViewModel.pageUpgradeCheck(of: fixture.book, access: .live), .readAgain)

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        XCTAssertTrue(keptCopies(of: row).isEmpty, "a copy of text nobody edited was kept")
        XCTAssertTrue(debugLogLines(containing: "PAGES_REPLACED_TEXT: \(row.title)").isEmpty)
        XCTAssertEqual(row.pageReaderVersion, PageReaderVersions.current(for: .mobi))
        let content = try MarkdownCacheService.loadFromCache(for: row)
        // Four: the license piece at the end has no heading and repeats the title before it, so it goes on with ACT THIRD (S4).
        XCTAssertEqual(content.chapters.count, 4, "the book is read from its KF8 half now")
        assertPlaces(of: row, areAt: Self.ghostsPlaces, in: content)
    }

    func testAHybridKindleBookWhoseTextWasEditedIsStillCopied() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Hybrid Edited")
        let fixture = try makeBookBeforePages(
            sample: "mobi/pg8121-ghosts-hybrid.mobi", places: Self.ghostsPlaces,
            changingText: { $0.replacingOccurrences(of: "Th\u{E9}\u{E2}tre Libre", with: "Th\u{E9}\u{E2}tre Libre!") },
            kindleHalf: .mobi6, in: world)
        XCTAssertNotEqual(try LibraryViewModel.pageUpgradeCheck(of: fixture.book, access: .live), .readAgain)
    }

    func testChangedTextIsReadAgainWithPagesKeepingACopyOnce() async throws {
        let replaced = try await assertReplacedKeepingACopy("Pages Upgrade Changed") {
            $0.replacingOccurrences(of: "crate", with: "carton")
        }
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([replaced.row], access: .live), [])

        await runBatch(in: replaced.world)

        XCTAssertEqual(debugLogLines(containing: "PAGES_REPLACED_TEXT: \(replaced.row.title);").count, 1, "the second pass looked again")
        XCTAssertEqual(keptCopies(of: replaced.row).count, 1)
    }

    /// When no copy of differing text can be kept, the text is kept as it
    /// is, without pages, and recorded as edited (PG16), so a later automatic
    /// re-read keeps it as well: after a cache-format bump, which reads every
    /// other book's file again, it is still byte for byte what it was, and
    /// the bump says it kept it.
    func testDifferingTextNoCopyCanBeMadeOfIsKeptAndSurvivesABump() async throws {
        let copiesFailedBefore = PageUpgradeCopies._setCopiesFailForTesting(true)
        defer { PageUpgradeCopies._setCopiesFailForTesting(copiesFailedBefore) }
        let world = try makeIntegrationWorld("Pages Upgrade Kept Then Bumped")
        let fixture = try makeBookBeforePages(
            sample: Self.epubSample, changingText: { $0.replacingOccurrences(of: "crate", with: "carton") }, in: world
        )
        await runBatch(in: world)
        let kept = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: kept)), fixture.bytes, "the text was read over")
        XCTAssertTrue(try MarkdownCacheService.loadFromCache(for: kept).pages.isEmpty)
        XCTAssertEqual(kept.pageReaderVersion, Self.epubReader, "the row was not stamped")
        XCTAssertEqual(keptCopies(of: kept), [])
        XCTAssertEqual(debugLogLines(containing: "PAGES_SKIPPED_CHANGED_TEXT: \(kept.title)").count, 1)
        try assertRecordedAsEdited(kept, holding: fixture.bytes)

        // A later release's cache format: the row and its record both name
        // an older one, as every book's do after a bump.
        var bumped = kept
        bumped.cacheFormatVersion = "3.0.3"
        try bumped.saveBookInfoThrowing(contentIndex: XCTUnwrap(BookInfo.load(from: kept.tmbDirectory).contentIndex))
        LibraryPersistenceService.flushPendingSave()
        world.library.library.books = [bumped]
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([bumped], access: .live).map(\.id), [bumped.id])

        await runBatch(in: world)

        let cacheURL = MarkdownCacheService.cacheURL(for: bumped)
        XCTAssertEqual(try Data(contentsOf: cacheURL), fixture.bytes, "the bump read the book's file over the kept text")
        XCTAssertEqual(debugLogLines(containing: "TEXT_EDIT_KEPT: \(bumped.title):").count, 1)
        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        XCTAssertEqual(row.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        try assertRecordedAsEdited(row, holding: fixture.bytes)
    }

    /// A paragraph made a heading by hand changes no word, and is found: the
    /// whole content.md is compared, not only its reading text (PG16), and
    /// the text is copied before the book is read again.
    func testAParagraphMadeAHeadingIsCopiedBeforeTheReRead() async throws {
        try await assertReplacedKeepingACopy("Pages Upgrade Heading") {
            $0.replacingOccurrences(
                of: "(?m)^The coil was wound tight", with: "# The coil was wound tight", options: .regularExpression
            )
        }
    }

    /// A heading whose level was changed by hand is found and copied.
    func testAHeadingWithAnotherLevelIsCopiedBeforeTheReRead() async throws {
        try await assertReplacedKeepingACopy("Pages Upgrade Level") {
            $0.replacingOccurrences(of: "(?m)^## Opening the Crate", with: "### Opening the Crate", options: .regularExpression)
        }
    }

    /// A chapter renamed by hand in its `<!-- chapter: -->` line is found
    /// and copied.
    func testARenamedChapterIsCopiedBeforeTheReRead() async throws {
        try await assertReplacedKeepingACopy("Pages Upgrade Chapter") {
            $0.replacingOccurrences(
                of: MarkdownCacheService.chapterMarker(title: "Second Delivery"),
                with: MarkdownCacheService.chapterMarker(title: "The Second Delivery")
            )
        }
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
        XCTAssertEqual(row.pageReaderVersion, Self.epubReader)
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
            _ = try MarkdownCacheService.extractedMarkdown(for: book, includesPages: false)
            print("PAGES_COMPARISON_SECONDS: \(name): \(Date().timeIntervalSince(started))")
        }
    }

    /// A braille book read before pages is read again at the next launch,
    /// with every place where it was, since its pages add only markers, and
    /// gains its braille pages (PG12, V07): the Grade 1 sample's two, the
    /// second inside the paragraph it goes on. Its content.md is the file's
    /// text without pages, so no copy of it is kept, and it keeps its table.
    func testABrailleBookKeepsItsPlacesExactlyAndGainsItsBraillePages() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Braille")
        let fixture = try makeBrailleBookBeforePages(in: world)
        let before = try XCTUnwrap(fixture.book.readingPosition)
        let bookmarkBefore = try XCTUnwrap(fixture.book.bookmarks.first)

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        let content = try MarkdownCacheService.loadFromCache(for: row)
        XCTAssertEqual(content.pages.breaks.map(\.label), ["1", "2"])
        XCTAssertEqual(row.pageReaderVersion, PageReaderVersions.current(for: .braille))
        XCTAssertEqual(row.brailleTable, Self.brailleTable)
        // Not a number moved.
        XCTAssertEqual(row.readingPosition?.characterOffset, before.characterOffset)
        XCTAssertEqual(row.bookmarks.first?.characterOffset, bookmarkBefore.characterOffset)
        assertPlaces(of: row, areAt: Self.braillePlaces, in: content)
        XCTAssertEqual(keptCopies(of: row), [])
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [])
    }

    /// A BRL, which has no pages, shares braille's page reader (V07): read
    /// before pages, it is read again once at the next launch, keeps its
    /// content.md byte for byte, gains no pages, keeps no copy, and is
    /// stamped, so no later launch reads it.
    func testABRLIsReadAgainOnceKeepingItsTextAndIsStamped() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade BRL")
        let places = FixturePlaces(position: "taken it", bookmark: "Netherfield is taken", skippedHeading: nil)
        let fixture = try makeBrailleBookBeforePages(sample: "brl/pride-and-prejudice-ch1-grade1.brl", places: places, in: world)
        XCTAssertTrue(PageReaderVersions.isDueForPages(fixture.book))

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: row)), fixture.bytes)
        XCTAssertTrue(try MarkdownCacheService.loadFromCache(for: row).pages.isEmpty)
        XCTAssertEqual(row.pageReaderVersion, PageReaderVersions.current(for: .braille))
        XCTAssertEqual(keptCopies(of: row), [])
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [])
    }

    /// A braille book that cannot be read for its pages, because one of this
    /// Mac's tables it was read with has changed since (review R2: reading it
    /// again could move its text), keeps its text and is stamped
    /// "+failed-once"; the next launch tries once more and stamps "+failed",
    /// and no launch after that reads it.
    func testABrailleBookThatCannotBeReadIsStampedOnceThenForGood() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Braille Failure")
        let fixture = try makeBrailleBookBeforePages(adjustingBook: { book in
            book.brailleTable = "mac:fixture-changed.ctb"
            book.brailleTableVersion = "0.0.1-not-this-mac"
        }, in: world)
        XCTAssertTrue(PageReaderVersions.isDueForPages(fixture.book))
        let current = try XCTUnwrap(PageReaderVersions.current(for: .braille))

        await runBatch(in: world)
        let once = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        XCTAssertEqual(once.pageReaderVersion, current + "+failed-once")
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: once)), fixture.bytes)

        await runBatch(in: world)
        let twice = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        XCTAssertEqual(twice.pageReaderVersion, current + "+failed")
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: twice)), fixture.bytes)
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([twice], access: .live), [])
    }

    /// A plain text book read before pages is read again at the next launch
    /// and gains the pages its form feeds begin (PG13, V07), the sample's
    /// four, with every place where it was, since pages add only markers to
    /// plain text, and no copy of its text kept.
    func testAPlainTextBookGainsTheFormFeedPagesItHolds() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Form Feeds")
        let fixture = try makeBookBeforePages(sample: "txt-pages/form-feeds.txt", places: Self.formFeedPlaces, in: world)
        let before = try XCTUnwrap(fixture.book.readingPosition)

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        let content = try MarkdownCacheService.loadFromCache(for: row)
        XCTAssertEqual(content.pages.breaks.map(\.label), ["1", "2", "3", "4"])
        XCTAssertEqual(row.pageReaderVersion, PageReaderVersions.current(for: .txt))
        XCTAssertEqual(row.readingPosition?.characterOffset, before.characterOffset)
        assertPlaces(of: row, areAt: Self.formFeedPlaces, in: content)
        XCTAssertEqual(keptCopies(of: row), [])
    }

    /// A plain text book with no form feed between words, as most are, is
    /// read again once at the next launch, keeps its content.md byte for
    /// byte, gains no pages, and is stamped, so no later launch reads it.
    func testAPlainTextBookWithoutFormFeedsIsReadOnceAndKeepsItsText() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Plain Text")
        let places = FixturePlaces(position: "Mr. Bennet replied", bookmark: "Bingley.", skippedHeading: nil)
        let fixture = try makeBookBeforePages(sample: "brf/pride-and-prejudice-ch1.txt", places: places, in: world)
        XCTAssertTrue(PageReaderVersions.isDueForPages(fixture.book))

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: row)), fixture.bytes)
        XCTAssertTrue(try MarkdownCacheService.loadFromCache(for: row).pages.isEmpty)
        XCTAssertEqual(row.pageReaderVersion, PageReaderVersions.current(for: .txt))
        XCTAssertEqual(keptCopies(of: row), [])
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [])
    }

    /// A batch that stopped after writing a textutil document's content.md
    /// with pages leaves it differing from its record. When the next
    /// launch's run for the pages fails, nothing says whether that text is
    /// TextMouth's own (PG16 review, findings 2 and 3): the check neither
    /// takes it for TextMouth's text with pages, to stamp, nor leaves it to
    /// be taken for an edit saved while TextMouth was closed, but looks again
    /// at the next launch, whose run, when it works, finds TextMouth's own.
    func testAStoppedBatchsTextIsCheckedAgainWhenTheRunForPagesFails() throws {
        // These tests pin textutil's reading of the rich text sample, so the
        // sample is textutil's here (`OwnDocumentReaders.forcesTextutil`).
        try OwnDocumentReaders.$forcesTextutil.withValue(true) {
            let world = try makeIntegrationWorld("Pages Upgrade Stopped Textutil")
            let fixture = try makeBookBeforePages(
                sample: "rtf/page-breaks.rtf",
                places: FixturePlaces(position: "First page paragraph one", bookmark: "Third paragraph begins", skippedHeading: nil),
                in: world
            )
            let withPages = Data(try XCTUnwrap(MarkdownCacheService.extractedMarkdown(for: fixture.book, includesPages: true)).utf8)
            XCTAssertNotEqual(withPages, fixture.bytes, "the pages should change content.md")
            try withPages.write(to: MarkdownCacheService.cacheURL(for: fixture.book), options: .atomic)

            let failedRun = try TextutilConverter.$tool.withValue(Self.failingPageRun) {
                try LibraryViewModel.pageUpgradeCheck(of: fixture.book, access: .live)
            }
            XCTAssertEqual(failedRun, .tryAgainNextLaunch)
            XCTAssertEqual(try LibraryViewModel.pageUpgradeCheck(of: fixture.book, access: .live), .writtenWithPages)
        }
    }

    /// A book whose file is missing, or no longer extracts, gives nothing to
    /// compare its text with, nor pages to read (PG16). It keeps content.md
    /// byte for byte, is stamped with a failure note, not recorded as
    /// edited, and logged: a missing file once, and a file that could not be
    /// read, which may have failed only for a moment, at one more launch
    /// too (PG16 review, finding 5). After that, no launch chooses either
    /// book, where before each failed at every launch.
    func testABookWhoseFileIsMissingOrUnreadableIsStampedAndThenLeftAlone() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Unreadable")
        let missing = try makeBookBeforePages(sample: Self.epubSample, in: world)
        try FileManager.default.removeItem(at: missing.book.bookFileURL)
        let damaged = try makeBookBeforePages(
            sample: "pdf/labelled-pages.pdf", places: Self.pdfPlaces, damagingSource: true, in: world
        )
        world.library.library.books = [missing.book, damaged.book]

        await runBatch(in: world)
        let damagedOnce = try XCTUnwrap(world.library.bookByID(damaged.book.id))
        XCTAssertEqual(damagedOnce.pageReaderVersion, "1.0.0+failed-once", "a failed read is not tried once more")
        // The next launch reads the damaged file once more; the one after
        // chooses neither book.
        await runBatch(in: world)
        await runBatch(in: world)

        // Each book, how many launches logged it, and its stamp: "+failed"
        // after the version of its own format's page reader, which differs
        // for the EPUB and the PDF.
        for (fixture, launchesLogged, stamp) in [(missing, 1, Self.epubReader + "+failed"), (damaged, 2, "1.0.0+failed")] {
            let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
            XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: row)), fixture.bytes)
            XCTAssertEqual(row.pageReaderVersion, stamp)
            XCTAssertEqual(try BookInfo.load(from: row.tmbDirectory).state.pageReaderVersion, stamp)
            XCTAssertNil(row.editedText, "a book that could not be compared was recorded as edited")
            XCTAssertEqual(debugLogLines(containing: "PAGES_SKIPPED_UNREADABLE: \(row.title):").count, launchesLogged)
            XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [])
        }
        XCTAssertEqual(
            debugLogLines(containing: "PAGES_SKIPPED_UNREADABLE: \(missing.book.title): its file is missing").count, 1
        )
    }

    /// The batch ends with one line in the debug log that sums up its
    /// re-read for pages (PG16), which no listener hears: here one book
    /// given its pages, one kept as changed, and one skipped with its file
    /// missing. A batch that chooses no book for its pages says nothing of
    /// them.
    func testTheBatchSumsUpItsReReadForPagesInOneLine() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Summary")
        let plain = try makeBookBeforePages(sample: Self.epubSample, in: world)
        let changed = try makeBookBeforePages(
            sample: Self.epubSample, changingText: { $0.replacingOccurrences(of: "crate", with: "carton") }, in: world
        )
        let missing = try makeBookBeforePages(sample: "pdf/labelled-pages.pdf", places: Self.pdfPlaces, in: world)
        try FileManager.default.removeItem(at: missing.book.bookFileURL)
        world.library.library.books = [plain.book, changed.book, missing.book]
        let summary = "PAGES_UPGRADE_SUMMARY: 1 given pages, 1 replaced keeping a copy, 0 kept as changed, "
            + "1 skipped (0 in the cloud, 1 missing), 0 failed"
        let summariesBefore = debugLogLines(containing: summary).count

        await runBatch(in: world)

        XCTAssertEqual(debugLogLines(containing: summary).count, summariesBefore + 1)
        let anySummary = "PAGES_UPGRADE_SUMMARY:"
        let afterFirst = debugLogLines(containing: anySummary).count
        await runBatch(in: world)
        XCTAssertEqual(debugLogLines(containing: anySummary).count, afterFirst, "a batch that chose no book summed up pages")
    }

    /// textutil's run for a document's pages can fail or time out (PG16,
    /// finding 7). The document is then read without pages, and its page
    /// reader is not recorded as done: the next launch reads it once more.
    /// When that run fails too, the stamp says so, and no later launch
    /// reads the book again; when it works, the book gains its pages. Each
    /// launch's re-read runs this generation on the row it found.
    func testAFailedTextutilPageRunIsTriedAtOneMoreLaunch() throws {
        // These tests pin textutil's reading of the rich text sample, so the
        // sample is textutil's here (`OwnDocumentReaders.forcesTextutil`).
        try OwnDocumentReaders.$forcesTextutil.withValue(true) {
            // Rich text has a page reader of its own (1.1.0 since FMT47).
            let rtfReader = try XCTUnwrap(PageReaderVersions.current(for: .rtf))
            let world = try makeIntegrationWorld("Pages Upgrade Textutil")
            var book = try world.importBook(from: copyOfFormatSample("rtf/page-breaks.rtf"))
            book.title = "Pages Upgrade Textutil \(UUID().uuidString)"
            let failedLine = "PAGES_RUN_FAILED: \(book.title):"
            let cacheURL = MarkdownCacheService.cacheURL(for: book)

            // The first launch: the run for the pages fails.
            _ = try TextutilConverter.$tool.withValue(Self.failingPageRun) {
                try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &book)
            }
            XCTAssertEqual(book.pageReaderVersion, rtfReader + "+failed-once")
            XCTAssertTrue(PageReaderVersions.notesFailure(book.pageReaderVersion))
            XCTAssertTrue(try MarkdownCacheService.loadFromCache(for: book).pages.isEmpty)
            XCTAssertEqual(
                LibraryViewModel.booksNeedingCacheUpdate([book], access: .live).map(\.id), [book.id],
                "the next launch would not try again"
            )
            // content.md is the file's text without pages, which the next
            // launch's compare takes for TextMouth's own and reads again.
            let withoutPages = try XCTUnwrap(MarkdownCacheService.extractedMarkdown(for: book, includesPages: false))
            XCTAssertEqual(try Data(contentsOf: cacheURL), Data(withoutPages.utf8))

            // The next launch, where the run fails again: no later one tries.
            var failedAgain = book
            _ = try TextutilConverter.$tool.withValue(Self.failingPageRun) {
                try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &failedAgain)
            }
            XCTAssertEqual(failedAgain.pageReaderVersion, rtfReader + "+failed")
            XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([failedAgain], access: .live), [])
            XCTAssertEqual(debugLogLines(containing: failedLine).count, 2)

            // Or the next launch, where the run works: the book gains its pages.
            var succeeded = book
            _ = try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &succeeded)
            XCTAssertEqual(succeeded.pageReaderVersion, rtfReader)
            XCTAssertFalse(try MarkdownCacheService.loadFromCache(for: succeeded).pages.isEmpty, "the book gained no pages")
            XCTAssertEqual(debugLogLines(containing: failedLine).count, 2)
        }
    }

    /// A stand-in for textutil whose run for a document's pages, its plain
    /// text, fails at once, while its run for the HTML is Apple's own.
    private static let failingPageRun: TextutilConverter.Tool = {
        let real = TextutilConverter.Tool.textutil
        return TextutilConverter.Tool(
            command: { input, format, output in
                output.lastPathComponent.hasSuffix(TextutilConverter.plainTextTemporarySuffix)
                    ? (URL(fileURLWithPath: "/usr/bin/false"), [])
                    : real.command(input, format, output)
            },
            limits: real.limits,
            residentMemory: real.residentMemory
        )
    }()

    /// A batch that wrote a book's content.md with its pages and stopped
    /// before it committed the record, as a quit leaves it, is finished at
    /// the next launch (PG16): content.md is exactly what the file gives
    /// with pages, so it is TextMouth's own text. Only the row and the
    /// record are stamped; the text is not read again, nor taken for an
    /// edit saved while TextMouth was closed, and the places stay.
    func testTextWrittenWithPagesBeforeAStopIsOnlyStamped() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Stopped")
        let fixture = try makeBookBeforePages(sample: "pdf/labelled-pages.pdf", places: Self.pdfPlaces, in: world)
        // What the stopped batch wrote, while the record still describes the
        // text from before pages.
        let cacheURL = MarkdownCacheService.cacheURL(for: fixture.book)
        let withPages = Data(try XCTUnwrap(MarkdownCacheService.extractedMarkdown(for: fixture.book, includesPages: true)).utf8)
        XCTAssertNotEqual(withPages, fixture.bytes, "the pages should change content.md")
        try withPages.write(to: cacheURL, options: .atomic)

        await runBatch(in: world)

        XCTAssertEqual(try Data(contentsOf: cacheURL), withPages, "the text was written again")
        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        let record = try BookInfo.load(from: fixture.book.tmbDirectory).state
        XCTAssertEqual(row.pageReaderVersion, "1.0.0", "the row was not stamped")
        XCTAssertEqual(record.pageReaderVersion, "1.0.0", "the record was not stamped")
        XCTAssertNil(row.editedText, "TextMouth's own text was taken for an edit")
        XCTAssertNil(record.editedText, "TextMouth's own text was taken for an edit")
        XCTAssertEqual(row.readingPosition?.characterOffset, fixture.book.readingPosition?.characterOffset)
        XCTAssertEqual(row.bookmarks.first?.characterOffset, fixture.book.bookmarks.first?.characterOffset)
        let content = try MarkdownCacheService.loadFromCache(for: row)
        XCTAssertEqual(content.pages.breaks.map(\.label), ["i", "ii", "1", "2", "A-1"])
        assertPlaces(of: row, areAt: Self.pdfPlaces, in: content)
        XCTAssertEqual(debugLogLines(containing: "PAGES_SKIPPED_CHANGED_TEXT: \(row.title)").count, 0)
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [], "the next launch would look again")
    }

    // MARK: - Text an Earlier Page Reader Wrote (V05)

    /// A book an earlier page reader wrote, whose stamp notes no failure
    /// and whose content.md is as its record describes it, is read again
    /// with the newer reader, its places following their words, and no copy
    /// of its text is kept (V05). Compared, it would have been copied: it
    /// matches neither reading of its file, as after any change of a page
    /// reader, which would copy every book of the format.
    func testTextAnEarlierPageReaderWroteIsReadAgainWithoutACopy() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Earlier Reader")
        let fixture = try makeBookBeforePages(
            sample: Self.epubSample, withPages: true, changingText: Self.asAnEarlierReaderWroteIt,
            stamp: Self.earlierReader, in: world
        )
        let withPages = Data(try XCTUnwrap(MarkdownCacheService.extractedMarkdown(for: fixture.book, includesPages: true)).utf8)
        let withoutPages = Data(try XCTUnwrap(MarkdownCacheService.extractedMarkdown(for: fixture.book, includesPages: false)).utf8)
        XCTAssertNotEqual(fixture.bytes, withPages, "the text should differ from what the reader writes now")
        XCTAssertNotEqual(fixture.bytes, withoutPages, "the text should differ from the file's without pages")
        XCTAssertTrue(PageReaderVersions.isOutdated(fixture.book))
        XCTAssertEqual(try LibraryViewModel.pageUpgradeCheck(of: fixture.book, access: .live), .readAgain)

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: row)), withPages, "the book was not read again")
        XCTAssertEqual(keptCopies(of: row), [], "a copy was kept of text an earlier reader wrote")
        XCTAssertEqual(debugLogLines(containing: "PAGES_REPLACED_TEXT: \(row.title);").count, 0)
        XCTAssertEqual(row.pageReaderVersion, Self.epubReader, "the row was not stamped")
        XCTAssertEqual(try BookInfo.load(from: row.tmbDirectory).state.pageReaderVersion, Self.epubReader, "the record was not stamped")
        XCTAssertNil(row.editedText, "the text read again was recorded as an edit")
        assertPlaces(of: row, areAt: Self.epubPlaces, in: try MarkdownCacheService.loadFromCache(for: row))
    }

    /// The same text, when it is an edit Edit Text took (B12), is kept as it
    /// is: a stamp that notes no failure never reads over an edit.
    func testAnEditOfTextAnEarlierPageReaderWroteIsKept() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Earlier Reader Edit")
        let fixture = try makeBookBeforePages(
            sample: Self.epubSample, withPages: true, changingText: Self.asAnEarlierReaderWroteIt,
            recordingEdit: true, stamp: Self.earlierReader, in: world
        )

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: row)), fixture.bytes, "the edit was read over")
        XCTAssertEqual(keptCopies(of: row), [])
        try assertRecordedAsEdited(row, holding: fixture.bytes)
    }

    /// Text an earlier page reader wrote that changed since its record, as
    /// an edit saved while TextMouth was closed, is not read again without a
    /// look: the check for such an edit decides, as before V05, and takes it
    /// as the book's text.
    func testTextChangedSinceItsRecordIsLeftToTheEditCheck() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Earlier Reader Changed")
        let fixture = try makeBookBeforePages(
            sample: Self.epubSample, withPages: true, changingText: Self.asAnEarlierReaderWroteIt,
            stamp: Self.earlierReader, in: world
        )
        let cacheURL = MarkdownCacheService.cacheURL(for: fixture.book)
        let edited = Data(String(decoding: fixture.bytes, as: UTF8.self).replacingOccurrences(of: "crate", with: "carton").utf8)
        XCTAssertNotEqual(edited, fixture.bytes, "the edit should change the text")
        try edited.write(to: cacheURL, options: .atomic)
        XCTAssertEqual(try LibraryViewModel.pageUpgradeCheck(of: fixture.book, access: .live), .stale)

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        XCTAssertEqual(try Data(contentsOf: cacheURL), edited, "the edit saved while TextMouth was closed was read over")
        try assertRecordedAsEdited(row, holding: edited)
    }

    /// A batch that wrote a stamped book's content.md with the newer reader,
    /// then stopped before it committed the record, leaves text its record
    /// does not describe. The check still finds it the newer reader's own
    /// and only stamps the record (PG16), never taking it for an edit saved
    /// while TextMouth was closed, the risk the TODO's V06 names for a
    /// re-read without the compare.
    func testAStoppedBatchsTextForAStampedBookIsOnlyStamped() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Earlier Reader Stopped")
        let fixture = try makeBookBeforePages(
            sample: Self.epubSample, withPages: true, changingText: Self.asAnEarlierReaderWroteIt,
            stamp: Self.earlierReader, in: world
        )
        let cacheURL = MarkdownCacheService.cacheURL(for: fixture.book)
        let withPages = Data(try XCTUnwrap(MarkdownCacheService.extractedMarkdown(for: fixture.book, includesPages: true)).utf8)
        try withPages.write(to: cacheURL, options: .atomic)
        XCTAssertEqual(try LibraryViewModel.pageUpgradeCheck(of: fixture.book, access: .live), .writtenWithPages)

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        XCTAssertEqual(try Data(contentsOf: cacheURL), withPages)
        XCTAssertEqual(row.pageReaderVersion, Self.epubReader, "the row was not stamped")
        XCTAssertNil(row.editedText, "TextMouth's own text was taken for an edit")
        XCTAssertEqual(keptCopies(of: row), [])
    }

    /// The same text with no stamp, as from before pages, is compared as
    /// ever (PG16): it matches neither reading of its file, so a copy of it
    /// is kept before the book is read again.
    func testUnstampedTextIsComparedAsBefore() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Unstamped")
        let fixture = try makeBookBeforePages(
            sample: Self.epubSample, withPages: true, changingText: Self.asAnEarlierReaderWroteIt, in: world
        )

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        let copies = keptCopies(of: row)
        XCTAssertEqual(copies.count, 1, "the text without a stamp was not compared")
        XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, fixture.bytes)
        XCTAssertEqual(row.pageReaderVersion, Self.epubReader, "the row was not stamped")
    }

    /// A book stamped "+failed" by an earlier reader, while its file was
    /// missing, keeps its old text. Once its file is back and the reader has
    /// changed, the book is chosen again and compared, its stamp noting a
    /// failure: text changed by hand is copied before the book is read
    /// again, and text that is the file's own is read again with no copy.
    func testAFailedStampIsComparedOnceItsFileIsBack() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Failed Stamp")
        let failed = Self.earlierReader + "+failed"
        let changed = try makeBookBeforePages(
            sample: Self.epubSample, changingText: { $0.replacingOccurrences(of: "crate", with: "carton") },
            stamp: failed, in: world
        )
        let same = try makeBookBeforePages(sample: Self.epubSample, stamp: failed, in: world)
        world.library.library.books = [changed.book, same.book]
        XCTAssertTrue(PageReaderVersions.isOutdated(changed.book), "a newer reader should choose the book again")

        await runBatch(in: world)

        let changedRow = try XCTUnwrap(world.library.bookByID(changed.book.id))
        let copies = keptCopies(of: changedRow)
        XCTAssertEqual(copies.count, 1, "the text was not compared")
        XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, changed.bytes)
        let sameRow = try XCTUnwrap(world.library.bookByID(same.book.id))
        XCTAssertEqual(keptCopies(of: sameRow), [])
        for row in [changedRow, sameRow] {
            XCTAssertEqual(row.pageReaderVersion, Self.epubReader, "the row was not stamped")
            XCTAssertFalse(try MarkdownCacheService.loadFromCache(for: row).pages.isEmpty, "the book gained no pages")
        }
    }

    /// A "+failed-once" stamp keeps its meaning (PG16): the book is read once
    /// more, even at the current reader's version, and, its stamp noting a
    /// failure, its text is compared first.
    func testAFailedOnceStampIsReadOnceMoreAndCompared() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Failed Once")
        let fixture = try makeBookBeforePages(
            sample: Self.epubSample, changingText: { $0.replacingOccurrences(of: "crate", with: "carton") },
            stamp: Self.epubReader + "+failed-once", in: world
        )
        XCTAssertTrue(PageReaderVersions.isOutdated(fixture.book), "the book is not read once more")

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        XCTAssertEqual(keptCopies(of: row).count, 1, "the text was not compared")
        XCTAssertEqual(row.pageReaderVersion, Self.epubReader, "the row was not stamped")
    }

    // MARK: - Books open in a reader (ST01)

    /// A book a reader has open, which the batch reads again for its pages,
    /// shows its pages once the batch has: the reader takes the new text in
    /// place of the one it loaded, silently, with its cursor on the same
    /// words and the book's page reader recorded.
    func testABookOpenInAReaderShowsItsPagesOnceTheBatchReadsIt() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade Open Reader")
        let fixture = try makeBookBeforePages(sample: Self.epubSample, in: world)
        let reader = world.openReader(for: fixture.book)
        // This test is async, so the load, which ends on the main queue, is
        // waited for by yielding the main actor.
        await waitForReaderToLoadYielding(reader)
        // The reader registers its book as open as it loads.
        XCTAssertTrue(world.library.openBookIDs.contains(fixture.book.id))
        let noted = TextPlace(chapter: reader.currentChapterIndex, offset: reader.currentCharacterOffset)
        XCTAssertTrue(try XCTUnwrap(reader.content).pages.isEmpty, "the reader should start without pages")

        await runBatch(in: world)

        // The new text reaches the reader through the main queue, a moment
        // after the batch reports.
        let deadline = Date().addingTimeInterval(10)
        while reader.content?.chapters.contains(where: { !$0.pages.isEmpty }) != true && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(
            reader.content?.chapters.contains { !$0.pages.isEmpty } == true,
            "the reader never showed the book's pages"
        )
        let content = try XCTUnwrap(reader.content)
        XCTAssertEqual(reader.book.pageReaderVersion, Self.epubReader)
        // The cursor follows its words, in the same chapter. Its offset is
        // judged by the words there, not by the number: the second reading
        // removes the page number after a page break from the text.
        assertText(
            in: content, chapter: reader.currentChapterIndex, offset: reader.currentCharacterOffset,
            begins: Self.epubPlaces.position, "cursor", file: #filePath, line: #line
        )
        XCTAssertEqual(reader.currentChapterIndex, noted.chapter, "the cursor changed chapter")
    }

    /// A book no reader has open keeps no text for a reader: the batch reads
    /// it again as before, and its row and record gain the pages.
    func testABookNotOpenKeepsNoTextForAReader() async throws {
        let world = try makeIntegrationWorld("Pages Upgrade No Reader")
        let fixture = try makeBookBeforePages(sample: Self.epubSample, in: world)
        XCTAssertFalse(world.library.openBookIDs.contains(fixture.book.id))
        XCTAssertFalse(world.library.audioEditActivity.isOpenInReader(fixture.book.id))

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id))
        let content = try MarkdownCacheService.loadFromCache(for: row)
        XCTAssertFalse(content.pages.isEmpty, "the book gained no pages")
        XCTAssertEqual(row.pageReaderVersion, Self.epubReader)
        assertPlaces(of: row, areAt: Self.epubPlaces, in: content)
    }

    /// The batch reaches the books open in readers first, and keeps every
    /// other order as it was.
    func testOpenBooksComeFirstInTheBatch() {
        // One book per name, made apart so no subscript is needed.
        func book(_ name: String) -> Book { Book(title: name, format: .txt, filePath: "/\(name).txt", md5Hash: name) }
        let (a, b, c, d) = (book("a"), book("b"), book("c"), book("d"))
        let books = [a, b, c, d]

        XCTAssertEqual(LibraryViewModel.openBooksFirst(books, open: [c.id, a.id]).map(\.id), [a.id, c.id, b.id, d.id])
        XCTAssertEqual(LibraryViewModel.openBooksFirst(books, open: []).map(\.id), books.map(\.id))
        XCTAssertEqual(LibraryViewModel.openBooksFirst(books, open: [d.id]).map(\.id), [d.id, a.id, b.id, c.id])
    }

    // MARK: - The Switch

    /// The app ships with the launch re-read switched on (PG16): a book of a
    /// format with pages, from before pages, is due for them without the
    /// test seam.
    func testTheReReadIsSwitchedOnAsTheAppShipsIt() {
        XCTAssertTrue(PageReaderVersions.launchRereadIsOn)
        let epub = Book(title: "Before Pages", format: .epub, filePath: "/tmp/before-pages.epub", md5Hash: "m", folderPath: "")
        XCTAssertTrue(PageReaderVersions.isDueForPages(epub), "a book from before pages is not due for them")
    }

    /// With the launch re-read switched off, as a build may set it, the batch
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

    /// A book of a format without pages is never chosen for them: a
    /// Markdown file, which has pages only where it holds page lines (plain
    /// text was such a format until PG13 gave its form feeds pages).
    func testABookWithoutPagesIsNeverChosen() throws {
        let world = try makeIntegrationWorld("Pages Upgrade Text")
        let source = try makeSandboxDirectory("Pages Upgrade Text Source").appendingPathComponent("Plain Notes.md")
        try Data("Lamps were lit along the quay.\n".utf8).write(to: source)
        let book = try world.importBook(from: source)

        XCTAssertEqual(book.format, .markdown)
        XCTAssertNil(book.pageReaderVersion)
        XCTAssertFalse(PageReaderVersions.isOutdated(book))
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([book], access: .live), [])
    }

    // MARK: - Fixtures

    /// The EPUB sample with page-break elements, a TOC, and a page list.
    private static let epubSample = "epub3-pages/page-list.epub"

    /// The version of the EPUB page reader now, which every EPUB read by
    /// this TextMouth is stamped with.
    private static let epubReader = PageReaderVersions.current(for: .epub) ?? "none"

    /// The places the EPUB fixture saves, each by the words it begins at:
    /// after the page break "1", where the batch's second reading removes
    /// that number from the text.
    private static let epubPlaces = FixturePlaces(position: "somebody signed", bookmark: "coil of cable", skippedHeading: "Opening the Crate")

    /// The places the Ghosts fixture saves, which are in the MOBI 6 half's chapters (nine) and in the KF8 half's (five).
    private static let ghostsPlaces = FixturePlaces(
        position: "The mist still lies heavy over the landscape", bookmark: "Th\u{E9}\u{E2}tre Libre", skippedHeading: "ACT THIRD.")

    /// The places the PDF fixture saves.
    private static let pdfPlaces = FixturePlaces(position: "This is page four.", bookmark: "This is page five.", skippedHeading: nil)

    /// The table the braille fixture is imported with: the Grade 1 UEB its
    /// sample is written in.
    private static let brailleTable = "en-ueb-g1.ctb"

    /// The places the braille fixture saves: one on the second braille page,
    /// at its first words, inside the paragraph that goes on there.
    private static let braillePlaces = FixturePlaces(
        position: "taken it", bookmark: "Netherfield is taken", skippedHeading: "Chapter I"
    )

    /// The places the form feed fixture saves: one at page 2's first words,
    /// inside a paragraph, one at page 4's, and the heading before it.
    private static let formFeedPlaces = FixturePlaces(
        position: "before it crosses", bookmark: "In winter the evening", skippedHeading: "WINTER SERVICE"
    )

    /// The braille sample `sample` (the Grade 1 BRF unless named) as
    /// `makeBookBeforePages` leaves a book from before pages, with `places`
    /// and `adjustingBook` as it takes them, imported with the Grade 1 table
    /// the samples are written in.
    private func makeBrailleBookBeforePages(
        sample: String = "brf/pride-and-prejudice-ch1-grade1.brf",
        places: FixturePlaces = PagesUpgradeTests.braillePlaces,
        adjustingBook: ((inout Book) -> Void)? = nil,
        in world: IntegrationWorld
    ) throws -> BookBeforePages {
        try BraillePreferences.$tableForImports.withValue(Self.brailleTable) {
            try makeBookBeforePages(sample: sample, places: places, adjustingBook: adjustingBook, in: world)
        }
    }

    /// The stamp of a page reader earlier than any format's now, as a book
    /// carries once its format's reader has changed (V05): "0.9.0" stands
    /// for "1.0.2" once the reader is "1.0.3".
    private static let earlierReader = "0.9.0"

    /// The EPUB sample's text with pages as an earlier page reader wrote
    /// it, for V05: its first page is labelled otherwise than this reader
    /// labels it, so the text matches neither reading of the book's file,
    /// with pages or without, while its words are the same.
    private static let asAnEarlierReaderWroteIt: @Sendable (String) -> String = {
        $0.replacingOccurrences(of: "<!-- page: 1 -->", with: "<!-- page: one -->")
    }

    /// Where a fixture saves its position, its bookmark, and, when it has
    /// one, the heading it skips, each by the words there.
    private struct FixturePlaces {
        let position: String
        let bookmark: String
        let skippedHeading: String?
    }

    /// A book as it was before its format had pages, or, for V05, as an
    /// earlier page reader left it.
    private struct BookBeforePages {
        /// The book as its record holds it: no page reader (or the stamp the
        /// fixture gave), content.md without pages (or with them), and
        /// places saved in that text.
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
    /// bookmark, and a skipped heading saved at `places` in that text. With
    /// `damagingSource`, the book's file is then replaced by bytes no reader
    /// can read, which the record's fingerprint describes, as a file this
    /// build no longer extracts. With `withPages`, content.md is what the
    /// file gives with its page markers, which `changingText` can make an
    /// earlier page reader's (`asAnEarlierReaderWroteIt`), and `stamp` is
    /// the page reader the record names (V05). With `adjustingBook`, the row
    /// is changed as it says before its record is written. The book's title
    /// is made unique so that its log lines can be counted.
    private func makeBookBeforePages(
        sample: String,
        places: FixturePlaces? = nil,
        withPages: Bool = false,
        changingText: ((String) -> String)? = nil,
        recordingEdit: Bool = false,
        damagingSource: Bool = false,
        stamp: String? = nil,
        adjustingBook: ((inout Book) -> Void)? = nil,
        kindleHalf: MOBIBook.HybridChoice? = nil,
        in world: IntegrationWorld
    ) throws -> BookBeforePages {
        let places = places ?? Self.epubPlaces
        var book = try world.importBook(from: copyOfFormatSample(sample))
        book.title = "Pages Upgrade \(UUID().uuidString)"
        let cacheURL = MarkdownCacheService.cacheURL(for: book)

        // The text as it was written before pages, or with them.
        var markdown = try XCTUnwrap(
            MarkdownCacheService.extractedText(for: book, includesPages: withPages, kindleHalf: kindleHalf)?.markdown)
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

        if damagingSource {
            try Data("These bytes are no book at all.".utf8).write(to: book.bookFileURL, options: .atomic)
        }

        // The record describes that content.md as current, written by no
        // page reader, or by the one `stamp` names.
        var index = oldText.contentIndex.replacingFormat(book.format)
        index.textCacheFingerprint = TextCacheFingerprint(
            source: try XCTUnwrap(FileFingerprint(of: book.bookFileURL, hasher: .md5)),
            cache: try XCTUnwrap(FileFingerprint(of: cacheURL, hasher: .md5))
        )
        book.applyContentAnalysis(index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion)
        book.pageReaderVersion = stamp
        adjustingBook?(&book)
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

    /// Asserts that the batch, given an EPUB from before pages whose
    /// content.md `change` altered, keeps one copy of that content.md beside
    /// it holding its bytes, logs `PAGES_REPLACED_TEXT` naming the copy once,
    /// and reads the book again with its pages, its places on their words,
    /// stamped and recorded as no edit. The world is named `worldName`.
    /// - Returns: The world, the fixture, and the book's row after the batch.
    @discardableResult
    private func assertReplacedKeepingACopy(
        _ worldName: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        change: @escaping (String) -> String
    ) async throws -> (world: IntegrationWorld, fixture: BookBeforePages, row: Book) {
        let world = try makeIntegrationWorld(worldName)
        let fixture = try makeBookBeforePages(sample: Self.epubSample, changingText: change, in: world)

        await runBatch(in: world)

        let row = try XCTUnwrap(world.library.bookByID(fixture.book.id), file: file, line: line)
        let copies = keptCopies(of: row)
        XCTAssertEqual(copies.count, 1, "no copy of the text was kept", file: file, line: line)
        let copy = try XCTUnwrap(copies.first, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: copy), fixture.bytes, "the copy does not hold the text read over", file: file, line: line)
        XCTAssertEqual(
            debugLogLines(containing: "PAGES_REPLACED_TEXT: \(row.title); kept as \(copy.lastPathComponent)").count, 1,
            file: file, line: line
        )
        let content = try MarkdownCacheService.loadFromCache(for: row)
        XCTAssertFalse(content.pages.isEmpty, "the book gained no pages", file: file, line: line)
        XCTAssertEqual(row.pageReaderVersion, Self.epubReader, "the row was not stamped", file: file, line: line)
        XCTAssertNil(row.editedText, "the text read again was recorded as an edit", file: file, line: line)
        assertPlaces(of: row, areAt: Self.epubPlaces, in: content, file: file, line: line)
        return (world, fixture, row)
    }

    /// The copies of text kept beside `book`'s content.md, as
    /// content.md.edited- and a time (`BookTextEditSessions.keepCopy`).
    private func keptCopies(of book: Book) -> [URL] {
        LibraryIndexQuarantine.existingCopies(
            of: MarkdownCacheService.cacheURL(for: book),
            marker: TextMouthPaths.keptTextCopyMarker
        )
    }

    /// Asserts that `row` and its package record both record content.md,
    /// whose bytes are `bytes`, as an edit (`Book.editedText`, B12), which
    /// no automatic re-read replaces.
    private func assertRecordedAsEdited(
        _ row: Book, holding bytes: Data, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let digest = MaintenanceFileAccess.live.hasher.digestOfData(bytes)
        XCTAssertEqual(row.editedText?.cacheDigest, digest, "the row records no edit", file: file, line: line)
        XCTAssertEqual(
            try BookInfo.load(from: row.tmbDirectory).state.editedText?.cacheDigest, digest,
            "the record records no edit", file: file, line: line
        )
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
