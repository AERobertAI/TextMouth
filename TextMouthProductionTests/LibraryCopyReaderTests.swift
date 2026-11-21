import XCTest
import os
@testable import TextMouth

/// Reading two copies of a library and comparing them (Phase 0 of the
/// local-first design), against fixture folders in the test's own sandbox:
/// the comparison changes nothing in either folder, whether they are offered
/// as cloud folders or are local ones, waits for no file longer than its
/// limit, and lists a file it could not read as unread.
final class LibraryCopyReaderTests: XCTestCase {

    // MARK: - Read-Only, Proven

    /// Comparing two local folders changes no byte, no modification date, and
    /// no name in either.
    func testComparingLocalFoldersChangesNothing() throws {
        let (this, other) = try makeDivergedCopies()
        let before = try snapshot(of: [this, other])

        let outcome = LibraryCopyReader(itemStatus: LocalItemStatusProvider(), fetch: { _ in }).compare(thisFolder: this, otherFolder: other)

        guard case .compared(let comparison) = outcome else { return XCTFail("compared: \(outcome)") }
        XCTAssertFalse(comparison.differences.isEmpty)
        XCTAssertEqual(try snapshot(of: [this, other]), before)
    }

    /// The same, offered as cloud folders, some of whose files are only in
    /// the cloud: the files are fetched and read, nothing is changed, and
    /// the sync service is never asked to download or remove anything itself.
    func testComparingCloudFoldersChangesNothingAndAsksTheDriveForNothing() throws {
        let (this, other) = try makeDivergedCopies()
        let before = try snapshot(of: [this, other])
        let cloud = FakeCloud(onlyInCloud: ["library.json", "library-identity.json", "bookInfo.json"])
        let fetched = OSAllocatedUnfairLock<[String]>(initialState: [])
        let reader = LibraryCopyReader(itemStatus: cloud, fetch: { url in fetched.withLock { $0.append(url.lastPathComponent) } })

        let outcome = reader.compare(thisFolder: this, otherFolder: other)

        guard case .compared(let comparison) = outcome else { return XCTFail("compared: \(outcome)") }
        XCTAssertFalse(comparison.differences.isEmpty)
        XCTAssertEqual(try snapshot(of: [this, other]), before)
        XCTAssertFalse(fetched.withLock { $0 }.isEmpty, "files only in the cloud were fetched to be read")
        XCTAssertEqual(cloud.requests.withLock { $0 }, [], "the sync service was asked to download or remove nothing")
    }

    // MARK: - What Is Found

    /// Two diverged copies differ in each way the command lists, and the
    /// newer place and bookmark of each are found through the files.
    func testDivergedCopiesDifferInEachListedWay() throws {
        let (this, other) = try makeDivergedCopies()

        let outcome = LibraryCopyReader(itemStatus: LocalItemStatusProvider(), fetch: { _ in }).compare(thisFolder: this, otherFolder: other)

        guard case .compared(let comparison) = outcome else { return XCTFail("compared: \(outcome)") }
        XCTAssertEqual(comparison.differences.map { LibraryComparisonWording.sentence(for: $0) }, [
            "Book only in the other copy: Emma.",
            "Position in Moby-Dick: newer in this copy, chapter 3, 41%. The other copy has chapter 2, 20%.",
            "Bookmark 2 in Moby-Dick: only in the other copy, chapter 2, with the note “Across the water”.",
            "Reading list: Emma is only on the other copy's list, at place 1.",
            "Folder “Sea” is only in the other copy.",
        ])
        XCTAssertEqual(comparison.unread, [])
    }

    /// A copy's index held in memory stands in for the one on disk, which
    /// is not read, so places not yet saved are compared.
    func testTheLibraryInMemoryStandsInForTheSavedIndex() throws {
        let (this, other) = try makeDivergedCopies()
        let moby = movedBook("Moby-Dick", at: place(chapter: 5, offset: 900, at: 9_000_000_000))
        let reader = LibraryCopyReader(
            itemStatus: LocalItemStatusProvider(),
            fetch: { url in XCTFail("nothing is fetched: \(url.lastPathComponent)") }
        )

        let outcome = reader.compare(thisFolder: this, thisLibrary: Library(books: [moby]), otherFolder: other)

        guard case .compared(let comparison) = outcome else { return XCTFail("compared: \(outcome)") }
        XCTAssertTrue(comparison.differences.contains {
            LibraryComparisonWording.sentence(for: $0).hasPrefix("Position in Moby-Dick: newer in this copy, chapter 6, 90%")
        })
    }

    /// Folders holding different libraries are said to, and nothing else is.
    func testFoldersOfDifferentLibrariesAreNotCompared() throws {
        let this = try writeCopy("This", identity: LibraryIdentity(id: UUID(), created: Date(timeIntervalSince1970: 1_790_000_000)), books: [])
        let other = try writeCopy("Other", identity: LibraryIdentity(id: UUID(), created: Date(timeIntervalSince1970: 1_790_000_000)), books: [])

        let outcome = reader().compare(thisFolder: this, otherFolder: other)

        XCTAssertEqual(outcome, .differentLibraries)
    }

    // MARK: - Unread, Never Missing

    /// A folder with no identity marker can't be said to hold the same
    /// library: the marker is listed as unread.
    func testAFolderWithoutAnIdentityMarkerIsUnread() throws {
        let identity = LibraryIdentity(id: UUID(), created: Date(timeIntervalSince1970: 1_790_000_000))
        let this = try writeCopy("This", identity: identity, books: [])
        let other = try writeCopy("Other", identity: nil, books: [])

        let outcome = reader().compare(thisFolder: this, otherFolder: other)

        guard case .notComparable(let unread) = outcome else { return XCTFail("compared: \(outcome)") }
        XCTAssertEqual(unread.map(\.subject), [.identityMarker])
        XCTAssertEqual(unread.map(\.side), [.otherCopy])
    }

    /// A library index that is damaged is unread, and nothing is compared:
    /// no book is called missing because its index could not be read.
    func testADamagedIndexIsUnreadAndNothingIsComparedFromIt() throws {
        let (this, other) = try makeDivergedCopies()
        try Data("{ not a library".utf8).write(to: other.appendingPathComponent("library.json"))

        let outcome = reader().compare(thisFolder: this, otherFolder: other)

        guard case .notComparable(let unread) = outcome else { return XCTFail("compared: \(outcome)") }
        XCTAssertEqual(unread.map(\.subject), [.libraryIndex])
        XCTAssertEqual(unread.map(\.side), [.otherCopy])
        XCTAssertEqual(
            LibraryComparisonWording.sentence(for: unread[0]),
            "Unread: the library index in the other copy couldn't be read (its contents are damaged), "
                + "so nothing in the other copy was compared."
        )
    }

    /// A record that can't be read is unread, the rest is compared, and its
    /// book is still compared by its row.
    func testARecordThatCannotBeReadIsUnreadWhileTheRestIsCompared() throws {
        let (this, other) = try makeDivergedCopies()
        try Data("garbage".utf8).write(to: bookInfoFile(named: "Moby-Dick", in: other))

        let outcome = reader().compare(thisFolder: this, otherFolder: other)

        guard case .compared(let comparison) = outcome else { return XCTFail("compared: \(outcome)") }
        XCTAssertEqual(comparison.unread.map(\.side), [.otherCopy])
        XCTAssertEqual(comparison.unread.map(\.subject), [.record(bookID: mobyID, title: "Moby-Dick")])
        XCTAssertFalse(comparison.differences.isEmpty, "the rest is still compared")
    }

    /// A file that has not arrived from the cloud within the limit is
    /// unread, with the limit in the reason; the comparison goes on, and the
    /// wait was not longer than the limit.
    func testAFileThatDoesNotArriveWithinTheLimitIsUnread() throws {
        let (this, other) = try makeDivergedCopies()
        let cloud = FakeCloud(onlyInCloud: ["bookInfo.json"])
        let release = DispatchSemaphore(value: 0)
        addTeardownBlock { for _ in 0..<8 { release.signal() } }
        let reader = LibraryCopyReader(itemStatus: cloud, fetch: { _ in _ = release.wait(timeout: .now() + 30) }, waitLimit: 1, fetchGuard: FetchGuard())
        let started = Date()

        let outcome = reader.compare(thisFolder: this, otherFolder: other)

        guard case .compared(let comparison) = outcome else { return XCTFail("compared: \(outcome)") }
        XCTAssertFalse(comparison.unread.isEmpty)
        XCTAssertTrue(comparison.unread.allSatisfy { $0.reason == .notArrived(seconds: 1) })
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "no wait outlasts its limit")
    }

    /// Once the whole comparison has used its time, the files not yet read are
    /// unread for that reason, and the comparison ends.
    func testFilesLeftWhenTheWholeTimeIsUsedAreUnread() throws {
        let (this, other) = try makeDivergedCopies()
        let cloud = FakeCloud(onlyInCloud: ["bookInfo.json"])
        let release = DispatchSemaphore(value: 0)
        addTeardownBlock { for _ in 0..<8 { release.signal() } }
        let reader = LibraryCopyReader(
            itemStatus: cloud,
            fetch: { _ in _ = release.wait(timeout: .now() + 30) },
            waitLimit: 30,
            overallLimit: 1,
            readSlots: 1,
            fetchGuard: FetchGuard()
        )

        let outcome = reader.compare(thisFolder: this, otherFolder: other)

        guard case .compared(let comparison) = outcome else { return XCTFail("compared: \(outcome)") }
        XCTAssertEqual(comparison.unread.count, 3)
        XCTAssertTrue(comparison.unread.contains { $0.reason == .timeRanOut(seconds: 1) }, "\(comparison.unread)")
    }

    /// The sheet's model reads off the main thread, ends with the count and the
    /// rows, and the folders are as they were.
    @MainActor
    func testTheSheetsModelComparesAndEndsWithTheCountAndRows() async throws {
        let (this, other) = try makeDivergedCopies()
        let before = try snapshot(of: [this, other])
        let model = LibraryComparisonModel(
            otherFolder: other,
            thisFolder: this,
            thisLibrary: try LibraryPersistenceService.decodeIndex(from: Data(contentsOf: this.appendingPathComponent("library.json"))),
            reader: reader()
        )

        model.start()
        for _ in 0..<200 where model.phase == .comparing {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(model.phase, .finished)
        XCTAssertEqual(model.heading, "5 differences between this library and the copy in \(other.path).")
        XCTAssertEqual(model.rows.count, 5)
        XCTAssertTrue(model.copyableText.hasPrefix("5 differences between this library and the copy in "))
        XCTAssertEqual(try snapshot(of: [this, other]), before)
    }

    /// A drive that never answers is not asked again for a file whose last
    /// fetch has not returned: the second comparison lists it as unread at once
    /// and starts no new fetch, so stuck reads never pile up.
    func testAFileWhoseLastFetchHasNotReturnedIsNotFetchedAgain() throws {
        let (this, other) = try makeDivergedCopies()
        let cloud = FakeCloud(onlyInCloud: ["bookInfo.json"])
        let release = DispatchSemaphore(value: 0)
        addTeardownBlock { for _ in 0..<16 { release.signal() } }
        let calls = OSAllocatedUnfairLock<Int>(initialState: 0)
        let reader = LibraryCopyReader(
            itemStatus: cloud,
            fetch: { _ in calls.withLock { $0 += 1 }; _ = release.wait(timeout: .now() + 30) },
            waitLimit: 1,
            fetchGuard: FetchGuard()
        )

        _ = reader.compare(thisFolder: this, otherFolder: other)
        let first = calls.withLock { $0 }
        let started = Date()
        let outcome = reader.compare(thisFolder: this, otherFolder: other)

        guard case .compared(let comparison) = outcome else { return XCTFail("compared: \(outcome)") }
        XCTAssertEqual(first, 3, "each stuck record was asked for once")
        XCTAssertEqual(calls.withLock { $0 }, 3, "none was asked for again")
        XCTAssertEqual(comparison.unread.count, 3)
        XCTAssertTrue(comparison.unread.allSatisfy { $0.reason == .stillBeingFetched }, "\(comparison.unread)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9, "listed at once, with no wait")
    }

    /// No more fetches are out at once than the guard allows, however many
    /// files are only in the cloud.
    func testNoMoreFetchesAreOutThanTheGuardAllows() {
        let guardOfTwo = FetchGuard(limit: 2)

        XCTAssertTrue(guardOfTwo.begin("/a"))
        XCTAssertFalse(guardOfTwo.begin("/a"), "its last fetch is still out")
        XCTAssertTrue(guardOfTwo.begin("/b"))
        XCTAssertFalse(guardOfTwo.begin("/c"), "two are out")
        guardOfTwo.end("/a")
        XCTAssertTrue(guardOfTwo.begin("/c"))
    }

    /// A comparison that goes on says so every interval, and stops saying so
    /// once it ends.
    @MainActor
    func testALongComparisonSaysItIsStillGoing() async throws {
        let (this, other) = try makeDivergedCopies()
        let release = DispatchSemaphore(value: 0)
        addTeardownBlock { for _ in 0..<8 { release.signal() } }
        let reader = LibraryCopyReader(
            itemStatus: FakeCloud(onlyInCloud: ["bookInfo.json"]),
            fetch: { _ in _ = release.wait(timeout: .now() + 30) },
            waitLimit: 2,
            fetchGuard: FetchGuard()
        )
        var said: [String] = []
        let model = LibraryComparisonModel(
            otherFolder: other,
            thisFolder: this,
            thisLibrary: try LibraryPersistenceService.decodeIndex(from: Data(contentsOf: this.appendingPathComponent("library.json"))),
            reader: reader,
            progressInterval: .milliseconds(300),
            announce: { said.append($0) }
        )

        model.start()
        for _ in 0..<200 where model.phase == .comparing {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let progress = said.filter { $0.hasPrefix("Still comparing") }

        XCTAssertGreaterThanOrEqual(progress.count, 2, "\(said)")
        XCTAssertEqual(said.last, model.heading, "the count is the last thing said")
        XCTAssertFalse(model.unreadRows.isEmpty, "the files not read are a list of their own")
        XCTAssertTrue(model.rows.allSatisfy { !$0.sentence.hasPrefix("Unread") })
    }

    /// A fetch the sync service fails is unread with its reason, never
    /// missing.
    func testAFileTheDriveFailsToBringIsUnreadWithItsReason() throws {
        let (this, other) = try makeDivergedCopies()
        let cloud = FakeCloud(onlyInCloud: ["library.json"])
        let reader = LibraryCopyReader(itemStatus: cloud, fetch: { _ in throw CocoaError(.fileReadNoPermission) })

        let outcome = reader.compare(thisFolder: this, otherFolder: other)

        guard case .notComparable(let unread) = outcome else { return XCTFail("compared: \(outcome)") }
        XCTAssertEqual(Set(unread.map(\.side)), [.thisCopy, .otherCopy])
        XCTAssertTrue(unread.allSatisfy { if case .cannotBeRead = $0.reason { return true } else { return false } })
    }

    /// Stopping a comparison while it reads ends it as stopped, whatever it
    /// had read, and changes nothing.
    func testStoppingWhileReadingEndsTheComparisonAsStopped() throws {
        let (this, other) = try makeDivergedCopies()
        let before = try snapshot(of: [this, other])
        let asked = OSAllocatedUnfairLock<Int>(initialState: 0)

        // True from the third question on: after the identities, during the reading.
        let outcome = reader().compare(thisFolder: this, otherFolder: other, isCancelled: { asked.withLock { $0 += 1; return $0 > 2 } })

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(try snapshot(of: [this, other]), before)
    }

    /// Stopping the comparison before it starts reads nothing.
    func testACancelledComparisonSaysSo() throws {
        let (this, other) = try makeDivergedCopies()

        XCTAssertEqual(reader().compare(thisFolder: this, otherFolder: other, isCancelled: { true }), .cancelled)
    }

    // MARK: - Fixtures

    /// A reader over local folders.
    private func reader() -> LibraryCopyReader {
        LibraryCopyReader(itemStatus: LocalItemStatusProvider(), fetch: { _ in })
    }

    /// The library's identity both fixture copies share.
    private let sharedIdentity = LibraryIdentity(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, created: Date(timeIntervalSince1970: 1_790_000_000))

    /// A fixed ID for Moby-Dick, which both copies hold.
    private let mobyID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    /// Moby-Dick, 1,000 characters long, with `position`.
    private func movedBook(_ title: String, at position: ReadingPosition, bookmarks: [Bookmark] = []) -> Book {
        Book(
            id: title == "Moby-Dick" ? mobyID : UUID(),
            title: title,
            format: .txt,
            filePath: "/\(title).txt",
            md5Hash: title,
            readingPosition: position,
            bookmarks: bookmarks,
            totalCharacterCount: 1_000,
            tmbDirectoryName: "\(title).tmb"
        )
    }

    /// A place in `chapter` (from 0) at `offset`, saved `seconds` after the
    /// start of the epoch.
    private func place(chapter: Int, offset: Int, at seconds: TimeInterval) -> ReadingPosition {
        var position = ReadingPosition(chapterIndex: chapter, characterOffset: offset, globalCharacterOffset: offset)
        position.lastUpdated = Date(timeIntervalSince1970: seconds)
        return position
    }

    /// Two copies of one small library that differ in each way the command
    /// lists: this copy holds a newer place in Moby-Dick; the other holds a
    /// bookmark this lacks, a book (Emma) this lacks, that book on its
    /// reading list, and a folder this lacks. Returns their folders.
    private func makeDivergedCopies() throws -> (this: URL, other: URL) {
        let moby = movedBook("Moby-Dick", at: place(chapter: 2, offset: 410, at: 2_000))
        var mobyThere = movedBook("Moby-Dick", at: place(chapter: 1, offset: 200, at: 1_000))
        mobyThere.bookmarks = [Bookmark(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!, number: 2, chapterIndex: 1, characterOffset: 5, label: "Across the water")]
        let emma = movedBook("Emma", at: place(chapter: 0, offset: 0, at: 500))
        let this = try writeCopy("This", identity: sharedIdentity, books: [moby])
        let other = try writeCopy(
            "Other",
            identity: sharedIdentity,
            books: [mobyThere, emma],
            folders: [BookFolder(name: "Sea")],
            readingList: ReadingList(bookIDs: [emma.id])
        )
        return (this, other)
    }

    /// Writes a copy of a library into a new sandbox folder: its identity
    /// marker (unless nil), library.json, and each book's package with its
    /// record, as the app writes them. Returns the folder.
    private func writeCopy(
        _ label: String,
        identity: LibraryIdentity?,
        books: [Book],
        folders: [BookFolder] = [],
        readingList: ReadingList = ReadingList()
    ) throws -> URL {
        let root = try makeSandboxDirectory(label)
        if let identity {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(identity).write(to: LibraryIdentity.markerURL(in: root))
        }
        let library = Library(books: books, folders: folders, readingList: readingList)
        try LibraryPersistenceService.encodedIndex(library).write(to: root.appendingPathComponent("library.json"))
        for book in books {
            let package = book.packageDirectory(inDataDirectory: root)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try book.saveBookInfoThrowing(inPackageAt: package)
        }
        return root
    }

    /// The bookInfo.json of the package of the book titled `title` in the
    /// copy at `root`.
    private func bookInfoFile(named title: String, in root: URL) throws -> URL {
        TextMouthPaths.bookInfoPath(in: root.appendingPathComponent("Library").appendingPathComponent("\(title).tmb"))
    }

    /// What a snapshot holds of one item: whether it is a folder, its bytes,
    /// and its modification date.
    private struct Item: Equatable {
        var isFolder: Bool
        var bytes: Data?
        var modified: Date?
    }

    /// Every item under `folders`, by path: its kind, every file's bytes, and
    /// every item's modification date.
    private func snapshot(of folders: [URL]) throws -> [String: Item] {
        var items: [String: Item] = [:]
        for folder in folders {
            let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
            let walk = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: []))
            for case let url as URL in walk {
                let values = try url.resourceValues(forKeys: Set(keys))
                let isFolder = values.isDirectory ?? false
                items[url.path] = Item(isFolder: isFolder, bytes: isFolder ? nil : try Data(contentsOf: url), modified: values.contentModificationDate)
            }
        }
        return items
    }
}

// MARK: - A Stand-In for a Cloud Drive

/// A sync service whose folders are cloud folders and whose files named in
/// `onlyInCloud` are only in the cloud, as far as the comparison asks. Any
/// request to download or remove is noted, since the comparison must never
/// make one.
private struct FakeCloud: CloudItemStatusProviding {
    /// The file names the service says are only in the cloud.
    let onlyInCloud: Set<String>
    /// Every download or removal asked of the service.
    let requests = OSAllocatedUnfairLock<[String]>(initialState: [])

    func location(of folder: URL) -> StorageLocation {
        .cloud(.googleDrive)
    }

    func status(of file: URL) -> CloudItemStatus {
        CloudItemStatus(
            state: onlyInCloud.contains(file.lastPathComponent) ? .notDownloaded : .downloaded,
            isUploaded: true,
            byteCount: 1,
            hasUnresolvedConflicts: false,
            downloadError: nil
        )
    }

    func requestDownload(of file: URL) throws {
        requests.withLock { $0.append("download \(file.lastPathComponent)") }
    }

    func removeLocalCopy(of file: URL) throws {
        requests.withLock { $0.append("remove \(file.lastPathComponent)") }
    }
}
