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

    // MARK: - Fixtures

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
