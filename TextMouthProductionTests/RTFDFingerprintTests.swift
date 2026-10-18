import XCTest
@testable import TextMouth

/// An RTFD is a folder, not a file, and three places measured a book's file
/// as a regular file: the text cache's fingerprint, the launch's check of
/// it, and Export's size. A folder gave all three nothing, so an imported
/// RTFD's cache never knew its source, every launch read it again, and
/// Export said "Zero KB". An RTFD now has a stamp (the total size of its
/// files and the latest time among them), a digest (the checksum its import
/// used), and so a size and a fingerprint like any book's.
final class RTFDFingerprintTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        ReadingTextCache.waitForBackgroundWork()
        sandbox?.restore()
    }

    // MARK: - The Stamp

    /// An RTFD's stamp is the sum of its regular files' sizes and the latest
    /// of their modification times.
    func testAnRTFDStampIsTheTotalSizeAndTheLatestTimeOfItsFiles() throws {
        let folder = try copyOfFormatSample("rtfd/with-image.rtfd")
        let text = folder.appendingPathComponent("TXT.rtf")
        let picture = folder.appendingPathComponent("Attachment.png")
        try setModificationTime(of: text, nanoseconds: 1_790_000_000_000_000_000)
        try setModificationTime(of: picture, nanoseconds: 1_790_000_005_000_000_007)

        let stamp = try XCTUnwrap(FileStamp(of: folder))

        let sizes = try [text, picture].map { try XCTUnwrap(FileStamp(of: $0)).byteCount }
        XCTAssertEqual(stamp.byteCount, sizes.reduce(0, +))
        XCTAssertEqual(stamp.modificationTimeNanoseconds, 1_790_000_005_000_000_007)
    }

    /// A hidden file, a symbolic link, and a file in a hidden folder are
    /// passed over, as the RTFD's checksum passes them over, so a visit in
    /// the Finder never changes the stamp.
    func testAnRTFDStampPassesOverHiddenFilesAndLinks() throws {
        let folder = try copyOfFormatSample("rtfd/with-image.rtfd")
        let before = try XCTUnwrap(FileStamp(of: folder))

        try Data("finder".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
        let hidden = folder.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: hidden.appendingPathComponent("note.txt"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("link.png"),
            withDestinationURL: folder.appendingPathComponent("Attachment.png")
        )

        XCTAssertEqual(FileStamp(of: folder), before)
    }

    /// Adding a file to the RTFD changes the stamp, and so does changing one.
    func testAChangeInAnRTFDChangesItsStamp() throws {
        let folder = try copyOfFormatSample("rtfd/with-image.rtfd")
        let before = try XCTUnwrap(FileStamp(of: folder))

        try Data("more".utf8).write(to: folder.appendingPathComponent("Extra.txt"))
        let added = try XCTUnwrap(FileStamp(of: folder))
        XCTAssertEqual(added.byteCount, before.byteCount + 4)

        try setModificationTime(of: folder.appendingPathComponent("TXT.rtf"), nanoseconds: 1_999_000_000_000_000_000)
        XCTAssertEqual(FileStamp(of: folder)?.modificationTimeNanoseconds, 1_999_000_000_000_000_000)
    }

    /// Only an RTFD is measured as a folder: any other folder still has no
    /// stamp, an RTFD with no file in it has none, and a plain file named
    /// .rtfd is stamped as the file it is.
    func testOnlyAnRTFDFolderWithFilesHasAFolderStamp() throws {
        let sandbox = try makeSandboxDirectory("RTFDStamp")
        let plainFolder = sandbox.appendingPathComponent("Pictures", isDirectory: true)
        try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
        try Data("not counted".utf8).write(to: plainFolder.appendingPathComponent("a.txt"))
        let emptyRTFD = sandbox.appendingPathComponent("Empty.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRTFD, withIntermediateDirectories: true)
        let plainFile = sandbox.appendingPathComponent("Flat.rtfd")
        try Data("twelve bytes".utf8).write(to: plainFile)

        XCTAssertNil(FileStamp(of: plainFolder))
        XCTAssertNil(FileStamp(of: emptyRTFD))
        XCTAssertEqual(FileStamp(of: plainFile)?.byteCount, 12)
    }

    // MARK: - The Fingerprint

    /// An RTFD's digest is the checksum its import is known by, from the
    /// same walk of its files, and its fingerprint holds that digest with
    /// its stamp.
    func testAnRTFDFingerprintHoldsTheChecksumOfItsImport() throws {
        let folder = try copyOfFormatSample("rtfd/with-image.rtfd")

        let fingerprint = try XCTUnwrap(FileFingerprint(of: folder, hasher: .md5))

        XCTAssertEqual(fingerprint.digest, try FileImportService.importHash(of: folder))
        XCTAssertEqual(fingerprint.stamp, FileStamp(of: folder))
    }

    // MARK: - An Imported RTFD

    /// An imported RTFD records a fingerprint of its folder and its
    /// content.md, as every text book does.
    func testAnImportedRTFDHasATextCacheFingerprint() throws {
        let book = try importedForTest(try copyOfFormatSample("rtfd/headings.rtfd")).book

        let fingerprint = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).state.textCacheFingerprint)

        XCTAssertEqual(fingerprint.source.digest, book.md5Hash)
        XCTAssertEqual(fingerprint.source.stamp, FileStamp(of: book.bookFileURL))
        XCTAssertFalse(LibraryViewModel.needsTextCacheFingerprint(try recordedBook(book)))
    }

    /// A launch's maintenance of an unchanged imported RTFD reads nothing:
    /// its stamps are compared, no digest is taken, and the cache is
    /// current. (Without a fingerprint, every launch read the book again.)
    func testALaunchDoesNotReadAnUnchangedRTFDAgain() throws {
        let book = try recordedBook(try importedForTest(try copyOfFormatSample("rtfd/with-image.rtfd")).book)
        let counter = CountingFingerprintHasher()

        XCTAssertFalse(LibraryViewModel.needsTextCacheFingerprint(book))
        XCTAssertFalse(LibraryViewModel.hasResizedTextCacheFile(book))
        XCTAssertFalse(LibraryViewModel.hasRedatedTextCache(book))
        XCTAssertNotNil(BookContentAnalysisService.completedTextCacheIndex(for: book, hasher: counter.hasher))
        XCTAssertEqual(counter.count, 0, "an unchanged RTFD was read for a digest")
    }

    /// The reading text of an imported RTFD is kept by the reading-text
    /// cache like any book's, which needs the book's fingerprint.
    func testTheReadingTextOfAnRTFDIsKept() throws {
        let book = try recordedBook(try importedForTest(try copyOfFormatSample("rtfd/headings.rtfd")).book)
        let cache = ReadingTextCache(
            folder: try makeSandboxDirectory("RTFDReadingText"),
            producer: "RTFDFingerprintTests",
            minimumContentByteCount: 0
        )

        _ = try BookContentAnalysisService.load(book: book, readingTexts: cache)
        ReadingTextCache.waitForBackgroundWork()
        let reopened = try BookContentAnalysisService.load(book: book, readingTexts: cache)

        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.url(for: book.id).path))
        XCTAssertTrue(reopened.readFromReadingTextCache)
    }

    /// Changing the RTFD's text makes its cache stale: the recorded folder
    /// no longer matches, by its size, or by its digest when only the time
    /// moved.
    func testChangingTheTextOfAnRTFDMakesItsCacheStale() throws {
        let book = try recordedBook(try importedForTest(try copyOfFormatSample("rtfd/headings.rtfd")).book)
        let recorded = try XCTUnwrap(book.textCacheFingerprint)
        let text = book.bookFileURL.appendingPathComponent("TXT.rtf")

        // A longer file: another size, which needs no digest.
        let original = try Data(contentsOf: text)
        try (original + Data(" ".utf8)).write(to: text)
        XCTAssertTrue(LibraryViewModel.hasResizedTextCacheFile(book))
        XCTAssertNil(BookContentAnalysisService.completedTextCacheIndex(for: book))

        // The same size with other bytes and a new time: found by its digest.
        var changed = original
        changed[changed.count - 1] = changed[changed.count - 1] ^ 0x01
        try changed.write(to: text)
        try setModificationTime(of: text, nanoseconds: 1_900_000_000_000_000_000)
        let counter = CountingFingerprintHasher()
        XCTAssertEqual(
            recorded.verify(
                sourceURL: book.bookFileURL,
                sourceStamp: FileStamp(of: book.bookFileURL),
                cacheStamp: FileStamp(of: MarkdownCacheService.cacheURL(for: book)),
                cacheDigest: { recorded.cache.digest },
                hasher: counter.hasher
            ),
            .stale(.sourceChanged)
        )
        XCTAssertEqual(counter.fileCount, 1)
    }

    // MARK: - Export

    /// Export names an RTFD's real size, the total of its files, not zero.
    func testExportNamesTheRealSizeOfAnRTFD() throws {
        let book = try importedForTest(try copyOfFormatSample("rtfd/with-image.rtfd")).book
        let folder = book.bookFileURL
        let expected = try ["TXT.rtf", "Attachment.png"].map {
            try XCTUnwrap(FileStamp(of: folder.appendingPathComponent($0))).byteCount
        }.reduce(0, +)

        let offer = BookExportService.offer(for: book)

        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(offer.item(.originalFile)?.byteCount, expected)
    }

    // MARK: - Helpers

    /// `book` as the library lists it after an import: with the record its
    /// package keeps (the fingerprint of its text cache), which a launch's
    /// checks read from the library's row.
    private func recordedBook(_ book: Book) throws -> Book {
        var listed = book
        listed.textCacheFingerprint = try BookInfo.load(from: book.tmbDirectory).state.textCacheFingerprint
        return listed
    }
}
