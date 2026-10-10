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
        // Optional: tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
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
    /// An index cut short gave no reading list or sort settings to keep,
    /// and the outcome says so.
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
            .savedProvisionalLibrary(
                bookCount: model.library.books.count,
                preservedCopy: copy,
                notKept: [.readingList, .sortSettings]
            )
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
    func testDataDirectoryMaintenanceWaitsForRecoveryToEnd() async throws {
        let damagedBytes = try sandbox.stage(.truncated, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        XCTAssertNoThrow(try model.ensureLibraryIndexIsReadable())
        model.loadLibraryIndex()

        XCTAssertThrowsError(try model.ensureLibraryIndexIsReadable())
        await model.rebuildDirectory().value

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

    /// Saving the provisional library as the new index says which parts of
    /// the arrangement it could not keep, before naming the copy that
    /// keeps them, and says nothing of them when it kept both.
    func testOutcomeMessagesNameWhatCouldNotBeKept() {
        let copy = URL(fileURLWithPath: "/tmp/library.json.unreadable-20260921T141320Z")

        XCTAssertEqual(
            LibraryIndexRecoveryOutcome.rebuilt(bookCount: 12, preservedCopy: copy, notKept: [.readingList, .sortSettings]).message,
            "The library index was rebuilt with 12 books. TextMouth could not read the reading list or the sort "
                + "settings in the previous index. The previous index is kept at \(copy.path)."
        )
        XCTAssertEqual(
            LibraryIndexRecoveryOutcome.rebuilt(bookCount: 1, preservedCopy: nil, notKept: [.sortSettings]).message,
            "The library index was rebuilt with 1 book. TextMouth could not read the sort settings in the previous index."
        )
        XCTAssertEqual(
            LibraryIndexRecoveryOutcome.savedProvisionalLibrary(bookCount: 2, preservedCopy: nil, notKept: [.readingList]).message,
            "The unreadable library index is no longer there, so TextMouth saved the library rebuilt from your books "
                + "as the new index, with 2 books. TextMouth could not read the reading list in the previous index."
        )
        XCTAssertFalse(LibraryIndexRecoveryOutcome.rebuilt(bookCount: 2, preservedCopy: copy).message.contains("could not read"))
    }

    // MARK: - The Reading List and the Sort Settings (FR09)

    /// Rebuild Library Index keeps the reading list and the sort settings
    /// of an index that cannot be read as a whole but still holds them
    /// readably: the library shown while recovering has them, the books
    /// adopted from their records keep their places on the list, and the
    /// rebuilt index saves them, with nothing said to be lost.
    @MainActor
    func testRebuildKeepsTheReadingListAndSortSettingsAnUnreadableIndexStillHolds() throws {
        let shelf = uniqueFolderName("Recovery Shelf")
        let first = try makePackage(title: "First Listed", inFolder: shelf)
        let second = try makePackage(title: "Second Listed", inFolder: shelf)
        var index = indexHolding(first)
        index.books.append(second)
        index.readingList = ReadingList(bookIDs: [second.id, first.id], continuation: .playBookAbove, skipsFinished: false)
        try sandbox.stage(.unknownFormat, of: index, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()

        XCTAssertEqual(model.indexRecovery?.arrangementNotKept, [])
        XCTAssertEqual(model.library.readingList, index.readingList)
        XCTAssertEqual(model.readingListBooks.map(\.id), [second.id, first.id])
        XCTAssertEqual(model.library.folderSortSettings[shelf], index.folderSortSettings[shelf])

        let outcome = model.rebuildLibraryIndex()

        guard case .rebuilt(_, _, let notKept) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(notKept, [])
        XCTAssertFalse(outcome.message.contains("could not read"), outcome.message)
        let written = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(written.readingList, index.readingList)
        XCTAssertEqual(written.folderSortSettings[shelf], index.folderSortSettings[shelf])
    }

    /// An index cut short holds nothing that can be read: the library shown
    /// starts with no reading list and no sort settings, and Rebuild
    /// Library Index says it could not read either.
    @MainActor
    func testRebuildSaysWhatItCouldNotReadInAnIndexCutShort() throws {
        let shelf = uniqueFolderName("Recovery Shelf")
        let book = try makePackage(title: "Cut Short", inFolder: shelf)
        var index = indexHolding(book)
        index.readingList = ReadingList(bookIDs: [book.id])
        try sandbox.stage(.truncated, of: index, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()

        XCTAssertEqual(model.indexRecovery?.arrangementNotKept, [.readingList, .sortSettings])
        XCTAssertEqual(model.library.readingList, ReadingList())

        let outcome = model.rebuildLibraryIndex()

        guard case .rebuilt(_, _, let notKept) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(notKept, [.readingList, .sortSettings])
        XCTAssertTrue(
            outcome.message.contains("TextMouth could not read the reading list or the sort settings in the previous index."),
            outcome.message
        )
    }

    /// When the data directory comes back with an index that can't be read,
    /// the library shown keeps this session's reading list and sort
    /// settings, the latest, whatever the unreadable index holds, and
    /// Rebuild Library Index saves them.
    @MainActor
    func testRecoveryAfterTheDataDirectoryReturnedKeepsTheSessionsArrangement() throws {
        let shelf = uniqueFolderName("Recovery Shelf")
        let book = try makePackage(title: "Session Listed", inFolder: shelf)
        let session = ReadingList(bookIDs: [book.id], continuation: .stop, skipsFinished: true)
        let sessionSort = FolderSortSetting(sortField: .author, sortAscending: false)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book], folderSortSettings: [shelf: sessionSort], readingList: session)
        try sandbox.stage(.truncated, of: indexHolding(book), at: sandbox.indexURL)

        model.reloadLibraryAfterDataDirectoryReturned()

        XCTAssertNotNil(model.indexRecovery)
        XCTAssertEqual(model.indexRecovery?.arrangementNotKept, [])
        XCTAssertEqual(model.library.readingList, session)
        XCTAssertEqual(model.library.folderSortSettings[shelf], sessionSort)

        let outcome = model.rebuildLibraryIndex()

        guard case .rebuilt(_, _, let notKept) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(notKept, [])
        let written = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(written.readingList, session)
        XCTAssertEqual(written.folderSortSettings[shelf], sessionSort)
    }

    /// Try Again that still can't read the index keeps what the library
    /// shown could not keep, for Rebuild Library Index to say.
    @MainActor
    func testTryAgainThatStillFailsKeepsWhatCouldNotBeKept() throws {
        try sandbox.stage(.truncated, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()

        _ = model.retryLibraryIndex()

        XCTAssertEqual(model.indexRecovery?.arrangementNotKept, [.readingList, .sortSettings])
    }

    /// The arrangement of an unreadable index is read part by part: a
    /// missing part, or one written as null, loses nothing; a reading list
    /// that is not a list is lost on its own; sort settings keep every
    /// entry that can be read; and bytes that are not a JSON object, or no
    /// bytes at all, give neither part.
    func testTheArrangementOfAnUnreadableIndexIsReadPartByPart() throws {
        let book = UUID()
        func read(_ json: String) -> SalvagedLibraryArrangement {
            SalvagedLibraryArrangement.read(from: Data(json.utf8))
        }

        let neither = SalvagedLibraryArrangement(readingList: nil, sortSettings: nil, unread: [.readingList, .sortSettings])
        XCTAssertEqual(SalvagedLibraryArrangement.read(from: nil), neither)
        XCTAssertEqual(read("{ \"books\": [ {"), neither)
        XCTAssertEqual(read("[1, 2]"), neither)

        let none = read("{ \"books\": 7 }")
        XCTAssertEqual(none, SalvagedLibraryArrangement(readingList: ReadingList(), sortSettings: [:], unread: []))
        XCTAssertEqual(read("{ \"readingList\": null, \"folderSortSettings\": null }"), none)

        let listLost = read("""
            { "readingList": 5, "folderSortSettings": { "Essays": { "sortField": "Author", "sortAscending": false } } }
            """)
        XCTAssertNil(listLost.readingList)
        XCTAssertEqual(listLost.sortSettings, ["Essays": FolderSortSetting(sortField: .author, sortAscending: false)])
        XCTAssertEqual(listLost.unread, [.readingList])

        let someSorts = read("""
            { "readingList": { "bookIDs": ["\(book.uuidString)"], "continuation": "stop" },
              "folderSortSettings": { "Essays": { "sortField": "Author", "sortAscending": false }, "Broken": { "sortField": 3 } } }
            """)
        XCTAssertEqual(someSorts.readingList, ReadingList(bookIDs: [book], continuation: .stop))
        XCTAssertEqual(someSorts.sortSettings, ["Essays": FolderSortSetting(sortField: .author, sortAscending: false)])
        XCTAssertEqual(someSorts.unread, [.sortSettings])

        let noSorts = read("{ \"folderSortSettings\": [1] }")
        XCTAssertNil(noSorts.sortSettings)
        XCTAssertEqual(noSorts.unread, [.sortSettings])
    }

    /// Each part of the arrangement comes from the session when the session
    /// holds it, the index's bytes read only for a part it does not hold;
    /// a part neither gives is named as not kept.
    func testEachPartComesFromTheSessionWhenItHoldsOne() throws {
        let book = UUID()
        let sessionList = ReadingList(bookIDs: [book])
        let sessionSorts = ["Essays": FolderSortSetting(sortField: .author, sortAscending: false)]
        let indexSorts = ["Poems": FolderSortSetting(sortField: .dateAdded, sortAscending: true)]
        let indexBytes = try LibraryIndexSandbox.encoded(Library(folderSortSettings: indexSorts))
        var reads = 0
        func bytes(_ data: Data?) -> () -> Data? {
            { reads += 1; return data }
        }

        let both = LibraryViewModel.recoveredArrangement(
            session: Library(folderSortSettings: sessionSorts, readingList: sessionList),
            unreadableIndex: bytes(indexBytes)
        )
        XCTAssertEqual(both, .init(readingList: sessionList, sortSettings: sessionSorts, notKept: []))
        XCTAssertEqual(reads, 0, "the index was read though the session held both parts")

        let listOnly = LibraryViewModel.recoveredArrangement(
            session: Library(readingList: sessionList),
            unreadableIndex: bytes(indexBytes)
        )
        XCTAssertEqual(listOnly, .init(readingList: sessionList, sortSettings: indexSorts, notKept: []))

        let nothing = LibraryViewModel.recoveredArrangement(session: Library(), unreadableIndex: bytes(nil))
        XCTAssertEqual(nothing, .init(readingList: ReadingList(), sortSettings: [:], notKept: [.readingList, .sortSettings]))

        let sortsHeld = LibraryViewModel.recoveredArrangement(
            session: Library(folderSortSettings: sessionSorts),
            unreadableIndex: bytes(nil)
        )
        XCTAssertEqual(sortsHeld, .init(readingList: ReadingList(), sortSettings: sessionSorts, notKept: [.readingList]))
        XCTAssertEqual(reads, 3)
    }

    /// The Rebuild Library Index choice says what it keeps and what is
    /// lost, names any part of the arrangement it could not read, and names
    /// the saved copy that keeps the old data.
    func testRebuildDescriptionNamesTheLossAndTheSavedCopy() {
        let copy = URL(fileURLWithPath: "/tmp/library.json.unreadable-20260921T141320Z")

        let described = LibraryIndexRecoveryText.rebuild(savedCopy: copy)

        XCTAssertEqual(
            described,
            "Saves the temporary library as the new index, with the reading list and the sort settings "
                + "TextMouth could read. Folder placement and manual order that were stored only in the "
                + "unreadable index are lost from the library. The saved copy at \(copy.path) keeps the old data."
        )
        XCTAssertTrue(LibraryIndexRecoveryText.rebuild(savedCopy: nil).contains("does not rebuild if it cannot"))
        XCTAssertTrue(
            LibraryIndexRecoveryText.rebuild(savedCopy: copy, notKept: [.readingList]).contains(
                "are lost from the library. TextMouth could not read the reading list in the unreadable index. The saved copy"
            )
        )
        XCTAssertTrue(
            LibraryIndexRecoveryText.rebuild(savedCopy: copy, notKept: [.readingList, .sortSettings]).contains(
                "TextMouth could not read the reading list or the sort settings in the unreadable index."
            )
        )
    }

    /// Storage settings name an unreadable index in words, ahead of the data
    /// directory's own state.
    func testStorageStatusNamesAnUnreadableIndex() {
        XCTAssertEqual(
            StorageSettingsView.statusText(isRecoveringIndex: true, directoryExists: true),
            "Library index unreadable"
        )
        XCTAssertEqual(StorageSettingsView.statusText(isRecoveringIndex: false, directoryExists: true), "Active")
        XCTAssertEqual(StorageSettingsView.statusText(isRecoveringIndex: false, directoryExists: false), "Not Created")
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
