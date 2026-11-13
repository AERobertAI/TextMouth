import Combine
import XCTest
import ZIPFoundation
@testable import TextMouth

/// Saving edited EPUB metadata writes the library's copy of the EPUB file
/// first and publishes only what was saved (TODO A09). After a write that
/// fails, the reader, the library row, the book's record (bookInfo.json),
/// and the file all stay as they were, and the failure names the file;
/// after a success all of them hold the edit, the file's new content hash
/// included. Fixtures are real packages in the hosted test root, each
/// holding a copy of the Alice EPUB, removed when the test ends.
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
            openedAs: try openedMetadata(of: book),
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

    /// A file missing from the library is told apart from one that could not
    /// be written: the sentence says it is missing, names the choice that
    /// saves to the library only, and reads out no path. The row, the
    /// record, and the file stay as they were.
    func testTheLibrarysSaveSaysAMissingFileIsMissing() throws {
        let book = try makePackagedEPUB()
        let library = makeLibrary(with: book)
        let fileBefore = try Data(contentsOf: book.bookFileURL)
        let wording = EPUBMetadataSaveWording(filePath: book.filePath)
        let writerReportingItMissing = EPUBMetadataWriter { _, file in
            throw EPUBParserError.fileNotFound(file.path)
        }

        let save = library.saveEPUBMetadata(
            try editedMetadata(of: book),
            openedAs: try openedMetadata(of: book),
            for: book,
            writingToFile: true,
            writer: writerReportingItMissing
        )

        XCTAssertNil(save.savedBook)
        XCTAssertEqual(save.outcome, .failure(wording.fileMissing))
        XCTAssertTrue(wording.fileMissing.contains("is missing from the library"))
        XCTAssertTrue(wording.fileMissing.contains("Also write to the library's copy of the EPUB file"))
        XCTAssertFalse(save.outcome.failureMessage?.contains("/") ?? true, "no path is read out")
        XCTAssertEqual(try agreedMetadata(of: book, in: library), SavedMetadata(book))
        XCTAssertEqual(try Data(contentsOf: book.bookFileURL), fileBefore)
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

        let save = library.saveEPUBMetadata(edited, openedAs: try openedMetadata(of: book), for: staleCopy, writingToFile: true)

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

        let save = library.saveEPUBMetadata(
            try editedMetadata(of: book), openedAs: try openedMetadata(of: book), for: book, writingToFile: true
        )

        XCTAssertEqual(
            save.outcome,
            .failure("Could not save metadata: “Alice's Adventures in Wonderland” is no longer in the library. Nothing was changed.")
        )
        XCTAssertEqual(try Data(contentsOf: book.bookFileURL), fileBefore)
        XCTAssertEqual(SavedMetadata(try BookInfo.load(from: book.tmbDirectory)), SavedMetadata(book))
    }

    /// Saving a book's details finds the package document the way reading
    /// does, without regard to case (ST09): a book whose container.xml names
    /// `OEBPS/Content.opf` while its ZIP holds `oebps/content.opf` is saved,
    /// the edit reads back, and the member keeps the spelling the ZIP used
    /// (no second copy of the package document appears).
    func testSavingDetailsFindsAPackageDocumentWhoseCaseDiffersFromTheContainers() throws {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/Content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opf = TextPipelineFixtures.packageDocument(
            metadata: "<dc:title>Before</dc:title><dc:creator>Someone Else</dc:creator>"
        )
        let chapter = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Words.</p></body></html>"
        let epub = try TextPipelineFixtures.writeEPUB([
            TestZIPEntry("mimetype", Data("application/epub+zip".utf8)),
            TestZIPEntry("META-INF/container.xml", Data(container.utf8)),
            TestZIPEntry("oebps/content.opf", Data(opf.utf8)),
            TestZIPEntry("oebps/chapter.xhtml", Data(chapter.utf8)),
        ], named: "lowercase-package.epub", for: self)
        var metadata = try EPUBParser.readMetadata(url: epub)
        XCTAssertEqual(metadata.title, "Before", "the fixture must be readable before it is written")
        metadata.title = "After"

        XCTAssertNoThrow(try EPUBParser.writeMetadata(metadata, to: epub))

        XCTAssertEqual(try EPUBParser.readMetadata(url: epub).title, "After")
        let archive = try XCTUnwrap(Archive.openedForReading(at: epub))
        let paths = archive.map(\.path)
        XCTAssertEqual(paths.filter { $0.lowercased() == "oebps/content.opf" }, ["oebps/content.opf"],
                       "the package document keeps its own spelling and is not duplicated; the members are \(paths)")
        // Every member is still there, once, and `mimetype` is still first,
        // as the EPUB container format requires of the book's first entry.
        XCTAssertEqual(
            paths.sorted(),
            ["META-INF/container.xml", "mimetype", "oebps/chapter.xhtml", "oebps/content.opf"],
            "the members are \(paths)"
        )
        XCTAssertEqual(paths.first, "mimetype", "the members are \(paths)")
    }

    /// A save records the fields it changed as edited by hand, on the row
    /// and in the record alike: the first save of a book imported before
    /// edits were recorded begins its record, a later save adds the fields
    /// it changes, and a save that changes nothing adds none.
    func testASaveRecordsTheFieldsItChangedAndALaterSaveAddsToThem() throws {
        let book = try makePackagedEPUB()
        let library = makeLibrary(with: book)
        XCTAssertNil(book.handEdits, "nothing has recorded the fixture's edits")

        var retitled = try openedMetadata(of: book)
        retitled.title = "Alice Underground"
        let first = library.saveEPUBMetadata(retitled, openedAs: try openedMetadata(of: book), for: book, writingToFile: false)
        XCTAssertTrue(first.outcome.succeeded)
        XCTAssertEqual(try agreedMetadata(of: book, in: library).handEdits, Book.HandEdits(fields: [.title], sinceImport: false))

        let row = try XCTUnwrap(library.bookByID(book.id))
        let second = library.saveEPUBMetadata(try editedMetadata(of: row), openedAs: try openedMetadata(of: row), for: row, writingToFile: false)
        XCTAssertTrue(second.outcome.succeeded)
        XCTAssertEqual(try agreedMetadata(of: book, in: library), .edited(hash: book.md5Hash))

        let unchanged = try openedMetadata(of: try XCTUnwrap(library.bookByID(book.id)))
        let third = library.saveEPUBMetadata(unchanged, openedAs: unchanged, for: row, writingToFile: false)
        XCTAssertTrue(third.outcome.succeeded)
        XCTAssertEqual(try agreedMetadata(of: book, in: library), .edited(hash: book.md5Hash))
    }

    // MARK: - The Reader's Save

    /// A write of the library's copy that fails changes nothing: the
    /// reader's metadata and book, the library row, the record, and the file
    /// all stay exactly as they were. The failure names the file and why, in
    /// the outcome the editor shows and in what VoiceOver hears, and is not
    /// raised again as the reader's error alert behind the editor.
    func testAFailedWriteLeavesTheReaderTheLibraryTheRecordAndTheFileAsTheyWere() async throws {
        let book = try makePackagedEPUB()
        let reader = try await makeLoadedReader(for: book, in: makeLibrary(with: book))
        let metadataBefore = editableFields(of: reader.epubMetadata)
        let savedBefore = try agreedMetadata(of: reader)
        let fileBefore = try Data(contentsOf: book.bookFileURL)
        let opened = try XCTUnwrap(reader.epubMetadata, "the reader shows no metadata to edit")
        let edited = try editedMetadata(of: book)

        var outcome: OperationOutcome?
        let recorder = recordingAnnouncements {
            outcome = reader.saveEPUBMetadata(edited, openedAs: opened, writeToFile: true, writer: .refusingReplacement)
        }

        XCTAssertEqual(outcome, .failure(Self.refusedWriteMessage))
        XCTAssertEqual(recorder.announcements.map(\.message), [Self.refusedWriteMessage])
        XCTAssertNil(reader.errorMessage, "the open editor shows the failure; no alert waits behind it")
        XCTAssertEqual(editableFields(of: reader.epubMetadata), metadataBefore)
        XCTAssertEqual(try agreedMetadata(of: reader), savedBefore)
        XCTAssertEqual(try Data(contentsOf: book.bookFileURL), fileBefore)
    }

    /// A write that works saves the edit everywhere at once: the file, the
    /// reader's metadata and book, the library row, and the record all hold
    /// it with the file's new content hash, and VoiceOver hears which file
    /// was written.
    func testASuccessfulWriteUpdatesTheReaderTheLibraryTheRecordAndTheHash() async throws {
        let book = try makePackagedEPUB()
        let reader = try await makeLoadedReader(for: book, in: makeLibrary(with: book))
        let opened = try XCTUnwrap(reader.epubMetadata, "the reader shows no metadata to edit")
        let edited = try editedMetadata(of: book)

        var outcome: OperationOutcome?
        let recorder = recordingAnnouncements {
            outcome = reader.saveEPUBMetadata(edited, openedAs: opened, writeToFile: true)
        }

        let saved = "Metadata saved to the library's copy of “alice.epub”."
        XCTAssertEqual(outcome, .success(saved))
        XCTAssertEqual(recorder.announcements.map(\.message), [saved])
        let newHash = try FileImportService.md5Hash(of: book.bookFileURL)
        XCTAssertNotEqual(newHash, book.md5Hash)
        XCTAssertEqual(try agreedMetadata(of: reader), .edited(hash: newHash))
        XCTAssertEqual(editableFields(of: reader.epubMetadata), editableFields(of: edited))
        XCTAssertEqual(editableFields(of: try EPUBParser.readMetadata(url: book.bookFileURL)), editableFields(of: edited))
    }

    /// Saving to the library only leaves the EPUB file and its hash exactly
    /// as they were, saves the edit to the reader, the library row, and the
    /// record, and says that the file is unchanged.
    func testALibraryOnlySaveLeavesTheFileAndItsHashUnchanged() async throws {
        let book = try makePackagedEPUB()
        let reader = try await makeLoadedReader(for: book, in: makeLibrary(with: book))
        let opened = try XCTUnwrap(reader.epubMetadata, "the reader shows no metadata to edit")
        let edited = try editedMetadata(of: book)
        let fileBefore = try Data(contentsOf: book.bookFileURL)

        var outcome: OperationOutcome?
        let recorder = recordingAnnouncements {
            outcome = reader.saveEPUBMetadata(edited, openedAs: opened, writeToFile: false)
        }

        let libraryOnly = "Metadata saved to the library only; the EPUB file is unchanged."
        XCTAssertEqual(outcome, .success(libraryOnly))
        XCTAssertEqual(recorder.announcements.map(\.message), [libraryOnly])
        XCTAssertEqual(try Data(contentsOf: book.bookFileURL), fileBefore)
        XCTAssertEqual(try agreedMetadata(of: reader), .edited(hash: book.md5Hash))
        XCTAssertEqual(editableFields(of: reader.epubMetadata), editableFields(of: edited))
    }

    /// A package that cannot be written makes the real write fail before it
    /// changes anything. The failure names the library's copy and gives the
    /// system's reason, and no write of the book's record was attempted, so
    /// nothing reaches the failure banner either.
    func testAPackageThatCannotBeWrittenFailsBeforeAnythingIsWritten() async throws {
        let center = cleanSharedFailureCenter()
        let book = try makePackagedEPUB()
        let reader = try await makeLoadedReader(for: book, in: makeLibrary(with: book))
        let opened = try XCTUnwrap(reader.epubMetadata, "the reader shows no metadata to edit")
        let edited = try editedMetadata(of: book)
        let savedBefore = try agreedMetadata(of: reader)
        let fileBefore = try Data(contentsOf: book.bookFileURL)
        makeReadOnly(book.tmbDirectory)

        let outcome = reader.saveEPUBMetadata(edited, openedAs: opened, writeToFile: true)

        let failure = try XCTUnwrap(outcome.failureMessage)
        XCTAssertTrue(failure.hasPrefix("Could not save metadata to the library's copy of “alice.epub”: "), failure)
        XCTAssertTrue(failure.hasSuffix(" Nothing was changed."), failure)
        XCTAssertEqual(reader.lastAnnouncement, failure)
        XCTAssertEqual(try agreedMetadata(of: reader), savedBefore)
        XCTAssertEqual(try Data(contentsOf: book.bookFileURL), fileBefore)
        XCTAssertTrue(center.outstandingFailures().isEmpty, "\(center.outstandingFailures().map(\.sentence))")
    }

    // MARK: - The Editor's Words

    /// The editor says which file it writes. The choice to write the file
    /// names the library's copy and its hint says the imported original is
    /// not touched; VoiceOver's label for Save follows the choice in both of
    /// its states. Nothing the editor says claims to change the original.
    func testTheEditorSaysWhichFileItWrites() {
        typealias Wording = EPUBMetadataSaveWording
        XCTAssertEqual(Wording.writeBackToggleTitle, "Also write to the library's copy of the EPUB file")
        XCTAssertTrue(
            Wording.writeBackToggleHint.hasSuffix("The original file you imported is not touched."),
            Wording.writeBackToggleHint
        )
        XCTAssertEqual(Wording.saveButtonLabel(writesToFile: false), "Save metadata to the library only")
        XCTAssertEqual(
            Wording.saveButtonLabel(writesToFile: true),
            "Save metadata to the library and to the library's copy of the EPUB file"
        )

        let everything = [
            Wording.writeBackToggleTitle,
            Wording.writeBackToggleHint,
            Wording.writeBackNote,
            Wording.saveButtonLabel(writesToFile: false),
            Wording.saveButtonLabel(writesToFile: true)
        ]
        for words in everything {
            XCTAssertFalse(words.localizedCaseInsensitiveContains("original EPUB"), words)
            XCTAssertFalse(words.localizedCaseInsensitiveContains("modify the original"), words)
        }
    }

    // MARK: - Fixtures

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
        try FileManager.default.copyItem(at: requireFile("alice.epub"), to: file)
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

    /// A reader for `book`, returned once its content and metadata have
    /// loaded and every write the load queued has reached the disk, so that
    /// afterwards only the save under test changes anything. The reader is
    /// closed when the test ends.
    private func makeLoadedReader(for book: Book, in library: LibraryViewModel) async throws -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false),
            notificationCenter: NotificationCenter()
        )
        addTeardownBlock { await reader.close() }
        let loaded = expectation(description: "Content loaded")
        let subscription = reader.$isLoading.filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        defer { subscription.cancel() }
        await fulfillment(of: [loaded], timeout: 10)
        XCTAssertNil(reader.errorMessage, "the fixture did not load")
        // The fixture's row keeps none of the EPUB's metadata, so the reader
        // reads it from the file once the book shows (`showEPUBMetadata()`),
        // and keeps it on the row and in the record then, as the import
        // would have: that is the state a save then starts from.
        let metadataShown = expectation(description: "EPUB metadata shown")
        let metadataSubscription = reader.$epubMetadata.compactMap { $0 }.prefix(1).sink { _ in
            metadataShown.fulfill()
        }
        defer { metadataSubscription.cancel() }
        await fulfillment(of: [metadataShown], timeout: 10)
        XCTAssertNotNil(reader.epubMetadata, "the fixture's metadata did not load")
        LibraryPersistenceService.flushPendingSave()
        return reader
    }

    /// The metadata an editor opens with for `book`: the file's, with the
    /// book's own edits laid over it, as Book Info reads it.
    private func openedMetadata(of book: Book) throws -> EPUBMetadata {
        book.mergingEditableEPUBMetadata(try EPUBParser.readMetadata(url: book.bookFileURL))
    }

    /// The metadata an editor opens with for `book`, edited as
    /// `SavedMetadata.edited(hash:)` describes.
    private func editedMetadata(of book: Book) throws -> EPUBMetadata {
        var metadata = try openedMetadata(of: book)
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

    /// The metadata the reader's book, the library row, and the book's
    /// record all agree on, once every queued write has reached the disk.
    /// Fails when any of them disagrees.
    private func agreedMetadata(
        of reader: ReaderViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SavedMetadata {
        let saved = try agreedMetadata(of: reader.book, in: reader.libraryViewModel, file: file, line: line)
        XCTAssertEqual(SavedMetadata(reader.book), saved, "the reader's book disagrees with the library", file: file, line: line)
        return saved
    }
}

// MARK: - Test Support

/// The metadata an EPUB save changes, as a book or its record holds it,
/// with the record of which fields were edited by hand.
private struct SavedMetadata: Equatable {
    var title: String
    var author: String
    var publisher: String?
    var publicationDate: String?
    var md5Hash: String
    var handEdits: Book.HandEdits?
}

private extension SavedMetadata {
    /// The metadata `book` holds.
    init(_ book: Book) {
        self.init(
            title: book.title,
            author: book.author,
            publisher: book.epubPublisher,
            publicationDate: book.epubPublicationDate,
            md5Hash: book.md5Hash,
            handEdits: book.handEdits
        )
    }

    /// The metadata a package's bookInfo.json holds.
    init(_ record: BookInfo) {
        self.init(
            title: record.metadata.title,
            author: record.metadata.author,
            publisher: record.metadata.publisher,
            publicationDate: record.metadata.publicationDate,
            md5Hash: record.metadata.md5Hash,
            handEdits: record.metadata.handEdits
        )
    }

    /// The edit every test makes, saved with the content hash `hash`: every
    /// editable field changed, so every one is recorded as edited by hand,
    /// in a record begun by that edit.
    static func edited(hash: String) -> SavedMetadata {
        SavedMetadata(
            title: "The Annotated Rabbit Hole",
            author: "Ottoline Brabazon",
            publisher: "Tollgate Press",
            publicationDate: "2026-10-02",
            md5Hash: hash,
            handEdits: Book.HandEdits(fields: [.title, .author, .publisher, .publicationDate], sinceImport: false)
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
