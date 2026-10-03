import XCTest
@testable import TextMouth

/// The startup repair in a cloud library (FR02): it runs with dataless files
/// left in the cloud, and nothing is moved, rewritten, adopted, separated,
/// or relocated on the strength of a check that met a dataless folder or a
/// read that was refused. Such a book keeps its row as it is, and one
/// `MAINTENANCE_SKIPPED_IN_CLOUD` line counts such books. The first test is
/// the verification test that showed the behavior before the fix: a refused
/// read of a shared package's record separated it and rewrote the record.
final class CloudMaintenanceRepairTests: CloudMaintenanceTestCase {

    // MARK: - Verification

    /// When the record of a package two rows share cannot be read, neither
    /// row is separated, the record and the text cache stay as they were,
    /// both rows stay as they were, and the skip line counts both. (Before
    /// the fix, the record's own book was separated into a new package, the
    /// record was rewritten for the other row, and the cache was deleted.)
    @MainActor
    func testRepairDecidesNothingFromARefusedRead() throws {
        let owner = try commitCache(of: makePackagedBook(title: "Owner"))
        let other = Book(
            title: "Other",
            format: .markdown,
            filePath: owner.filePath,
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            tmbDirectoryName: owner.tmbDirectoryName,
            cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        )
        let package = owner.tmbDirectory
        let record = TextMouthPaths.bookInfoPath(in: package)
        let cache = TextMouthPaths.contentMarkdownPath(in: package)
        let recordBefore = contents(of: record)
        let cacheBefore = contents(of: cache)
        cloud.refuseReads(of: record)
        let skipLinesBefore = logLineCount(skipLine(.startupRepair, count: 2))
        let model = makeModel(with: [other, owner])

        model.migrateOldBooksIfNeeded(access: cloud.access)

        XCTAssertEqual(try folderEntries(), [package.lastPathComponent])
        XCTAssertEqual(contents(of: record), recordBefore, "the record was rewritten")
        XCTAssertEqual(contents(of: cache), cacheBefore, "the text cache was removed")
        XCTAssertEqual(model.bookByID(other.id), other)
        XCTAssertEqual(model.bookByID(owner.id), owner)
        XCTAssertEqual(logLineCount(skipLine(.startupRepair, count: 2)), skipLinesBefore + 1)
    }

    // MARK: - Separating, Moving, and Relocating

    /// A shared package one of whose files is dataless is not separated: the
    /// copy would download it.
    @MainActor
    func testSharedPackageWithADatalessFileIsNotSeparated() throws {
        let owner = try commitCache(of: makePackagedBook(title: "Owner"))
        let other = Book(
            title: "Other",
            format: .markdown,
            filePath: owner.filePath,
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            tmbDirectoryName: owner.tmbDirectoryName
        )
        cloud.markDataless(owner.bookFileURL)
        let model = makeModel(with: [other, owner])

        model.migrateOldBooksIfNeeded(access: cloud.access)

        XCTAssertEqual(try folderEntries(), [owner.tmbDirectoryName])
        XCTAssertEqual(model.bookByID(other.id), other)
        XCTAssertEqual(model.bookByID(owner.id), owner)
    }

    /// A book whose folder is dataless, and whose package is therefore not
    /// listed on this Mac, is not taken for missing: a stale copy of its
    /// package at the top of the library is not moved into the folder, and
    /// the row keeps its path.
    @MainActor
    func testStalePathRepairMovesNothingBehindADatalessFolder() throws {
        let shelf = "\(folderPath)/Shelf"
        try TextMouthPaths.ensureLibrarySubfolder(shelf)
        let packageName = "Shelved-\(UUID().uuidString).tmb"
        let staleCopy = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: staleCopy, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: staleCopy) }
        try "# Copy".write(to: staleCopy.appendingPathComponent("source.md"), atomically: true, encoding: .utf8)
        let book = Book(
            title: "Shelved",
            format: .markdown,
            filePath: TextMouthPaths.tmbPath(folderPath: shelf, tmbName: packageName)
                .appendingPathComponent("source.md").path,
            md5Hash: UUID().uuidString,
            folderPath: shelf,
            tmbDirectoryName: packageName
        )
        cloud.markDataless(TextMouthPaths.libraryDir.appendingPathComponent(shelf, isDirectory: true))
        let skipLinesBefore = logLineCount(skipLine(.startupRepair, count: 1))
        let model = makeModel(with: [book])

        model.migrateOldBooksIfNeeded(access: cloud.access)

        XCTAssertTrue(FileManager.default.fileExists(atPath: staleCopy.path), "the stale copy was moved")
        XCTAssertEqual(model.bookByID(book.id), book)
        XCTAssertEqual(logLineCount(skipLine(.startupRepair, count: 1)), skipLinesBefore + 1)
    }

    /// Relocation moves no package into a folder whose listing is in the
    /// cloud, and no package that is itself dataless, while a package on
    /// this Mac misplaced at the top of the library still moves into its
    /// folder.
    @MainActor
    func testRelocationMovesOnlyPackagesWhoseFoldersAreOnThisMac() throws {
        let cloudy = "\(folderPath)/Cloudy"
        try TextMouthPaths.ensureLibrarySubfolder(cloudy)
        cloud.markDataless(TextMouthPaths.libraryDir.appendingPathComponent(cloudy, isDirectory: true))
        let intoCloudyFolder = try makeMisplacedBook(title: "Into Cloudy Folder", folder: cloudy)
        let datalessPackage = try makeMisplacedBook(title: "Dataless Package", folder: folderPath)
        cloud.markDataless(TextMouthPaths.tmbPath(folderPath: "", tmbName: datalessPackage.tmbDirectoryName))
        let movable = try makeMisplacedBook(title: "Movable", folder: folderPath)
        let skipLinesBefore = logLineCount(skipLine(.startupRepair, count: 2))
        let model = makeModel(with: [intoCloudyFolder, datalessPackage, movable])

        model.migrateOldBooksIfNeeded(access: cloud.access)

        XCTAssertEqual(model.bookByID(intoCloudyFolder.id), intoCloudyFolder)
        XCTAssertEqual(model.bookByID(datalessPackage.id), datalessPackage)
        XCTAssertEqual(
            model.bookByID(movable.id)?.filePath,
            movable.tmbDirectory.appendingPathComponent("source.md").path,
            "a package on this Mac was not moved into its folder"
        )
        XCTAssertEqual(logLineCount(skipLine(.startupRepair, count: 2)), skipLinesBefore + 1)
    }

    // MARK: - Adopting

    /// Orphan adoption adopts a package on this Mac, and leaves those whose
    /// folder, record, or removal marker is in the cloud, or whose record's
    /// read is refused: none is adopted or rewritten, and each is counted.
    @MainActor
    func testAdoptionLeavesOrphansWhoseFilesAreInTheCloud() throws {
        let adoptable = try makeOrphan(title: "Adoptable")
        let recordInCloud = try makeOrphan(title: "Record In Cloud")
        let refusedRecord = try makeOrphan(title: "Refused Record")
        let packageInCloud = try makeOrphan(title: "Package In Cloud")
        let markerInCloud = try makeOrphan(title: "Marker In Cloud")
        try RemovedFromLibraryMarker(book: markerInCloud).write(into: markerInCloud.tmbDirectory)
        cloud.markDataless(
            TextMouthPaths.bookInfoPath(in: recordInCloud.tmbDirectory),
            packageInCloud.tmbDirectory,
            TextMouthPaths.removedFromLibraryMarkerPath(in: markerInCloud.tmbDirectory)
        )
        cloud.refuseReads(of: TextMouthPaths.bookInfoPath(in: refusedRecord.tmbDirectory))
        let left = [recordInCloud, refusedRecord, packageInCloud, markerInCloud]
        let recordsBefore = left.map { contents(of: TextMouthPaths.bookInfoPath(in: $0.tmbDirectory)) }
        let skipLinesBefore = logLineCount(skipLine(.startupRepair, count: 4))
        let model = makeModel(with: [])

        model.migrateOldBooksIfNeeded(access: cloud.access)

        XCTAssertNotNil(model.bookByID(adoptable.id), "the orphan on this Mac was not adopted")
        for book in left {
            XCTAssertNil(model.bookByID(book.id), "\(book.title) was adopted")
        }
        XCTAssertEqual(left.map { contents(of: TextMouthPaths.bookInfoPath(in: $0.tmbDirectory)) }, recordsBefore)
        XCTAssertEqual(logLineCount(skipLine(.startupRepair, count: 4)), skipLinesBefore + 1)
    }

    // MARK: - Retired and Legacy Books

    /// A book whose removal marker is in the cloud keeps its row, since a
    /// marker that cannot be read would retire it, while a book whose marker
    /// is on this Mac is taken out as before.
    @MainActor
    func testRetiredBookWhoseMarkerIsInTheCloudKeepsItsRow() throws {
        let markerInCloud = try commitCache(of: makePackagedBook(title: "Marker In Cloud"))
        let markerHere = try commitCache(of: makePackagedBook(title: "Marker Here"))
        for book in [markerInCloud, markerHere] {
            try RemovedFromLibraryMarker(book: book).write(into: book.tmbDirectory)
        }
        cloud.markDataless(TextMouthPaths.removedFromLibraryMarkerPath(in: markerInCloud.tmbDirectory))
        let model = makeModel(with: [markerInCloud, markerHere])

        model.migrateOldBooksIfNeeded(access: cloud.access)

        XCTAssertEqual(model.bookByID(markerInCloud.id), markerInCloud)
        XCTAssertNil(model.bookByID(markerHere.id))
    }

    /// A book recorded without a package, whose original is dataless, waits
    /// as it is: no package is made, no alert is shown, and it is counted.
    @MainActor
    func testLegacyBookWhoseOriginalIsInTheCloudWaits() throws {
        let original = folderURL.appendingPathComponent("Old Notes.txt")
        try "Old notes.".write(to: original, atomically: true, encoding: .utf8)
        let legacy = Book(title: "Old Notes", format: .txt, filePath: original.path, md5Hash: UUID().uuidString)
        cloud.markDataless(original)
        let skipLinesBefore = logLineCount(skipLine(.startupRepair, count: 1))
        let model = makeModel(with: [legacy])

        model.migrateOldBooksIfNeeded(access: cloud.access)

        XCTAssertEqual(model.bookByID(legacy.id), legacy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(model.showError, "an alert was shown")
        XCTAssertEqual(logLineCount(skipLine(.startupRepair, count: 1)), skipLinesBefore + 1)
    }

    // MARK: - Downloads Off

    /// Every check of the repair runs with dataless files left in the cloud,
    /// and the main thread's own policy is back as it was afterwards.
    @MainActor
    func testRepairRunsWithDownloadsOff() throws {
        let book = try commitCache(of: makePackagedBook())
        let policies = PolicyRecorder()
        let access = MaintenanceFileAccess(isDataless: { _ in
            policies.record(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD))
            return false
        })
        let policyBefore = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        let model = makeModel(with: [book])

        model.migrateOldBooksIfNeeded(access: access)

        XCTAssertFalse(policies.values.isEmpty, "the repair asked nothing")
        XCTAssertEqual(Set(policies.values), [IOPOL_MATERIALIZE_DATALESS_FILES_OFF])
        XCTAssertEqual(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD), policyBefore)
    }

    // MARK: - Fixtures

    /// The names in this test's library folder.
    private func folderEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folderURL.path).sorted()
    }

    /// A book assigned to `folder` whose package sits at the top of the
    /// library instead, as a folder assignment that did not move the
    /// package left it. The package is removed when the test ends.
    private func makeMisplacedBook(title: String, folder: String) throws -> Book {
        let packageName = "\(title)-\(UUID().uuidString).tmb"
        let misplaced = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: misplaced, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: misplaced) }
        let source = misplaced.appendingPathComponent("source.md")
        try "# \(title)".write(to: source, atomically: true, encoding: .utf8)
        return Book(
            title: title,
            format: .markdown,
            filePath: source.path,
            md5Hash: UUID().uuidString,
            folderPath: folder,
            tmbDirectoryName: packageName
        )
    }

    /// A package in this test's folder with its source and a record, which
    /// no library row lists, and the book its record describes.
    private func makeOrphan(title: String) throws -> Book {
        let book = try makePackagedBook(title: title)
        try book.saveBookInfoThrowing()
        return book
    }
}

/// The values a check recorded, from whichever thread asked.
final class PolicyRecorder: @unchecked Sendable {
    /// Guards `recorded`.
    private let lock = NSLock()
    /// The values recorded so far, in order.
    private var recorded: [Int32] = []

    /// Records `value`.
    func record(_ value: Int32) {
        lock.withLock { recorded.append(value) }
    }

    /// The values recorded so far, in order.
    var values: [Int32] {
        lock.withLock { recorded }
    }
}
