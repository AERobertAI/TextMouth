import XCTest
@testable import TextMouth

/// Saving edited EPUB metadata writes the library's copy of the EPUB file
/// first and publishes only what was saved (TODO A09). After a write that
/// fails, the library row, the book's record (bookInfo.json), and the file
/// all stay as they were, and the failure names the file; after a success
/// all of them hold the edit, the file's new content hash included.
/// Fixtures are real packages in the hosted test root, each holding a copy
/// of the Alice EPUB, removed when the test ends.
@MainActor
final class EPUBMetadataWritebackTests: XCTestCase {
    /// What a save reports when writing the library's copy of the fixture
    /// is refused (`EPUBMetadataWriter.refusingReplacement`).
    private static let refusedWriteMessage =
        "Could not save metadata to the library's copy of “alice.epub”: The volume is read-only. Nothing was changed."

    // MARK: - The Library's Save

    /// The library's editor saves through the same path as the reader's, so
    /// a write that fails is reported with the file's name instead of being
    /// dropped, and changes neither the row, nor the record, nor the file.
    /// No library alert is raised either: the editor, still open, shows it.
    func testTheLibrarysSaveReportsAFailedWriteAndChangesNothing() throws {
        let book = try makePackagedEPUB()
        let library = makeLibrary(with: book)
        let fileBefore = try Data(contentsOf: book.bookFileURL)

        let save = library.saveEPUBMetadata(
            try editedMetadata(of: book),
            for: book,
            writingToFile: true,
            writer: .refusingReplacement
        )

        XCTAssertNil(save.savedBook)
        XCTAssertEqual(save.outcome, .failure(Self.refusedWriteMessage))
        XCTAssertEqual(try agreedMetadata(of: book, in: library), SavedMetadata(book))
        XCTAssertEqual(try Data(contentsOf: book.bookFileURL), fileBefore)
        XCTAssertFalse(library.showError)
        XCTAssertNil(library.errorMessage)
    }

    /// The edit applies to the book where the library holds it now: an
    /// editor whose copy of the book names an older location still writes
    /// the library's copy, and the row and the record take the edit with
    /// the written file's new hash.
    func testTheLibrarysSaveWritesTheFileWhereTheLibraryHoldsItNow() throws {
        let book = try makePackagedEPUB()
        let library = makeLibrary(with: book)
        var staleCopy = book
        staleCopy.filePath = "/Volumes/Unmounted/\(UUID().uuidString).epub"
        let edited = try editedMetadata(of: book)

        let save = library.saveEPUBMetadata(edited, for: staleCopy, writingToFile: true)

        XCTAssertEqual(save.outcome, .success("Metadata saved to the library's copy of “alice.epub”."))
        let newHash = try FileImportService.md5Hash(of: book.bookFileURL)
        XCTAssertNotEqual(newHash, book.md5Hash)
        XCTAssertEqual(save.savedBook.map { SavedMetadata($0) }, .edited(hash: newHash))
        XCTAssertEqual(try agreedMetadata(of: book, in: library), .edited(hash: newHash))
        XCTAssertEqual(editableFields(of: try EPUBParser.readMetadata(url: book.bookFileURL)), editableFields(of: edited))
    }

    /// A book that has left the library has nowhere to save its edit:
    /// nothing is written, not even the EPUB file, and the failure says why.
    func testABookThatLeftTheLibraryIsNotSaved() throws {
        let book = try makePackagedEPUB()
        let library = makeLibrary(with: book)
        library.library = Library(books: [])
        let fileBefore = try Data(contentsOf: book.bookFileURL)

        let save = library.saveEPUBMetadata(try editedMetadata(of: book), for: book, writingToFile: true)

        XCTAssertEqual(
            save.outcome,
            .failure("Could not save metadata: “Alice's Adventures in Wonderland” is no longer in the library. Nothing was changed.")
        )
        XCTAssertEqual(try Data(contentsOf: book.bookFileURL), fileBefore)
        XCTAssertEqual(SavedMetadata(try BookInfo.load(from: book.tmbDirectory)), SavedMetadata(book))
    }

    // MARK: - Fixtures

    /// The Alice EPUB in the repository's test data.
    private static let aliceFixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("TestData/alice.epub")

    /// A managed EPUB book: a package in the isolated library holding a copy
    /// of the Alice EPUB as “alice.epub” and its bookInfo.json, removed when
    /// the test ends.
    private func makePackagedEPUB() throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        let packageName = "MetadataWriteback-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        addTeardownBlock {
            // Give write permission back first, in case the test took it.
            _ = chmod(package.path, 0o755)
            try? FileManager.default.removeItem(at: package)
        }
        let file = package.appendingPathComponent("alice.epub")
        try FileManager.default.copyItem(at: Self.aliceFixture, to: file)
        let book = Book(
            title: "Alice's Adventures in Wonderland",
            author: "Lewis Carroll",
            format: .epub,
            filePath: file.path,
            md5Hash: try FileImportService.md5Hash(of: file),
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing()
        return book
    }

    /// A library model listing `book`, without the app's services.
    private func makeLibrary(with book: Book) -> LibraryViewModel {
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        return library
    }

    /// The metadata an editor opens with for `book`, edited as
    /// `SavedMetadata.edited(hash:)` describes.
    private func editedMetadata(of book: Book) throws -> EPUBMetadata {
        var metadata = book.mergingEditableEPUBMetadata(try EPUBParser.readMetadata(url: book.bookFileURL))
        let edit = SavedMetadata.edited(hash: "")
        metadata.title = edit.title
        metadata.author = edit.author
        metadata.publisher = edit.publisher ?? ""
        metadata.publicationDate = edit.publicationDate ?? ""
        return metadata
    }

    /// The fields of `metadata` that an edit changes and a write puts in the
    /// file: title, author, publisher, and publication date.
    private func editableFields(of metadata: EPUBMetadata?) -> [String]? {
        metadata.map { [$0.title, $0.author, $0.publisher, $0.publicationDate] }
    }

    /// The metadata the library row and the book's record agree on, once
    /// every queued write has reached the disk. Fails when they disagree.
    private func agreedMetadata(
        of book: Book,
        in library: LibraryViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SavedMetadata {
        LibraryPersistenceService.flushPendingSave()
        let row = SavedMetadata(try XCTUnwrap(library.bookByID(book.id), "the book left the library", file: file, line: line))
        let record = SavedMetadata(try BookInfo.load(from: book.tmbDirectory))
        XCTAssertEqual(record, row, "bookInfo.json disagrees with the library row", file: file, line: line)
        return row
    }
}

// MARK: - Test Support

/// The metadata an EPUB save changes, as a book or its record holds it.
private struct SavedMetadata: Equatable {
    var title: String
    var author: String
    var publisher: String?
    var publicationDate: String?
    var md5Hash: String
}

private extension SavedMetadata {
    /// The metadata `book` holds.
    init(_ book: Book) {
        self.init(
            title: book.title,
            author: book.author,
            publisher: book.epubPublisher,
            publicationDate: book.epubPublicationDate,
            md5Hash: book.md5Hash
        )
    }

    /// The metadata a package's bookInfo.json holds.
    init(_ record: BookInfo) {
        self.init(
            title: record.metadata.title,
            author: record.metadata.author,
            publisher: record.metadata.publisher,
            publicationDate: record.metadata.publicationDate,
            md5Hash: record.metadata.md5Hash
        )
    }

    /// The edit every test makes, saved with the content hash `hash`.
    static func edited(hash: String) -> SavedMetadata {
        SavedMetadata(
            title: "The Annotated Rabbit Hole",
            author: "Ottoline Brabazon",
            publisher: "Tollgate Press",
            publicationDate: "2026-10-02",
            md5Hash: hash
        )
    }
}

private extension EPUBMetadataWriter {
    /// The app's write, refused at its last step as a read-only volume would
    /// refuse it: everything before runs, and the file stays as it was.
    static let refusingReplacement = EPUBMetadataWriter { metadata, file in
        try EPUBParser.writeMetadata(metadata, to: file, replacingWith: { _, _ in throw WriteRefused() })
    }
}
