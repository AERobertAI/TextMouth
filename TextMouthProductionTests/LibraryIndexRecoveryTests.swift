import XCTest
@testable import TextMouth

/// While the library index cannot be read, the model shows a provisional
/// library rebuilt from disk, saves nothing to the index, and offers Try
/// Again, Rebuild Library Index, and Quit (TODO S01). Tests stage fixtures in
/// the isolated test root, create real packages there, and restore it all.
final class LibraryIndexRecoveryTests: XCTestCase {
    private var sandbox: LibraryIndexSandbox!
    /// Folder directories created in the test root, removed with their packages.
    private var createdFolders: [URL] = []

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        createdFolders = []
    }

    override func tearDownWithError() throws {
        sandbox.restore()
        for folder in createdFolders {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Startup

    /// At startup an unreadable index puts the model into recovery with a
    /// provisional library rebuilt from disk, empty folders included. The
    /// startup repair and later saves write nothing to the index, while
    /// reading positions are still saved with each book.
    @MainActor
    func testUnreadableIndexStartsRecoveryWithAProvisionalLibrary() throws {
        let shelf = uniqueFolderName("Recovery Shelf")
        let emptyShelf = uniqueFolderName("Empty Shelf")
        let book = try makePackage(title: "Provisional Fixture", inFolder: shelf)
        try makeFolder(emptyShelf)
        let damagedBytes = try sandbox.stage(.truncated, of: indexHolding(book), at: sandbox.indexURL)
        let inode = try LibraryIndexSandbox.inode(of: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)

        model.loadLibraryIndex()

        let recovery = try XCTUnwrap(model.indexRecovery)
        XCTAssertEqual(recovery.failure.indexURL.standardizedFileURL, sandbox.indexURL.standardizedFileURL)
        XCTAssertNotNil(recovery.failure.quarantineURL)
        XCTAssertTrue(model.showIndexRecoveryOptions)
        XCTAssertTrue(LibraryPersistenceService.areIndexWritesSuspended)
        let provisional = try XCTUnwrap(model.library.books.first { $0.id == book.id })
        XCTAssertEqual(provisional.folderPath, shelf)
        XCTAssertTrue(Set(model.library.folders.map(\.fullPath)).isSuperset(of: [shelf, emptyShelf]))

        // Reading continues: the position reaches bookInfo.json, never the index.
        model.persistReadingPosition(bookID: book.id, position: ReadingPosition(characterOffset: 9))
        model.migrateOldBooksIfNeeded()
        model.save()
        waitPastLibrarySaveDebounce()
        LibraryPersistenceService.flushPendingSave()

        let savedInfo = try BookInfo.load(from: provisional.tmbDirectory)
        XCTAssertEqual(savedInfo.state.readingPosition?.characterOffset, 9)
        XCTAssertEqual(try LibraryIndexSandbox.inode(of: sandbox.indexURL), inode)
        XCTAssertEqual(try Data(contentsOf: sandbox.indexURL), damagedBytes)
    }

    // MARK: - Try Again

    /// Try Again after the index is readable again restores it, with its
    /// folder rows, sort settings, and manual order, carries over the reading
    /// progress made meanwhile, and resumes index writes.
    @MainActor
    func testTryAgainAfterRestoringTheIndexLoadsItAndResumesWrites() throws {
        let shelf = uniqueFolderName("Recovery Shelf")
        let book = try makePackage(
            title: "Restored Fixture",
            inFolder: shelf,
            position: ReadingPosition(characterOffset: 1)
        )
        let index = indexHolding(book)
        try sandbox.stage(.unreadable, of: index, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()
        let copy = try XCTUnwrap(model.indexRecovery?.failure.quarantineURL)
        var progress = ReadingPosition(characterOffset: 30)
        progress.lastUpdated = Date().addingTimeInterval(60)
        model.persistReadingPosition(bookID: book.id, position: progress)

        LibraryIndexSandbox.makeReadable(sandbox.indexURL)
        let outcome = model.retryLibraryIndex()

        XCTAssertEqual(outcome, .restored(bookCount: model.library.books.count))
        XCTAssertNil(model.indexRecovery)
        XCTAssertFalse(model.showIndexRecoveryOptions)
        XCTAssertFalse(LibraryPersistenceService.areIndexWritesSuspended)
        let restored = try XCTUnwrap(model.library.books.first { $0.id == book.id })
        XCTAssertEqual(restored.manualSortOrder, 3)
        XCTAssertEqual(restored.readingPosition?.characterOffset, 30)
        XCTAssertEqual(model.library.folders.first { $0.fullPath == shelf }?.id, index.folders.first?.id)
        XCTAssertEqual(model.library.folderSortSettings[shelf], index.folderSortSettings[shelf])

        LibraryPersistenceService.flushPendingSave()
        let written = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(written.books.first { $0.id == book.id }?.readingPosition?.characterOffset, 30)
        XCTAssertEqual(written.folderSortSettings[shelf], index.folderSortSettings[shelf])
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "the preserved copy stays")
    }

    /// Try Again while the index is still unreadable stays in recovery, says
    /// why, and makes no second copy of the same file.
    @MainActor
    func testTryAgainWhileStillUnreadableStaysInRecovery() throws {
        try sandbox.stage(.unknownFormat, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()

        let outcome = model.retryLibraryIndex()

        guard case .stillUnreadable(let reason) = outcome else {
            return XCTFail("Expected the index to stay unreadable, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("does not recognize"), reason)
        XCTAssertEqual(model.indexRecovery?.lastAttempt, outcome)
        XCTAssertTrue(LibraryPersistenceService.areIndexWritesSuspended)
        XCTAssertEqual(LibraryIndexQuarantine.existingCopies(of: sandbox.indexURL).count, 1)
    }

    /// Try Again after a legacy index is repaired restores it into the current
    /// location, as the ordinary migration would.
    @MainActor
    func testTryAgainRestoresARepairedLegacyIndex() throws {
        let shelf = uniqueFolderName("Legacy Shelf")
        let book = try makePackage(title: "Legacy Fixture", inFolder: shelf)
        let index = indexHolding(book)
        try sandbox.stage(.truncated, of: index, at: sandbox.legacyURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()
        XCTAssertEqual(
            model.indexRecovery?.failure.indexURL.standardizedFileURL,
            sandbox.legacyURL.standardizedFileURL
        )

        try sandbox.stageValid(index, at: sandbox.legacyURL)
        let outcome = model.retryLibraryIndex()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(outcome, .restored(bookCount: model.library.books.count))
        let written = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(written.books.first { $0.id == book.id }?.manualSortOrder, 3)
        XCTAssertEqual(written.folderSortSettings[shelf], index.folderSortSettings[shelf])
    }

    /// When the damaged index is gone by the time Try Again runs, nothing is
    /// left to protect, so the provisional library becomes the new index.
    @MainActor
    func testTryAgainAfterTheIndexWasRemovedSavesTheProvisionalLibrary() throws {
        let shelf = uniqueFolderName("Recovery Shelf")
        let book = try makePackage(title: "Provisional Fixture", inFolder: shelf)
        try sandbox.stage(.truncated, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()
        let copy = try XCTUnwrap(model.indexRecovery?.failure.quarantineURL)
        try FileManager.default.removeItem(at: sandbox.indexURL)

        let outcome = model.retryLibraryIndex()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(
            outcome,
            .savedProvisionalLibrary(bookCount: model.library.books.count, preservedCopy: copy)
        )
        XCTAssertNil(model.indexRecovery)
        let written = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(written.books.first { $0.id == book.id }?.folderPath, shelf)
        XCTAssertTrue(written.folders.contains { $0.fullPath == shelf })
    }

    // MARK: - Rebuild

    /// Rebuild Library Index saves the provisional library, folders
    /// included, keeps the verbatim copy of the old index, and resumes writes.
    @MainActor
    func testRebuildSavesTheProvisionalLibraryAndKeepsTheCopy() throws {
        let shelf = uniqueFolderName("Recovery Shelf")
        let book = try makePackage(title: "Rebuilt Fixture", inFolder: shelf)
        let damagedBytes = try sandbox.stage(.unknownFormat, of: indexHolding(book), at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()
        let copy = try XCTUnwrap(model.indexRecovery?.failure.quarantineURL)

        let outcome = model.rebuildLibraryIndex()

        XCTAssertEqual(outcome, .rebuilt(bookCount: model.library.books.count, preservedCopy: copy))
        XCTAssertNil(model.indexRecovery)
        XCTAssertFalse(model.showIndexRecoveryOptions)
        XCTAssertFalse(LibraryPersistenceService.areIndexWritesSuspended)
        XCTAssertEqual(try Data(contentsOf: copy), damagedBytes)
        let written = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(Set(written.books.map(\.id)), Set(model.library.books.map(\.id)))
        XCTAssertTrue(written.folders.contains { $0.fullPath == shelf })

        // Ordinary saves reach the disk again.
        model.updateBook(id: book.id) { $0.manualSortOrder = 7 }
        LibraryPersistenceService.flushPendingSave()
        let resaved = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(resaved.books.first { $0.id == book.id }?.manualSortOrder, 7)
    }

    // MARK: - Data-Directory Maintenance

    /// Data-directory maintenance waits for recovery to end, because it would
    /// act on or copy the provisional library. Rebuild Directory is refused
    /// with an explanation and changes nothing. Change Location and Reset to
    /// Default share the same guard, which is checked directly: driving them
    /// here could write the test host's real preferences if it ever failed.
    @MainActor
    func testDataDirectoryMaintenanceWaitsForRecoveryToEnd() throws {
        let damagedBytes = try sandbox.stage(.truncated, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        XCTAssertNoThrow(try model.ensureLibraryIndexIsReadable())
        model.loadLibraryIndex()

        XCTAssertThrowsError(try model.ensureLibraryIndexIsReadable())
        model.rebuildDirectory()

        XCTAssertTrue(model.showError)
        XCTAssertEqual(
            model.errorMessage,
            "Failed to rebuild directory: \(LibraryIndexRecoveryError.indexUnreadable.localizedDescription)"
        )
        XCTAssertNotNil(model.indexRecovery)
        XCTAssertFalse(model.isExtracting, "no maintenance may start")
        XCTAssertEqual(try Data(contentsOf: sandbox.indexURL), damagedBytes)
    }

    /// Recovery actions do nothing while the index is readable.
    @MainActor
    func testRecoveryActionsDoNothingOutsideRecovery() {
        let model = LibraryViewModel(initializeServices: false)

        XCTAssertEqual(model.retryLibraryIndex(), .notRecovering)
        XCTAssertEqual(model.rebuildLibraryIndex(), .notRecovering)
        XCTAssertFalse(LibraryPersistenceService.areIndexWritesSuspended)
    }

    // MARK: - Merging and Messages

    /// Try Again keeps the loaded index authoritative but carries newer
    /// reading progress and moved packages over from the provisional library.
    func testMergeCarriesOnlyNewerProgressAndMovedPackages() {
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = earlier.addingTimeInterval(3_600)
        let movedID = UUID()
        let aheadID = UUID()
        let loaded = Library(
            books: [
                Book(id: movedID, title: "Moved", format: .txt, filePath: "/old/moved.txt", md5Hash: "m",
                     folderPath: "Old", lastOpened: earlier, readingPosition: position(5, at: earlier),
                     tmbDirectoryName: "Moved.tmb"),
                Book(id: aheadID, title: "Ahead", format: .txt, filePath: "/kept/ahead.txt", md5Hash: "a",
                     readingPosition: position(50, at: later)),
                Book(title: "Untouched", format: .txt, filePath: "/kept/untouched.txt", md5Hash: "u")
            ],
            folders: [BookFolder(name: "Old")]
        )
        let provisional = Library(books: [
            Book(id: movedID, title: "Moved", format: .txt, filePath: "/new/moved.txt", md5Hash: "m",
                 folderPath: "New", lastOpened: later, readingPosition: position(40, at: later),
                 tmbDirectoryName: "Moved.tmb"),
            Book(id: aheadID, title: "Ahead", format: .txt, filePath: "/kept/ahead.txt", md5Hash: "a",
                 readingPosition: position(20, at: earlier))
        ])
        let existingFiles: Set<String> = ["/new/moved.txt", "/kept/ahead.txt", "/kept/untouched.txt"]

        let merged = LibraryViewModel.carryingRecoverySessionState(
            from: provisional,
            into: loaded,
            fileExists: existingFiles.contains
        )

        XCTAssertEqual(merged.books[0].filePath, "/new/moved.txt")
        XCTAssertEqual(merged.books[0].folderPath, "New")
        XCTAssertEqual(merged.books[0].readingPosition?.characterOffset, 40)
        XCTAssertEqual(merged.books[0].lastOpened, later)
        XCTAssertEqual(merged.books[1].readingPosition?.characterOffset, 50, "an older session position never wins")
        XCTAssertEqual(merged.books[2], loaded.books[2])
        XCTAssertEqual(merged.folders.map(\.id), loaded.folders.map(\.id))
    }

    /// Outcome sentences name the number of books and the preserved copy.
    func testOutcomeMessagesNameCountsAndThePreservedCopy() {
        let copy = URL(fileURLWithPath: "/tmp/library.json.unreadable-20260921T141320Z")

        XCTAssertEqual(
            LibraryIndexRecoveryOutcome.rebuilt(bookCount: 1, preservedCopy: copy).message,
            "The library index was rebuilt with 1 book. "
                + "The previous index is kept at /tmp/library.json.unreadable-20260921T141320Z."
        )
        XCTAssertEqual(
            LibraryIndexRecoveryOutcome.stillUnreadable(reason: "The file is empty.").message,
            "The library index still could not be read. The file is empty."
        )
        XCTAssertTrue(LibraryIndexRecoveryOutcome.restored(bookCount: 3).message.contains("3 books"))
        XCTAssertFalse(LibraryIndexRecoveryOutcome.rebuilt(bookCount: 2, preservedCopy: nil).message.contains("kept at"))
    }

    /// The Rebuild Library Index choice says what is lost and names the saved
    /// copy that keeps the old data.
    func testRebuildDescriptionNamesTheLossAndTheSavedCopy() {
        let copy = URL(fileURLWithPath: "/tmp/library.json.unreadable-20260921T141320Z")

        let described = LibraryIndexRecoveryText.rebuild(savedCopy: copy)

        XCTAssertTrue(described.contains("Folder placement, sort settings, and manual order"))
        XCTAssertTrue(described.contains("The saved copy at \(copy.path) keeps the old data."))
        XCTAssertTrue(LibraryIndexRecoveryText.rebuild(savedCopy: nil).contains("does not rebuild if it cannot"))
    }

    // MARK: - Fixtures

    /// A folder name unique to this test, so leftovers in the shared test
    /// root cannot collide with it.
    private func uniqueFolderName(_ base: String) -> String {
        "\(base) \(UUID().uuidString.prefix(8))"
    }

    /// Creates a top-level folder directory in the test root's library and
    /// schedules it, with everything inside, for removal.
    private func makeFolder(_ folder: String) throws {
        let directory = TextMouthPaths.libraryDir.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !createdFolders.contains(directory) {
            createdFolders.append(directory)
        }
    }

    /// Creates a real package in `folder`, with a readable book file and a
    /// bookInfo.json, as an import would leave it.
    private func makePackage(
        title: String,
        inFolder folder: String,
        position: ReadingPosition? = nil
    ) throws -> Book {
        try makeFolder(folder)
        let packageName = "IndexRecovery-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folder, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = package.appendingPathComponent("book.txt")
        try Data("Words kept safe while the index could not be read.".utf8).write(to: content)
        let book = Book(
            title: title,
            author: "Test Fixture",
            format: .txt,
            filePath: content.path,
            md5Hash: "index-recovery-\(UUID().uuidString)",
            folderPath: folder,
            readingPosition: position,
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing()
        return book
    }

    /// An index for `book` holding state that only the index keeps: the
    /// folder row, a manual sort setting, and the book's manual position.
    private func indexHolding(_ book: Book) -> Library {
        var indexed = book
        indexed.manualSortOrder = 3
        return Library(
            books: [indexed],
            folders: [BookFolder(name: book.folderPath)],
            folderSortSettings: [book.folderPath: FolderSortSetting(sortField: .manual, sortAscending: false)]
        )
    }

    /// A reading position saved at `date`.
    private func position(_ offset: Int, at date: Date) -> ReadingPosition {
        var position = ReadingPosition(characterOffset: offset)
        position.lastUpdated = date
        return position
    }
}
