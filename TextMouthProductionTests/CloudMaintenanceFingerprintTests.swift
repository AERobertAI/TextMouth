import XCTest
@testable import TextMouth

/// A text cache's fingerprints in a cloud library (FR02): a dataless file is
/// never read for its digest and never judged by the size and date it
/// reports, and a read refused for a dataless file is no reason to rebuild a
/// cache. The first two tests are the verification tests that showed the
/// behavior before the fix: a redated dataless source was read in full, and
/// the zero size of an evicted source made its cache stale.
final class CloudMaintenanceFingerprintTests: CloudMaintenanceTestCase {

    // MARK: - Verification

    /// A dataless source with a new modification date is never read for
    /// its digest, and its cache is kept, as for a source that cannot be
    /// examined. (Before the fix, the source was read in full.)
    func testRedatedDatalessSourceIsNotReadForItsDigest() throws {
        let book = try commitCache(of: makePackagedBook())
        try setModificationTime(of: book.bookFileURL, nanoseconds: 1_800_000_000_000_000_000)
        cloud.markDataless(book.bookFileURL)
        let counter = CountingFingerprintHasher()

        let index = BookContentAnalysisService.completedTextCacheIndex(
            for: book,
            hasher: counter.hasher,
            isDataless: cloud.access.isDataless
        )

        XCTAssertEqual(counter.fileCount, 0, "the dataless source was read for its digest")
        XCTAssertNotNil(index, "the cache of a source in the cloud was called stale")
    }

    /// The size of 0 that an evicted iCloud Drive file reports (1,153 of
    /// the 1,164 on the developer's Mac) is not a resize: the cache stays.
    /// (Before the fix, the cache was called stale.)
    func testZeroSizeOfAnEvictedSourceIsNotAResize() throws {
        let book = try commitCache(of: makePackagedBook())
        try Data().write(to: book.bookFileURL)
        cloud.markDataless(book.bookFileURL)

        XCTAssertFalse(LibraryViewModel.hasResizedTextCacheFile(book, isDataless: cloud.access.isDataless))
    }

    // MARK: - Comparing a Dataless File

    /// A dataless file compares as dataless, whatever its stamp says; any
    /// other file compares by its stamp as before.
    func testDatalessFileComparesAsDatalessWhateverItsStamp() {
        let recorded = FileFingerprint(stamp: FileStamp(byteCount: 10, modificationTimeNanoseconds: 5), digest: "d")
        let resized = FileStamp(byteCount: 0, modificationTimeNanoseconds: 9)

        XCTAssertEqual(recorded.comparison(with: resized, isDataless: true), .dataless)
        XCTAssertEqual(recorded.comparison(with: nil, isDataless: true), .dataless)
        XCTAssertEqual(recorded.comparison(with: resized, isDataless: false), .resized)
        XCTAssertEqual(recorded.comparison(with: recorded.stamp, isDataless: false), .same)
    }

    /// Neither a dataless source nor a dataless content.md is resized by the
    /// size it reports, while a file on this Mac with another size still is.
    func testOnlyAFileOnThisMacCanBeResized() throws {
        let book = try commitCache(of: makePackagedBook())
        let recorded = try XCTUnwrap(book.textCacheFingerprint)
        let zero = FileStamp(byteCount: 0, modificationTimeNanoseconds: 1)
        let cacheNow = FileStamp(of: MarkdownCacheService.cacheURL(for: book))

        XCTAssertFalse(recorded.hasResizedFile(sourceStamp: zero, cacheStamp: cacheNow, sourceIsDataless: true))
        XCTAssertFalse(recorded.hasResizedFile(sourceStamp: nil, cacheStamp: zero, cacheIsDataless: true))
        XCTAssertTrue(recorded.hasResizedFile(sourceStamp: zero, cacheStamp: cacheNow))
        XCTAssertTrue(recorded.hasResizedFile(sourceStamp: nil, cacheStamp: zero, sourceIsDataless: true))
    }

    // MARK: - Verifying a Cache

    /// A dataless source keeps its cache however its stamp changed, and is
    /// never read for its digest: as a source that cannot be examined.
    func testVerifyKeepsTheCacheOfADatalessSourceWithoutReadingIt() throws {
        let book = try commitCache(of: makePackagedBook())
        let recorded = try XCTUnwrap(book.textCacheFingerprint)
        let counter = CountingFingerprintHasher()
        let cacheURL = MarkdownCacheService.cacheURL(for: book)

        for sourceStamp in [
            FileStamp(byteCount: 0, modificationTimeNanoseconds: 1),
            FileStamp(byteCount: recorded.source.byteCount, modificationTimeNanoseconds: 1)
        ] {
            let verification = recorded.verify(
                sourceURL: book.bookFileURL,
                sourceStamp: sourceStamp,
                cacheStamp: FileStamp(of: cacheURL),
                cacheDigest: { counter.hasher.digestOfData(Data()) },
                hasher: counter.hasher,
                sourceIsDataless: true
            )
            XCTAssertEqual(verification, .current(recorded))
        }
        XCTAssertEqual(counter.count, 0, "a digest was computed")
    }

    /// A dataless content.md is not stale, whatever size and date it
    /// reports, and its digest is never asked for.
    func testDatalessTextCacheIsNotStale() throws {
        let book = try commitCache(of: makePackagedBook())
        let recorded = try XCTUnwrap(book.textCacheFingerprint)
        let counter = CountingFingerprintHasher()
        var digestsAsked = 0

        for cacheStamp in [
            FileStamp(byteCount: 0, modificationTimeNanoseconds: 1),
            FileStamp(byteCount: recorded.cache.byteCount, modificationTimeNanoseconds: 1),
            nil
        ] {
            let verification = recorded.verify(
                sourceURL: book.bookFileURL,
                sourceStamp: FileStamp(of: book.bookFileURL),
                cacheStamp: cacheStamp,
                cacheDigest: {
                    digestsAsked += 1
                    return "asked"
                },
                hasher: counter.hasher,
                cacheIsDataless: true
            )
            XCTAssertEqual(verification, .current(recorded))
        }
        XCTAssertEqual(digestsAsked, 0)
        XCTAssertEqual(counter.count, 0)
    }

    /// A digest of content.md whose read was refused is no reason to
    /// rebuild: the batch's check throws the refusal instead of answering
    /// nil, which would have the cache rebuilt, while the plain check, for
    /// callers that never leave files in the cloud, still answers nil.
    func testRefusedDigestOfTheTextCacheIsNoReasonToRebuild() throws {
        let book = try commitCache(of: makePackagedBook())
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        try setModificationTime(of: cacheURL, nanoseconds: 1_800_000_000_000_000_000)
        cloud.refuseReads(of: cacheURL)
        let access = cloud.access

        XCTAssertThrowsError(try BookContentAnalysisService.recoveredTextCacheIndex(
            for: book,
            hasher: access.hasher,
            isDataless: access.isDataless
        )) { error in
            XCTAssertTrue(DatalessFiles.isDownloadRefusal(error), "\(error)")
        }
        XCTAssertNil(BookContentAnalysisService.completedTextCacheIndex(for: book, hasher: access.hasher))
        XCTAssertEqual(cloud.refusedReads, [FakeCloudFiles.key(cacheURL), FakeCloudFiles.key(cacheURL)])
    }

    /// A load never fingerprints a cache written before fingerprints while
    /// its source is dataless: that would read the whole source for its
    /// digest. The cache still loads, unfingerprinted, for a later load to
    /// fingerprint once the source is on this Mac.
    func testLoadDoesNotFingerprintADatalessSource() throws {
        var book = try commitCache(of: makePackagedBook())
        var index = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).contentIndex)
        index.textCacheFingerprint = nil
        book.textCacheFingerprint = nil
        try book.saveBookInfoThrowing(contentIndex: index)
        cloud.markDataless(book.bookFileURL)
        let counter = CountingFingerprintHasher()

        let result = try BookContentAnalysisService.load(
            book: book,
            hasher: counter.hasher,
            isDataless: cloud.access.isDataless
        )

        XCTAssertNil(result.index.textCacheFingerprint)
        XCTAssertEqual(counter.fileCount, 0, "the dataless source was read for its digest")
        XCTAssertEqual(result.content.allHeadings.map(\.text), ["Opening"])
    }
}
