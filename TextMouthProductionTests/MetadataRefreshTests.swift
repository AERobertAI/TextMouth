import XCTest
@testable import TextMouth

/// The launch's metadata refresh: a row an older metadata reader read is
/// read again and takes what its file names where the row may
/// (`LibraryViewModel.refreshedValues(of:from:)`), never a field the user
/// edited by hand; every row read is stamped; and a book whose file is in
/// the cloud is left as it is (FR02).
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
        XCTAssertNil(row.handEdits, "the refresh records no edit of its own")
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

    /// A row whose record of hand edits has been kept since its import
    /// takes the title, author, publisher, and date its file names, on the
    /// row and in its record, which keeps the record of hand edits as it
    /// was.
    @MainActor
    func testARowRecordedSinceItsImportTakesWhatItsFileNames() async throws {
        var book = try makePackagedEPUB(
            author: Book.unknownAuthor,
            fileNames: "Alastair Reynolds",
            fileTitle: "Century Rain: Revised",
            filePublisher: "Gollancz",
            fileDate: "2004"
        )
        book.handEdits = .noneSinceImport
        let model = makeModel(with: [book])

        await runRefresh(of: model)

        let row = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(row.title, "Century Rain: Revised")
        XCTAssertEqual(row.author, "Alastair Reynolds")
        XCTAssertEqual(row.epubPublisher, "Gollancz")
        XCTAssertEqual(row.epubPublicationDate, "2004")
        XCTAssertEqual(row.handEdits, .noneSinceImport)
        XCTAssertEqual(row.metadataReaderVersion, ImportedFileMetadata.readerVersion)
        LibraryPersistenceService.writePendingBookInfoNow(bookID: book.id)
        let record = try BookInfo.load(from: book.tmbDirectory).metadata
        XCTAssertEqual(record.title, "Century Rain: Revised")
        XCTAssertEqual(record.publisher, "Gollancz")
        XCTAssertEqual(record.publicationDate, "2004")
        XCTAssertEqual(record.handEdits, .noneSinceImport)
    }

    /// A title typed by hand stays whatever the file names, while the same
    /// row's author, which the import read, takes the file's.
    @MainActor
    func testATitleTypedByHandStaysWhileTheRowsOtherFieldsFollowTheFile() async throws {
        var book = try makePackagedEPUB(title: "XF03 Paradise", author: "Import Read", fileNames: "Alastair Reynolds", fileTitle: "Paradise")
        book.handEdits = Book.HandEdits(fields: [.title], sinceImport: true)
        let model = makeModel(with: [book])

        await runRefresh(of: model)

        let row = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(row.title, "XF03 Paradise")
        XCTAssertEqual(row.author, "Alastair Reynolds")
        XCTAssertEqual(row.handEdits, book.handEdits)
    }

    /// A row from before edits were recorded keeps a title that differs
    /// from its file's, as the titles typed by hand before then do, with
    /// or without a record begun by an edit since; its author follows the
    /// rule from before: the placeholder is replaced, a name stays.
    @MainActor
    func testARowFromBeforeEditsWereRecordedKeepsATitleThatDiffersFromItsFile() async throws {
        let unrecorded = try makePackagedEPUB(title: "XF03 Paradise", author: Book.unknownAuthor, fileNames: "Alastair Reynolds", fileTitle: "Paradise")
        var begunByAnEdit = try makePackagedEPUB(title: "XF03 Paradise", author: "Hand Typed", fileNames: "Alastair Reynolds", fileTitle: "Paradise")
        begunByAnEdit.handEdits = Book.HandEdits(fields: [.publisher], sinceImport: false)
        let model = makeModel(with: [unrecorded, begunByAnEdit])

        await runRefresh(of: model)

        let first = try XCTUnwrap(model.bookByID(unrecorded.id))
        XCTAssertEqual(first.title, "XF03 Paradise")
        XCTAssertEqual(first.author, "Alastair Reynolds")
        XCTAssertNil(first.handEdits)
        let second = try XCTUnwrap(model.bookByID(begunByAnEdit.id))
        XCTAssertEqual(second.title, "XF03 Paradise")
        XCTAssertEqual(second.author, "Hand Typed")
        XCTAssertEqual(second.handEdits, begunByAnEdit.handEdits)
        XCTAssertEqual(second.metadataReaderVersion, ImportedFileMetadata.readerVersion)
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

    /// What every rule test's file names: a title, an author, a publisher,
    /// and a date.
    private static let everythingNamed: Book.MetadataValues = [
        .title: "Paradise", .author: "Russell Hoban", .publisher: "Tollgate Press", .publicationDate: "2004"
    ]

    /// For a row without a record of hand edits, as every row from before
    /// edits were recorded is, only an author at the placeholder is
    /// replaced, and only by a name: a title that differs from the file's,
    /// a named author, and a publisher or date the row lacks all stay.
    func testARowWithoutARecordTakesOnlyAnAuthorForThePlaceholder() {
        var row = Self.makeRow(title: "XF03 Paradise", author: Book.unknownAuthor)
        XCTAssertEqual(Self.refreshed(row, Self.everythingNamed), [.author: "Russell Hoban"])
        row.author = ""
        XCTAssertEqual(Self.refreshed(row, Self.everythingNamed), [.author: "Russell Hoban"])
        XCTAssertEqual(Self.refreshed(row, [.title: "Paradise"]), [:], "a file that names no one leaves the placeholder")
        row.author = "Hand Typed"
        XCTAssertEqual(Self.refreshed(row, Self.everythingNamed), [:])
    }

    /// A row whose record began with an edit is treated the same, and a
    /// field it records is never replaced: an author blanked by hand stays
    /// blank.
    func testARowWhoseRecordBeganWithAnEditKeepsItsUnrecordedFieldsToo() {
        var row = Self.makeRow(title: "XF03 Paradise", author: Book.unknownAuthor)
        row.handEdits = Book.HandEdits(fields: [.publisher], sinceImport: false)
        XCTAssertEqual(Self.refreshed(row, Self.everythingNamed), [.author: "Russell Hoban"])
        row.handEdits = Book.HandEdits(fields: [.author], sinceImport: false)
        row.author = ""
        XCTAssertEqual(Self.refreshed(row, Self.everythingNamed), [:], "an author blanked by hand stays blank")
    }

    /// A row whose record has been kept since its import takes every field
    /// its file names that the user did not edit: a value the row already
    /// holds is not counted, a field the file names none of stays, and a
    /// field edited by hand stays whatever the file names.
    func testARowRecordedSinceItsImportTakesEveryFieldItsFileNamesButTheUsers() {
        var row = Self.makeRow(title: "Paradise", author: "Import Read")
        row.handEdits = .noneSinceImport
        XCTAssertEqual(
            Self.refreshed(row, Self.everythingNamed),
            [.author: "Russell Hoban", .publisher: "Tollgate Press", .publicationDate: "2004"],
            "the title the row already holds is not counted"
        )
        XCTAssertEqual(Self.refreshed(row, [.title: "Paradise", .author: "Russell Hoban"]), [.author: "Russell Hoban"])
        row.handEdits = Book.HandEdits(fields: [.author, .publisher], sinceImport: true)
        XCTAssertEqual(Self.refreshed(row, Self.everythingNamed), [.publicationDate: "2004"])
        row.title = "XF03 Paradise"
        XCTAssertEqual(Self.refreshed(row, Self.everythingNamed), [.title: "Paradise", .publicationDate: "2004"])
    }

    /// What a reading takes from a file's metadata: a title, an author
    /// other than the placeholder, and an EPUB's publisher and date where
    /// they are not empty; nothing from a file that names nothing.
    func testAReadingTakesWhatTheFileNames() {
        let id = UUID()
        var read = ImportedFileMetadata(title: "")
        XCTAssertEqual(MetadataReading(bookID: id, read: read).named, [:])
        XCTAssertEqual(MetadataReading(bookID: id).named, [:])

        read.title = "Paradise"
        read.author = "Russell Hoban"
        read.epub = EPUBMetadata(
            title: "Paradise", author: "Russell Hoban", publisher: "Tollgate Press", publicationDate: "2004",
            isbn: "", language: "", identifier: "", epubVersion: "3.0"
        )
        XCTAssertEqual(MetadataReading(bookID: id, read: read).named, Self.everythingNamed)

        read.author = Book.unknownAuthor
        read.epub?.publisher = ""
        XCTAssertEqual(MetadataReading(bookID: id, read: read).named, [.title: "Paradise", .publicationDate: "2004"])
    }

    /// The pass's log line counts the books read, the fields replaced, and
    /// the rows they were replaced on.
    func testTheLogLineCountsBooksFieldsAndRows() {
        XCTAssertEqual(
            LibraryViewModel.metadataRefreshLogLine(read: 1, replaced: 1, rows: 1),
            "METADATA_REFRESH: read 1 book again; replaced 1 field of 1"
        )
        XCTAssertEqual(
            LibraryViewModel.metadataRefreshLogLine(read: 312, replaced: 0, rows: 0),
            "METADATA_REFRESH: read 312 books again; replaced 0 fields of 0"
        )
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

    /// A row listed under `title` and `author`, with nothing else kept and
    /// no record of hand edits, for the rules.
    private static func makeRow(title: String, author: String) -> Book {
        Book(title: title, author: author, format: .epub, filePath: "/tmp/row.epub", md5Hash: "hash")
    }

    /// The fields of `row` the refresh replaces when its file names
    /// `named`, with their values.
    private static func refreshed(_ row: Book, _ named: Book.MetadataValues) -> Book.MetadataValues {
        LibraryViewModel.refreshedValues(of: row, from: MetadataReading(bookID: row.id, named: named))
    }

    /// An EPUB in a package of its own in this test's folder, whose package
    /// document names `fileTitle` as the title, `name` as the author in a
    /// dcterms:creator meta element, or no one when nil, and a publisher
    /// and a date when given; listed under `title` and `author` by a row no
    /// reader has stamped and no record of hand edits is kept for.
    private func makePackagedEPUB(
        title: String = "Century Rain",
        author: String,
        fileNames name: String?,
        fileTitle: String = "Century Rain",
        filePublisher: String? = nil,
        fileDate: String? = nil
    ) throws -> Book {
        let packageName = "Refresh-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let creator = name.map { "<meta property=\"dcterms:creator\">\($0)</meta>" } ?? ""
        let publisher = filePublisher.map { "<dc:publisher>\($0)</dc:publisher>" } ?? ""
        let date = fileDate.map { "<dc:date>\($0)</dc:date>" } ?? ""
        let opf = TextPipelineFixtures.packageDocument(
            metadata: "<dc:title>\(fileTitle)</dc:title>" + creator + publisher + date
        )
        let zip = try makeTemporaryZip(prefix: "MetadataRefresh", orderedEntries: TextPipelineFixtures.minimalEPUB(packageDocument: opf))
        let file = package.appendingPathComponent("book.epub")
        try FileManager.default.moveItem(at: zip, to: file)
        return Book(
            title: title,
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
