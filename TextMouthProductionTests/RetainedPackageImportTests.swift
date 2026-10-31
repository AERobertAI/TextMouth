import XCTest
@testable import TextMouth

/// Importing a package of a book that Remove from Library Only took out takes
/// back the package the removal retained, where it is, instead of copying
/// the book a second time (TODO S02, following S06). The removal deletes the
/// package's bookInfo.json, so the record is usually rebuilt from the
/// removal marker. Tests use real packages in the isolated test root and put
/// its library index back afterwards. None asks for a reader window, which
/// the hosted app would really open.
final class RetainedPackageImportTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox!
    /// Directories this test created, removed after it with everything inside.
    private var createdDirectories: [URL] = []

    /// A fixed moment in whole seconds, since bookInfo.json stores dates to
    /// the second.
    private static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        createdDirectories = []
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
        for directory in createdDirectories {
            Self.forceRemove(directory)
        }
    }

    // MARK: - The Retained Package Itself

    /// The acceptance case: a package whose record the removal deleted is
    /// identified by its marker and taken back where it is, under its own
    /// ID, title, and checksum, with its marker cleared and a record that
    /// reads back. No copy is made, opening it again finds the listed book,
    /// its metadata is saved again, and a restart lists it once.
    @MainActor
    func testImportingARetainedPackageTakesItBackOnceWithItsMarkerCleared() throws {
        let book = try makePackage(title: "Gear Ratios")
        try removeFromLibraryOnly(book)
        XCTAssertFalse(exists(record(of: book)), "the removal deletes the record")

        let source = try FileImportService.identifyTMBPackage(at: book.tmbDirectory)
        XCTAssertNil(source.inspection)
        XCTAssertEqual(source.bookID, book.id)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        XCTAssertNil(model.listedBookID(for: source))

        let imported = try FileImportService.importTMBPackage(source)
        model.completePackageImport(imported, openAfterImport: false)

        let returned = imported.book
        XCTAssertEqual(returned.id, book.id)
        XCTAssertEqual(returned.title, "Gear Ratios")
        XCTAssertEqual(returned.author, "Test Fixture")
        XCTAssertEqual(returned.md5Hash, book.md5Hash)
        XCTAssertEqual(returned.folderPath, book.folderPath)
        XCTAssertEqual(returned.tmbDirectory.path, book.tmbDirectory.path)
        XCTAssertEqual(returned.filePath, book.filePath)
        XCTAssertFalse(exists(marker(of: book)))
        let saved = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(saved.metadata.bookID, book.id)
        XCTAssertNotNil(saved.contentIndex)
        XCTAssertEqual(model.library.books.map(\.id), [book.id])
        XCTAssertEqual(try packageNames(in: book.folderPath), [book.tmbDirectoryName])
        XCTAssertFalse(try libraryTopLevelHoldsPackage(of: book.id))

        let again = try FileImportService.identifyTMBPackage(at: book.tmbDirectory)
        XCTAssertEqual(model.listedBookID(for: again), book.id, "a second open finds the listed book")

        var edited = try XCTUnwrap(model.bookByID(book.id))
        edited.manualSortOrder = 3
        LibraryPersistenceService.saveBookInfo(for: edited)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).state.manualSortOrder, 3)
        let restarted = LibraryViewModel(initializeServices: false)
        restarted.loadLibraryIndex()
        XCTAssertEqual(restarted.library.books.filter { $0.id == book.id }.count, 1)
    }

    /// A retained package that kept its record (its deletion failed) comes
    /// back with that record's reading position and bookmarks.
    @MainActor
    func testRetainedPackageThatKeptItsRecordReturnsWithItsPositionAndBookmarks() throws {
        let position = Self.position(at: 14)
        let bookmark = Bookmark(
            number: 1, chapterIndex: 0, characterOffset: 4, label: "Spoke count", dateCreated: Self.fixedDate
        )
        let book = try makePackage(title: "Wheel Truing", position: position, bookmarks: [bookmark])
        try lock(record(of: book))
        try removeFromLibraryOnly(book, expectingReport: true)
        try unlock(record(of: book))

        let source = try FileImportService.identifyTMBPackage(at: book.tmbDirectory)
        XCTAssertNotNil(source.inspection)
        let imported = try FileImportService.importTMBPackage(source)

        XCTAssertEqual(imported.book.tmbDirectory.path, book.tmbDirectory.path)
        XCTAssertEqual(imported.book.readingPosition, position)
        XCTAssertEqual(imported.book.bookmarks, [bookmark])
        XCTAssertFalse(exists(marker(of: book)))
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).bookmarks, [bookmark])
    }

    /// An audio book kept as a folder of tracks, whose record is gone, is
    /// rebuilt from its marker: an audio book whose checksum is made from
    /// its ID (the archive it came from is gone), with its tracks analyzed.
    @MainActor
    func testRetainedAudioBookWithoutARecordIsRebuiltFromItsMarker() throws {
        let book = try makeAudioPackage(title: "Cadence Drills")
        try removeFromLibraryOnly(book)

        let imported = try FileImportService.importTMBPackageWithReport(from: book.tmbDirectory)

        XCTAssertEqual(imported.book.id, book.id)
        XCTAssertEqual(imported.book.format, .audio)
        XCTAssertEqual(imported.book.filePath, book.filePath)
        XCTAssertEqual(imported.book.md5Hash, "package-\(book.id.uuidString.lowercased())")
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).contentIndex?.chapters.count, 1)
        XCTAssertFalse(exists(marker(of: book)))
    }

    /// A reinstatement that fails, while saving the record or while clearing
    /// the marker, leaves the package retired exactly as it was: the marker
    /// stays, the record and the content index beside it are put back (here:
    /// absent), the content stays, and adoption still leaves the package out.
    @MainActor
    func testFailedReinstatementLeavesThePackageRetiredAsItWas() throws {
        let book = try makePackage(title: "Chain Wear")
        try removeFromLibraryOnly(book)
        let source = try FileImportService.identifyTMBPackage(at: book.tmbDirectory)

        for failingStep in [ImportStep.savingRecord, .reinstating] {
            XCTAssertThrowsError(try FileImportService.importTMBPackage(source, observer: { step, _ in
                if step == failingStep { throw CocoaError(.fileWriteOutOfSpace) }
            })) { error in
                XCTAssertEqual((error as? ImportFailure)?.step, failingStep)
            }

            XCTAssertTrue(exists(marker(of: book)), "\(failingStep)")
            XCTAssertFalse(exists(record(of: book)), "\(failingStep)")
            XCTAssertFalse(exists(TextMouthPaths.contentIndexPath(in: book.tmbDirectory)), "\(failingStep)")
            XCTAssertTrue(exists(URL(fileURLWithPath: book.filePath)), "\(failingStep)")
            XCTAssertFalse(adoptedFromLibraryDirectory().books.contains { $0.id == book.id }, "\(failingStep)")
        }
    }

    // MARK: - Another Package of the Same Book

    /// A copy taken before the removal (with its record) brings back the
    /// retained package, not a second copy, with the copy's reading
    /// position. The chosen copy is left as it was.
    @MainActor
    func testImportingACopyOfARemovedBookTakesBackTheRetainedPackage() throws {
        let position = Self.position(at: 9)
        let book = try makePackage(title: "Tire Pressure", position: position)
        let copy = try copyOutOfLibrary(book)
        try removeFromLibraryOnly(book)
        let copyBefore = try snapshot(of: copy)

        let source = try FileImportService.identifyTMBPackage(at: copy)
        let imported = try FileImportService.importTMBPackage(source)

        XCTAssertEqual(imported.book.id, book.id)
        XCTAssertEqual(imported.book.tmbDirectory.path, book.tmbDirectory.path)
        XCTAssertEqual(imported.book.readingPosition, position)
        XCTAssertFalse(exists(marker(of: book)))
        XCTAssertTrue(exists(record(of: book)))
        XCTAssertFalse(try libraryTopLevelHoldsPackage(of: book.id))
        XCTAssertEqual(try snapshot(of: copy), copyBefore)
    }

    /// A package of the same content under another book ID also brings back
    /// the retained package, which takes the chosen package's record.
    @MainActor
    func testPackageWithTheSameContentUnderAnotherIDTakesBackTheRetainedPackage() throws {
        let book = try makePackage(title: "Derailleur Limits")
        let content = try Data(contentsOf: URL(fileURLWithPath: book.filePath))
        try removeFromLibraryOnly(book)
        let other = try makeExternalPackage(bookID: UUID(), title: "Derailleur Limits, Second Copy", content: content)

        let source = try FileImportService.identifyTMBPackage(at: other)
        let imported = try FileImportService.importTMBPackage(source)

        XCTAssertEqual(imported.book.tmbDirectory.path, book.tmbDirectory.path)
        XCTAssertEqual(imported.book.id, source.bookID)
        XCTAssertEqual(imported.book.title, "Derailleur Limits, Second Copy")
        XCTAssertFalse(exists(marker(of: book)))
        XCTAssertFalse(try libraryTopLevelHoldsPackage(of: source.bookID))
    }

    /// A package of the same book whose record describes other content does
    /// not fit the retained package, so it is imported as a new package,
    /// and the retained one stays retired.
    @MainActor
    func testPackageDescribingOtherContentIsImportedAsANewPackage() throws {
        let book = try makePackage(title: "Saddle Height")
        try removeFromLibraryOnly(book)
        let other = try makeExternalPackage(
            bookID: book.id,
            title: "Saddle Height",
            content: Data("A later edition of the saddle notes.".utf8)
        )

        let source = try FileImportService.identifyTMBPackage(at: other)
        XCTAssertEqual(
            FileImportService.retainedPackage(matching: source)?.resolvingSymlinksInPath().path,
            book.tmbDirectory.resolvingSymlinksInPath().path
        )
        let imported = try FileImportService.importTMBPackage(source)
        createdDirectories.append(imported.book.tmbDirectory)

        XCTAssertNotEqual(imported.book.tmbDirectory.path, book.tmbDirectory.path)
        XCTAssertEqual(imported.book.tmbDirectory.deletingLastPathComponent().path, TextMouthPaths.libraryDir.path)
        XCTAssertTrue(exists(marker(of: book)), "the retained package stays retired")
        XCTAssertFalse(exists(TextMouthPaths.removedFromLibraryMarkerPath(in: imported.book.tmbDirectory)))
    }

    /// A copy taken of a retained package after the removal (marker, no
    /// record), once the library no longer holds the retained package, is
    /// imported as a new package rebuilt from its marker, without the
    /// marker. The copy is left as it was.
    @MainActor
    func testCopyOfARetainedPackageIsRebuiltFromItsMarkerWhenTheLibraryHasNoneLeft() throws {
        let book = try makePackage(title: "Brake Cable")
        try removeFromLibraryOnly(book)
        let copy = try copyOutOfLibrary(book)
        Self.forceRemove(book.tmbDirectory)
        let copyBefore = try snapshot(of: copy)

        let imported = try FileImportService.importTMBPackageWithReport(from: copy)
        createdDirectories.append(imported.book.tmbDirectory)

        XCTAssertEqual(imported.book.id, book.id)
        XCTAssertEqual(imported.book.title, "Brake Cable")
        XCTAssertEqual(imported.book.author, "Test Fixture")
        XCTAssertEqual(imported.book.md5Hash, book.md5Hash)
        XCTAssertNil(imported.book.readingPosition)
        XCTAssertEqual(imported.book.tmbDirectory.deletingLastPathComponent().path, TextMouthPaths.libraryDir.path)
        XCTAssertFalse(exists(TextMouthPaths.removedFromLibraryMarkerPath(in: imported.book.tmbDirectory)))
        XCTAssertEqual(try BookInfo.load(from: imported.book.tmbDirectory).metadata.bookID, book.id)
        XCTAssertEqual(try snapshot(of: copy), copyBefore)
    }

    // MARK: - A Book the Library Still Lists

    /// Opening a retired package of a book the library lists again (from
    /// another package) opens the listed book and leaves its listing where
    /// it is, rather than pointing it at the retired package.
    @MainActor
    func testRetiredPackageIsNeverTakenAsAListedBooksOwnPackage() throws {
        let retained = try makePackage(title: "Bottom Bracket")
        try lock(record(of: retained))
        try removeFromLibraryOnly(retained, expectingReport: true)
        try unlock(record(of: retained))
        var listed = retained
        listed.folderPath = uniqueFolderName("Relisted Shelf")
        listed.tmbDirectoryName = "Relisted-\(UUID().uuidString).tmb"
        listed.filePath = listed.tmbDirectory.appendingPathComponent("book.txt").path
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [listed])

        let source = try FileImportService.identifyTMBPackage(at: retained.tmbDirectory)

        XCTAssertEqual(model.listedBookID(for: source), listed.id)
        XCTAssertEqual(model.library.books, [listed])
    }

    /// Opening a listed book's own package still repairs a listing whose
    /// folder went stale, as before.
    @MainActor
    func testListedBookIsStillRepairedFromItsOwnPackage() throws {
        let book = try makePackage(title: "Pedal Threads")
        var stale = book
        stale.folderPath = "Shelf That Moved"
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [stale])

        let source = try FileImportService.identifyTMBPackage(at: book.tmbDirectory)

        XCTAssertEqual(model.listedBookID(for: source), book.id)
        XCTAssertEqual(model.bookByID(book.id)?.folderPath, book.folderPath)
    }

    // MARK: - Text the User Changed (B12)

    /// A book whose text the user changed with Edit Text, taken out with
    /// Remove from Library Only and added back by opening its package, keeps
    /// the edit: the removal marker carries the record of the edit and the
    /// fingerprints that describe it, so the book rebuilt from the marker
    /// keeps content.md byte for byte and records the edit, in the book and
    /// in its record, and no copy is kept, since nothing was replaced. Until
    /// October 30, 2026 the marker left the edit out, and the book's file
    /// was read over it with no copy kept.
    @MainActor
    func testATextEditSurvivesRemovingTheBookAndAddingItBack() throws {
        let taken = try takingTextEdit(of: try makePackage(title: "Spoke Tension")) {
            $0.replacingOccurrences(of: "Notes on", with: "Corrected notes on")
        }
        try removeFromLibraryOnly(taken.book)
        XCTAssertFalse(exists(record(of: taken.book)), "the removal deletes the record")
        let written = try RemovedFromLibraryMarker.read(in: taken.book.tmbDirectory)
        XCTAssertEqual(written.editedText?.cacheDigest, taken.book.editedText?.cacheDigest)
        XCTAssertEqual(written.textCacheFingerprint, taken.book.textCacheFingerprint)

        let imported = try FileImportService.importTMBPackage(FileImportService.identifyTMBPackage(at: taken.book.tmbDirectory))

        let book = imported.book
        XCTAssertEqual(book.id, taken.book.id)
        XCTAssertEqual(book.tmbDirectory.path, taken.book.tmbDirectory.path)
        let cache = MarkdownCacheService.cacheURL(for: book)
        XCTAssertEqual(try Data(contentsOf: cache), taken.edited, "the book's file was read over the edit")
        let digest = FingerprintHasher.md5.digestOfData(taken.edited)
        XCTAssertEqual(book.editedText?.cacheDigest, digest)
        XCTAssertEqual(book.textCacheFingerprint?.cache.digest, digest)
        let saved = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(saved.state.editedText?.cacheDigest, digest)
        XCTAssertEqual(saved.state.textCacheFingerprint?.cache.digest, digest)
        XCTAssertTrue(BookTextEditSessions.holdsTakenEdit(book, access: .live), "a later re-read would not keep the edit")
        XCTAssertFalse(exists(marker(of: book)))
        XCTAssertEqual(keptTextCopies(of: cache), [], "a copy was kept of text nothing replaced")
    }

    /// A marker written before it carried an edit (no editedText or
    /// textCacheFingerprint key, written here by hand as an older TextMouth
    /// wrote it) still decodes, with neither, and its package is reinstated
    /// as before, its text read from the book's file.
    @MainActor
    func testAMarkerWrittenBeforeItCarriedAnEditStillReinstatesItsBook() throws {
        let book = try makePackage(title: "Rim Brakes")
        try removeFromLibraryOnly(book)
        let older = """
            {
              "author" : "Test Fixture",
              "bookID" : "\(book.id.uuidString)",
              "removedAt" : "2026-09-01T12:00:00Z",
              "title" : "Rim Brakes"
            }
            """
        try Data(older.utf8).write(to: marker(of: book), options: .atomic)

        let decoded = try RemovedFromLibraryMarker.read(in: book.tmbDirectory)
        XCTAssertEqual(decoded.bookID, book.id)
        XCTAssertEqual(decoded.title, "Rim Brakes")
        XCTAssertNil(decoded.editedText)
        XCTAssertNil(decoded.textCacheFingerprint)

        let imported = try FileImportService.importTMBPackage(FileImportService.identifyTMBPackage(at: book.tmbDirectory))

        XCTAssertEqual(imported.book.id, book.id)
        XCTAssertEqual(imported.book.tmbDirectory.path, book.tmbDirectory.path)
        XCTAssertNil(imported.book.editedText)
        XCTAssertEqual(
            try Data(contentsOf: MarkdownCacheService.cacheURL(for: imported.book)),
            try MarkdownCacheService.extractedText(for: imported.book, includesPages: true)?.bytes
        )
        XCTAssertFalse(exists(marker(of: book)))
    }

    /// Text changed by hand while the book was out of the library, which no
    /// record of an edit describes, is kept beside content.md when adding
    /// the book back reads its file again: the marker's fingerprints say
    /// what TextMouth last wrote there. Until October 30, 2026 the marker
    /// had none, and the changed text was lost.
    @MainActor
    func testTextChangedWhileTheBookWasRemovedIsKeptBesideItWhenAddedBack() throws {
        // Cached as an import caches it, so its record has fingerprints.
        var cached = try makePackage(title: "Brake Pads")
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &cached))
        let book = try XCTUnwrap(LibraryPersistenceService.saveContentAnalysis(
            for: cached, index: index, cacheFormatVersion: cached.cacheFormatVersion
        ))
        XCTAssertNotNil(book.textCacheFingerprint)
        try removeFromLibraryOnly(book)
        let cache = MarkdownCacheService.cacheURL(for: book)
        let changed = Data("<!-- chapter: Brake Pads -->\nToe the pads in slightly before tightening.\n".utf8)
        try changed.write(to: cache, options: .atomic)

        let imported = try FileImportService.importTMBPackage(FileImportService.identifyTMBPackage(at: book.tmbDirectory))

        XCTAssertNil(imported.book.editedText)
        XCTAssertEqual(keptTextCopies(of: cache).compactMap { try? Data(contentsOf: $0) }, [changed])
    }

    /// A reinstatement that fails after reading the book's text again puts
    /// content.md back as it was: here text changed by hand that nothing
    /// records, which the read replaced before the step that failed. The
    /// package stays retired, as before.
    @MainActor
    func testAFailedReinstatementPutsTheTextBackAsItWas() throws {
        let book = try makePackage(title: "Chain Lube")
        try removeFromLibraryOnly(book)
        let cache = MarkdownCacheService.cacheURL(for: book)
        let changed = Data("<!-- chapter: Chain Lube -->\nWipe the chain before each coat.\n".utf8)
        try changed.write(to: cache, options: .atomic)
        let source = try FileImportService.identifyTMBPackage(at: book.tmbDirectory)

        for failingStep in [ImportStep.savingRecord, .reinstating] {
            XCTAssertThrowsError(try FileImportService.importTMBPackage(source, observer: { step, _ in
                if step == failingStep { throw CocoaError(.fileWriteOutOfSpace) }
            })) { error in
                XCTAssertEqual((error as? ImportFailure)?.step, failingStep)
            }

            XCTAssertEqual(try Data(contentsOf: cache), changed, "\(failingStep)")
            XCTAssertTrue(exists(marker(of: book)), "\(failingStep)")
            XCTAssertFalse(exists(record(of: book)), "\(failingStep)")
        }
    }

    // MARK: - Fixtures

    /// A reading position at `offset` in the first chapter, last updated at
    /// `fixedDate`.
    private static func position(at offset: Int) -> ReadingPosition {
        var position = ReadingPosition(characterOffset: offset, globalCharacterOffset: offset)
        position.lastUpdated = fixedDate
        return position
    }

    /// A folder name unique to this test.
    private func uniqueFolderName(_ base: String) -> String {
        "\(base) \(UUID().uuidString.prefix(8))"
    }

    /// Creates a folder directory in the test root's library, removed after
    /// the test with everything inside.
    @discardableResult
    private func makeFolder(_ folder: String) throws -> URL {
        let directory = TextMouthPaths.libraryDir.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)
        return directory
    }

    /// Creates a real text package in a folder of its own, as an import
    /// leaves it: a document whose unique words give it a unique checksum,
    /// and a bookInfo.json holding `position` and `bookmarks`.
    private func makePackage(
        title: String,
        position: ReadingPosition? = nil,
        bookmarks: [Bookmark] = []
    ) throws -> Book {
        let folder = uniqueFolderName("Retained Shelf")
        try makeFolder(folder)
        let packageName = "RetainedPackage-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folder, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = package.appendingPathComponent("book.txt")
        try Data("Notes on \(title), kept as \(UUID().uuidString).".utf8).write(to: content)
        let book = Book(
            title: title,
            author: "Test Fixture",
            format: .txt,
            filePath: content.path,
            md5Hash: try FileImportService.md5Hash(of: content),
            folderPath: folder,
            dateAdded: Self.fixedDate,
            readingPosition: position,
            bookmarks: bookmarks,
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing()
        return book
    }

    /// Creates a real audio package, as an audio archive import leaves it:
    /// a folder of one playable track and a bookInfo.json.
    private func makeAudioPackage(title: String) throws -> Book {
        let folder = uniqueFolderName("Retained Audio Shelf")
        try makeFolder(folder)
        let packageName = "RetainedAudio-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folder, tmbName: packageName)
        let audio = package.appendingPathComponent("audio", isDirectory: true)
        try AudioTestFixtures.writeSilence(to: audio.appendingPathComponent("01.wav"))
        let book = Book(
            title: title,
            author: "Test Fixture",
            format: .audio,
            filePath: audio.path,
            md5Hash: "archive-\(UUID().uuidString)",
            folderPath: folder,
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing()
        return book
    }

    /// A package outside the library holding `content` as book.txt, with a
    /// record naming book `bookID` titled `title`.
    private func makeExternalPackage(bookID: UUID, title: String, content: Data) throws -> URL {
        let package = try makeScratchDirectory().appendingPathComponent("Shared Copy.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("book.txt")
        try content.write(to: file)
        let book = Book(
            id: bookID,
            title: title,
            author: "Test Fixture",
            format: .txt,
            filePath: file.path,
            md5Hash: try FileImportService.md5Hash(of: file),
            tmbDirectoryName: package.lastPathComponent
        )
        try book.makeBookInfo().save(to: package)
        return package
    }

    /// A copy of `book`'s package outside the library, as it is now.
    private func copyOutOfLibrary(_ book: Book) throws -> URL {
        let copy = try makeScratchDirectory().appendingPathComponent(book.tmbDirectoryName, isDirectory: true)
        try FileManager.default.copyItem(at: book.tmbDirectory, to: copy)
        return copy
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
        XCTAssertTrue(exists(marker(of: book)))
        LibraryPersistenceService.flushPendingSave()
    }

    /// What orphan adoption finds in the test root's library directory.
    private func adoptedFromLibraryDirectory() -> Library {
        var adopted = Library()
        FileImportService.adoptOrphanedTMBPackages(library: &adopted)
        return adopted
    }

    /// The visible names in the library folder `folder`.
    private func packageNames(in folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: TextMouthPaths.libraryDir.appendingPathComponent(folder, isDirectory: true).path
        ).filter { !$0.hasPrefix(".") }
    }

    /// Whether the library's top level holds a package named for `bookID`,
    /// as a copied import would be.
    private func libraryTopLevelHoldsPackage(of bookID: UUID) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: TextMouthPaths.libraryDir.path)
            .contains { $0.hasSuffix("\(bookID.uuidString.lowercased()).tmb") }
    }

    /// Every file directly in `package` by name, with its bytes.
    private func snapshot(of package: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: package.path) {
            files[name] = try Data(contentsOf: package.appendingPathComponent(name))
        }
        return files
    }

    /// bookInfo.json in `book`'s package.
    private func record(of book: Book) -> URL {
        TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
    }

    /// The removal marker in `book`'s package.
    private func marker(of book: Book) -> URL {
        TextMouthPaths.removedFromLibraryMarkerPath(in: book.tmbDirectory)
    }

    /// The copies of the user's text kept beside the content.md at `cache`
    /// (`TextMouthPaths.keptTextCopyMarker`).
    private func keptTextCopies(of cache: URL) -> [URL] {
        LibraryIndexQuarantine.existingCopies(of: cache, marker: TextMouthPaths.keptTextCopyMarker)
    }

    /// Whether anything exists at `url`.
    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Locks `file` as Finder's Locked checkbox does, so the removal cannot
    /// delete it.
    private func lock(_ file: URL) throws {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
    }

    /// Unlocks `file` again.
    private func unlock(_ file: URL) throws {
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
    }

    /// A new directory outside the library, removed after the test.
    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetainedPackage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)
        return directory
    }

    /// Removes `url` and everything inside it, first unlocking files and
    /// giving directories their write permission back.
    private static func forceRemove(_ url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        chmod(url.path, 0o755)
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in enumerator {
                try? fileManager.setAttributes([.immutable: false], ofItemAtPath: item.path)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    chmod(item.path, 0o755)
                }
            }
        }
        try? fileManager.removeItem(at: url)
    }
}
