import XCTest
@testable import TextMouth

/// The library's side of syncing (FR43): how a merge's rows meet the library
/// as it is now (`SyncRowMerge`), and what `LibraryViewModel` does with a
/// merge (`applySync`). The merge itself is sync-core's; these tests hand the
/// host applications made by hand.
@MainActor
final class SyncLibraryHostTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox!

    override func setUp() async throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    /// What a test made in the hosted library: packages and folders, removed after it.
    private var made: [URL] = []

    override func tearDown() async throws {
        // Optional: tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
        for url in made { try? FileManager.default.removeItem(at: url) }
        made = []
    }

    /// Makes a placeholder package in the hosted library, removed after the test.
    private func makePlaceholder(_ title: String, folderPath: String = "") throws -> Book {
        var newBook = makeNewBook(title)
        newBook.book.folderPath = folderPath
        let book = try SyncPlaceholder.makePackage(for: newBook, storeID: UUID())
        made.append(book.tmbDirectory)
        return book
    }

    // MARK: - Fixtures

    /// A book with no package on disk.
    private func makeBook(_ title: String, folderPath: String = "") -> Book {
        Book(
            title: title, author: "Test Fixture", format: .txt,
            filePath: "/nonexistent/sync-host/\(UUID().uuidString).txt",
            md5Hash: "sync-host-\(UUID().uuidString)", folderPath: folderPath,
            tmbDirectoryName: "SyncHost-\(UUID().uuidString).tmb"
        )
    }

    /// An application that gives `library` as the merged one and nothing else.
    private func makeApplication(
        library: Library, add: [SyncNewBook] = [], remove: [UUID] = [], moves: Bool = false, keys: Set<SyncKey> = []
    ) -> SyncApplication {
        SyncApplication(
            library: library, booksToAdd: add, booksToRemove: remove, movesPackages: moves,
            entriesToRecord: [:], appliedKeys: keys
        )
    }

    /// A new book as sync-core's merge makes one.
    private func makeNewBook(_ title: String) -> SyncNewBook {
        let book = Book(id: UUID(), title: title, author: "Test Fixture", format: .txt, filePath: "", md5Hash: "", folderPath: "")
        let content = SyncContent(
            manifest: "m.manifest.json", format: .txt, dateAdded: Date(timeIntervalSince1970: 1_790_000_000),
            md5Hash: "new-\(UUID().uuidString)", totalWordCount: nil, audioDuration: nil
        )
        return SyncNewBook(book: book, content: content)
    }

    // MARK: - SyncRowMerge

    /// A row the merge changed replaces the library's when the library's is
    /// as it was; a row the merge left alone stays.
    func testAChangedRowReplacesTheLibrarysRow() {
        let first = makeBook("First"), second = makeBook("Second")
        let start = Library(books: [first, second])
        var merged = start
        merged.books[0].localWPM = 321
        let merge = SyncRowMerge.make(applying: makeApplication(library: merged), start: start, current: start, added: [])
        XCTAssertEqual(merge.library.books[0].localWPM, 321)
        XCTAssertEqual(merge.library.books[1], second)
        XCTAssertEqual(merge.changedBookIDs, [first.id])
        XCTAssertTrue(merge.staleBookIDs.isEmpty)
    }

    /// A row a person changed while the merge was applied is left as they
    /// made it, and its keys are not reported applied, so the next sync
    /// merges it again.
    func testARowChangedMeanwhileIsLeftAlone() {
        let book = makeBook("Busy")
        let start = Library(books: [book])
        var merged = start
        merged.books[0].localWPM = 111
        var current = start
        current.books[0].localWPM = 222
        let key = SyncKey.book(book.id, .rate)
        let application = makeApplication(library: merged, keys: [key, .book(UUID(), .title)])
        let merge = SyncRowMerge.make(applying: application, start: start, current: current, added: [])
        XCTAssertEqual(merge.library.books[0].localWPM, 222)
        XCTAssertEqual(merge.staleBookIDs, [book.id])
        XCTAssertFalse(merge.appliedKeys(of: application, failed: []).contains(key))
        XCTAssertEqual(merge.appliedKeys(of: application, failed: []).count, 1)
    }

    /// A new book joins the library, but a book whose hash the library has
    /// is refused, and its keys are not reported applied.
    func testANewBookJoinsUnlessItsHashIsKnown() {
        let existing = makeBook("Already Here")
        var duplicate = makeBook("Same File Elsewhere")
        duplicate.md5Hash = existing.md5Hash
        let fresh = makeBook("Fresh")
        let start = Library(books: [existing])
        let merge = SyncRowMerge.make(
            applying: makeApplication(library: start), start: start, current: start, added: [duplicate, fresh]
        )
        XCTAssertEqual(merge.addedBookIDs, [fresh.id])
        XCTAssertEqual(merge.refusedBookIDs, [duplicate.id])
        XCTAssertEqual(merge.library.books.count, 2)
    }

    /// Folders and the reading list follow the same rule as rows.
    func testFoldersAndTheListChangedMeanwhileAreLeftAlone() {
        let start = Library(books: [])
        var merged = start
        merged.folders = [BookFolder(name: "Merged Shelf")]
        var current = start
        current.folders = [BookFolder(name: "Own Shelf")]
        let application = makeApplication(library: merged, keys: [.folder(UUID(), .name), .readingListOption(.continuation)])
        let merge = SyncRowMerge.make(applying: application, start: start, current: current, added: [])
        XCTAssertEqual(merge.library.folders.map(\.name), ["Own Shelf"])
        XCTAssertTrue(merge.foldersAreStale)
        XCTAssertEqual(merge.appliedKeys(of: application, failed: []), [.readingListOption(.continuation)])
    }

    /// A row left alone in one field still follows the rename that moved the
    /// merged row: the folder is a field of its own (review item 5).
    func testARowChangedMeanwhileStillFollowsAFolderRename() {
        let book = makeBook("Renamed Away", folderPath: "Old")
        // The folders the rename holds, as the library the move published does.
        var start = Library(books: [book])
        start.folders = [BookFolder(name: "Old"), BookFolder(name: "New")]
        var merged = start
        merged.books[0].folderPath = "New"
        merged.books[0].localWPM = 111
        var current = start
        current.books[0].localWPM = 222
        let application = makeApplication(
            library: merged, keys: [.book(book.id, .folder), .book(book.id, .rate)]
        )
        let merge = SyncRowMerge.make(applying: application, start: start, current: current, added: [])
        XCTAssertEqual(merge.library.books[0].folderPath, "New")
        XCTAssertEqual(merge.library.books[0].localWPM, 222)
        XCTAssertEqual(merge.staleBookIDs, [book.id])
    }

    /// Fields are independent: a field the person changed meanwhile stands,
    /// and another the merge changed still lands (review item 2).
    func testAFieldChangedMeanwhileDoesNotHoldBackTheOthers() {
        let book = makeBook("Two Fields")
        let start = Library(books: [book])
        var merged = start
        merged.books[0].localWPM = 111
        merged.books[0].localPitch = 1.5
        var current = start
        current.books[0].localWPM = 222
        let merge = SyncRowMerge.make(applying: makeApplication(library: merged), start: start, current: current, added: [])
        XCTAssertEqual(merge.library.books[0].localWPM, 222)
        XCTAssertEqual(merge.library.books[0].localPitch, 1.5)
        XCTAssertEqual(merge.changedBookIDs, [book.id])
    }

    /// A bookmark the person added meanwhile stays, beside the merge's.
    func testABookmarkAddedMeanwhileStaysBesideTheMerges() {
        let book = makeBook("Marks")
        let start = Library(books: [book])
        var merged = start
        merged.books[0].bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: 10, label: "theirs")]
        var current = start
        current.books[0].bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: 20, label: "mine")]
        let merge = SyncRowMerge.make(applying: makeApplication(library: merged), start: start, current: current, added: [])
        XCTAssertEqual(Set(merge.library.books[0].bookmarks.map(\.label)), ["theirs", "mine"])
    }

    /// A merge made from an older library does not undo what was changed
    /// since: the row keeps the change, and its key is not reported applied.
    func testApplyAgainstAnOlderSourceKeepsTheChangeSince() async throws {
        let model = LibraryViewModel(initializeServices: false)
        let book = try makePlaceholder("Edited Since")
        let source = Library(books: [book])
        model.library = source
        model.updateBook(id: book.id) { $0.localWPM = 222 }
        var merged = source
        merged.books[0].localWPM = 111
        let key = SyncKey.book(book.id, .rate)
        let applied = await model.applySync(makeApplication(library: merged, keys: [key]), from: source)
        XCTAssertEqual(model.bookByID(book.id)?.localWPM, 222)
        XCTAssertFalse(applied.contains(key))
    }

    /// Each kind of key names the book it changes, and a folder's or the
    /// list's option names none.
    func testKeysNameTheirBooks() {
        let book = UUID()
        XCTAssertEqual(SyncKey.book(book, .title).bookID, book)
        XCTAssertEqual(SyncKey.bookmark(book: book, id: UUID()).bookID, book)
        XCTAssertEqual(SyncKey.readingList(book: book).bookID, book)
        XCTAssertNil(SyncKey.folder(UUID(), .name).bookID)
        XCTAssertNil(SyncKey.readingListOption(.continuation).bookID)
    }

    // MARK: - The Host

    /// A sync may not change the library while its index is being recovered.
    func testAnIndexInRecoveryRefusesASync() async {
        let model = LibraryViewModel(initializeServices: false)
        XCTAssertTrue(model.maySyncNow)
        model.library = Library(books: [makeBook("Waiting")])
        let application = makeApplication(library: Library(), add: [makeNewBook("Never Added")])
        model.indexRecovery = LibraryIndexRecovery(failure: LibraryIndexReadFailure(
            indexURL: TextMouthPaths.libraryIndexFile, quarantineURL: nil,
            error: CocoaError(.fileReadCorruptFile), byteCount: 0
        ))
        XCTAssertFalse(model.maySyncNow)
        let applied = await model.applySync(application)
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(model.library.books.count, 1)
    }

    /// A sync may change the library only once recovery has ended, and not
    /// while an operation holds the storage work (FR43): so a library
    /// emptied by recovery is never recorded as every book removed.
    func testMaySyncNowFollowsRecoveryAndHeldStorageWork() throws {
        let model = LibraryViewModel(initializeServices: false)
        XCTAssertTrue(model.maySyncNow)
        model.indexRecovery = LibraryIndexRecovery(failure: LibraryIndexReadFailure(
            indexURL: TextMouthPaths.libraryIndexFile, quarantineURL: nil,
            error: CocoaError(.fileReadCorruptFile), byteCount: 0
        ))
        XCTAssertFalse(model.maySyncNow, "recovery under way")
        model.indexRecovery = nil
        XCTAssertTrue(model.maySyncNow, "recovery over")
        let hold = try StorageBoundary.shared.holdWork(for: .movingBooksBetweenFolders)
        XCTAssertFalse(model.maySyncNow, "storage work held")
        hold.release()
        XCTAssertTrue(model.maySyncNow, "storage work released")
    }

    /// A new book joins as a placeholder in the library, its keys applied.
    func testApplyAddsAPlaceholderBook() async throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let newBook = makeNewBook("From Another Device")
        let key = SyncKey.book(newBook.book.id, .presence)
        let applied = await model.applySync(makeApplication(library: Library(), add: [newBook], keys: [key]))
        XCTAssertEqual(applied, [key])
        let added = try XCTUnwrap(model.bookByID(newBook.book.id))
        made.append(added.tmbDirectory)
        XCTAssertEqual(added.md5Hash, newBook.content.md5Hash)
        let package = SyncPlaceholder.packageDirectory(of: added, in: TextMouthPaths.libraryDir)
        XCTAssertTrue(SyncPlaceholder.isPlaceholder(package: package, contentFile: added.bookFileURL))
    }

    /// After a fetch the row's file path is the content file as the store
    /// names it, in the book's package; a path already right, a missing
    /// content path, and a book that is gone change nothing.
    func testAFetchSetsTheRowsFilePathToTheContentPath() throws {
        let model = LibraryViewModel(initializeServices: false)
        let book = try makePlaceholder("Fetched")
        model.library = Library(books: [book])
        model.syncDidFetch(bookID: book.id, contentPath: "Original Name.txt")
        let row = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(row.filePath, book.tmbDirectory.appendingPathComponent("Original Name.txt").path)
        model.syncDidFetch(bookID: book.id, contentPath: nil)
        model.syncDidFetch(bookID: UUID(), contentPath: "Other.txt")
        XCTAssertEqual(model.bookByID(book.id)?.filePath, row.filePath)
    }

    /// A book busy in the synchronous sense (a reader open now, its audio
    /// being edited) is not removed, though the published set lags (review item 8).
    func testABusyBookIsNotRemoved() async throws {
        keepDeletionsOutOfTheTrash()
        let model = LibraryViewModel(initializeServices: false)
        let editing = try makePlaceholder("Editing")
        model.library = Library(books: [editing])
        model.audioEditActivity.setOpenInReaders([editing.id])
        let key = SyncKey.book(editing.id, .presence)
        let applied = await model.applySync(makeApplication(library: Library(), remove: [editing.id], keys: [key]))
        XCTAssertNotNil(model.bookByID(editing.id))
        XCTAssertFalse(applied.contains(key))
    }

    /// The device a reader hears the place came from is the writer of the
    /// place's own key, not the device heard from last (round 2, item 2).
    func testTheDeviceNamedIsTheWriterOfThePlace() async throws {
        let model = LibraryViewModel(initializeServices: false)
        let book = try makePlaceholder("Written Elsewhere")
        model.library = Library(books: [book])
        model.audioEditActivity.setOpenInReaders([book.id])
        model.syncDeviceName = { key in key == .book(book.id, .position) ? "iPad" : "iPhone" }
        var heard: [String] = []
        let subscription = model.syncedReadingStates.sink { heard.append($0.device) }
        defer { subscription.cancel() }
        var merged = model.library
        var place = ReadingPosition(chapterIndex: 0, characterOffset: 40)
        place.lastUpdated = Date(timeIntervalSince1970: 1_790_000_500)
        merged.books[0].readingPosition = place
        let key = SyncKey.book(book.id, .position)
        let applied = await model.applySync(makeApplication(library: merged, keys: [key]), from: model.library)
        XCTAssertEqual(applied, [key])
        XCTAssertEqual(heard, ["iPad"])
    }

    /// A folder changed meanwhile never leaves a row in a folder the list
    /// lacks: the folders the moved rows need are added (round 2, item 5).
    func testARowNeverMovesIntoAFolderTheListLacks() async throws {
        let model = LibraryViewModel(initializeServices: false)
        let book = try makePlaceholder("Moved Into New")
        let own = BookFolder(name: "Own Shelf \(UUID().uuidString.prefix(6))")
        made.append(TextMouthPaths.libraryDir.appendingPathComponent(own.fullPath, isDirectory: true))
        let start = Library(books: [book])
        model.library = start
        // The person makes a folder after the merge was computed.
        var edited = start
        edited.folders = [own]
        model.library = edited
        let landing = BookFolder(name: "Landing \(UUID().uuidString.prefix(6))")
        made.append(TextMouthPaths.libraryDir.appendingPathComponent(landing.fullPath, isDirectory: true))
        var merged = start
        merged.folders = [landing]
        merged.books[0].folderPath = landing.fullPath
        _ = await model.applySync(makeApplication(library: merged, moves: true, keys: [.book(book.id, .folder)]), from: start)
        let paths = Set(model.library.folders.map(\.fullPath))
        XCTAssertTrue(paths.contains(own.fullPath), "the person's folder stays")
        for row in model.library.books where !row.folderPath.isEmpty {
            XCTAssertTrue(paths.contains(row.folderPath), "\(row.folderPath) is in the list")
        }
    }

    /// A key left alone lands at the next sync: a row changed meanwhile is
    /// merged again once it is as it was, and an open book is removed once
    /// it is closed (round 2, item 10).
    func testADeferredRemovalLandsAtTheNextSync() async throws {
        keepDeletionsOutOfTheTrash()
        let model = LibraryViewModel(initializeServices: false)
        let book = try makePlaceholder("Open Then Closed")
        model.library = Library(books: [book])
        let key = SyncKey.book(book.id, .presence)
        let removal = makeApplication(library: Library(), remove: [book.id], keys: [key])
        model.audioEditActivity.setOpenInReaders([book.id])
        let first = await model.applySync(removal)
        XCTAssertFalse(first.contains(key))
        model.audioEditActivity.setOpenInReaders([])
        let second = await model.applySync(removal)
        XCTAssertTrue(second.contains(key))
        XCTAssertNil(model.bookByID(book.id))
    }

    /// A book being fetched (downloading) is not removed.
    func testABookBeingFetchedIsNotRemoved() async throws {
        keepDeletionsOutOfTheTrash()
        let model = LibraryViewModel(initializeServices: false)
        let book = try makePlaceholder("Being Fetched")
        model.library = Library(books: [book])
        BookCloudStates.shared.record(.downloading(.notStarted), for: book.id)
        addTeardownBlock { @MainActor in BookCloudStates.shared.record(.inCloud, for: book.id) }
        let key = SyncKey.book(book.id, .presence)
        let applied = await model.applySync(makeApplication(library: Library(), remove: [book.id], keys: [key]))
        XCTAssertNotNil(model.bookByID(book.id))
        XCTAssertFalse(applied.contains(key))
    }

    /// A keep a person just made stays over a set from a run that ended
    /// before it was recorded, and goes once a set agrees (round 2, item 3).
    func testAKeepStaysOverAnOlderRunsSet() {
        let kept = KeptBooks(file: nil)
        let book = UUID()
        kept.noteSyncedChange(keeping: true, [book])
        kept.setSyncedBooks([])
        XCTAssertTrue(kept.isKeptOnAllDevices(book), "the old run's set does not undo it")
        kept.setSyncedBooks([book])
        XCTAssertTrue(kept.isKeptOnAllDevices(book))
        kept.setSyncedBooks([])
        XCTAssertFalse(kept.isKeptOnAllDevices(book), "once agreed, the sync's set rules")
        kept.noteSyncedChange(keeping: false, [book])
        kept.setSyncedBooks([book])
        XCTAssertFalse(kept.isKeptOnAllDevices(book), "a stop stays over an older set too")
    }

    /// A merge that puts a book in a new folder moves its package there,
    /// through the library transition, and the keys are applied.
    func testApplyMovesAPackageIntoANewFolder() async throws {
        let model = LibraryViewModel(initializeServices: false)
        let book = try makePlaceholder("Mover")
        model.library = Library(books: [book])
        var merged = model.library
        let folder = BookFolder(name: "Synced Shelf \(UUID().uuidString.prefix(6))")
        made.append(TextMouthPaths.libraryDir.appendingPathComponent(folder.fullPath, isDirectory: true))
        merged.folders = [folder]
        merged.books[0].folderPath = folder.fullPath
        let key = SyncKey.book(book.id, .folder)
        let applied = await model.applySync(makeApplication(library: merged, moves: true, keys: [key]))
        XCTAssertEqual(applied, [key])
        let moved = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(moved.folderPath, folder.fullPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.tmbDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
    }

    /// A book a person removed elsewhere is removed here, package and row;
    /// one open in a reader waits for the next sync and its key is not applied.
    func testApplyRemovesABookButNotAnOpenOne() async throws {
        keepDeletionsOutOfTheTrash()
        let model = LibraryViewModel(initializeServices: false)
        let gone = try makePlaceholder("Gone")
        let open = try makePlaceholder("Open")
        model.library = Library(books: [gone, open])
        model.openBookIDs = [open.id]
        let keys: Set<SyncKey> = [.book(gone.id, .presence), .book(open.id, .presence)]
        let applied = await model.applySync(
            makeApplication(library: Library(books: [gone, open]), remove: [gone.id, open.id], keys: keys)
        )
        XCTAssertNil(model.bookByID(gone.id))
        XCTAssertNotNil(model.bookByID(open.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.tmbDirectory.path))
        XCTAssertEqual(applied, [.book(gone.id, .presence)])
    }

    /// A merged place is saved in the record as the merge chose it, even
    /// when the record held a later place.
    func testAMergedRecordKeepsTheMergedPlace() async throws {
        let model = LibraryViewModel(initializeServices: false)
        var book = try makePlaceholder("Place")
        var later = ReadingPosition(chapterIndex: 0, characterOffset: 900)
        later.lastUpdated = Date(timeIntervalSince1970: 1_790_000_900)
        book.readingPosition = later
        try book.saveBookInfoThrowing()
        model.library = Library(books: [book])

        // The merge chooses an earlier place.
        var merged = Library(books: [book])
        var earlier = ReadingPosition(chapterIndex: 0, characterOffset: 100)
        earlier.lastUpdated = Date(timeIntervalSince1970: 1_790_000_100)
        merged.books[0].readingPosition = earlier
        _ = await model.applySync(makeApplication(library: merged, keys: [.book(book.id, .position)]))
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(model.bookByID(book.id)?.readingPosition?.characterOffset, 100)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).state.readingPosition?.characterOffset, 100)
    }

    /// A placeholder is recorded as In Cloud, but a download under way keeps its own state.
    func testPlaceholdersAreRecordedInCloudButNotOverADownload() {
        let states = BookCloudStates()
        let waiting = UUID(), downloading = UUID()
        let progress = BookDownloadProgress(completedFiles: 0, totalFiles: 2, completedBytes: 0, totalBytes: 10)
        states.record(.downloading(progress), for: downloading)
        LibraryViewModel.recordInCloud([waiting, downloading], in: states)
        XCTAssertEqual(states.state(of: waiting), .inCloud)
        XCTAssertEqual(states.state(of: downloading), .downloading(progress))
    }

    /// In a synced library that is not in a cloud folder, the cloud
    /// refresher's call leaves the kept books alone: only a sync's own call
    /// (`afterSync`), which has checked the network, downloads them.
    func testTheRefreshersCallDoesNotDownloadInASyncedLibrary() {
        let model = LibraryViewModel(initializeServices: false)
        let book = makeBook("Kept And Away")
        model.library = Library(books: [book])
        let states = BookCloudStates()
        states.setSyncIsOn(true)
        states.record(.inCloud, for: book.id)
        let kept = KeptBooks(file: nil)
        kept.setSyncedBooks([book.id])
        let commands = LibraryCloudCommands(states: states, kept: kept)
        XCTAssertNil(commands.downloadEvictedKeptBooks(in: model))
    }

    /// Stopping to keep says so, once, only for the books whose keep it
    /// removed; keeping says so for the books it newly keeps.
    func testStoppingToKeepSaysSoOnlyForBooksThatWereKept() {
        let kept = makeBook("Was Kept"), other = makeBook("Never Kept")
        let before = KeptBooks.shared.syncedBookIDs
        addTeardownBlock { @MainActor in KeptBooks.shared.setSyncedBooks(before) }
        KeptBooks.shared.setSyncedBooks([kept.id])

        let stopped = recordingAnnouncements {
            LibraryCloudCommands.shared.setKeptOnAllDevices(false, [kept, other], from: nil)
        }
        XCTAssertEqual(stopped.announcements.map(\.message), [SyncWording.announceStoppedKeeping(title: "Was Kept")])
        XCTAssertFalse(KeptBooks.shared.isKeptOnAllDevices(kept.id))

        let again = recordingAnnouncements {
            LibraryCloudCommands.shared.setKeptOnAllDevices(false, [kept, other], from: nil)
        }
        XCTAssertTrue(again.announcements.isEmpty, "nothing was kept, so nothing is said")

        let keeping = recordingAnnouncements {
            LibraryCloudCommands.shared.setKeptOnAllDevices(true, [other], from: nil)
        }
        XCTAssertEqual(keeping.announcements.map(\.message), [SyncWording.announceKeeping(title: "Never Kept")])
    }

    /// The books kept on all devices are kept on this Mac too, and the
    /// listener's own keep is a different choice.
    func testSyncedBooksAreKept() {
        let kept = KeptBooks(file: nil)
        let book = UUID()
        kept.setSyncedBooks([book])
        XCTAssertTrue(kept.isKept(book))
        XCTAssertTrue(kept.isKeptOnAllDevices(book))
        XCTAssertFalse(kept.contains(book))
        XCTAssertFalse(kept.isKeptOnlyForReadingList(book))
        XCTAssertTrue(kept.keepsAnyBook)
        kept.setSyncedBooks([])
        XCTAssertFalse(kept.isKept(book))
    }
}
