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

    /// Retiring a package writes its marker, cancels a write still waiting
    /// in the debounce, deletes bookInfo.json, and drops every later write,
    /// debounced or flushed at quit. The content file stays.
    func testRetiringCancelsAQueuedWriteAndDropsLaterOnes() throws {
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

    /// A package directory outside the library, for checks of the marker
    /// on its own.
    private func makeScratchPackage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryOnlyRemoval-\(UUID().uuidString)", isDirectory: true)
        let package = directory.appendingPathComponent("Scratch.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        createdDirectories.append(directory)
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
