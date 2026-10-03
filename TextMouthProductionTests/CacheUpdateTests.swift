import Combine
import XCTest
@testable import TextMouth

/// Exercise real cache writes, package checkpoints, and library progress in the
/// hosted test sandbox. No timing threshold or production library is required.
final class CacheUpdateTests: XCTestCase {
    /// A book counted as done is durable: its package record holds the
    /// analysis before progress counts it, so quitting or crashing during a
    /// long batch loses no work. Its row waits to change with others' (TODO
    /// PERF12), and every row has changed, and the index has been saved,
    /// once the batch ends.
    @MainActor
    func testAutomaticUpdateCommitsEachBookBeforeProgressAndEveryRowByTheEnd() async throws {
        preserveLibraryIndex()
        let books = try [makeBook(), makeBook()]
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: books)
        let firstCheckpoint = expectation(description: "First book counted")
        let finished = expectation(description: "Batch finished")
        let subscription = model.textExtraction.$current.filter { $0 == 1 }.prefix(1).sink { _ in
            let counted = books.first {
                (try? BookInfo.load(from: $0.tmbDirectory).state.cacheFormatVersion) == MarkdownCacheService.currentCacheVersion
            }
            XCTAssertNotNil(counted, "the counted book's record does not hold its analysis")
            firstCheckpoint.fulfill()
        }
        defer { subscription.cancel() }

        model.extractMissingContentCaches { finished.fulfill() }
        await fulfillment(of: [firstCheckpoint, finished], timeout: 10)

        XCTAssertFalse(model.isExtracting)
        XCTAssertEqual(model.textExtraction.current, 2)
        XCTAssertEqual(model.analysisSummaries.pendingCount, 0)
        XCTAssertTrue(model.library.books.allSatisfy { $0.contentIndexVersion == BookContentIndex.currentVersion })
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(
            LibraryPersistenceService.load().library?.books.map(\.cacheFormatVersion),
            books.map { _ in MarkdownCacheService.currentCacheVersion }
        )
    }

    /// A crash after bookInfo.json commits but before library.json saves must
    /// not reparse that source. A missing source makes this distinction observable.
    @MainActor
    func testAutomaticUpdateResumesCompletedPackageWithoutReadingSource() async throws {
        preserveLibraryIndex()
        let book = try makeBook()
        let savedIndex = try checkpoint(book)
        try FileManager.default.removeItem(atPath: book.filePath)
        let cache = book.tmbDirectory.appendingPathComponent("content.md")
        let priorBytes = try Data(contentsOf: cache)
        let priorDate = try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        let finished = expectation(description: "Checkpoint resumed")

        model.extractMissingContentCaches { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)

        XCTAssertEqual(model.library.books[0].cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertEqual(model.library.books[0].totalCharacterCount, savedIndex.totalCharacterCount)
        XCTAssertEqual(try Data(contentsOf: cache), priorBytes)
        XCTAssertEqual(try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, priorDate)
    }

    /// Redo Text Extraction explicitly requests new source content, even when
    /// an earlier package checkpoint would satisfy an automatic update.
    @MainActor
    func testManualUpdateRebuildsCompletedPackage() async throws {
        preserveLibraryIndex()
        let book = try makeBook()
        _ = try checkpoint(book)
        try "# Replacement\n\nFresh words.".write(toFile: book.filePath, atomically: true, encoding: .utf8)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        let finished = expectation(description: "Manual extraction finished")
        let subscription = model.textExtraction.$isExtracting.dropFirst().filter { !$0 }.prefix(1)
            .sink { _ in finished.fulfill() }
        defer { subscription.cancel() }

        model.redoAllTextExtraction()
        await fulfillment(of: [finished], timeout: 10)

        let content = try MarkdownCacheService.loadFromCache(for: book)
        XCTAssertEqual(content.allHeadings.map(\.text), ["Replacement"])
        XCTAssertTrue(content.allText.contains("Fresh words."))
    }

    /// Package metadata alone is not a completed checkpoint if its cache vanished.
    func testMissingCacheCannotReuseCompletedCheckpoint() throws {
        let book = try makeBook()
        _ = try checkpoint(book)
        try FileManager.default.removeItem(at: book.tmbDirectory.appendingPathComponent("content.md"))

        XCTAssertNil(BookContentAnalysisService.completedTextCacheIndex(for: book))
    }

    /// Both extraction and index revisions must be current before skipping work.
    func testOldIndexCannotReuseCompletedCheckpoint() throws {
        let book = try makeBook()
        var index = try checkpoint(book)
        index.version = "obsolete"
        var savedBook = book
        savedBook.cacheFormatVersion = MarkdownCacheService.currentCacheVersion
        try savedBook.saveBookInfoThrowing(contentIndex: index)

        XCTAssertNil(BookContentAnalysisService.completedTextCacheIndex(for: book))
    }

    /// Repeated actions cannot launch competing writers or reset live progress.
    @MainActor
    func testOverlappingAutomaticAndManualRequestsKeepActiveBatch() throws {
        let book = try makeBook()
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        model.textExtraction.begin("Updating text cache", total: 9)
        for _ in 0..<3 {
            model.textExtraction.advance()
        }

        model.extractMissingContentCaches()
        model.redoAllTextExtraction()

        XCTAssertEqual(model.textExtraction.current, 3)
        XCTAssertEqual(model.textExtraction.total, 9)
        XCTAssertFalse(MarkdownCacheService.cacheExists(for: book))
    }

    /// Returning generated content directly must match a later cache reload for
    /// plain text, Markdown chapter markers, and HTML with literal punctuation.
    func testGeneratedContentMatchesCacheReloadAcrossTextFormats() throws {
        let examples: [(BookFormat, String)] = [
            (.markdown, "<!-- chapter: First -->\n# Title\n\n🙂 Words.\n\n<!-- chapter: Second -->\nMore words."),
            (.txt, "OPENING\n\nText after the heading."),
            (.html, "<h1>Opening</h1><p>🙂 &lt;literal&gt; *punctuation*.</p>")
        ]
        for (format, source) in examples {
            let book = try makeBook(format: format, source: source)
            let generated = try XCTUnwrap(MarkdownCacheService.generateCacheContent(for: book))
            let reloaded = try MarkdownCacheService.loadFromCache(for: book)
            XCTAssertEqual(generated.title, reloaded.title)
            XCTAssertEqual(generated.chapters.map(\.text), reloaded.chapters.map(\.text))
            XCTAssertEqual(generated.allHeadings, reloaded.allHeadings)
            XCTAssertEqual(generated.contentIndex.chapters, reloaded.contentIndex.chapters)
            XCTAssertEqual(generated.contentIndex.format, format)
        }
    }

    /// A failed source read preserves the old readable cache and leaves the book
    /// eligible for retry instead of publishing a successful version checkpoint.
    @MainActor
    func testFailedAutomaticUpdateRetainsCacheAndOldVersion() async throws {
        preserveLibraryIndex()
        let book = try makeBook()
        let cache = book.tmbDirectory.appendingPathComponent("content.md")
        try "# Previous\n\nRetained text.".write(to: cache, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: book.filePath)
        let oldBytes = try Data(contentsOf: cache)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        let finished = expectation(description: "Failed book attempted")

        model.extractMissingContentCaches { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)

        XCTAssertFalse(model.isExtracting)
        XCTAssertEqual(model.library.books[0].cacheFormatVersion, "3.0.3")
        XCTAssertEqual(try Data(contentsOf: cache), oldBytes)
    }

    /// Changes confined to reading/index derivation can rebuild from Markdown;
    /// they must not require decompressing or even finding the original EPUB.
    func testIndexOnlyUpdateUsesExistingCacheWithoutSource() throws {
        var book = try makeBook()
        var index = try checkpoint(book)
        book.cacheFormatVersion = MarkdownCacheService.currentCacheVersion
        index.version = "obsolete"
        try book.saveBookInfoThrowing(contentIndex: index)
        try FileManager.default.removeItem(atPath: book.filePath)

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertFalse(result.usedPersistedIndex)
        XCTAssertEqual(result.index.version, BookContentIndex.currentVersion)
        XCTAssertEqual(result.content.allHeadings.map(\.text), ["Opening"])
    }

    /// Hold the first two workers until both start, proving real overlap, then
    /// verify the remaining work never exceeds the cap and finishes exactly once.
    func testEPUBWorkersOverlapWithinTwoBookLimit() throws {
        let books = try (0..<4).map { _ in try makeBook(format: .epub) }
        let probe = CacheWorkProbe()
        let gate = DispatchSemaphore(value: 0)
        let firstPair = expectation(description: "Two workers started")
        firstPair.expectedFulfillmentCount = 2
        let finished = expectation(description: "Every worker finished")

        TextCacheUpdateQueue.run(books: books, update: { _ in
            XCTAssertFalse(Thread.isMainThread)
            let state = probe.enter()
            XCTAssertLessThanOrEqual(state.active, 2)
            if state.started <= 2 { firstPair.fulfill() }
            gate.wait()
            probe.leave()
        }, completion: { finished.fulfill() })
        wait(for: [firstPair], timeout: 5)
        for _ in books { gate.signal() }
        wait(for: [finished], timeout: 5)

        XCTAssertEqual(probe.snapshot().peak, 2)
        XCTAssertEqual(probe.snapshot().completed, books.count)
    }

    /// A large source is a barrier: preceding work completes before it starts,
    /// and subsequent small EPUBs wait until its memory-intensive work returns.
    func testLargeEPUBRunsBetweenCompletedNeighbors() throws {
        let books = try (0..<3).map { _ in try makeBook(format: .epub) }
        let largeFile = try FileHandle(forWritingTo: URL(fileURLWithPath: books[1].filePath))
        try largeFile.truncate(atOffset: UInt64(TextCacheUpdateQueue.maximumParallelEPUBBytes + 1))
        try largeFile.close()
        let probe = CacheWorkProbe()
        let finished = expectation(description: "Barrier batch finished")

        TextCacheUpdateQueue.run(books: books, update: { book in
            let expectedPosition = books.firstIndex(where: { $0.id == book.id })!
            XCTAssertEqual(probe.snapshot().completed, expectedPosition)
            XCTAssertEqual(probe.enter().active, 1)
            probe.leave()
        }, completion: { finished.fulfill() })
        wait(for: [finished], timeout: 5)

        XCTAssertEqual(probe.snapshot().completed, books.count)
    }

    /// Two library entries referring to one package must never write its cache
    /// together, even though each entry would otherwise qualify for parallel work.
    func testRepeatedPackageRunsSequentially() throws {
        let book = try makeBook(format: .epub)
        let probe = CacheWorkProbe()
        let finished = expectation(description: "Repeated package finished")
        TextCacheUpdateQueue.run(books: [book, book], update: { _ in
            XCTAssertEqual(probe.enter().active, 1)
            probe.leave()
        }, completion: { finished.fulfill() })
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(probe.snapshot().completed, 2)
    }

    /// Keep the shared hosted-test library index intact after UI batch tests.
    private func preserveLibraryIndex() {
        LibraryPersistenceService.flushPendingSave()
        let previous = LibraryPersistenceService.load().library ?? Library()
        addTeardownBlock {
            LibraryPersistenceService.save(previous)
            LibraryPersistenceService.flushPendingSave()
        }
    }

    /// Create a disposable package whose library snapshot still predates 3.0.4.
    private func makeBook(format: BookFormat = .markdown, source: String = "# Opening\n\nSome words.") throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        let name = "CacheUpdate-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: name)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        let file = package.appendingPathComponent("source.\(format.fileExtensions.first ?? "md")")
        try source.write(to: file, atomically: true, encoding: .utf8)
        return Book(title: "Cache fixture", format: format, filePath: file.path,
                    md5Hash: UUID().uuidString, tmbDirectoryName: name, cacheFormatVersion: "3.0.3")
    }

    /// Commit the package while deliberately retaining an older library snapshot.
    private func checkpoint(_ book: Book) throws -> BookContentIndex {
        var completed = book
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &completed))
        try LibraryPersistenceService.saveContentAnalysis(
            for: completed, index: index, cacheFormatVersion: completed.cacheFormatVersion
        )
        return index
    }
}

/// Observe actual worker overlap without sharing unsynchronized test variables.
/// Every field is accessed under the lock, including snapshots used in assertions.
private final class CacheWorkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var started = 0
    private var peak = 0
    private var completed = 0

    /// Count entry and return the ordering needed for deterministic worker gates.
    func enter() -> (active: Int, started: Int) {
        lock.lock()
        defer { lock.unlock() }
        active += 1
        started += 1
        peak = max(peak, active)
        return (active, started)
    }

    /// Mark the update as complete before the queue signals batch completion.
    func leave() {
        lock.lock()
        defer { lock.unlock() }
        active -= 1
        completed += 1
    }

    /// Return a coherent view of observed concurrency and completion.
    func snapshot() -> (peak: Int, completed: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (peak, completed)
    }
}
