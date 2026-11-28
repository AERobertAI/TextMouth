import XCTest
import os
@testable import TextMouth

/// A cloud drive's conflict copies of the library's files, reported once
/// (Phase 0 of the local-first design): the names each drive gives them, what
/// the report says each holds, that it is remembered on this Mac, and that
/// finding them changes nothing. No real drive: a stand-in says which files
/// are in conflict or not yet on this Mac.
final class ConflictCopyTests: XCTestCase {

    // MARK: - Names

    /// The conflict copy names of each drive are told from the library's own
    /// files.
    func testEachDrivesConflictCopyNamesAreRecognized() {
        let copies = [
            "library 2.json", "library 3.json",                                  // iCloud Drive
            "library (1).json", "library (2).json",                              // Google Drive
            "library (Galley's conflicted copy 2026-10-03).json",                // Dropbox
            "library (Galley's conflicted copy 2026-10-03) (1).json",
            "library (Case Conflict).json", "library (Case Conflict 1).json",
        ]
        for name in copies {
            XCTAssertTrue(ConflictCopyNames.isConflictCopy(name, of: "library.json"), name)
        }
        let others = [
            "library.json", "library-identity.json", "library.json.unreadable-2026-11-14", "library backup.json",
            "library 2.txt", "libraries 2.json", "library (draft).json", ".library 2.json", "library.json 2",
        ]
        for name in others {
            XCTAssertFalse(ConflictCopyNames.isConflictCopy(name, of: "library.json"), name)
        }
        XCTAssertTrue(ConflictCopyNames.isConflictCopy("bookInfo 2.json", of: "bookInfo.json"))
        XCTAssertFalse(ConflictCopyNames.isConflictCopy("contentIndex 2.json", of: "bookInfo.json"))
    }

    // MARK: - Finding Them

    /// A library in a cloud drive's folder with a conflict copy of its index,
    /// a feed's record, and a book's record has each reported, with what it
    /// holds, where it is, and that nothing was merged or removed.
    func testConflictCopiesOfTheIndexAFeedAndABookAreFound() throws {
        let library = try makeLibrary()
        let drive = FakeDrive()

        let findings = ConflictCopyFinder(itemStatus: drive).findAll(in: library.root)

        XCTAssertEqual(findings.map(\.subject), [.libraryIndex, .feedRecord, .bookRecord])
        XCTAssertEqual(
            findings[0].sentence,
            "Google Drive set aside a conflicting copy of the library index, library.json: “library (1).json”, in "
                + "\(library.root.path). It holds 1 book, 0 folders, and 0 books on the reading list; library.json holds "
                + "2 books, 0 folders, and 0 books on the reading list. TextMouth hasn't merged it or removed it."
        )
        XCTAssertEqual(
            findings[1].sentence,
            "Google Drive set aside a conflicting copy of a feed's record, \(library.feedID.uuidString).json: "
                + "“\(library.feedID.uuidString) 2.json”, in "
                + "\(library.root.path)/Feeds. It holds the feed “Copy Cast” with 0 items; the record holds 0 items. "
                + "TextMouth hasn't merged it or removed it."
        )
        XCTAssertTrue(findings[2].sentence.hasPrefix("Google Drive set aside a conflicting copy of a book's record, bookInfo.json: "
            + "“bookInfo (1).json”, in \(library.mobyPackage.path). It holds the record of “Moby-Dick”: chapter 4, saved "))
        XCTAssertTrue(findings[2].sentence.hasSuffix(", and 1 bookmark; the record holds chapter 1, saved "
            + "\(Date(timeIntervalSince1970: 1_000).formatted(date: .abbreviated, time: .shortened)), and 0 bookmarks. "
            + "TextMouth hasn't merged it or removed it."), findings[2].sentence)
        XCTAssertEqual(findings[0].folderPath, library.root.path)
    }

    /// A feed's own index, Feeds/<feed ID>/library.json, is searched too, and
    /// a copy of it is reported with what it holds.
    func testConflictCopiesOfAFeedsOwnIndexAreFound() throws {
        let library = try makeLibrary(withConflictFiles: false)
        let folder = FeedPaths.itemsFolder(of: library.feedID, in: library.root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let episode = Book(title: "Episode 1", format: .txt, filePath: "/e.mp3", md5Hash: "e", tmbDirectoryName: "e.tmb")
        // A real feed index: its feed ID and rows, and no folders.
        let feedID = library.feedID
        try FeedIndexFiles.encoded(FeedIndex(feedID: feedID, books: [episode])).write(to: folder.appendingPathComponent("library.json"))
        try FeedIndexFiles.encoded(FeedIndex(feedID: feedID, books: [])).write(to: folder.appendingPathComponent("library (1).json"))

        let findings = ConflictCopyFinder(itemStatus: FakeDrive()).findAll(in: library.root)

        XCTAssertEqual(findings.map(\.subject), [.feedIndex])
        XCTAssertTrue(findings[0].sentence.hasPrefix("Google Drive set aside a conflicting copy of a feed's index of its episodes, library.json: “library (1).json”"))
        XCTAssertTrue(findings[0].sentence.contains("It holds 0 episodes; the index holds 1 episode."), findings[0].sentence)
    }

    /// iCloud Drive syncs a book's package as one item, so a conflict sits on
    /// the package, not on the record inside it: asked of the package too.
    func testICloudsConflictOnABooksPackageIsReported() throws {
        let library = try makeLibrary(withConflictFiles: false)
        let drive = FakeDrive(provider: .iCloudDrive, conflicted: ["Moby-Dick.tmb"])
        let saved = Date(timeIntervalSince1970: 1_790_000_000)
        let finder = ConflictCopyFinder(itemStatus: drive, versions: { file in
            file.lastPathComponent == "Moby-Dick.tmb" ? [ConflictVersion(computerName: "Study iMac", modified: saved)] : []
        })

        let findings = finder.findAll(in: library.root)

        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings[0].sentence.hasPrefix("iCloud Drive holds a conflicting version of a book's record, Moby-Dick.tmb, saved on “Study iMac”"), findings[0].sentence)
    }

    /// A library that is not in a cloud location has none found, though a
    /// file is named like a conflict copy.
    func testALocalLibraryHasNoConflictCopiesReported() throws {
        let library = try makeLibrary()

        let findings = ConflictCopyFinder(itemStatus: LocalItemStatusProvider()).findAll(in: library.root)

        XCTAssertEqual(findings, [])
    }

    /// A copy not on this Mac yet is reported without being opened, never
    /// downloaded.
    func testACopyNotOnThisMacIsReportedWithoutLookingInside() throws {
        let library = try makeLibrary()
        let drive = FakeDrive(notOnThisMac: ["library (1).json"])

        let findings = ConflictCopyFinder(itemStatus: drive).findAll(in: library.root)

        XCTAssertTrue(findings[0].sentence.contains("Its contents aren't on this Mac yet, so TextMouth hasn't looked inside it."))
        XCTAssertEqual(drive.reads.withLock { $0 }, [], "nothing was fetched")
    }

    /// iCloud Drive's unresolved versions of a file are reported, with the
    /// Mac that saved each and when, beside the copies that are files.
    func testICloudsUnresolvedVersionsAreReported() throws {
        let library = try makeLibrary(withConflictFiles: false)
        let drive = FakeDrive(provider: .iCloudDrive, conflicted: ["library.json"])
        let saved = Date(timeIntervalSince1970: 1_790_000_000)
        let finder = ConflictCopyFinder(itemStatus: drive, versions: { file in
            file.lastPathComponent == "library.json"
                ? [ConflictVersion(computerName: "Study iMac", modified: saved)]
                : []
        })

        let findings = finder.findAll(in: library.root)

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(
            findings[0].sentence,
            "iCloud Drive holds a conflicting version of the library index, library.json, saved on “Study iMac” on "
                + "\(saved.formatted(date: .abbreviated, time: .shortened)). TextMouth hasn't merged it or removed it."
        )
    }

    /// Finding the copies changes no byte, no date, and no name in the
    /// library.
    func testFindingConflictCopiesChangesNothing() throws {
        let library = try makeLibrary()
        let before = try snapshot(of: library.root)

        _ = ConflictCopyFinder(itemStatus: FakeDrive()).findAll(in: library.root)

        XCTAssertEqual(try snapshot(of: library.root), before)
    }

    // MARK: - Once

    /// A copy is reported once: remembered on this Mac, across launches, and
    /// a later conflict copy of the same name, saved at another time, is a new
    /// one.
    func testEachCopyIsReportedOnceAndAnotherWithTheSameNameIsNew() throws {
        let library = try makeLibrary(withConflictFiles: false)
        let memory = ConflictCopyMemory(file: try makeSandboxDirectory("Memory").appendingPathComponent("Reported.json"))
        let copy = library.root.appendingPathComponent("library (1).json")
        try Data("{}".utf8).write(to: copy)
        try setModified(1_790_000_000, of: copy)
        let finder = ConflictCopyFinder(itemStatus: FakeDrive())

        let first = memory.unreported(finder.findAll(in: library.root))
        memory.remember(first)
        let again = ConflictCopyMemory(file: memory.file).unreported(finder.findAll(in: library.root))
        try setModified(1_790_100_000, of: copy)
        let later = memory.unreported(finder.findAll(in: library.root))

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(again, [], "reported once, remembered by a later launch")
        XCTAssertEqual(later.count, 1, "a conflict copy saved later is a new one")
    }

    /// The memory keeps only the newest keys, so it never grows without end.
    func testTheMemoryKeepsOnlyTheNewestKeys() throws {
        let memory = ConflictCopyMemory(file: try makeSandboxDirectory("Limit").appendingPathComponent("Reported.json"))
        let findings = (0..<(ConflictCopyMemory.limit + 20)).map {
            ConflictCopyFinding(subject: .libraryIndex, place: .file(path: "/x/\($0)"), sentence: "", key: "key \($0)")
        }

        memory.remember(findings)

        XCTAssertEqual(memory.reportedKeys().count, ConflictCopyMemory.limit)
        XCTAssertEqual(memory.reportedKeys().last, "key \(ConflictCopyMemory.limit + 19)")
    }

    /// The library's launch reports new copies once through the report it
    /// is given, and a second look reports nothing.
    @MainActor
    func testTheLibraryReportsNewCopiesOnceAtLaunch() async throws {
        // The data directory in use is the test sandbox's; a conflict copy
        // of its index is put there, and taken away when the test ends.
        try TextMouthPaths.ensureDirectoryStructure()
        let copy = TextMouthPaths.root.appendingPathComponent("library (1).json")
        try Data("{}".utf8).write(to: copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        let memory = ConflictCopyMemory(file: try makeSandboxDirectory("LaunchMemory").appendingPathComponent("Reported.json"))
        let model = LibraryViewModel(initializeServices: false)
        let reports = OSAllocatedUnfairLock<[[ConflictCopyFinding]]>(initialState: [])
        let first = expectation(description: "reported once")
        let present: @MainActor ([ConflictCopyFinding]) -> Void = { findings in
            reports.withLock { $0.append(findings) }
            first.fulfill()
        }

        model.reportConflictCopiesInBackground(finder: ConflictCopyFinder(itemStatus: FakeDrive()), memory: memory, present: present)
        await fulfillment(of: [first], timeout: 10)
        // The report is remembered just after it shows.
        try await Task.sleep(nanoseconds: 500_000_000)
        model.reportConflictCopiesInBackground(finder: ConflictCopyFinder(itemStatus: FakeDrive()), memory: memory, present: present)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(reports.withLock { $0 }.count, 1, "the second look reports nothing new")
        XCTAssertEqual(reports.withLock { $0 }.first?.map(\.subject), [.libraryIndex])
    }

    /// A report is remembered only after it was shown: while the library is
    /// unavailable nothing is shown and nothing is remembered, so the next look
    /// reports the copy.
    @MainActor
    func testAReportIsRememberedOnlyAfterItIsShown() async throws {
        let memory = ConflictCopyMemory(file: try makeSandboxDirectory("AfterShown").appendingPathComponent("Reported.json"))
        let finding = ConflictCopyFinding(subject: .libraryIndex, place: .file(path: "/x/library 2.json"), sentence: "A copy.", key: "k")
        let keysWhenShown = OSAllocatedUnfairLock<[String]?>(initialState: nil)

        await LibraryViewModel.reportAndRemember([finding], libraryIsAvailable: false, memory: memory, present: { _ in
            XCTFail("nothing is shown while the library is unavailable")
        })
        XCTAssertEqual(memory.reportedKeys(), [], "not shown, so not remembered")

        await LibraryViewModel.reportAndRemember([finding], libraryIsAvailable: true, memory: memory, present: { _ in
            keysWhenShown.withLock { $0 = memory.reportedKeys() }
        })
        XCTAssertEqual(keysWhenShown.withLock { $0 }, [], "not yet remembered as it is shown")
        XCTAssertEqual(memory.reportedKeys(), ["k"], "remembered once shown")
    }

    // MARK: - The Alert's Words

    /// The alert names its title, and lists at most five copies, saying how
    /// many more there are.
    func testTheAlertListsAFewAndCountsTheRest() {
        let findings = (1...7).map {
            ConflictCopyFinding(subject: .bookRecord, place: .file(path: "/x/\($0)"), sentence: "Copy \($0).", key: "\($0)")
        }

        let message = ConflictCopyWording.message(for: findings)

        XCTAssertEqual(ConflictCopyWording.alertTitle, "Conflicting Copies Found")
        XCTAssertEqual(
            message,
            "Copy 1.\n\nCopy 2.\n\nCopy 3.\n\nCopy 4.\n\nCopy 5.\n\nAnd 2 more copies, which the log lists."
        )
    }

    // MARK: - Fixtures

    /// A library folder holding what the fixtures need.
    private struct LibraryFixture {
        var root: URL
        var feedID: UUID
        var mobyPackage: URL
    }

    /// A library in a sandbox folder: an index of two books with a conflict
    /// copy of one book, a feed's record and its conflict copy, and a book's
    /// record in a package in a folder with its conflict copy. Without
    /// `withConflictFiles` the files are the library's own alone.
    private func makeLibrary(withConflictFiles: Bool = true) throws -> LibraryFixture {
        let root = try makeSandboxDirectory("ConflictLibrary")
        let moby = Book(
            title: "Moby-Dick", format: .txt, filePath: "/Moby.txt", md5Hash: "m",
            folderPath: "Sea", readingPosition: place(chapter: 0, at: 1_000), totalCharacterCount: 1_000, tmbDirectoryName: "Moby-Dick.tmb"
        )
        let emma = Book(title: "Emma", format: .txt, filePath: "/Emma.txt", md5Hash: "e", tmbDirectoryName: "Emma.tmb")
        let index = try LibraryPersistenceService.encodedIndex(Library(books: [moby, emma]))
        try index.write(to: root.appendingPathComponent("library.json"))
        let package = moby.packageDirectory(inDataDirectory: root)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try moby.saveBookInfoThrowing(inPackageAt: package)
        let feedID = UUID()
        let feeds = FeedPaths.recordsFolder(in: root)
        try FileManager.default.createDirectory(at: feeds, withIntermediateDirectories: true)
        var feed = Feed(id: feedID, feedURL: URL(string: "https://example.com/feed.xml")!, folderID: UUID(), subscribedDate: Date(timeIntervalSince1970: 1_000))
        feed.title = "Original Cast"
        let record = FeedRecord(feed: feed)
        try FeedRecordCoding.encoder().encode(record).write(to: FeedPaths.recordFile(of: feedID, in: feeds))
        guard withConflictFiles else { return LibraryFixture(root: root, feedID: feedID, mobyPackage: package) }

        let one = Library(books: [moby])
        try LibraryPersistenceService.encodedIndex(one).write(to: root.appendingPathComponent("library (1).json"))
        var copyRecord = record
        copyRecord.feed.title = "Copy Cast"
        try FeedRecordCoding.encoder().encode(copyRecord).write(to: feeds.appendingPathComponent("\(feedID.uuidString) 2.json"))
        var moved = moby
        moved.readingPosition = place(chapter: 3, at: 2_000)
        moved.bookmarks = [Bookmark(number: 1, chapterIndex: 3, characterOffset: 4)]
        let copyPackage = try makeSandboxDirectory("CopyPackage")
        try moved.saveBookInfoThrowing(inPackageAt: copyPackage)
        try Data(contentsOf: TextMouthPaths.bookInfoPath(in: copyPackage)).write(to: package.appendingPathComponent("bookInfo (1).json"))
        return LibraryFixture(root: root, feedID: feedID, mobyPackage: package)
    }

    /// A place in `chapter` (from 0), saved `seconds` after the epoch began.
    private func place(chapter: Int, at seconds: TimeInterval) -> ReadingPosition {
        var position = ReadingPosition(chapterIndex: chapter, characterOffset: 10, globalCharacterOffset: 10)
        position.lastUpdated = Date(timeIntervalSince1970: seconds)
        return position
    }

    /// Sets the modification date of `file`.
    private func setModified(_ seconds: TimeInterval, of file: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: file.path)
    }

    /// Every item under `folder`: its bytes and modification date.
    private func snapshot(of folder: URL) throws -> [String: [AnyHashable]] {
        var items: [String: [AnyHashable]] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let walk = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: []))
        for case let url as URL in walk {
            let values = try url.resourceValues(forKeys: Set(keys))
            let isFolder = values.isDirectory ?? false
            items[url.path] = [isFolder, isFolder ? Data() : try Data(contentsOf: url), values.contentModificationDate ?? Date(timeIntervalSince1970: 0)]
        }
        return items
    }
}

// MARK: - A Stand-In for a Cloud Drive

/// A sync service whose folders are in `provider`'s drive, whose files named
/// in `conflicted` carry unresolved conflicts and whose files named in
/// `notOnThisMac` are only in the cloud. Asking it to download or remove
/// anything is noted, since finding a copy must never do either.
private struct FakeDrive: CloudItemStatusProviding {
    var provider: CloudProvider = .googleDrive
    var conflicted: Set<String> = []
    var notOnThisMac: Set<String> = []
    /// Every download or removal asked of the drive.
    let reads = OSAllocatedUnfairLock<[String]>(initialState: [])

    func location(of folder: URL) -> StorageLocation {
        .cloud(provider)
    }

    func status(of file: URL) -> CloudItemStatus {
        CloudItemStatus(
            state: notOnThisMac.contains(file.lastPathComponent) ? .notDownloaded : .downloaded,
            isUploaded: true,
            byteCount: 1,
            hasUnresolvedConflicts: conflicted.contains(file.lastPathComponent),
            downloadError: nil
        )
    }

    func requestDownload(of file: URL) throws {
        reads.withLock { $0.append("download \(file.lastPathComponent)") }
    }

    func removeLocalCopy(of file: URL) throws {
        reads.withLock { $0.append("remove \(file.lastPathComponent)") }
    }
}
