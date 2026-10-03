import Combine
import XCTest
@testable import TextMouth

/// The text cache batch and Redo Text Extraction in a cloud library (FR02):
/// a book any of whose files the pass reads is in the cloud is left as it
/// is and counted in the pass's one `MAINTENANCE_SKIPPED_IN_CLOUD` line, and
/// a read refused for a dataless file is never a failure, an omission, a
/// rebuild, or a record write. The first test is the verification test that
/// showed the behavior before the fix: a cache format change read a dataless
/// book and rebuilt its cache.
final class CloudMaintenanceCacheBatchTests: CloudMaintenanceTestCase {

    // MARK: - Verification

    /// A cache format change leaves a book whose source is dataless in the
    /// cloud: the batch never reads it, writes no cache, keeps the row's
    /// format version, and counts it in its one skip line. (Before the fix,
    /// the source was read and a cache written.)
    @MainActor
    func testFormatChangeLeavesADatalessBookInTheCloud() async throws {
        let book = try makePackagedBook()
        cloud.markDataless(book.bookFileURL)
        let extracted = BookIDRecorder()
        MarkdownCacheService.extractionObserver = { extracted.record($0.id) }
        defer { MarkdownCacheService.extractionObserver = nil }
        let skipLinesBefore = logLineCount(skipLine(.textCacheUpdate, count: 1))
        let model = makeModel(with: [book])

        await runCacheBatch(of: model)

        XCTAssertFalse(extracted.contains(book.id), "the dataless source was read")
        XCTAssertNil(contents(of: MarkdownCacheService.cacheURL(for: book)), "a text cache was written")
        XCTAssertEqual(model.bookByID(book.id)?.cacheFormatVersion, "3.0.3")
        XCTAssertEqual(logLineCount(skipLine(.textCacheUpdate, count: 1)), skipLinesBefore + 1)
    }

    // MARK: - Skipping Books in the Cloud

    /// The batch leaves the books whose text cache or record is dataless,
    /// brings the others up to date, counts the progress of all of them, and
    /// counts the ones it left in one line.
    @MainActor
    func testBatchLeavesBooksWithAFileInTheCloudAndUpdatesTheRest() async throws {
        let local = try makePackagedBook(title: "Local")
        let cachedInCloud = try makePackagedBook(title: "Cache In Cloud")
        let recordInCloud = try makePackagedBook(title: "Record In Cloud")
        let oldCache = Data("# Old\n\nOld words.".utf8)
        try oldCache.write(to: MarkdownCacheService.cacheURL(for: cachedInCloud))
        cloud.markDataless(
            MarkdownCacheService.cacheURL(for: cachedInCloud),
            TextMouthPaths.bookInfoPath(in: recordInCloud.tmbDirectory)
        )
        let skipLinesBefore = logLineCount(skipLine(.textCacheUpdate, count: 2))
        let model = makeModel(with: [local, cachedInCloud, recordInCloud])

        await runCacheBatch(of: model)

        XCTAssertEqual(model.bookByID(local.id)?.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertNotNil(contents(of: MarkdownCacheService.cacheURL(for: local)))
        XCTAssertEqual(model.bookByID(cachedInCloud.id)?.cacheFormatVersion, "3.0.3")
        XCTAssertEqual(contents(of: MarkdownCacheService.cacheURL(for: cachedInCloud)), oldCache)
        XCTAssertEqual(model.bookByID(recordInCloud.id)?.cacheFormatVersion, "3.0.3")
        XCTAssertNil(contents(of: MarkdownCacheService.cacheURL(for: recordInCloud)))
        XCTAssertEqual(model.extractionProgressCurrent, 3)
        XCTAssertEqual(logLineCount(skipLine(.textCacheUpdate, count: 2)), skipLinesBefore + 1)
    }

    /// Redo Text Extraction leaves a book whose source is dataless, and
    /// re-extracts one whose source is on this Mac though its old text
    /// cache is dataless: the old cache is replaced, never read.
    @MainActor
    func testRedoTextExtractionLeavesOnlyBooksWhoseSourceIsInTheCloud() async throws {
        let sourceInCloud = try commitCache(of: makePackagedBook(title: "Source In Cloud"))
        let cacheInCloud = try commitCache(of: makePackagedBook(title: "Cache In Cloud", text: "# Fresh\n\nNew words."))
        let sourceCacheBefore = contents(of: MarkdownCacheService.cacheURL(for: sourceInCloud))
        try "# Stale\n\nOld words.".write(
            to: MarkdownCacheService.cacheURL(for: cacheInCloud),
            atomically: true,
            encoding: .utf8
        )
        cloud.markDataless(sourceInCloud.bookFileURL, MarkdownCacheService.cacheURL(for: cacheInCloud))
        let skipLinesBefore = logLineCount(skipLine(.textReextraction, count: 1))
        let model = makeModel(with: [sourceInCloud, cacheInCloud])
        let finished = expectation(description: "Redo Text Extraction finished")
        let subscription = model.$isExtracting.dropFirst().filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        defer { subscription.cancel() }

        model.redoAllTextExtraction(access: cloud.access)
        await fulfillment(of: [finished], timeout: 10)

        XCTAssertEqual(contents(of: MarkdownCacheService.cacheURL(for: sourceInCloud)), sourceCacheBefore)
        let redone = try MarkdownCacheService.loadFromCache(for: cacheInCloud)
        XCTAssertEqual(redone.allHeadings.map(\.text), ["Fresh"])
        XCTAssertEqual(logLineCount(skipLine(.textReextraction, count: 1)), skipLinesBefore + 1)
    }

    /// A batch that leaves nothing in the cloud writes no skip line.
    @MainActor
    func testBatchWithEveryBookOnThisMacWritesNoSkipLine() async throws {
        let book = try makePackagedBook()
        let model = makeModel(with: [book])
        let anySkip = "MAINTENANCE_SKIPPED_IN_CLOUD: \(MaintenancePass.textCacheUpdate.rawValue): "
        let skipLinesBefore = logLineCount(anySkip)

        await runCacheBatch(of: model)

        XCTAssertEqual(model.bookByID(book.id)?.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertEqual(logLineCount(anySkip), skipLinesBefore)
    }

    // MARK: - Refused Reads

    /// A read of the source refused while the book is being brought up to
    /// date leaves it as it is: no cache is rebuilt, its record and old
    /// cache keep their bytes, nothing is logged as incomplete content, and
    /// the book is counted in the skip line.
    @MainActor
    func testRefusedSourceReadIsNoRebuildFailureOmissionOrRecordWrite() async throws {
        // The row predates a format change its package already recorded.
        var book = try commitCache(of: makePackagedBook())
        book.cacheFormatVersion = "3.0.3"
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        let recordURL = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
        let cacheBefore = contents(of: cacheURL)
        let recordBefore = contents(of: recordURL)
        cloud.refuseReads(of: book.bookFileURL)
        let omissionLinesBefore = logLineCount("_INCOMPLETE_CONTENT: \(book.title)")
        let skipLinesBefore = logLineCount(skipLine(.textCacheUpdate, count: 1))
        let model = makeModel(with: [book])

        await runCacheBatch(of: model)

        XCTAssertEqual(contents(of: cacheURL), cacheBefore, "the cache was rebuilt")
        XCTAssertEqual(contents(of: recordURL), recordBefore, "the record was written")
        XCTAssertEqual(model.bookByID(book.id), book)
        XCTAssertEqual(logLineCount("_INCOMPLETE_CONTENT: \(book.title)"), omissionLinesBefore)
        XCTAssertEqual(logLineCount(skipLine(.textCacheUpdate, count: 1)), skipLinesBefore + 1)
        XCTAssertTrue(cloud.refusedReads.contains(FakeCloudFiles.key(book.bookFileURL)))
    }

    /// A refused read of content.md for its digest, while the batch checks
    /// a cache an earlier run committed, is no reason to rebuild it: the
    /// cache keeps its bytes and date, and the book waits as it is.
    @MainActor
    func testRefusedTextCacheDigestDuringTheBatchRebuildsNothing() async throws {
        let committed = try commitCache(of: makePackagedBook())
        var row = committed
        row.cacheFormatVersion = "3.0.3"
        let cacheURL = MarkdownCacheService.cacheURL(for: row)
        try setModificationTime(of: cacheURL, nanoseconds: 1_800_000_000_000_000_000)
        let cacheBefore = contents(of: cacheURL)
        cloud.refuseReads(of: cacheURL)
        let skipLinesBefore = logLineCount(skipLine(.textCacheUpdate, count: 1))
        let model = makeModel(with: [row])

        await runCacheBatch(of: model)

        XCTAssertEqual(cloud.refusedReads, [FakeCloudFiles.key(cacheURL)], "content.md was never read for its digest")
        XCTAssertEqual(contents(of: cacheURL), cacheBefore)
        XCTAssertEqual(FileStamp(of: cacheURL)?.modificationTimeNanoseconds, 1_800_000_000_000_000_000)
        XCTAssertEqual(model.bookByID(row.id)?.cacheFormatVersion, "3.0.3")
        XCTAssertEqual(logLineCount(skipLine(.textCacheUpdate, count: 1)), skipLinesBefore + 1)
    }

    // MARK: - Fixtures

    /// Runs the startup cache batch of `model` with this test's cloud, to
    /// its end.
    @MainActor
    private func runCacheBatch(of model: LibraryViewModel) async {
        let finished = expectation(description: "The cache batch finished")
        model.extractMissingContentCaches(access: cloud.access) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)
    }
}
