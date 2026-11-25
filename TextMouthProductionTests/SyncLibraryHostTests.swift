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

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
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

    /// A row now in another library folder is a book whose package moves.
    func testBooksMovedAreThoseInAnotherFolder() {
        let mover = makeBook("Mover"), stayer = makeBook("Stayer")
        let start = Library(books: [mover, stayer])
        var merged = start
        merged.books[0].folderPath = "Elsewhere"
        let merge = SyncRowMerge.make(applying: makeApplication(library: merged), start: start, current: start, added: [])
        XCTAssertEqual(merge.booksMoved(from: start), [mover.id])
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

    /// A new book joins as a placeholder in the library, its keys applied.
    func testApplyAddsAPlaceholderBook() async throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let newBook = makeNewBook("From Another Device")
        let key = SyncKey.book(newBook.book.id, .presence)
        let applied = await model.applySync(makeApplication(library: Library(), add: [newBook], keys: [key]))
        XCTAssertEqual(applied, [key])
        let added = try XCTUnwrap(model.bookByID(newBook.book.id))
        XCTAssertEqual(added.md5Hash, newBook.content.md5Hash)
        let package = SyncPlaceholder.packageDirectory(of: added, in: TextMouthPaths.libraryDir)
        XCTAssertTrue(SyncPlaceholder.isPlaceholder(package: package, contentFile: added.bookFileURL))
    }

    /// After a fetch the row's file path is the content file as the store
    /// names it, in the book's package; a path already right, a missing
    /// content path, and a book that is gone change nothing.
    func testAFetchSetsTheRowsFilePathToTheContentPath() throws {
        let model = LibraryViewModel(initializeServices: false)
        let book = try SyncPlaceholder.makePackage(for: makeNewBook("Fetched"), storeID: UUID())
        model.library = Library(books: [book])
        model.syncDidFetch(bookID: book.id, contentPath: "Original Name.txt")
        let row = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(row.filePath, book.tmbDirectory.appendingPathComponent("Original Name.txt").path)
        model.syncDidFetch(bookID: book.id, contentPath: nil)
        model.syncDidFetch(bookID: UUID(), contentPath: "Other.txt")
        XCTAssertEqual(model.bookByID(book.id)?.filePath, row.filePath)
    }

    /// A merge that puts a book in a new folder moves its package there,
    /// through the library transition, and the keys are applied.
    func testApplyMovesAPackageIntoANewFolder() async throws {
        let model = LibraryViewModel(initializeServices: false)
        let book = try SyncPlaceholder.makePackage(for: makeNewBook("Mover"), storeID: UUID())
        model.library = Library(books: [book])
        var merged = model.library
        let folder = BookFolder(name: "Synced Shelf \(UUID().uuidString.prefix(6))")
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
        let model = LibraryViewModel(initializeServices: false)
        let gone = try SyncPlaceholder.makePackage(for: makeNewBook("Gone"), storeID: UUID())
        let open = try SyncPlaceholder.makePackage(for: makeNewBook("Open"), storeID: UUID())
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
        var book = try SyncPlaceholder.makePackage(for: makeNewBook("Place"), storeID: UUID())
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
