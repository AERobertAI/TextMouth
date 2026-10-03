import Combine
import XCTest
@testable import TextMouth

/// A book's text cache (content.md) and its index are trusted only while
/// they still describe the source they came from and each other (TODO T07).
/// Every cache write fingerprints the source and content.md; every load
/// checks those fingerprints, by size and modification time alone for an
/// unchanged book, before it trusts the cache or the saved index.
final class TextCacheVerificationTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox!

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
    }

    // MARK: - Writing a Cache

    /// Writing a cache fingerprints the source it read and the content.md it
    /// wrote: each file's size, modification time, and MD5 digest. The book
    /// takes the fingerprints with the rest of the analysis.
    func testWritingACacheFingerprintsItsSourceAndContentMarkdown() throws {
        var book = try makeBook()

        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &book))

        let fingerprint = try XCTUnwrap(index.textCacheFingerprint)
        try assertFingerprint(fingerprint, describesFilesOf: book)
        XCTAssertEqual(book.textCacheFingerprint, fingerprint)
    }

    /// An import records the fingerprints in the package record, beside the
    /// cache version and in the saved index, and on the book it returns.
    /// Publishing the staged package keeps every file's stamp, so the
    /// fingerprints still describe the published files.
    func testImportRecordsFingerprintsInTheRecordAndOnTheBook() throws {
        let imports = [
            try importBookFile(Data(Self.twoChapterSource.utf8), named: "Fingerprinted Import.md"),
            try importFixture("alice.epub"),
        ]

        for book in imports {
            let record = try BookInfo.load(from: book.tmbDirectory)
            let fingerprint = try XCTUnwrap(book.textCacheFingerprint, book.format.rawValue)
            XCTAssertEqual(record.state.textCacheFingerprint, fingerprint, book.format.rawValue)
            XCTAssertEqual(record.contentIndex?.textCacheFingerprint, fingerprint, book.format.rawValue)
            XCTAssertEqual(record.state.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
            try assertFingerprint(fingerprint, describesFilesOf: book)
        }
    }

    /// A failed write leaves the book exactly as it was: no version, no
    /// statistics, and no fingerprints claim a cache that was not written.
    func testFailedWriteRecordsNoFingerprints() throws {
        var book = try makeBook()
        try FileManager.default.removeItem(at: book.bookFileURL)
        let before = book

        XCTAssertNil(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &book))
        XCTAssertEqual(book, before)
    }

    // MARK: - Opening an Unchanged Book

    /// An unchanged book is verified by the sizes and dates of its source
    /// and content.md alone: opening it reads no file for a digest, reuses
    /// the saved index, and reports nothing.
    func testUnchangedBookOpensWithoutHashing() throws {
        let book = try makeCachedBook()
        let counter = CountingFingerprintHasher()

        let result = try BookContentAnalysisService.load(book: book, hasher: counter.hasher)

        XCTAssertTrue(result.usedPersistedIndex)
        XCTAssertEqual(result.index, try savedIndex(of: book))
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(staleReports(for: book), [])
        XCTAssertEqual(rejections(of: book), [])
    }

    /// A source rewritten with the same bytes (copied over itself, or
    /// touched) is read once for its digest, found unchanged, and keeps its
    /// cache; the result carries the new date for the caller to save, after
    /// which opening the book reads nothing again.
    func testTouchedSourceKeepsItsCacheAndRecordsItsNewDate() throws {
        let book = try makeCachedBook()
        let recorded = try XCTUnwrap(try savedIndex(of: book).textCacheFingerprint)
        try setModificationTime(of: book.bookFileURL, nanoseconds: recorded.source.modificationTimeNanoseconds + 1_000_000_000)
        let counter = CountingFingerprintHasher()

        let result = try BookContentAnalysisService.load(book: book, hasher: counter.hasher)

        XCTAssertFalse(result.usedPersistedIndex, "the new date must be saved")
        XCTAssertEqual(counter.fileCount, 1)
        XCTAssertEqual(staleReports(for: book), [])
        XCTAssertEqual(result.index.textCacheFingerprint?.source.stamp, FileStamp(of: book.bookFileURL))
        XCTAssertEqual(result.index.textCacheFingerprint?.cache, recorded.cache)
        try assertNextOpenReadsNothing(after: result, for: book)
    }

    // MARK: - Edited content.md

    /// content.md edited to the same length but other words is caught by its
    /// digest, since its date changed, and rebuilt from the source rather
    /// than trusted: the words, the index, and the fingerprints all follow
    /// the source again.
    func testContentMarkdownEditedToTheSameLengthIsRebuiltFromTheSource() throws {
        let book = try makeCachedBook()
        let recorded = try XCTUnwrap(try savedIndex(of: book).textCacheFingerprint)
        let cache = MarkdownCacheService.cacheURL(for: book)
        try editCache(of: book, replacing: "One two three.", with: "Two one three.")
        try setModificationTime(of: cache, nanoseconds: recorded.cache.modificationTimeNanoseconds + 1_000_000_000)
        XCTAssertEqual(FileStamp(of: cache)?.byteCount, recorded.cache.byteCount, "the edit keeps the length")

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertEqual(staleReports(for: book), ["CACHE_STALE: \(book.title): content.md changed"])
        XCTAssertFalse(result.usedPersistedIndex)
        XCTAssertEqual(result.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertTrue(result.content.chapters[0].text.contains("One two three."))
        XCTAssertTrue(try MarkdownCacheService.loadFromCache(for: book).allText.contains("One two three."))
        try assertFingerprint(try XCTUnwrap(result.index.textCacheFingerprint), describesFilesOf: book)
        try assertNextOpenReadsNothing(after: result, for: book)
    }

    /// An edit that kept content.md's size and even its date (as `touch -r`
    /// can) passes the stamps, but not the saved index: a renamed heading
    /// fails alignment, and content.md's digest then shows the edit, so the
    /// cache is rebuilt rather than indexed again.
    func testEditKeepingContentMarkdownsSizeAndDateIsCaughtByTheIndex() throws {
        let book = try makeCachedBook()
        let recorded = try XCTUnwrap(try savedIndex(of: book).textCacheFingerprint)
        try editCache(of: book, replacing: "## Later", with: "## Never")
        try setModificationTime(of: MarkdownCacheService.cacheURL(for: book), nanoseconds: recorded.cache.modificationTimeNanoseconds)
        let counter = CountingFingerprintHasher()

        let result = try BookContentAnalysisService.load(book: book, hasher: counter.hasher)

        // "Later" and "Never" differ from their first letter on, and are
        // named only by that place and their lengths.
        XCTAssertEqual(
            rejections(of: book),
            ["CONTENT_INDEX_REJECTED: \(book.title): chapters[1].headings[1].text differs from the reading "
                + "text's label at UTF-16 offset 0 (lengths 5 and 5)"]
        )
        XCTAssertEqual(staleReports(for: book), ["CACHE_STALE: \(book.title): content.md changed"])
        XCTAssertEqual(counter.dataCount, 1, "only the rejected index sends content.md to be digested")
        XCTAssertEqual(result.index.allHeadings.map(\.text), ["First", "Second", "Later"])
        XCTAssertFalse(result.usedPersistedIndex)
    }

    // MARK: - Replaced Source

    /// Replacing the book's file inside its package with another book of the
    /// same name is caught when the book opens: the cache is rebuilt from
    /// the new source, and its text, index, title, and headings all follow
    /// it. Once the result is saved, the next open takes the fast path.
    func testSourceReplacedByAnotherBookIsCaughtOnOpen() throws {
        let original = try writeEPUB(chapters: [
            ("The Ferry Timetable", "Departures were posted at noon."),
            ("Crates on the Quay", "Nobody claimed the third crate."),
        ])
        let book = try FileImportService.importFile(from: original)
        addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        let replacementHeadings = ["Inventory of Spoons", "A Ledger Misplaced", "Third Visit"]
        try writeEPUB(chapters: replacementHeadings.map { ($0, "Pages about \($0.lowercased()).") }, to: book.bookFileURL)

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertEqual(staleReports(for: book), ["CACHE_STALE: \(book.title): source changed"])
        XCTAssertFalse(result.usedPersistedIndex)
        XCTAssertEqual(result.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertEqual(result.content.title, "Inventory of Spoons")
        XCTAssertEqual(result.content.chapters.map(\.title), replacementHeadings)
        XCTAssertEqual(result.index.allHeadings.map(\.text), replacementHeadings)
        XCTAssertEqual(result.index.chapters.count, 3)
        XCTAssertEqual(try MarkdownCacheService.loadFromCache(for: book).allHeadings.map(\.text), replacementHeadings)
        try assertFingerprint(try XCTUnwrap(result.index.textCacheFingerprint), describesFilesOf: book)
        try assertNextOpenReadsNothing(after: result, for: book)
    }

    /// A source replaced by one of exactly the same size, with a new date,
    /// is read for its digest, which shows the change.
    func testSourceReplacedBySameSizeFileIsCaughtByItsDigest() throws {
        let book = try makeCachedBook()
        let source = try String(contentsOf: book.bookFileURL, encoding: .utf8)
        try source.replacingOccurrences(of: "Four five.", with: "Five four.")
            .write(to: book.bookFileURL, atomically: true, encoding: .utf8)
        let recorded = try XCTUnwrap(try savedIndex(of: book).textCacheFingerprint)
        try setModificationTime(of: book.bookFileURL, nanoseconds: recorded.source.modificationTimeNanoseconds + 1_000_000_000)
        XCTAssertEqual(FileStamp(of: book.bookFileURL)?.byteCount, recorded.source.byteCount)
        let counter = CountingFingerprintHasher()

        let result = try BookContentAnalysisService.load(book: book, hasher: counter.hasher)

        XCTAssertEqual(counter.fileCount, 1)
        XCTAssertEqual(staleReports(for: book), ["CACHE_STALE: \(book.title): source changed"])
        XCTAssertTrue(result.content.chapters[1].text.contains("Five four."))
    }

    /// A missing source is no reason to distrust the cache, which is then
    /// the only copy of the text: the book opens from it, unreported.
    func testMissingSourceKeepsTheCache() throws {
        let book = try makeCachedBook()
        try FileManager.default.removeItem(at: book.bookFileURL)

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertTrue(result.usedPersistedIndex)
        XCTAssertEqual(staleReports(for: book), [])
        XCTAssertEqual(result.index.allHeadings.map(\.text), ["First", "Second", "Later"])
    }

    /// When a stale cache cannot be rebuilt because its source cannot be
    /// read, the book still opens with the cache as it is, and keeps the
    /// fingerprints it was written with, so the next open tries again
    /// instead of trusting the edit.
    func testStaleCacheThatCannotBeRebuiltIsReadAsItIsAndTriedAgain() throws {
        let book = try makeCachedBook()
        let recorded = try XCTUnwrap(try savedIndex(of: book).textCacheFingerprint)
        try editCache(of: book, replacing: "Six seven eight.", with: "Six seven eight. Nine ten.")
        try makeUnreadable(book.bookFileURL)

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertTrue(result.content.chapters[1].text.hasSuffix("Nine ten."))
        XCTAssertEqual(result.index.textCacheFingerprint, recorded)
        XCTAssertFalse(result.usedPersistedIndex, "the edited text needs its own index")
        XCTAssertNil(result.index.alignmentFailure(with: result.content.chapters))

        try LibraryPersistenceService.saveContentAnalysis(
            for: book, index: result.index, cacheFormatVersion: result.cacheFormatVersion
        )
        _ = try BookContentAnalysisService.load(book: book)
        XCTAssertEqual(staleReports(for: book).count, 2)
    }

    // MARK: - Index Disagreeing With Its Text

    /// An index whose headings disagree with the text it is paired with is
    /// indexed again, with the reason naming the heading by its place, never
    /// by its label. content.md still holds what was written, as one digest
    /// of it confirms, so it is not rebuilt.
    func testIndexWhoseHeadingsDisagreeIsReindexedNamingTheHeading() throws {
        let book = try makeCachedBook()
        var relabeled = try savedIndex(of: book)
        relabeled.chapters[1].headings[1].text = "Sooner"
        relabeled.chapters[1].headings[1].id = "relabeled"
        try book.saveBookInfoThrowing(contentIndex: relabeled)
        let counter = CountingFingerprintHasher()

        let result = try BookContentAnalysisService.load(book: book, hasher: counter.hasher)

        // The index's "Sooner" (6 long) against the text's "Later" (5).
        XCTAssertEqual(
            rejections(of: book),
            ["CONTENT_INDEX_REJECTED: \(book.title): chapters[1].headings[1].text differs from the reading "
                + "text's label at UTF-16 offset 0 (lengths 6 and 5)"]
        )
        XCTAssertEqual(staleReports(for: book), [])
        XCTAssertEqual(counter.dataCount, 1)
        XCTAssertEqual(counter.fileCount, 0)
        XCTAssertFalse(result.usedPersistedIndex)
        XCTAssertEqual(result.index.allHeadings.map(\.text), ["First", "Second", "Later"])
        XCTAssertEqual(result.index.textCacheFingerprint, relabeled.textCacheFingerprint)
        try assertNextOpenReadsNothing(after: result, for: book)
    }

    // MARK: - Caches Written Before Fingerprints

    /// A book whose package records no fingerprints, as every book written
    /// before them, opens from its cache as before. That first open, once
    /// the saved index passes every check, reads both files once to
    /// fingerprint them; once the result is saved, every later open
    /// compares stamps alone.
    func testCacheWithoutFingerprintsIsFingerprintedOnceThenTakesTheFastPath() throws {
        let book = try makeLegacyCachedBook()
        let counter = CountingFingerprintHasher()

        let result = try BookContentAnalysisService.load(book: book, hasher: counter.hasher)

        XCTAssertEqual(counter.fileCount, 1, "the source")
        XCTAssertEqual(counter.dataCount, 1, "content.md, from the bytes already read")
        XCTAssertFalse(result.usedPersistedIndex, "the fingerprints must be saved")
        XCTAssertEqual(staleReports(for: book), [])
        XCTAssertEqual(rejections(of: book), [])
        try assertFingerprint(try XCTUnwrap(result.index.textCacheFingerprint), describesFilesOf: book)
        try assertNextOpenReadsNothing(after: result, for: book)
    }

    // MARK: - Resuming an Interrupted Batch

    /// A batch resuming after a crash recovers a package's committed cache
    /// only while it still describes its source: a stale one is reported
    /// and rebuilt instead.
    func testInterruptedBatchDoesNotRecoverAStaleCache() throws {
        let book = try makeCachedBook()
        XCTAssertEqual(BookContentAnalysisService.completedTextCacheIndex(for: book), try savedIndex(of: book))

        try "# Replacement\n\nA different and longer book.".write(to: book.bookFileURL, atomically: true, encoding: .utf8)

        XCTAssertNil(BookContentAnalysisService.completedTextCacheIndex(for: book))
        XCTAssertEqual(staleReports(for: book), ["CACHE_STALE: \(book.title): source changed"])
    }

    // MARK: - Startup Maintenance

    /// The startup batch rebuilds a cache whose source changed size, as it
    /// rebuilds an outdated one: the batch reports it and rebuilds it from
    /// the source, and the library row and the package record the new
    /// fingerprints. The next batch has nothing to do.
    @MainActor
    func testStartupBatchRebuildsAResizedCacheOnce() async throws {
        let book = try makeCachedBook()
        try "# Replacement\n\nA different and longer book.".write(to: book.bookFileURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(LibraryViewModel.hasResizedTextCacheFile(book))
        let model = makeModel(with: [book])

        await runStartupBatch(of: model)

        XCTAssertEqual(model.textExtraction.total, 1)
        XCTAssertEqual(staleReports(for: book), ["CACHE_STALE: \(book.title): source changed"])
        XCTAssertEqual(try MarkdownCacheService.loadFromCache(for: book).allHeadings.map(\.text), ["Replacement"])
        let row = try XCTUnwrap(model.bookByID(book.id))
        let fingerprint = try XCTUnwrap(row.textCacheFingerprint)
        try assertFingerprint(fingerprint, describesFilesOf: book)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).state.textCacheFingerprint, fingerprint)
        XCTAssertFalse(LibraryViewModel.hasResizedTextCacheFile(row))

        model.extractMissingContentCaches()
        XCTAssertFalse(model.isExtracting, "a rebuilt cache is not queued again")
        XCTAssertEqual(staleReports(for: book).count, 1)
    }

    /// An edited content.md of another size is rebuilt at startup as well.
    @MainActor
    func testStartupBatchRebuildsAResizedContentMarkdown() async throws {
        let book = try makeCachedBook()
        try editCache(of: book, replacing: "Six seven eight.", with: "Six seven eight. Nine ten.")
        let model = makeModel(with: [book])

        await runStartupBatch(of: model)

        XCTAssertEqual(staleReports(for: book), ["CACHE_STALE: \(book.title): content.md changed"])
        XCTAssertFalse(try MarkdownCacheService.loadFromCache(for: book).allText.contains("Nine ten."))
    }

    /// A library row can lag its package: a crash after the package recorded
    /// a rebuilt cache, but before library.json was saved, leaves the row
    /// with the old fingerprints, which no longer match the files. The batch
    /// then finds the package's own fingerprints matching and recovers its
    /// cache instead of rebuilding it: nothing is reported or rewritten, and
    /// the row takes the package's fingerprints.
    @MainActor
    func testStartupBatchRecoversAPackageNewerThanItsRow() async throws {
        let row = try makeCachedBook()
        try "# Second Edition\n\nA longer book than the first.".write(to: row.bookFileURL, atomically: true, encoding: .utf8)
        var rebuilt = row
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &rebuilt))
        try LibraryPersistenceService.saveContentAnalysis(
            for: rebuilt, index: index, cacheFormatVersion: rebuilt.cacheFormatVersion
        )
        let packageFingerprint = try XCTUnwrap(index.textCacheFingerprint)
        XCTAssertTrue(LibraryViewModel.hasResizedTextCacheFile(row), "the row's fingerprints are the old ones")
        let cacheStamp = FileStamp(of: MarkdownCacheService.cacheURL(for: row))
        let model = makeModel(with: [row])

        await runStartupBatch(of: model)

        XCTAssertEqual(model.textExtraction.total, 1)
        XCTAssertEqual(staleReports(for: row), [])
        XCTAssertEqual(FileStamp(of: MarkdownCacheService.cacheURL(for: row)), cacheStamp, "content.md was not rewritten")
        XCTAssertEqual(model.bookByID(row.id)?.textCacheFingerprint, packageFingerprint)
    }

    /// Nothing changes for a book whose files match their fingerprints, nor
    /// for one whose source only has a new date, which its next open reads
    /// for a digest: no batch starts, and neither content.md is rewritten.
    @MainActor
    func testStartupBatchLeavesUnchangedAndTouchedCachesAlone() throws {
        let unchanged = try makeCachedBook()
        let touched = try makeCachedBook()
        let recorded = try XCTUnwrap(touched.textCacheFingerprint)
        try setModificationTime(of: touched.bookFileURL, nanoseconds: recorded.source.modificationTimeNanoseconds + 1_000_000_000)
        let books = [unchanged, touched]
        let cacheStamps = books.map { FileStamp(of: MarkdownCacheService.cacheURL(for: $0)) }
        let model = makeModel(with: books)

        model.extractMissingContentCaches()

        XCTAssertFalse(model.isExtracting)
        XCTAssertEqual(books.map { FileStamp(of: MarkdownCacheService.cacheURL(for: $0)) }, cacheStamps)
    }

    // MARK: - Fingerprinting Older Caches in the Background

    /// Only a text book with a current cache and no fingerprints needs them:
    /// not one already fingerprinted, nor an outdated cache (which the cache
    /// batch rebuilds, fingerprinted), an audio book, or a book without a
    /// package.
    func testOnlyCurrentUnfingerprintedTextCachesNeedFingerprints() throws {
        let legacy = try makeLegacyCachedBook()
        XCTAssertTrue(LibraryViewModel.needsTextCacheFingerprint(legacy))
        XCTAssertTrue(LibraryViewModel.needsContentAnalysis(legacy))

        var fingerprinted = legacy
        fingerprinted.textCacheFingerprint = TextCacheFingerprint(
            source: FileFingerprint(stamp: FileStamp(byteCount: 1, modificationTimeNanoseconds: 1), digest: "source"),
            cache: FileFingerprint(stamp: FileStamp(byteCount: 2, modificationTimeNanoseconds: 2), digest: "cache")
        )
        XCTAssertFalse(LibraryViewModel.needsTextCacheFingerprint(fingerprinted))
        XCTAssertFalse(LibraryViewModel.needsContentAnalysis(fingerprinted))

        var outdated = legacy
        outdated.cacheFormatVersion = "3.0.3"
        var audio = legacy
        audio.format = .audio
        var unpackaged = legacy
        unpackaged.tmbDirectoryName = ""
        for book in [outdated, audio, unpackaged] {
            XCTAssertFalse(LibraryViewModel.needsTextCacheFingerprint(book))
        }
    }

    /// The statistics pass fingerprints a cache written before fingerprints
    /// in the background: the library row and the package record the
    /// fingerprints of the files as they are, and the book then needs
    /// nothing more.
    @MainActor
    func testStatisticsPassFingerprintsAnOlderCache() async throws {
        let book = try makeLegacyCachedBook()
        let model = makeModel(with: [book])
        let fingerprinted = expectation(description: "The row received its fingerprints")
        let subscription = model.$library
            .first { $0.books.first?.textCacheFingerprint != nil }
            .sink { _ in fingerprinted.fulfill() }
        defer { subscription.cancel() }

        model.calculateMissingBookStats()
        await fulfillment(of: [fingerprinted], timeout: 10)
        LibraryPersistenceService.flushPendingSave()

        let row = try XCTUnwrap(model.bookByID(book.id))
        let fingerprint = try XCTUnwrap(row.textCacheFingerprint)
        try assertFingerprint(fingerprint, describesFilesOf: book)
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.state.textCacheFingerprint, fingerprint)
        XCTAssertEqual(record.contentIndex?.textCacheFingerprint, fingerprint)
        XCTAssertFalse(LibraryViewModel.needsContentAnalysis(row))
        XCTAssertEqual(staleReports(for: book), [])
    }

    // MARK: - Fixtures

    /// A library model listing `books`, without the app's services.
    @MainActor
    private func makeModel(with books: [Book]) -> LibraryViewModel {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: books)
        return model
    }

    /// Runs the startup cache batch of `model` to its end, then writes every
    /// pending save.
    @MainActor
    private func runStartupBatch(of model: LibraryViewModel) async {
        let finished = expectation(description: "The startup batch finished")
        model.extractMissingContentCaches { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)
        LibraryPersistenceService.flushPendingSave()
    }

    /// Two chapters with a heading each and a subheading in the second, so
    /// offsets between chapters and heading labels are observable.
    private static let twoChapterSource = """
    <!-- chapter: First -->
    # First

    One two three.

    <!-- chapter: Second -->
    # Second

    Four five.

    ## Later

    Six seven eight.
    """

    /// A Markdown book holding `source` in a new package in the test
    /// library, as an import leaves it before its cache is written. The
    /// package is removed when the test ends; the title is unique, so each
    /// test finds only its own debug log lines.
    private func makeBook(source: String = twoChapterSource, fileName: String = "book.md") throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        let name = "CacheVerification-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: name)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        let file = package.appendingPathComponent(fileName)
        try source.write(to: file, atomically: true, encoding: .utf8)
        return Book(
            title: "Verified Fixture \(UUID().uuidString)",
            format: BookFormat.detect(from: file) ?? .markdown,
            filePath: file.path,
            md5Hash: try FileImportService.md5Hash(of: file),
            tmbDirectoryName: name
        )
    }

    /// A Markdown book as a completed import leaves it: its cache written,
    /// and its index and fingerprints saved through the analysis path.
    private func makeCachedBook() throws -> Book {
        var book = try makeBook()
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &book))
        try LibraryPersistenceService.saveContentAnalysis(
            for: book, index: index, cacheFormatVersion: book.cacheFormatVersion
        )
        return book
    }

    /// A cached book whose package and library row record no fingerprints,
    /// as TextMouth left every book before it kept them.
    private func makeLegacyCachedBook() throws -> Book {
        var book = try makeCachedBook()
        var index = try savedIndex(of: book)
        index.textCacheFingerprint = nil
        book.textCacheFingerprint = nil
        try book.saveBookInfoThrowing(contentIndex: index)
        XCTAssertNil(try BookInfo.load(from: book.tmbDirectory).state.textCacheFingerprint)
        return book
    }

    /// The index saved in `book`'s package.
    private func savedIndex(of book: Book) throws -> BookContentIndex {
        try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).contentIndex)
    }

    /// Replaces `old`, which must be there, with `new` in `book`'s
    /// content.md, as editing it by hand would.
    private func editCache(of book: Book, replacing old: String, with new: String) throws {
        let cache = MarkdownCacheService.cacheURL(for: book)
        let text = try String(contentsOf: cache, encoding: .utf8)
        XCTAssertTrue(text.contains(old), "content.md does not hold \(old)")
        try text.replacingOccurrences(of: old, with: new).write(to: cache, atomically: true, encoding: .utf8)
    }

    /// Takes every permission away from the file at `url`, so nothing can
    /// read it, and gives them back when the test ends.
    private func makeUnreadable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
    }

    /// Writes an EPUB of `chapters` (see `writeEPUB(chapters:to:)`) as
    /// "Same Name.epub" in a new scratch folder, removed when the test ends.
    private func writeEPUB(chapters: [(heading: String, body: String)]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheVerificationEPUB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Same Name.epub")
        try writeEPUB(chapters: chapters, to: url)
        return url
    }

    /// Writes an EPUB to `url`, replacing any file there: one XHTML document
    /// per chapter, opening with the chapter's heading, in spine order. Its
    /// title is unique, so a book imported from it, named after it, finds
    /// only its own lines in the debug log.
    private func writeEPUB(chapters: [(heading: String, body: String)], to url: URL) throws {
        let manifest = chapters.indices.map {
            #"<item id="c\#($0)" href="chapter\#($0).xhtml" media-type="application/xhtml+xml"/>"#
        }.joined()
        let spine = chapters.indices.map { #"<itemref idref="c\#($0)"/>"# }.joined()
        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "OEBPS/content.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>Fingerprint Fixture \(UUID().uuidString.prefix(8))</dc:title>
            <dc:creator>Odalys Brandvold</dc:creator><dc:language>en</dc:language>
            </metadata>
            <manifest>\(manifest)</manifest>
            <spine>\(spine)</spine>
            </package>
            """.utf8),
        ]
        for (number, chapter) in chapters.enumerated() {
            entries["OEBPS/chapter\(number).xhtml"] = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(chapter.heading)</title></head>
            <body><h1>\(chapter.heading)</h1><p>\(chapter.body)</p></body></html>
            """.utf8)
        }
        let zip = try makeTemporaryZip(prefix: "CacheVerification", entries: entries)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: zip, to: url)
    }

    /// The debug log's `CACHE_STALE` reports about `book`, each from its tag
    /// onwards (without the timestamp).
    private func staleReports(for book: Book) -> [String] {
        logLines(tagged: "CACHE_STALE", about: book)
    }

    /// The debug log's `CONTENT_INDEX_REJECTED` reports about `book`, each
    /// from its tag onwards.
    private func rejections(of book: Book) -> [String] {
        logLines(tagged: "CONTENT_INDEX_REJECTED", about: book)
    }

    /// The debug log's lines tagged `tag` about `book`, each from the tag
    /// onwards.
    private func logLines(tagged tag: String, about book: Book) -> [String] {
        debugLogLines(containing: "\(tag): \(book.title):").compactMap { line in
            line.range(of: "\(tag):").map { String(line[$0.lowerBound...]) }
        }
    }

    /// Saves `result` as the reader and the statistics pass save a load's
    /// result, then asserts that the next open verifies the book by stamps
    /// alone and reuses exactly that index.
    private func assertNextOpenReadsNothing(
        after result: BookContentAnalysisService.Result,
        for book: Book,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try LibraryPersistenceService.saveContentAnalysis(
            for: book, index: result.index, cacheFormatVersion: result.cacheFormatVersion
        )
        let counter = CountingFingerprintHasher()
        let reopened = try BookContentAnalysisService.load(book: book, hasher: counter.hasher)
        XCTAssertTrue(reopened.usedPersistedIndex, file: file, line: line)
        XCTAssertEqual(reopened.index, result.index, file: file, line: line)
        XCTAssertEqual(counter.count, 0, file: file, line: line)
    }

    /// Imports the TestData fixture `name` through the production path,
    /// removing its package when the test ends.
    private func importFixture(_ name: String) throws -> Book {
        let book = try FileImportService.importFile(from: requireFile(name))
        addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        return book
    }

    /// Asserts that `fingerprint` records the stamps the files of `book`'s
    /// text cache have now and the MD5 digests of their bytes.
    private func assertFingerprint(
        _ fingerprint: TextCacheFingerprint,
        describesFilesOf book: Book,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let cache = MarkdownCacheService.cacheURL(for: book)
        XCTAssertEqual(fingerprint.source.stamp, FileStamp(of: book.bookFileURL), file: file, line: line)
        XCTAssertEqual(fingerprint.source.digest, try FileImportService.md5Hash(of: book.bookFileURL), file: file, line: line)
        XCTAssertEqual(fingerprint.cache.stamp, FileStamp(of: cache), file: file, line: line)
        XCTAssertEqual(fingerprint.cache.digest, try FileImportService.md5Hash(of: cache), file: file, line: line)
    }
}
