import XCTest
@testable import TextMouth

/// The launch's metadata refresh: a row an older metadata reader read is
/// read again and takes the author its file names where it listed the
/// placeholder, every row read is stamped, and a book whose file is in the
/// cloud is left as it is (FR02).
final class MetadataRefreshTests: CloudMaintenanceTestCase {

    /// A row listing the placeholder takes the author its file names, on
    /// the row, in its record, and in the index, and is stamped.
    @MainActor
    func testARowListingThePlaceholderTakesTheAuthorItsFileNamesAndIsStamped() async throws {
        let book = try makePackagedEPUB(author: Book.unknownAuthor, fileNames: "Alastair Reynolds")
        let model = makeModel(with: [book])

        await runRefresh(of: model)

        let row = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(row.author, "Alastair Reynolds")
        XCTAssertEqual(row.metadataReaderVersion, ImportedFileMetadata.readerVersion)
        LibraryPersistenceService.writePendingBookInfoNow(bookID: book.id)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.author, "Alastair Reynolds")
        LibraryPersistenceService.flushPendingSave()
        let saved = LibraryPersistenceService.load().library?.books.first { $0.id == book.id }
        XCTAssertEqual(saved?.author, "Alastair Reynolds")
        XCTAssertEqual(saved?.metadataReaderVersion, ImportedFileMetadata.readerVersion)
    }

    /// An author typed by hand stays, whatever the file names; the row is
    /// stamped all the same.
    @MainActor
    func testAnAuthorTypedByHandStays() async throws {
        let book = try makePackagedEPUB(author: "Hand Typed", fileNames: "Alastair Reynolds")
        let model = makeModel(with: [book])

        await runRefresh(of: model)

        let row = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(row.author, "Hand Typed")
        XCTAssertEqual(row.metadataReaderVersion, ImportedFileMetadata.readerVersion)
    }

    /// A file that still names no one leaves the placeholder; the row is
    /// stamped, so the file is not read again at the next launch.
    @MainActor
    func testAFileThatStillNamesNoOneLeavesThePlaceholder() async throws {
        let book = try makePackagedEPUB(author: Book.unknownAuthor, fileNames: nil)
        let model = makeModel(with: [book])

        await runRefresh(of: model)

        let row = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(row.author, Book.unknownAuthor)
        XCTAssertEqual(row.metadataReaderVersion, ImportedFileMetadata.readerVersion)
    }

    /// A book whose file is in the cloud is left as it is, unstamped, and
    /// counted in the pass's skip line.
    @MainActor
    func testABookInTheCloudIsLeftAsItIsAndCounted() async throws {
        let book = try makePackagedEPUB(author: Book.unknownAuthor, fileNames: "Alastair Reynolds")
        cloud.markDataless(book.bookFileURL)
        let skipLinesBefore = logLineCount(skipLine(.metadataRefresh, count: 1))
        let model = makeModel(with: [book])

        await runRefresh(of: model)

        XCTAssertEqual(model.bookByID(book.id), book)
        XCTAssertEqual(logLineCount(skipLine(.metadataRefresh, count: 1)), skipLinesBefore + 1)
    }

    /// A row this reader stamped is not looked at: here its file is in the
    /// cloud, which a look would count.
    @MainActor
    func testARowThisReaderStampedIsNotLookedAt() async throws {
        var book = try makePackagedEPUB(author: Book.unknownAuthor, fileNames: "Alastair Reynolds")
        book.metadataReaderVersion = ImportedFileMetadata.readerVersion
        cloud.markDataless(book.bookFileURL)
        let skipLinesBefore = logLineCount(skipLine(.metadataRefresh, count: 1))
        let model = makeModel(with: [book])

        await runRefresh(of: model)

        XCTAssertEqual(model.bookByID(book.id), book)
        XCTAssertEqual(logLineCount(skipLine(.metadataRefresh, count: 1)), skipLinesBefore)
    }

    /// A book whose format keeps no metadata in its file is stamped without
    /// its file being looked at: here a Markdown book in the cloud, which a
    /// look would count.
    @MainActor
    func testABookWhoseFormatKeepsNoMetadataIsStampedWithoutALook() async throws {
        let book = try makePackagedBook(title: "Notes")
        cloud.markDataless(book.bookFileURL)
        let skipLinesBefore = logLineCount(skipLine(.metadataRefresh, count: 1))
        let model = makeModel(with: [book])

        await runRefresh(of: model)

        let row = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(row.author, Book.unknownAuthor)
        XCTAssertEqual(row.metadataReaderVersion, ImportedFileMetadata.readerVersion)
        XCTAssertEqual(logLineCount(skipLine(.metadataRefresh, count: 1)), skipLinesBefore)
    }

    /// Launch maintenance reads metadata first, then builds the text caches,
    /// then the statistics, and says when the last has ended.
    @MainActor
    func testLaunchMaintenanceReadsMetadataThenCachesThenStatistics() async throws {
        let book = try makePackagedEPUB(author: Book.unknownAuthor, fileNames: "Alastair Reynolds")
        let model = makeModel(with: [book])
        let finished = expectation(description: "Launch maintenance finished")

        model.updateContentCachesAndStatistics(access: cloud.access) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 20)

        let row = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(row.author, "Alastair Reynolds")
        XCTAssertEqual(row.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertNotNil(row.totalWordCount)
    }

    // MARK: - The Rules

    /// The refresh replaces only the placeholder, and only with a name.
    func testTheRefreshReplacesOnlyThePlaceholderWithAName() {
        XCTAssertEqual(LibraryViewModel.refreshedAuthor(current: Book.unknownAuthor, read: "Russell Hoban"), "Russell Hoban")
        XCTAssertEqual(LibraryViewModel.refreshedAuthor(current: "", read: "Russell Hoban"), "Russell Hoban")
        XCTAssertNil(LibraryViewModel.refreshedAuthor(current: Book.unknownAuthor, read: Book.unknownAuthor))
        XCTAssertNil(LibraryViewModel.refreshedAuthor(current: Book.unknownAuthor, read: ""))
        XCTAssertNil(LibraryViewModel.refreshedAuthor(current: "Hand Typed", read: "Russell Hoban"))
    }

    /// A row stamped by an older reader, or by none, is read again; one
    /// stamped by this reader, or by a newer one, is not.
    func testARowAnOlderReaderReadIsReadAgain() {
        var book = Book(title: "Row", format: .epub, filePath: "/tmp/row.epub", md5Hash: "hash")
        XCTAssertTrue(LibraryViewModel.needsMetadataRefresh(book))
        book.metadataReaderVersion = "0.9.0"
        XCTAssertTrue(LibraryViewModel.needsMetadataRefresh(book))
        book.metadataReaderVersion = ImportedFileMetadata.readerVersion
        XCTAssertFalse(LibraryViewModel.needsMetadataRefresh(book))
        book.metadataReaderVersion = "99.0.0"
        XCTAssertFalse(LibraryViewModel.needsMetadataRefresh(book))
    }

    // MARK: - Fixtures

    /// An EPUB in a package of its own in this test's folder, whose package
    /// document names `name` as the author in a dcterms:creator meta
    /// element, or no one when nil, listed under `author` by a row no
    /// reader has stamped.
    private func makePackagedEPUB(author: String, fileNames name: String?) throws -> Book {
        let packageName = "Refresh-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let creator = name.map { "<meta property=\"dcterms:creator\">\($0)</meta>" } ?? ""
        let opf = TextPipelineFixtures.packageDocument(metadata: "<dc:title>Century Rain</dc:title>" + creator)
        let zip = try makeTemporaryZip(prefix: "MetadataRefresh", orderedEntries: TextPipelineFixtures.minimalEPUB(packageDocument: opf))
        let file = package.appendingPathComponent("book.epub")
        try FileManager.default.moveItem(at: zip, to: file)
        return Book(
            title: "Century Rain",
            author: author,
            format: .epub,
            filePath: file.path,
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            tmbDirectoryName: packageName
        )
    }

    /// Runs the metadata refresh of `model` with this test's cloud, to its
    /// end.
    @MainActor
    private func runRefresh(of model: LibraryViewModel) async {
        let finished = expectation(description: "The metadata refresh finished")
        model.refreshOutdatedMetadata(access: cloud.access) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)
    }
}
