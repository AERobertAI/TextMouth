import XCTest
@testable import TextMouth

/// An RTFD book's own package (.tmb) opens and imports as the book it holds
/// (FMT13 review item 1). An RTFD, unlike every other text book, is a folder,
/// and the package code once took every folder for an audio book's tracks:
/// the package could not be opened from the Finder, and Remove from Library
/// Only then rebuilt the book as audio with a made-up checksum.
///
/// The RTFD comes from a copy of `rtfd/with-image.rtfd` imported through
/// the code under test, so these tests read it only in a child process.
/// Library packages live in the hosted tests' isolated root, and the library
/// index is put back after each test. The tests that take a book out of the
/// library use no reader window, which the hosted app would really open.
final class RTFDPackageTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox!

    /// A fixed moment in whole seconds, since bookInfo.json stores dates to
    /// the second.
    private static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
    }

    // MARK: - The Package Itself

    /// The package of an RTFD book, taken out of the library as a copy (as
    /// the Finder or a backup holds it), imports as the RTFD it holds: its
    /// format, its folder checksum, its reading position, and its bookmark
    /// all come back, and the reader opens its text.
    func testAnRTFDBooksPackageImportsAsTheRTFDWithItsPlaceAndBookmark() throws {
        let sample = try copyOfFormatSample("rtfd/with-image.rtfd")
        let folderChecksum = try FileImportService.contentChecksum(of: sample, format: .rtfd)
        let kept = try importedWithPlace(sample)
        let copy = try copyOutOfLibrary(kept)
        // Gone from the library, as on another Mac or after a restore.
        try FileManager.default.removeItem(at: kept.tmbDirectory)

        let imported = try FileImportService.importTMBPackageWithReport(from: copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }

        XCTAssertEqual(imported.book.id, kept.id)
        XCTAssertEqual(imported.book.format, .rtfd)
        XCTAssertEqual(imported.book.md5Hash, folderChecksum)
        XCTAssertEqual(imported.book.readingPosition, Self.place)
        XCTAssertEqual(imported.book.bookmarks, [Self.bookmark])
        XCTAssertTrue(imported.book.filePath.hasSuffix(".rtfd"))
        XCTAssertTrue(isFolder(imported.book.filePath), "the document stays a folder in the package")
        XCTAssertFalse(try openedContent(of: imported.book).chapters.isEmpty)
    }

    /// A package whose RTFD folder was changed since the record was written
    /// is refused as any package with changed content is, not read as an
    /// audio book.
    func testAnRTFDPackageWhoseFolderChangedIsRefusedForItsChecksum() throws {
        let kept = try importedWithPlace(try copyOfFormatSample("rtfd/with-image.rtfd"))
        let copy = try copyOutOfLibrary(kept)
        let attachment = copy.appendingPathComponent(kept.filePathLastComponent)
            .appendingPathComponent("Attachment.png")
        try Data("not the picture".utf8).write(to: attachment)

        XCTAssertThrowsError(try FileImportService.identifyTMBPackage(at: copy)) { error in
            XCTAssertTrue(error.localizedDescription.contains("content hash does not match"), "\(error)")
        }
    }

    // MARK: - After Remove from Library Only

    /// Remove from Library Only deletes the record and keeps the package, so
    /// taking the book back rebuilds it from the removal marker: it is an
    /// RTFD again, known by its folder checksum, not an audio book known by
    /// a checksum made from its ID.
    @MainActor
    func testARetainedRTFDWithoutARecordIsRebuiltAsAnRTFD() throws {
        let sample = try copyOfFormatSample("rtfd/with-image.rtfd")
        let folderChecksum = try FileImportService.contentChecksum(of: sample, format: .rtfd)
        let kept = try importedWithPlace(sample)
        try removeFromLibraryOnly(kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TextMouthPaths.bookInfoPath(in: kept.tmbDirectory).path))

        let imported = try FileImportService.importTMBPackageWithReport(from: kept.tmbDirectory)

        XCTAssertEqual(imported.book.id, kept.id)
        XCTAssertEqual(imported.book.format, .rtfd)
        XCTAssertEqual(imported.book.md5Hash, folderChecksum)
        XCTAssertEqual(imported.book.tmbDirectory.path, kept.tmbDirectory.path)
        XCTAssertTrue(isFolder(imported.book.filePath))
        XCTAssertFalse(try openedContent(of: imported.book).chapters.isEmpty)
    }

    /// A retained RTFD whose record survived (its deletion failed) comes
    /// back as an RTFD with its place and bookmark.
    @MainActor
    func testARetainedRTFDThatKeptItsRecordReturnsWithItsPlaceAndBookmark() throws {
        let sample = try copyOfFormatSample("rtfd/with-image.rtfd")
        let folderChecksum = try FileImportService.contentChecksum(of: sample, format: .rtfd)
        let kept = try importedWithPlace(sample)
        let record = TextMouthPaths.bookInfoPath(in: kept.tmbDirectory)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: record.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: record.path) }
        try removeFromLibraryOnly(kept, expectingReport: true)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: record.path)

        let imported = try FileImportService.importTMBPackageWithReport(from: kept.tmbDirectory)

        XCTAssertEqual(imported.book.format, .rtfd)
        XCTAssertEqual(imported.book.md5Hash, folderChecksum)
        XCTAssertEqual(imported.book.readingPosition, Self.place)
        XCTAssertEqual(imported.book.bookmarks, [Self.bookmark])
        XCTAssertEqual(imported.book.tmbDirectory.path, kept.tmbDirectory.path)
    }

    /// The same RTFD in a package of another book ID (a copy made on another
    /// Mac) is found to hold the retained package's content by its folder
    /// checksum, so the retained package is taken back instead of the book
    /// being copied a second time.
    @MainActor
    func testAnRTFDPackageUnderAnotherIDTakesBackTheRetainedPackage() throws {
        let sample = try copyOfFormatSample("rtfd/with-image.rtfd")
        let kept = try importedWithPlace(sample)
        let other = try makeExternalRTFDPackage(copying: sample, bookID: UUID())
        try removeFromLibraryOnly(kept)

        let source = try FileImportService.identifyTMBPackage(at: other)
        let imported = try FileImportService.importTMBPackage(source)

        XCTAssertEqual(imported.book.tmbDirectory.path, kept.tmbDirectory.path)
        XCTAssertEqual(imported.book.id, source.bookID)
        XCTAssertEqual(imported.book.format, .rtfd)
        XCTAssertEqual(imported.book.readingPosition, Self.place)
    }

    // MARK: - Folders of Tracks Stay Audio

    /// A folder of audio tracks in a package is still audio content, known
    /// by a checksum made from its book ID, and a folder that is not an
    /// RTFD is told apart from one.
    func testAFolderThatIsNotAnRTFDIsStillAFolderOfTracks() throws {
        let folder = try makeSandboxDirectory("Tracks")
        let tracks = folder.appendingPathComponent("Tracks", isDirectory: true)
        try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
        let rtfd = folder.appendingPathComponent("Notes.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: rtfd, withIntermediateDirectories: true)
        let fileNamedRTFD = folder.appendingPathComponent("Plain.rtfd")
        try Data("not a folder".utf8).write(to: fileNamedRTFD)
        let bookID = UUID()

        XCTAssertFalse(FileImportService.isRTFDFolder(tracks))
        XCTAssertTrue(FileImportService.isRTFDFolder(rtfd))
        XCTAssertFalse(FileImportService.isRTFDFolder(fileNamedRTFD), "a plain file named .rtfd is a file")
        XCTAssertEqual(
            try FileImportService.contentHash(of: tracks, bookID: bookID),
            "package-\(bookID.uuidString.lowercased())"
        )
        XCTAssertEqual(
            try FileImportService.contentHash(of: fileNamedRTFD, bookID: bookID),
            try FileImportService.md5Hash(of: fileNamedRTFD)
        )
    }

    // MARK: - Helpers

    /// The reading position every test book is given.
    private static let place: ReadingPosition = {
        var position = ReadingPosition(characterOffset: 14, globalCharacterOffset: 14)
        position.lastUpdated = fixedDate
        return position
    }()

    /// The bookmark every test book is given.
    private static let bookmark = Bookmark(
        number: 1, chapterIndex: 0, characterOffset: 4, label: "Pictured line", dateCreated: fixedDate
    )

    /// Imports the RTFD at `sample` as Open Book does, gives the book its
    /// reading position and bookmark, and saves its record, so the library
    /// package holds them. The package is removed when the test ends.
    private func importedWithPlace(_ sample: URL) throws -> Book {
        var book = try importedForTest(sample).book
        XCTAssertEqual(book.format, .rtfd)
        book.readingPosition = Self.place
        book.bookmarks = [Self.bookmark]
        try book.saveBookInfoThrowing()
        return book
    }

    /// A copy of `book`'s package in a folder of its own outside the library.
    private func copyOutOfLibrary(_ book: Book) throws -> URL {
        let copy = try makeSandboxDirectory("RTFDPackage").appendingPathComponent(book.tmbDirectoryName, isDirectory: true)
        try FileManager.default.copyItem(at: book.tmbDirectory, to: copy)
        return copy
    }

    /// A package outside the library holding a copy of the RTFD `sample`
    /// under a record of `bookID`, with the place and bookmark, as another
    /// Mac would have made it.
    private func makeExternalRTFDPackage(copying sample: URL, bookID: UUID) throws -> URL {
        let package = try makeSandboxDirectory("RTFDPackage").appendingPathComponent("Shared Copy.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = package.appendingPathComponent(sample.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: sample, to: content)
        let book = Book(
            id: bookID,
            title: "Shared Copy",
            author: "Test Fixture",
            format: .rtfd,
            filePath: content.path,
            md5Hash: try FileImportService.contentChecksum(of: content, format: .rtfd),
            dateAdded: Self.fixedDate,
            readingPosition: Self.place,
            bookmarks: [Self.bookmark],
            tmbDirectoryName: package.lastPathComponent
        )
        try book.makeBookInfo().save(to: package)
        return package
    }

    /// Takes `book` out with Remove from Library Only, through a library
    /// model that lists it. Only a removal expected to report a record it
    /// could not delete may raise the alert.
    @MainActor
    private func removeFromLibraryOnly(_ book: Book, expectingReport: Bool = false) throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        model.removeBooksFromLibraryOnly([book])
        XCTAssertNil(model.bookByID(book.id), "the removal must take the book out")
        XCTAssertEqual(model.showError, expectingReport, model.errorMessage ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.removedFromLibraryMarkerPath(in: book.tmbDirectory).path))
        LibraryPersistenceService.flushPendingSave()
    }

    /// Whether `path` is a folder.
    private func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

private extension Book {
    /// The last component of the book's file path: the name of its content
    /// inside its package.
    var filePathLastComponent: String { URL(fileURLWithPath: filePath).lastPathComponent }
}
