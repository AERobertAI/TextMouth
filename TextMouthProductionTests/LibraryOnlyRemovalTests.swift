import XCTest
@testable import TextMouth

/// Remove from Library Only takes a book out of the library for good while
/// its package and content file stay on disk for a later re-import (TODO
/// S06). A removedFromLibrary.json marker, written into the package before
/// the row is removed, is what keeps the book out. Tests use real packages
/// in the isolated test root and restore its library index afterwards.
final class LibraryOnlyRemovalTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox!
    /// Directories this test created, removed after it with everything inside.
    private var createdDirectories: [URL] = []

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

    // MARK: - The Marker

    /// A marker retires the book it names and no other. One that cannot be
    /// read retires any book, because only a removal writes it. A package
    /// without one retires nothing.
    func testMarkerRetiresOnlyTheBookItNames() throws {
        let package = try makeScratchPackage()
        let removed = fixtureBook(title: "Named Removal")
        let neighbour = fixtureBook(title: "Shared Package Neighbour")
        XCTAssertFalse(RemovedFromLibraryMarker.retires(removed.id, in: package))

        try RemovedFromLibraryMarker(book: removed).write(into: package)
        XCTAssertTrue(RemovedFromLibraryMarker.retires(removed.id, in: package))
        XCTAssertFalse(RemovedFromLibraryMarker.retires(neighbour.id, in: package))

        try Data("not a marker".utf8).write(to: TextMouthPaths.removedFromLibraryMarkerPath(in: package))
        XCTAssertTrue(RemovedFromLibraryMarker.retires(removed.id, in: package))
        XCTAssertTrue(RemovedFromLibraryMarker.retires(neighbour.id, in: package))
    }

    /// The marker is a readable file beside bookInfo.json that names the
    /// book, its title and author, and when it was removed.
    func testMarkerRecordsTheBookAndWhenItWasRemoved() throws {
        let package = try makeScratchPackage()
        let book = fixtureBook(title: "Recorded Removal")
        let removedAt = Date(timeIntervalSince1970: 1_790_000_000)

        try RemovedFromLibraryMarker(book: book, removedAt: removedAt).write(into: package)

        let url = package.appendingPathComponent("removedFromLibrary.json")
        XCTAssertEqual(TextMouthPaths.removedFromLibraryMarkerPath(in: package), url)
        let marker = try RemovedFromLibraryMarker.read(in: package)
        XCTAssertEqual(marker.bookID, book.id)
        XCTAssertEqual(marker.title, "Recorded Removal")
        XCTAssertEqual(marker.author, "Test Fixture")
        XCTAssertEqual(marker.removedAt, removedAt)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(book.id.uuidString), text)
    }

    /// A record without a package name resolves to its folder rather than a
    /// package, so it is never retired, whatever that folder holds.
    func testRecordWithoutAPackageIsNeverRetired() throws {
        let folder = uniqueFolderName("Legacy Shelf")
        let folderDirectory = try makeFolder(folder)
        var legacy = fixtureBook(title: "Legacy Record")
        legacy.folderPath = folder
        legacy.tmbDirectoryName = ""
        try RemovedFromLibraryMarker(book: legacy).write(into: folderDirectory)

        XCTAssertTrue(RemovedFromLibraryMarker.retires(legacy.id, in: folderDirectory))
        XCTAssertFalse(RemovedFromLibraryMarker.retires(legacy))
    }

    // MARK: - Orphan Adoption

    /// Adoption skips a package whose marker retires its book, even with a
    /// readable bookInfo.json left in it, and leaves every file in it as it
    /// was. An unmarked package beside it is adopted as before.
    func testAdoptionSkipsAPackageWhoseMarkerRetiresItsBook() throws {
        let orphan = try makePackage(title: "Interrupted Import")
        let removed = try makePackage(title: "Removed Book")
        try RemovedFromLibraryMarker(book: removed).write(into: removed.tmbDirectory)
        let before = try packageSnapshot(of: removed)

        let adopted = adoptedFromLibraryDirectory()

        XCTAssertTrue(adopted.books.contains { $0.id == orphan.id })
        XCTAssertFalse(adopted.books.contains { $0.id == removed.id })
        XCTAssertEqual(try packageSnapshot(of: removed), before)
    }

    /// A marker naming another book, as a removal can leave in a legacy
    /// package still shared by two records, does not stop the package's own
    /// book from being adopted, and is never taken for its content file.
    func testAdoptionIgnoresAMarkerNamingAnotherBook() throws {
        let owner = try makePackage(title: "Package Owner")
        try RemovedFromLibraryMarker(book: fixtureBook(title: "Former Sharer")).write(into: owner.tmbDirectory)

        let adopted = try XCTUnwrap(adoptedFromLibraryDirectory().books.first { $0.id == owner.id })

        XCTAssertEqual(URL(fileURLWithPath: adopted.filePath).lastPathComponent, "book.txt")
        XCTAssertEqual(
            URL(fileURLWithPath: adopted.filePath).resolvingSymlinksInPath().path,
            URL(fileURLWithPath: owner.filePath).resolvingSymlinksInPath().path
        )
    }

    // MARK: - The Metadata Queue

    /// Retiring a package writes its marker and deletes bookInfo.json, and
    /// no write recreates that record: neither one still waiting in the
    /// debounce nor a later one, whether the debounce fires or the quit
    /// flush runs. The content file stays.
    func testNoQueuedOrLaterWriteRecreatesARetiredPackagesRecord() throws {
        let book = try makePackage(title: "Queued Write")
        var edited = book
        edited.manualSortOrder = 4
        LibraryPersistenceService.saveBookInfo(for: edited)

        let retirement = try LibraryPersistenceService.retirePackage(of: book)
        LibraryPersistenceService.saveBookInfo(for: edited)
        LibraryPersistenceService.flushPendingSave()
        waitPastLibrarySaveDebounce()

        XCTAssertTrue(retirement.isPackageMarked)
        XCTAssertNil(retirement.recordDeletionError)
        XCTAssertEqual(try RemovedFromLibraryMarker.read(in: book.tmbDirectory).bookID, book.id)
        XCTAssertFalse(exists(record(of: book)), "no write may recreate the record")
        XCTAssertTrue(exists(URL(fileURLWithPath: book.filePath)))
    }

    /// Background analysis committing while the book is removed leaves no
    /// record behind, whichever runs first: a commit before the removal is
    /// deleted with bookInfo.json, and one after it is dropped. The content
    /// file and its text cache stay.
    func testAnalysisCommittedAroundTheRemovalLeavesNoRecord() throws {
        let book = try makePackage(title: "Analyzed During Removal")
        var parsed = book
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &parsed))
        let analyzed = parsed
        let committed = expectation(description: "The analysis worker committed its result")

        DispatchQueue.global(qos: .utility).async {
            do {
                try LibraryPersistenceService.saveContentAnalysis(
                    for: analyzed, index: index, cacheFormatVersion: analyzed.cacheFormatVersion
                )
            } catch {
                XCTFail("Committing the analysis threw \(error)")
            }
            committed.fulfill()
        }
        XCTAssertNoThrow(try LibraryPersistenceService.retirePackage(of: book))
        wait(for: [committed], timeout: 10)
        XCTAssertNoThrow(try LibraryPersistenceService.saveContentAnalysis(
            for: analyzed, index: index, cacheFormatVersion: analyzed.cacheFormatVersion
        ))

        XCTAssertFalse(exists(record(of: book)))
        XCTAssertTrue(exists(marker(of: book)))
        XCTAssertTrue(exists(URL(fileURLWithPath: book.filePath)))
        XCTAssertTrue(exists(TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory)))
    }

    /// A package that cannot take the marker refuses the retirement with an
    /// error naming the package, and nothing changes: the record is intact
    /// and the book's metadata is still saved.
    func testUnwritablePackageRefusesRetirementAndChangesNothing() throws {
        let book = try makePackage(title: "Read-Only Package")
        let recordBefore = try Data(contentsOf: record(of: book))
        setWritable(book.tmbDirectory, false)

        XCTAssertThrowsError(try LibraryPersistenceService.retirePackage(of: book)) { error in
            guard case LibraryRemovalError.couldNotMarkPackage(let packageName, _) = error else {
                return XCTFail("Expected couldNotMarkPackage, got \(error)")
            }
            XCTAssertEqual(packageName, book.tmbDirectoryName)
            XCTAssertTrue(error.localizedDescription.contains(book.tmbDirectoryName), error.localizedDescription)
        }
        setWritable(book.tmbDirectory, true)

        XCTAssertFalse(exists(marker(of: book)))
        XCTAssertEqual(try Data(contentsOf: record(of: book)), recordBefore)
        var edited = book
        edited.manualSortOrder = 6
        LibraryPersistenceService.saveBookInfo(for: edited)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).state.manualSortOrder, 6)
    }

    /// A record that cannot be deleted is reported, but the marker still
    /// retires the package, so adoption leaves it out even though its
    /// bookInfo.json can be read.
    func testLockedRecordIsReportedButThePackageStaysRetired() throws {
        let book = try makePackage(title: "Locked Record")
        try lock(record(of: book))

        let retirement = try LibraryPersistenceService.retirePackage(of: book)

        XCTAssertTrue(retirement.isPackageMarked)
        XCTAssertNotNil(retirement.recordDeletionError)
        XCTAssertTrue(exists(record(of: book)))
        XCTAssertTrue(exists(marker(of: book)))
        XCTAssertFalse(adoptedFromLibraryDirectory().books.contains { $0.id == book.id })
    }

    /// A record with nothing on disk, because its package is already gone or
    /// it never had one, is retired without writing anything anywhere.
    func testRetiringARecordWithoutAPackageOnDiskWritesNothing() throws {
        let folder = uniqueFolderName("Missing Package Shelf")
        let folderDirectory = try makeFolder(folder)
        var gone = fixtureBook(title: "Package Already Gone")
        gone.folderPath = folder
        var legacy = fixtureBook(title: "Legacy Record")
        legacy.folderPath = folder
        legacy.tmbDirectoryName = ""

        for book in [gone, legacy] {
            let retirement = try LibraryPersistenceService.retirePackage(of: book)
            XCTAssertFalse(retirement.isPackageMarked, book.title)
            XCTAssertNil(retirement.recordDeletionError, book.title)
        }

        XCTAssertFalse(exists(gone.tmbDirectory), "no package is created")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folderDirectory.path), [])
    }

    /// A .tmb import of an earlier copy keeps the book's ID in a package of
    /// its own. Retiring the original package must not drop that copy's writes.
    func testAnotherPackageOfTheSameBookIsStillSaved() throws {
        let book = try makePackage(title: "Imported Twice")
        _ = try LibraryPersistenceService.retirePackage(of: book)
        var copy = book
        copy.folderPath = uniqueFolderName("Import Shelf")
        try makeFolder(copy.folderPath)
        try FileManager.default.createDirectory(at: copy.tmbDirectory, withIntermediateDirectories: true)
        copy.filePath = copy.tmbDirectory.appendingPathComponent("book.txt").path

        LibraryPersistenceService.saveBookInfo(for: copy)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try BookInfo.load(from: copy.tmbDirectory).metadata.bookID, book.id)
        XCTAssertFalse(exists(record(of: book)))
    }

    /// A deliberate return deletes the marker and forgets the retirement:
    /// the book's metadata is saved again, and adoption finds the package.
    func testReinstatingAPackageLetsItsWritesAndAdoptionReturn() throws {
        let book = try makePackage(title: "Deliberate Return")
        _ = try LibraryPersistenceService.retirePackage(of: book)

        try LibraryPersistenceService.reinstatePackage(of: book)
        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertFalse(exists(marker(of: book)))
        XCTAssertTrue(exists(record(of: book)))
        XCTAssertTrue(adoptedFromLibraryDirectory().books.contains { $0.id == book.id })
    }

    // MARK: - Removing from the Library

    /// Remove from Library Only takes the row out, marks the package, and
    /// keeps its content file; the other books and their records stay.
    @MainActor
    func testRemovalMarksThePackageAndKeepsItsContent() throws {
        let book = try makePackage(title: "Removed Quietly")
        let kept = try makePackage(title: "Still Listed")
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book, kept])

        model.removeBooksFromLibraryOnly([book])

        XCTAssertEqual(model.library.books.map(\.id), [kept.id])
        XCTAssertFalse(model.showError)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try RemovedFromLibraryMarker.read(in: book.tmbDirectory).title, "Removed Quietly")
        XCTAssertFalse(exists(record(of: book)))
        XCTAssertTrue(exists(URL(fileURLWithPath: book.filePath)))
        XCTAssertTrue(exists(record(of: kept)))
    }

    /// A package write still waiting in the debounce when the book is removed
    /// never lands, whether the debounce fires or the quit flush runs: no
    /// bookInfo.json returns, adoption finds nothing, and the index is saved
    /// without the book.
    @MainActor
    func testQueuedWriteCannotBringARemovedBookBack() throws {
        let book = try makePackage(title: "Pending Save")
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        model.updateLocalVoiceAndSpeed(bookID: book.id, voiceID: nil, wpm: 210)

        model.removeBooksFromLibraryOnly([book])
        LibraryPersistenceService.flushPendingSave()
        waitPastLibrarySaveDebounce()

        XCTAssertFalse(exists(record(of: book)))
        XCTAssertFalse(adoptedFromLibraryDirectory().books.contains { $0.id == book.id })
        let saved = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertFalse(saved.books.contains { $0.id == book.id })
    }

    /// A reader window left open on the removed book keeps saving through
    /// the library model. Its position, bookmarks, settings, and analysis
    /// neither recreate the record nor bring the row back.
    @MainActor
    func testOpenReaderSavesCannotBringARemovedBookBack() throws {
        let book = try makePackage(title: "Open In A Reader")
        var parsed = book
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &parsed))
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])

        model.removeBooksFromLibraryOnly([book])
        model.persistReadingPosition(bookID: book.id, position: ReadingPosition(characterOffset: 40))
        model.addBookmark(bookID: book.id, chapterIndex: 0, characterOffset: 40, label: "Late")
        model.updateLocalVoiceAndSpeed(bookID: book.id, voiceID: nil, wpm: 190)
        model.markBookOpened(book.id)
        model.updateWordCounts(bookID: book.id, wordCount: 9, charCount: 60)
        model.updateContentIndex(bookID: book.id, index: index, cacheFormatVersion: parsed.cacheFormatVersion)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertNil(model.bookByID(book.id))
        XCTAssertFalse(exists(record(of: book)))
        XCTAssertFalse(adoptedFromLibraryDirectory().books.contains { $0.id == book.id })
    }

    /// A package that cannot take the marker keeps its book in the library,
    /// and the alert names the book and the package. Nothing is changed.
    @MainActor
    func testUnwritablePackageKeepsTheBookAndNamesThePackage() throws {
        let book = try makePackage(title: "Cannot Be Marked")
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        setWritable(book.tmbDirectory, false)

        model.removeBooksFromLibraryOnly([book])
        setWritable(book.tmbDirectory, true)

        XCTAssertEqual(model.library.books.map(\.id), [book.id])
        XCTAssertTrue(model.showError)
        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(message.hasPrefix("This book could not be removed from the library and remains in it:\n"), message)
        XCTAssertTrue(message.contains("Cannot Be Marked: "), message)
        XCTAssertTrue(message.contains(book.tmbDirectoryName), message)
        XCTAssertFalse(exists(marker(of: book)))
        XCTAssertTrue(exists(record(of: book)))
    }

    /// Of several books, those whose package can be marked are removed; only
    /// the one kept is named in the alert.
    @MainActor
    func testPartialRemovalReportsOnlyTheBookKept() throws {
        let removable = try makePackage(title: "Removable")
        let stuck = try makePackage(title: "Stuck In Place")
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [removable, stuck])
        setWritable(stuck.tmbDirectory, false)

        model.removeBooksFromLibraryOnly([removable, stuck])
        setWritable(stuck.tmbDirectory, true)

        XCTAssertEqual(model.library.books.map(\.id), [stuck.id])
        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(message.contains("Stuck In Place: "), message)
        XCTAssertFalse(message.contains("Removable"), message)
        XCTAssertTrue(exists(marker(of: removable)))
    }

    /// A bookInfo.json that cannot be deleted is reported, yet the book stays
    /// out: after a restart (a fresh model loading the same root) and after
    /// Rebuild Directory, though adoption could read that record. The
    /// content file stays on disk throughout.
    @MainActor
    func testLockedRecordIsReportedAndTheBookStaysOutAfterRestartAndRebuild() throws {
        let book = try makePackage(title: "Locked Record")
        let kept = try makePackage(title: "Kept Beside It")
        try lock(record(of: book))
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book, kept])

        model.removeBooksFromLibraryOnly([book])

        XCTAssertEqual(model.library.books.map(\.id), [kept.id])
        XCTAssertTrue(model.showError)
        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(message.hasPrefix("This book was removed from the library, but its bookInfo.json file"), message)
        XCTAssertTrue(message.contains("Locked Record: "), message)

        LibraryPersistenceService.flushPendingSave()
        let restarted = LibraryViewModel(initializeServices: false)
        restarted.loadLibraryIndex()
        XCTAssertNil(restarted.bookByID(book.id))
        XCTAssertNotNil(restarted.bookByID(kept.id))

        try FileImportService.rebuildDirectoryStructure(library: &restarted.library)
        XCTAssertNil(restarted.bookByID(book.id))
        XCTAssertNotNil(restarted.bookByID(kept.id))
        XCTAssertTrue(exists(URL(fileURLWithPath: book.filePath)))
        XCTAssertTrue(exists(marker(of: book)))
    }

    /// The confirmation captures its books when it opens. A book moved to
    /// another folder before the user confirms is marked where its package
    /// is now, not where the stale copy says.
    @MainActor
    func testRemovalMarksTheCurrentPackageOfABookMovedMeanwhile() throws {
        let book = try makePackage(title: "Moved Before Confirming")
        let destination = uniqueFolderName("Moved Shelf")
        try makeFolder(destination)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        let move = outcome { await model.moveBooksReturningOutcome([book], toFolder: destination) }
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")
        let moved = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(moved.folderPath, destination)

        model.removeBooksFromLibraryOnly([book])

        XCTAssertTrue(model.library.books.isEmpty)
        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertEqual(try RemovedFromLibraryMarker.read(in: moved.tmbDirectory).bookID, book.id)
        XCTAssertFalse(adoptedFromLibraryDirectory().books.contains { $0.id == book.id })
    }

    /// Importing the same file again lists the book once, in a new package,
    /// and still once after a restart: the retained package stays retired
    /// instead of returning as a second copy. A file import does not look
    /// for a retained package to take back, so its marker stays; importing
    /// a .tmb package does (see `RetainedPackageImportTests`).
    @MainActor
    func testReimportingTheSameFileListsTheBookOnce() throws {
        let book = try makePackage(title: "Imported Again")
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        model.removeBooksFromLibraryOnly([book])
        let source = try makeScratchDirectory().appendingPathComponent("Imported Again.txt")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: book.filePath), to: source)

        let reimported = try FileImportService.importFile(from: source, toFolder: book.folderPath)
        XCTAssertTrue(model.addBookCheckingDuplicate(reimported))
        model.save()
        LibraryPersistenceService.flushPendingSave()
        let restarted = LibraryViewModel(initializeServices: false)
        restarted.loadLibraryIndex()

        let listed = restarted.library.books.filter { $0.md5Hash == book.md5Hash }
        XCTAssertEqual(listed.map(\.id), [reimported.id])
        XCTAssertFalse(exists(marker(of: reimported)))
        XCTAssertTrue(exists(marker(of: book)))
        XCTAssertTrue(exists(URL(fileURLWithPath: book.filePath)))
    }

    /// While the index cannot be read, the library shown is rebuilt from the
    /// packages on disk. A removed book is not part of it, even with a
    /// readable bookInfo.json left in its package.
    @MainActor
    func testProvisionalLibraryDuringIndexRecoveryLeavesARemovedBookOut() throws {
        let book = try makePackage(title: "Removed Before The Damage")
        try lock(record(of: book))
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        model.removeBooksFromLibraryOnly([book])
        LibraryPersistenceService.flushPendingSave()
        try sandbox.stage(.truncated, of: Library(books: [book]), at: sandbox.indexURL)

        let recovering = LibraryViewModel(initializeServices: false)
        recovering.loadLibraryIndex()

        XCTAssertNotNil(recovering.indexRecovery)
        XCTAssertNil(recovering.bookByID(book.id))
    }

    // MARK: - An Index Saved Before the Removal

    /// The startup repair takes out exactly the listed books whose own
    /// package retires them; a book whose package marker names another
    /// record stays, and nothing is deleted from disk.
    func testStartupRepairTakesOutOnlyBooksTheirPackagesRetire() throws {
        let retired = try makePackage(title: "Retired")
        let sharer = try makePackage(title: "Shares A Package Once")
        let untouched = try makePackage(title: "Untouched")
        try RemovedFromLibraryMarker(book: retired).write(into: retired.tmbDirectory)
        try RemovedFromLibraryMarker(book: fixtureBook(title: "Removed Sharer")).write(into: sharer.tmbDirectory)
        var library = Library(books: [retired, sharer, untouched])

        let removed = RemovedFromLibraryMarker.removeRetiredBooks(from: &library)

        XCTAssertEqual(removed.map(\.id), [retired.id])
        XCTAssertEqual(library.books.map(\.id), [sharer.id, untouched.id])
        XCTAssertTrue(exists(URL(fileURLWithPath: retired.filePath)))
        XCTAssertTrue(exists(record(of: retired)))
    }

    /// When the app stops before the removal's debounced save reaches the
    /// disk, the next launch loads an index that still lists the book. The
    /// marker is the later decision: the book stays out, and the repaired
    /// index is saved without it. Its package and content stay.
    @MainActor
    func testIndexSavedBeforeTheRemovalCannotBringTheBookBack() throws {
        let book = try makePackage(title: "Removed Just Before Quitting")
        let kept = try makePackage(title: "Listed Throughout")
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book, kept])
        model.removeBooksFromLibraryOnly([book])
        LibraryPersistenceService.flushPendingSave()
        try sandbox.stageValid(Library(books: [book, kept]), at: sandbox.indexURL)

        let restarted = LibraryViewModel(initializeServices: false)
        restarted.loadLibraryIndex()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertNil(restarted.bookByID(book.id))
        XCTAssertNotNil(restarted.bookByID(kept.id))
        let saved = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertFalse(saved.books.contains { $0.id == book.id })
        XCTAssertTrue(saved.books.contains { $0.id == kept.id })
        XCTAssertTrue(exists(marker(of: book)))
        XCTAssertTrue(exists(URL(fileURLWithPath: book.filePath)))
    }

    /// Rebuild Directory applies the same rule to the library it rebuilds.
    func testRebuildTakesARemovedBookOutOfALibraryThatStillListsIt() throws {
        let book = try makePackage(title: "Listed Again By Mistake")
        _ = try LibraryPersistenceService.retirePackage(of: book)
        var library = Library(books: [book])

        try FileImportService.rebuildDirectoryStructure(library: &library)

        XCTAssertFalse(library.books.contains { $0.id == book.id })
        XCTAssertTrue(exists(URL(fileURLWithPath: book.filePath)))
    }

    /// A book removed while the index could not be read stays removed when
    /// Try Again then loads the index, which still lists it.
    @MainActor
    func testRemovalDuringIndexRecoverySurvivesTryAgain() throws {
        let book = try makePackage(title: "Removed While Recovering")
        try sandbox.stage(.unreadable, of: Library(books: [book]), at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()
        XCTAssertNotNil(model.bookByID(book.id), "the provisional library adopted the package")

        model.removeBooksFromLibraryOnly([book])
        LibraryIndexSandbox.makeReadable(sandbox.indexURL)
        let outcome = model.retryLibraryIndex()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(outcome, .restored(bookCount: model.library.books.count))
        XCTAssertNil(model.bookByID(book.id))
        let saved = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertFalse(saved.books.contains { $0.id == book.id })
        XCTAssertTrue(exists(URL(fileURLWithPath: book.filePath)))
    }

    /// The alert says which books stayed and which records were left, one
    /// line per book, in singular or plural as fits.
    func testRemovalProblemMessagesNameEachBookAndWhatHappened() {
        XCTAssertNil(LibraryViewModel.libraryOnlyRemovalProblems(refused: [], recordsLeft: []))
        XCTAssertEqual(
            LibraryViewModel.libraryOnlyRemovalProblems(
                refused: ["Atlas: no permission", "Bestiary: read-only volume"],
                recordsLeft: ["Chronicle: locked"]
            ),
            "These books could not be removed from the library and remain in it:\n"
                + "Atlas: no permission\nBestiary: read-only volume\n\n"
                + "This book was removed from the library, but its bookInfo.json file could not be deleted. "
                + "It will still stay out of the library:\nChronicle: locked"
        )
        XCTAssertEqual(
            LibraryViewModel.libraryOnlyRemovalProblems(refused: [], recordsLeft: ["Atlas: locked", "Bestiary: locked"]),
            "These books were removed from the library, but their bookInfo.json files could not be deleted. "
                + "They will still stay out of the library:\nAtlas: locked\nBestiary: locked"
        )
    }

    // MARK: - Fixtures

    /// A folder name unique to this test, so leftovers in the shared test
    /// root cannot collide with it.
    private func uniqueFolderName(_ base: String) -> String {
        "\(base) \(UUID().uuidString.prefix(8))"
    }

    /// Creates a top-level folder directory in the test root's library and
    /// schedules it, with everything inside, for removal.
    @discardableResult
    private func makeFolder(_ folder: String) throws -> URL {
        let directory = TextMouthPaths.libraryDir.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)
        return directory
    }

    /// Creates a real package in a folder of its own, as an import leaves it:
    /// a text file whose unique words give it a unique hash, and a
    /// bookInfo.json that orphan adoption could read.
    private func makePackage(title: String) throws -> Book {
        let folder = uniqueFolderName("Removal Shelf")
        try makeFolder(folder)
        let packageName = "LibraryOnlyRemoval-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folder, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = package.appendingPathComponent("book.txt")
        try Data("Words that outlive the removal of \(title), \(UUID().uuidString).".utf8).write(to: content)
        let book = Book(
            title: title,
            author: "Test Fixture",
            format: .txt,
            filePath: content.path,
            md5Hash: try FileImportService.md5Hash(of: content),
            folderPath: folder,
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing()
        return book
    }

    /// Every file in `book`'s package by name, with its bytes. Equal
    /// snapshots show nothing in the package was added, removed, or changed.
    private func packageSnapshot(of book: Book) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: book.tmbDirectory.path)
        var snapshot: [String: Data] = [:]
        for name in names {
            snapshot[name] = try Data(contentsOf: book.tmbDirectory.appendingPathComponent(name))
        }
        return snapshot
    }

    /// What orphan adoption finds in the test root's library directory, as
    /// startup, index recovery, and rebuild would adopt it into an index that
    /// lists none of it.
    private func adoptedFromLibraryDirectory() -> Library {
        var adopted = Library()
        FileImportService.adoptOrphanedTMBPackages(library: &adopted)
        return adopted
    }

    /// bookInfo.json in `book`'s package.
    private func record(of book: Book) -> URL {
        TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
    }

    /// The removal marker in `book`'s package.
    private func marker(of book: Book) -> URL {
        TextMouthPaths.removedFromLibraryMarkerPath(in: book.tmbDirectory)
    }

    /// Whether anything exists at `url`.
    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Locks `file` as Finder's Locked checkbox does, so it cannot be deleted
    /// although its folder is writable. A read-only mode would not do: the
    /// folder's permission, not the file's, decides whether it can be deleted.
    /// Tear-down unlocks it.
    private func lock(_ file: URL) throws {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
    }

    /// Gives `directory` or takes away its write permission, so nothing can
    /// be created in it. Tear-down gives it back in any case.
    private func setWritable(_ directory: URL, _ writable: Bool) {
        XCTAssertEqual(chmod(directory.path, writable ? 0o755 : 0o555), 0)
    }

    /// A new directory outside the library, removed after the test.
    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryOnlyRemoval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        createdDirectories.append(directory)
        return directory
    }

    /// A package directory outside the library, for checks of the marker
    /// on its own.
    private func makeScratchPackage() throws -> URL {
        let package = try makeScratchDirectory().appendingPathComponent("Scratch.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        return package
    }

    /// A book record that no package on disk holds.
    private func fixtureBook(title: String) -> Book {
        Book(
            title: title,
            author: "Test Fixture",
            format: .txt,
            filePath: "/nonexistent/library-only-removal/\(UUID().uuidString).txt",
            md5Hash: "library-only-removal-\(UUID().uuidString)",
            tmbDirectoryName: "LibraryOnlyRemoval-\(UUID().uuidString).tmb"
        )
    }

    /// Removes `url` and everything inside it, first unlocking files and
    /// giving directories their write permission back, since some tests
    /// lock a record or make a package read-only.
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
