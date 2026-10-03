import XCTest
import os
@testable import TextMouth

/// How maintenance reaches a cloud library's files (FR02,
/// `MaintenanceFileAccess`): reads with dataless files left in the cloud,
/// refusals tests can script, a presence check that never answers "absent"
/// when only the cloud knows, the files of a book a pass reads, the one
/// line that counts the books a pass left in the cloud, and the library's
/// saves of package records, which leave a record in the cloud alone.
final class CloudMaintenanceAccessTests: CloudMaintenanceTestCase {

    // MARK: - Reading

    /// A read through the access runs with dataless files left in the
    /// cloud, and the thread's policy is back as it was afterwards.
    func testReadRunsWithDownloadsOff() throws {
        let book = try makePackagedBook()
        let policyBefore = currentPolicy()

        let policyDuringRead = try MaintenanceFileAccess.live.read(book.bookFileURL) { currentPolicy() }

        XCTAssertEqual(policyDuringRead, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        XCTAssertEqual(currentPolicy(), policyBefore)
    }

    /// The live access reads a file on this Mac and calls it no dataless
    /// file; its hasher gives the digest `FingerprintHasher.md5` gives.
    func testLiveAccessReadsFilesOnThisMac() throws {
        let book = try makePackagedBook()
        let access = MaintenanceFileAccess.live

        let text = try access.read(book.bookFileURL) { try String(contentsOf: book.bookFileURL, encoding: .utf8) }

        XCTAssertEqual(text, "# Opening\n\nSome words.")
        XCTAssertFalse(access.isDataless(book.bookFileURL))
        XCTAssertEqual(try access.hasher.digestOfFile(book.bookFileURL), try FingerprintHasher.md5.digestOfFile(book.bookFileURL))
    }

    /// A refused read throws the refusal a dataless file meets, before the
    /// read starts, and reaches the access's digests too.
    func testRefusedReadThrowsADownloadRefusalBeforeReading() throws {
        let book = try makePackagedBook()
        cloud.refuseReads(of: book.bookFileURL)
        let access = cloud.access
        var bodyRan = false

        XCTAssertThrowsError(try access.read(book.bookFileURL) { bodyRan = true }) { error in
            XCTAssertTrue(DatalessFiles.isDownloadRefusal(error), "\(error)")
        }
        XCTAssertThrowsError(try access.hasher.digestOfFile(book.bookFileURL)) { error in
            XCTAssertTrue(DatalessFiles.isDownloadRefusal(error), "\(error)")
        }
        XCTAssertFalse(bodyRan)
    }

    // MARK: - Presence

    /// What is there is present, dataless or not; what is missing is absent;
    /// and what is missing from a folder only the cloud can list is in the
    /// cloud, never absent.
    func testPresenceNeverCallsMissingWhatOnlyTheCloudKnows() throws {
        let book = try makePackagedBook()
        let shelf = folderURL.appendingPathComponent("Shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        cloud.markDataless(book.bookFileURL, shelf)
        let access = cloud.access

        XCTAssertEqual(access.presence(of: book.bookFileURL), .present)
        XCTAssertEqual(access.presence(of: folderURL.appendingPathComponent("Missing.md")), .absent)
        XCTAssertEqual(access.presence(of: shelf.appendingPathComponent("Unlisted.tmb/source.md")), .inCloud)
        XCTAssertTrue(access.isInCloud(book.bookFileURL))
        XCTAssertTrue(access.isInCloud(shelf.appendingPathComponent("Unlisted.tmb")))
        XCTAssertFalse(access.isInCloud(folderURL.appendingPathComponent("Missing.md")))
    }

    /// A missing item whose nearest folders are missing too, below a folder
    /// only the cloud can list, is in the cloud however many levels up that
    /// folder is.
    func testPresenceFindsAFolderInTheCloudSeveralLevelsUp() throws {
        let shelf = folderURL.appendingPathComponent("Shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        cloud.markDataless(shelf)

        let deep = shelf.appendingPathComponent("Unlisted.tmb/Deeper/removedFromLibrary.json")

        XCTAssertEqual(cloud.access.presence(of: deep), .inCloud)
    }

    /// A file missing from a package that is there, as a removal marker
    /// almost always is, is absent after one question about the package
    /// (PERF13): a folder found with downloads off lies in no dataless
    /// folder, so the folders above it are not asked about.
    func testPresenceStopsAtThePackageAroundAMissingFile() throws {
        let book = try makePackagedBook()
        let asked = AskedItems()
        let access = MaintenanceFileAccess(isDataless: { url in
            asked.note(url)
            return false
        })

        let marker = TextMouthPaths.removedFromLibraryMarkerPath(in: book.tmbDirectory)

        XCTAssertEqual(access.presence(of: marker), .absent)
        XCTAssertEqual(asked.paths, [FakeCloudFiles.key(book.tmbDirectory)])
    }

    // MARK: - The Files a Pass Reads

    /// Each file a pass reads is found in the cloud: the package, the
    /// record and the content index beside it, the text cache, and the
    /// source; a pass that does not read the text cache does not care where
    /// it is.
    func testFileInCloudFindsEachFileAPassReads() throws {
        let book = try commitCache(of: makePackagedBook())
        let record = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
        let contentIndex = TextMouthPaths.contentIndexPath(in: book.tmbDirectory)
        let cache = MarkdownCacheService.cacheURL(for: book)
        let rereadingSources: MaintainedFiles = [.content, .record]

        XCTAssertNil(cloud.access.fileInCloud(of: book, reading: .all))

        let cacheCloud = FakeCloudFiles()
        cacheCloud.markDataless(cache)
        assertSameItem(cacheCloud.access.fileInCloud(of: book, reading: .all), cache)
        XCTAssertNil(cacheCloud.access.fileInCloud(of: book, reading: rereadingSources))

        for file in [record, contentIndex, book.bookFileURL, book.tmbDirectory] {
            let fileCloud = FakeCloudFiles()
            fileCloud.markDataless(file)
            assertSameItem(fileCloud.access.fileInCloud(of: book, reading: rereadingSources), file)
        }
    }

    /// Every track of an audiobook kept as a folder counts as its content,
    /// while hidden items and the text-to-speech cache never do.
    func testFileInCloudLooksInsideFoldersOfContentOnly() throws {
        let packageName = "Tracks-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: packageName)
        let tracks = package.appendingPathComponent("audio", isDirectory: true)
        let spoken = TextMouthPaths.cachedAudioDir(in: package)
        for folder in [tracks, spoken] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for file in [tracks.appendingPathComponent("01.mp3"), tracks.appendingPathComponent("02.mp3"),
                     spoken.appendingPathComponent("chapter.caf"), package.appendingPathComponent(".DS_Store")] {
            try Data("bytes".utf8).write(to: file)
        }
        let book = Book(
            title: "Tracks",
            format: .audio,
            filePath: tracks.path,
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            tmbDirectoryName: packageName
        )

        let ignored = FakeCloudFiles()
        ignored.markDataless(spoken.appendingPathComponent("chapter.caf"), package.appendingPathComponent(".DS_Store"))
        XCTAssertNil(ignored.access.fileInCloud(of: book, reading: .all))

        let track = FakeCloudFiles()
        track.markDataless(tracks.appendingPathComponent("02.mp3"))
        assertSameItem(track.access.fileInCloud(of: book, reading: .content), tracks.appendingPathComponent("02.mp3"))
    }

    /// A package whose listing is refused is in the cloud: nothing of it
    /// can be examined without downloading.
    func testPackageThatCannotBeListedIsInTheCloud() throws {
        let book = try makePackagedBook()
        cloud.refuseReads(of: book.tmbDirectory)

        assertSameItem(cloud.access.fileInCloud(of: book, reading: .content), book.tmbDirectory)
        XCTAssertThrowsError(try cloud.access.requireOnThisMac(book, reading: .content)) { error in
            XCTAssertTrue(DatalessFiles.isDownloadRefusal(error), "\(error)")
        }
    }

    /// A book without a package has only its own file to read.
    func testBookWithoutAPackageHasOnlyItsFile() throws {
        let original = folderURL.appendingPathComponent("Loose.txt")
        try "Loose words.".write(to: original, atomically: true, encoding: .utf8)
        let loose = Book(title: "Loose", format: .txt, filePath: original.path, md5Hash: UUID().uuidString)

        XCTAssertNil(cloud.access.fileInCloud(of: loose, reading: .all))
        cloud.markDataless(original)
        assertSameItem(cloud.access.fileInCloud(of: loose, reading: .all), original)
        XCTAssertNil(cloud.access.fileInCloud(of: loose, reading: [.record, .textCache]))
    }

    // MARK: - The Skip Line

    /// A pass that left no book writes nothing; one that did writes one
    /// line counting each book once, in words that agree with the count.
    func testSkipLineCountsEachBookOnceAndOnlyWhenOneWasLeft() throws {
        let first = try makePackagedBook(title: "First")
        let second = try makePackagedBook(title: "Second")
        let package = folderURL.appendingPathComponent("Orphan.tmb", isDirectory: true)
        let anyStatisticsLine = "MAINTENANCE_SKIPPED_IN_CLOUD: \(MaintenancePass.statistics.rawValue): "
        let threeBooks = "MAINTENANCE_SKIPPED_IN_CLOUD: statistics: skipped 3 books whose files are not on this Mac"
        let oneBook = "MAINTENANCE_SKIPPED_IN_CLOUD: startup repair: skipped 1 book whose files are not on this Mac"
        let anyBefore = logLineCount(anyStatisticsLine)
        let threeBefore = logLineCount(threeBooks)
        let oneBefore = logLineCount(oneBook)

        CloudSkips(.statistics).log()
        XCTAssertEqual(logLineCount(anyStatisticsLine), anyBefore, "a pass that left nothing wrote a line")

        let skips = CloudSkips(.statistics)
        skips.record(first)
        skips.record(first)
        skips.record(second)
        skips.record(package: package)
        skips.record(package: package)
        XCTAssertEqual(skips.count, 3)
        skips.log()
        let single = CloudSkips(.startupRepair)
        single.record(first)
        single.log()

        XCTAssertEqual(logLineCount(anyStatisticsLine), anyBefore + 1)
        XCTAssertEqual(logLineCount(threeBooks), threeBefore + 1)
        XCTAssertEqual(logLineCount(oneBook), oneBefore + 1)
    }

    // MARK: - Saving Package Records

    /// A save of a book whose record, package, or removal marker is only in
    /// the cloud neither reads the record, which would download it, nor
    /// writes it: the library index alone holds the save, and one line says
    /// so however often the book is saved. Once the files are on this Mac
    /// again, the next save writes the record.
    func testSavingABookWhoseRecordIsInTheCloudLeavesTheRecordAlone() throws {
        let inCloud: [(name: String, item: (Book) -> URL)] = [
            ("record", { TextMouthPaths.bookInfoPath(in: $0.tmbDirectory) }),
            ("package", { $0.tmbDirectory }),
            ("removal marker", { TextMouthPaths.removedFromLibraryMarkerPath(in: $0.tmbDirectory) }),
        ]
        useRecordAccess(cloud.access)
        var books: [Book] = []
        for (name, item) in inCloud {
            var book = try makePackagedBook(title: "Tide Tables \(name)")
            try book.saveBookInfoThrowing()
            let record = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
            let written = try XCTUnwrap(contents(of: record))
            cloud.markDataless(item(book))
            // Any read of the record through the access is noted.
            cloud.refuseReads(of: record)

            book.title += ", Revised"
            save(book)
            save(book)

            XCTAssertEqual(contents(of: record), written, "a record was written with its \(name) in the cloud")
            XCTAssertEqual(logLineCount(recordInCloudLine(for: book)), 1, name)
            books.append(book)
        }
        XCTAssertEqual(cloud.refusedReads, [], "a record was read with its files in the cloud")

        useRecordAccess(.live)
        for book in books {
            save(book)
            XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.title, book.title)
        }
    }

    /// A record that goes to the cloud between the check and the read is
    /// refused rather than downloaded, and is left alone the same way.
    func testRecordGoingToTheCloudAsItIsReadIsLeftAlone() throws {
        var book = try makePackagedBook(title: "Harbor Charts")
        try book.saveBookInfoThrowing()
        let record = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
        let written = try XCTUnwrap(contents(of: record))
        cloud.refuseReads(of: record)
        useRecordAccess(cloud.access)

        book.title = "Harbor Charts, Second Edition"
        save(book)

        XCTAssertEqual(contents(of: record), written)
        XCTAssertEqual(cloud.refusedReads, [FakeCloudFiles.key(record)])
        XCTAssertEqual(logLineCount(recordInCloudLine(for: book)), 1)
    }

    /// An analysis finished for a book whose record is only in the cloud is
    /// dropped, rather than merged into the record, which would read it: one
    /// line says why, and the record is left alone.
    func testAnalysisOfABookWhoseRecordIsInTheCloudIsDropped() throws {
        let book = try makePackagedBook(title: "Harbor Lights")
        try book.saveBookInfoThrowing()
        let record = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
        let written = try XCTUnwrap(contents(of: record))
        var cached = book
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &cached))
        cloud.markDataless(record)
        useRecordAccess(cloud.access)

        let committed = try LibraryPersistenceService.saveContentAnalysis(
            for: cached,
            index: index,
            cacheFormatVersion: cached.cacheFormatVersion
        )

        XCTAssertNil(committed)
        XCTAssertEqual(contents(of: record), written)
        XCTAssertEqual(logLineCount(
            "CONTENT_ANALYSIS_DROPPED: book \(book.id.uuidString.prefix(8)) \"Harbor Lights\": its record is only in the cloud"
        ), 1)
    }

    // MARK: - Fixtures

    /// Has package record writes reach a package's files through `access`
    /// until the test ends.
    private func useRecordAccess(_ access: MaintenanceFileAccess) {
        let previous = LibraryPersistenceService._useRecordAccessForTesting(access)
        addTeardownBlock { LibraryPersistenceService._useRecordAccessForTesting(previous) }
    }

    /// Saves `book`'s record as the library does, and waits for the write.
    private func save(_ book: Book) {
        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()
    }

    /// The start of the line saying a save of `book` went to the library
    /// index alone.
    private func recordInCloudLine(for book: Book) -> String {
        "BOOK_RECORD_IN_CLOUD: book \(book.id.uuidString.prefix(8)) \"\(book.title)\""
    }

    /// This thread's policy for dataless files.
    private func currentPolicy() -> Int32 {
        getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    }

    /// Asserts that `found` names the item at `expected`, however either
    /// path is spelled.
    private func assertSameItem(_ found: URL?, _ expected: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(found.map(FakeCloudFiles.key), FakeCloudFiles.key(expected), file: file, line: line)
    }
}

/// The items an access was asked whether they are dataless, in order, by
/// their keys (`FakeCloudFiles.key`). The list lives in an
/// OSAllocatedUnfairLock: an access may be asked from any thread.
private final class AskedItems: Sendable {
    /// The keys asked about so far.
    private let items = OSAllocatedUnfairLock(initialState: [String]())

    /// Notes that the item at `url` was asked about.
    func note(_ url: URL) {
        items.withLock { $0.append(FakeCloudFiles.key(url)) }
    }

    /// The keys asked about so far, in order.
    var paths: [String] {
        items.withLock { $0 }
    }
}
