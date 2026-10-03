import XCTest
@testable import TextMouth

/// Undoing a library move that failed is never silent (TODO S09). A package
/// that cannot be moved back is reported with where it is and where the
/// library expects it, a record that cannot be restored is reported as the
/// book's unsaved record, and each retry puts things right. A move that
/// succeeds settles the book's earlier failure. Injected disk operations
/// fail at the chosen moment; everything else is real.
@MainActor
final class MoveRollbackFailureTests: XCTestCase {
    /// A package moved out of its folder that cannot be moved back stays
    /// where the move put it, and is reported with both paths; Retry moves
    /// it back and restores its record, and settles the failure.
    func testAPackageThatCannotBeMovedBackIsReportedWithBothPaths() throws {
        let center = cleanSharedFailureCenter()
        let (source, destination) = uniqueFolders()
        let book = try makePackagedBook("Stranded Atlas", folderPath: source)
        let home = book.tmbDirectory
        let location = TextMouthPaths.tmbPath(folderPath: destination, tmbName: book.tmbDirectoryName)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book], folders: [BookFolder(name: source)])
        let failing = FailureSwitch()
        // `commitLibraryTransition` and the failure center's retries run
        // these on the main actor, where the switch lives.
        let disk = LibraryTransitionDisk(
            moveItem: { from, to in
                try MainActor.assumeIsolated {
                    // Moving back home fails while the switch is on.
                    if to.standardizedFileURL.path == home.standardizedFileURL.path {
                        try failing.throwIfOn()
                    }
                    try FileManager.default.moveItem(at: from, to: to)
                }
            },
            writeRecord: { record in
                try MainActor.assumeIsolated {
                    // Writing the moved record fails, which starts the rollback.
                    if record.folderPath == destination { try failing.throwIfOn() }
                    try record.saveBookInfoThrowing()
                }
            }
        )

        XCTAssertThrowsError(try model.commitLibraryTransition(
            movedLibrary(model.library, to: destination, folders: [BookFolder(name: destination)]),
            affectedBookIDs: [book.id],
            disk: disk
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: location.path), "the package stays where it went")
        XCTAssertEqual(model.library.books.first?.folderPath, source, "the library still expects it at home")
        let failure = try XCTUnwrap(center.outstandingFailures().first)
        XCTAssertEqual(
            failure.subject,
            .strandedPackage(bookID: book.id, title: "Stranded Atlas", location: location.path, home: home.path)
        )
        XCTAssertEqual(failure.path, location.path)
        XCTAssertTrue(failure.sentence.contains("its files are at \(location.path) instead of \(home.path)"))
        XCTAssertTrue(center.hasUnsavedChanges)

        failing.isOn = false
        recordingAnnouncements { center.retry(.bookRecord) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
        XCTAssertEqual(try BookInfo.load(from: home).metadata.folderPath, source)
        XCTAssertFalse(center.hasUnsavedChanges)
    }

    /// When a transition fails after every record was rewritten, each
    /// package goes back; a record that cannot be restored there is reported
    /// as the book's unsaved record, and Retry restores it.
    func testARecordThatCannotBeRestoredIsReportedAndRetryRestoresIt() throws {
        let center = cleanSharedFailureCenter()
        let (source, destination) = uniqueFolders()
        let book = try makePackagedBook("Unrestored Atlas", folderPath: source)
        // A file where a new folder must be made fails the transition after
        // the package has moved and its record has been rewritten.
        let blockedFolder = "MoveRollbackBlocked-\(UUID().uuidString)"
        let blocker = TextMouthPaths.libraryDir.appendingPathComponent(blockedFolder)
        try Data("not a folder".utf8).write(to: blocker)
        addTeardownBlock { try? FileManager.default.removeItem(at: blocker) }
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book], folders: [BookFolder(name: source)])
        let failing = FailureSwitch()
        // `commitLibraryTransition` and the failure center's retries run
        // these on the main actor, where the switch lives.
        let disk = LibraryTransitionDisk(
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            writeRecord: { record in
                try MainActor.assumeIsolated {
                    // Restoring the record at home fails while the switch is on.
                    if record.folderPath == source { try failing.throwIfOn() }
                    try record.saveBookInfoThrowing()
                }
            }
        )

        XCTAssertThrowsError(try model.commitLibraryTransition(
            movedLibrary(
                model.library,
                to: destination,
                folders: [BookFolder(name: destination), BookFolder(name: blockedFolder)]
            ),
            affectedBookIDs: [book.id],
            disk: disk
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: book.tmbDirectory.path), "the package is back")
        let failure = try XCTUnwrap(center.outstandingFailures().first)
        XCTAssertEqual(failure.subject, .bookRecord(bookID: book.id, title: "Unrestored Atlas"))
        XCTAssertEqual(failure.path, TextMouthPaths.bookInfoPath(in: book.tmbDirectory).path)
        XCTAssertEqual(
            try BookInfo.load(from: book.tmbDirectory).metadata.folderPath,
            destination,
            "until the retry, the record still names the folder the move was going to"
        )

        failing.isOn = false
        recordingAnnouncements { center.retry(.bookRecord) }

        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.folderPath, source)
        XCTAssertFalse(center.hasUnsavedChanges)
    }

    /// A move that writes the book's record at its new place has saved the
    /// book's current state, which settles the book's earlier failure.
    func testAMoveThatWritesTheRecordSettlesTheBooksEarlierFailure() throws {
        let center = cleanSharedFailureCenter()
        let (source, destination) = uniqueFolders()
        let book = try makePackagedBook("Moved Atlas", folderPath: source)
        center.recordFailure(.bookRecord(bookID: book.id, title: book.title), path: "/unsaved", error: WriteRefused())
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book], folders: [BookFolder(name: source)])

        let outcome = self.outcome { await model.moveBooksReturningOutcome([book], toFolder: destination) }

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertFalse(center.hasUnsavedChanges)
    }

    // MARK: - Helpers

    /// Two new library folder names, both removed with their contents when
    /// the test ends.
    private func uniqueFolders() -> (source: String, destination: String) {
        let token = UUID().uuidString
        let folders = (source: "MoveRollbackSource-\(token)", destination: "MoveRollbackDestination-\(token)")
        for name in [folders.source, folders.destination] {
            let directory = TextMouthPaths.libraryDir.appendingPathComponent(name, isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        }
        return folders
    }

    /// `library` with every book in `destination`, and `folders` added.
    private func movedLibrary(_ library: Library, to destination: String, folders: [BookFolder]) -> Library {
        var moved = library
        for index in moved.books.indices {
            moved.books[index].folderPath = destination
        }
        moved.folders += folders
        return moved
    }
}
