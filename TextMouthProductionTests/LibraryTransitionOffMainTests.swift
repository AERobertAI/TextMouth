import XCTest
import os
@testable import TextMouth

/// A folder edit started from the library's sheets moves its books'
/// packages and rewrites their records off the main actor (PERF14), as
/// storage work that holds imports and extractions back, and publishes the
/// library once that is done. The library can change meanwhile, and keeps
/// every such change.
final class LibraryTransitionOffMainTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox!
    /// Folders this test created in the test root's library, removed after
    /// it with every package inside.
    private var createdFolders: [String] = []

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        createdFolders = []
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when capturing failed in set-up.
        // Restoring flushes pending saves, so none lands in a removed folder.
        sandbox?.restore()
        for folder in createdFolders {
            try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folder))
        }
    }

    // MARK: - Off the Main Thread

    /// Every package move and record write of a folder rename runs off the
    /// main thread, and the library holds the new rows afterwards.
    @MainActor
    func testAFolderRenameMovesItsPackagesOffTheMainThread() async throws {
        let (model, folder) = try makeShelf(bookCount: 3)
        let calls = DiskCallLog()
        let disk = LibraryTransitionDisk(
            moveItem: { source, destination in
                calls.note()
                try FileManager.default.moveItem(at: source, to: destination)
            },
            writeRecord: { book in
                calls.note()
                try book.saveBookInfoThrowing()
            }
        )
        let renamed = uniqueFolder("Renamed")
        var proposed = model.library
        try proposed.renameFolderThrowing(id: folder.id, to: renamed, equivalence: .library)

        try await model.performLibraryTransition(
            proposed,
            affectedBookIDs: model.bookIDsChangingFolder(in: proposed),
            disk: disk
        )

        XCTAssertEqual(calls.count, 6, "three moves and three record writes")
        XCTAssertEqual(calls.onMainThread, 0, "a package moved or a record was written on the main thread")
        XCTAssertEqual(Set(model.library.books.map(\.folderPath)), [renamed])
        for book in model.library.books {
            XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath))
            XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.folderPath, renamed)
        }
    }

    // MARK: - Changes Made Meanwhile

    /// A reader's checkpoint made while the packages move is kept: the row
    /// holds the new place and the new position, and the record at the new
    /// place holds the position too.
    @MainActor
    func testACheckpointMadeWhileThePackagesMoveIsKept() async throws {
        let (model, folder) = try makeShelf(bookCount: 2)
        let reading = try XCTUnwrap(model.library.books.first)
        let destination = uniqueFolder("Destination")
        let checkpointMade = DiskCallLog()
        let disk = LibraryTransitionDisk(
            moveItem: { source, destination in
                // The first move happens while a reader saves its position.
                if checkpointMade.count == 0 {
                    checkpointMade.note()
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            model.persistReadingPosition(
                                bookID: reading.id,
                                position: ReadingPosition(chapterIndex: 0, characterOffset: 42)
                            )
                        }
                    }
                }
                try FileManager.default.moveItem(at: source, to: destination)
            },
            writeRecord: { try $0.saveBookInfoThrowing() }
        )
        var proposed = model.library
        for index in proposed.books.indices {
            proposed.books[index].folderPath = destination
        }
        _ = folder

        try await model.performLibraryTransition(
            proposed,
            affectedBookIDs: Set(proposed.books.map(\.id)),
            disk: disk
        )
        LibraryPersistenceService.flushPendingSave()

        let row = try XCTUnwrap(model.bookByID(reading.id))
        XCTAssertEqual(row.folderPath, destination)
        XCTAssertEqual(row.readingPosition?.characterOffset, 42, "the checkpoint made meanwhile was lost")
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.filePath))
        XCTAssertEqual(try BookInfo.load(from: row.tmbDirectory).state.readingPosition?.characterOffset, 42)
        XCTAssertEqual(try BookInfo.load(from: row.tmbDirectory).metadata.folderPath, destination)
    }

    /// A failed move is put back off the main thread: every package is where
    /// it was, the library is unchanged, and the edit says why.
    @MainActor
    func testAFailedMoveIsPutBackAndChangesNothing() async throws {
        let (model, folder) = try makeShelf(bookCount: 3)
        let before = model.library.books
        let moves = DiskCallLog()
        let disk = LibraryTransitionDisk(
            moveItem: { source, destination in
                // The third move fails, after two packages moved; moving
                // those two back works.
                moves.note()
                if moves.count == 3 {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try FileManager.default.moveItem(at: source, to: destination)
            },
            writeRecord: { try $0.saveBookInfoThrowing() }
        )
        var proposed = model.library
        try proposed.renameFolderThrowing(id: folder.id, to: uniqueFolder("Never Made"), equivalence: .library)

        do {
            try await model.performLibraryTransition(
                proposed,
                affectedBookIDs: model.bookIDsChangingFolder(in: proposed),
                disk: disk
            )
            XCTFail("the move did not fail")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace)
        }

        XCTAssertEqual(model.library.books, before)
        for book in before {
            XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath), "\(book.title) is not back")
        }
    }

    /// While another operation holds the library's storage work, a folder
    /// edit is refused, saying what that operation is doing (#673): a
    /// data-directory move, Rebuild Directory, or another folder edit. It
    /// changes nothing.
    @MainActor
    func testAFolderEditIsRefusedWhileStorageIsHeldElsewhere() async throws {
        let (model, folder) = try makeShelf(bookCount: 1)
        let before = model.library.books
        let refusals: [(StorageHoldReason, String)] = [
            (.movingDataDirectory, "TextMouth is already moving its data directory. Try again once that move is done."),
            (.rebuildingDirectory, "TextMouth is rebuilding its data directory. Try again when that finishes."),
            (.movingBooksBetweenFolders, "TextMouth is moving books between folders. Try again when that finishes."),
        ]

        for (reason, refusal) in refusals {
            let hold = try StorageBoundary.shared.holdWork(for: reason)
            let outcome = await model.renameFolderReturningOutcome(folder, to: uniqueFolder("Held"))
            hold.release()

            XCTAssertEqual(outcome.failureMessage, "Could not rename folder: \(refusal)", "held for \(reason)")
            XCTAssertEqual(model.library.books, before, "held for \(reason)")
        }
    }

    /// An empty folder has no packages to move, so renaming it holds no
    /// storage work and waits for none: it is renamed at once even while
    /// another operation holds the library's storage work.
    @MainActor
    func testAnEmptyFolderIsRenamedAtOnceEvenWhileStorageIsHeld() async throws {
        let (model, folder) = try makeShelf(bookCount: 0)
        let renamed = uniqueFolder("Renamed Empty")
        let hold = try StorageBoundary.shared.holdWork(for: .movingDataDirectory)
        defer { hold.release() }

        let outcome = await model.renameFolderReturningOutcome(folder, to: renamed)

        XCTAssertEqual(outcome, .success(nil))
        XCTAssertEqual(model.library.folders.map(\.fullPath), [renamed])
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.libraryDir.appendingPathComponent(renamed).path))
    }

    /// The library published after a transition is the proposed one when
    /// nothing changed meanwhile; otherwise it is the library as it is now,
    /// with the transition's changes made to it: the moved books' places,
    /// and the folders and sort settings the transition added, changed, or
    /// removed. Every other change made meanwhile stays.
    @MainActor
    func testThePublishedLibraryKeepsChangesMadeMeanwhile() throws {
        let shelf = BookFolder(name: "Shelf")
        let other = BookFolder(name: "Other")
        let moving = Book(title: "Moving", format: .txt, filePath: "/old/Shelf/m.tmb/m.txt", md5Hash: "m", folderPath: "Shelf", tmbDirectoryName: "m.tmb")
        let staying = Book(title: "Staying", format: .txt, filePath: "/old/Other/s.tmb/s.txt", md5Hash: "s", folderPath: "Other", tmbDirectoryName: "s.tmb")
        let original = Library(
            books: [moving, staying],
            folders: [shelf, other],
            folderSortSettings: ["Shelf": .defaultSort, "Other": .defaultSort]
        )
        var renamedShelf = shelf
        renamedShelf.name = "Stacks"
        var moved = moving
        moved.fileLocation = Book.FileLocation(folderPath: "Stacks", filePath: "/old/Stacks/m.tmb/m.txt", tmbDirectoryName: "m.tmb")
        let proposed = Library(
            books: [moved, staying],
            folders: [renamedShelf, other],
            folderSortSettings: ["Stacks": .defaultSort, "Other": .defaultSort]
        )
        let plan = LibraryTransitionPlan(
            original: original,
            proposed: proposed,
            moves: [LibraryTransitionMove(
                original: moving,
                updated: moved,
                source: URL(fileURLWithPath: "/old/Shelf/m.tmb"),
                destination: URL(fileURLWithPath: "/old/Stacks/m.tmb"),
                needsDiskMove: true
            )],
            changedFolders: [renamedShelf]
        )

        XCTAssertEqual(LibraryViewModel.library(after: plan, current: original).books, proposed.books)

        var current = original
        current.books[0].readingPosition = ReadingPosition(chapterIndex: 2, characterOffset: 9)
        current.books.append(Book(title: "Added", format: .txt, filePath: "/old/a.txt", md5Hash: "a"))
        current.folders.append(BookFolder(name: "Created Meanwhile"))
        let manual = FolderSortSetting(sortField: .manual, sortAscending: true)
        current.folderSortSettings["Other"] = manual

        let published = LibraryViewModel.library(after: plan, current: current)

        let publishedMoving = try XCTUnwrap(published.books.first { $0.id == moving.id })
        XCTAssertEqual(publishedMoving.fileLocation, moved.fileLocation)
        XCTAssertEqual(publishedMoving.readingPosition?.characterOffset, 9)
        XCTAssertEqual(published.books.map(\.title), ["Moving", "Staying", "Added"])
        XCTAssertEqual(published.folders.map(\.fullPath), ["Stacks", "Other", "Created Meanwhile"])
        XCTAssertEqual(published.folderSortSettings, ["Stacks": .defaultSort, "Other": manual])
    }

    /// A change made meanwhile to a part of the library a folder edit leaves
    /// alone, a book added to the Reading List in another window or a feed
    /// item's row put on the feed shelf, stays once the edit publishes, with
    /// the edit's own move made too. The proposed library holds those parts
    /// as the plan found them, so it is published whole only when nothing at
    /// all changed meanwhile.
    @MainActor
    func testThePublishedLibraryKeepsAReadingListOrFeedShelfChangeMadeMeanwhile() throws {
        let shelf = BookFolder(name: "Shelf")
        let moving = Book(title: "Moving", format: .txt, filePath: "/old/m.tmb/m.txt", md5Hash: "m", tmbDirectoryName: "m.tmb")
        let listed = Book(title: "Listed", format: .txt, filePath: "/old/l.tmb/l.txt", md5Hash: "l", tmbDirectoryName: "l.tmb")
        let original = Library(books: [moving, listed], folders: [shelf])
        var moved = moving
        moved.fileLocation = Book.FileLocation(folderPath: "Shelf", filePath: "/old/Shelf/m.tmb/m.txt", tmbDirectoryName: "m.tmb")
        let proposed = Library(books: [moved, listed], folders: [shelf])
        let plan = LibraryTransitionPlan(
            original: original,
            proposed: proposed,
            moves: [LibraryTransitionMove(
                original: moving,
                updated: moved,
                source: URL(fileURLWithPath: "/old/m.tmb"),
                destination: URL(fileURLWithPath: "/old/Shelf/m.tmb"),
                needsDiskMove: true
            )],
            changedFolders: []
        )
        var item = Book(title: "Harbour Log", format: .txt, filePath: "/old/feed/h.tmb/h.txt", md5Hash: "h", tmbDirectoryName: "h.tmb")
        item.feedLink = FeedBookLink(feedID: UUID(), itemID: "guid:harbour-log")

        XCTAssertEqual(LibraryViewModel.library(after: plan, current: original), proposed, "nothing changed, yet the proposed library was not published whole")

        var listedMeanwhile = original
        listedMeanwhile.readingList.append([listed.id])
        let afterListing = LibraryViewModel.library(after: plan, current: listedMeanwhile)
        XCTAssertEqual(afterListing.readingList.bookIDs, [listed.id], "the book added to the Reading List meanwhile was dropped")
        XCTAssertEqual(afterListing.books, proposed.books, "the edit's move was not made")

        var shelvedMeanwhile = original
        shelvedMeanwhile.feedShelf.put(item)
        let afterShelving = LibraryViewModel.library(after: plan, current: shelvedMeanwhile)
        XCTAssertEqual(afterShelving.feedShelf.rows.map(\.id), [item.id], "the feed item's row put on the shelf meanwhile was dropped")
        XCTAssertEqual(afterShelving.books, proposed.books, "the edit's move was not made")
    }

    /// Only a transition that moves many packages, and so can take a while,
    /// says when it is done; a small one finishes before anyone could wonder.
    @MainActor
    func testOnlyALongTransitionAnnouncesItsEnd() {
        XCTAssertNil(LibraryTransitionWording.completion(movingPackagesOf: 0))
        XCTAssertNil(LibraryTransitionWording.completion(movingPackagesOf: LibraryTransitionWording.announcedPackageCount - 1))
        XCTAssertEqual(LibraryTransitionWording.completion(movingPackagesOf: 25), "Done. Moved 25 books.")
    }

    // MARK: - Fixtures

    /// A folder of this test's own holding `bookCount` packaged books, and a
    /// library model listing them.
    @MainActor
    private func makeShelf(bookCount: Int) throws -> (LibraryViewModel, BookFolder) {
        let name = uniqueFolder("Shelf")
        try TextMouthPaths.ensureLibrarySubfolder(name)
        let books = try (0..<bookCount).map { number -> Book in
            let packageName = "OffMain-\(number)-\(UUID().uuidString).tmb"
            let package = TextMouthPaths.tmbPath(folderPath: name, tmbName: packageName)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let source = package.appendingPathComponent("book.md")
            try "# Book \(number)\n\nWords.".write(to: source, atomically: true, encoding: .utf8)
            let book = Book(
                title: "Shelved \(number)",
                format: .markdown,
                filePath: source.path,
                md5Hash: UUID().uuidString,
                folderPath: name,
                tmbDirectoryName: packageName
            )
            try book.saveBookInfoThrowing()
            return book
        }
        let folder = BookFolder(name: name)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: books, folders: [folder])
        return (model, folder)
    }

    /// A library folder name no other test uses, removed when this test ends.
    @MainActor
    private func uniqueFolder(_ prefix: String) -> String {
        let name = "\(prefix) \(UUID().uuidString.prefix(8))"
        createdFolders.append(name)
        return name
    }
}

/// The calls a test's disk operations noted, and how many of them ran on
/// the main thread. Its state lives in an OSAllocatedUnfairLock, since the
/// operations run on whatever thread the transition gives them.
private final class DiskCallLog: Sendable {
    /// How many calls were noted, and how many on the main thread.
    private let state = OSAllocatedUnfairLock(initialState: (count: 0, onMainThread: 0))

    /// Notes a call made on the current thread.
    func note() {
        let isMain = Thread.isMainThread
        state.withLock {
            $0.count += 1
            if isMain { $0.onMainThread += 1 }
        }
    }

    /// How many calls were noted.
    var count: Int {
        state.withLock { $0.count }
    }

    /// How many of them ran on the main thread.
    var onMainThread: Int {
        state.withLock { $0.onMainThread }
    }
}
