import XCTest
@testable import TextMouth

/// A data-directory migration copies item by item (FR02): each book's
/// package whole, each ordinary folder made and filled, telling the move
/// that runs it how far it has got, and stopping at its Cancel with the
/// partial copy deleted and nothing else changed. Publication is S10's, and
/// `DataDirectoryMigrationTests` keeps covering it.
final class DataDirectoryCopyTests: XCTestCase {

    // MARK: - The Plan

    /// The plan names every item once, in the copy's order: within each
    /// folder, folders and packages before files, each by name, and each
    /// ordinary folder before what is inside it. A package is one item
    /// whose size is every file inside it; nothing inside it is listed.
    func testThePlanCopiesPackagesWholeAndTheBooksBeforeTheFilesAtTheTop() throws {
        let root = try makeSandboxDirectory("CopyPlan").appendingPathComponent("Data", isDirectory: true)
        try write("12345", to: root.appendingPathComponent("config.json"))
        try write("ab", to: root.appendingPathComponent("library.json"))
        try write("{}", to: root.appendingPathComponent("Sessions/mac.json"))
        try write("0123456789", to: root.appendingPathComponent("Library/Fiction/Tide.tmb/book.txt"))
        try write("abc", to: root.appendingPathComponent("Library/Fiction/Tide.tmb/Tracks/01.txt"))
        try write("xyz", to: root.appendingPathComponent("Library/legacy.txt"))
        try write("1234", to: root.appendingPathComponent("Library/Atlas.tmb/book.txt"))

        let plan = try DataDirectoryCopyPlan(of: root)

        XCTAssertEqual(plan.items.map(\.relativePath), [
            "Library",
            "Library/Atlas.tmb",
            "Library/Fiction",
            "Library/Fiction/Tide.tmb",
            "Library/legacy.txt",
            "Sessions",
            "Sessions/mac.json",
            "config.json",
            "library.json",
        ])
        XCTAssertEqual(plan.items.map(\.kind), [.folder, .whole, .folder, .whole, .whole, .folder, .whole, .whole, .whole])
        XCTAssertEqual(plan.items.first { $0.relativePath == "Library/Fiction/Tide.tmb" }?.byteCount, 13)
        XCTAssertEqual(plan.items.first { $0.relativePath == "Library" }?.byteCount, 0)
        XCTAssertEqual(plan.totalBytes, 5 + 2 + 2 + 13 + 3 + 4)
    }

    /// Hidden items are part of the data, and are copied like any other.
    func testThePlanIncludesHiddenItems() throws {
        let root = try makeSandboxDirectory("CopyPlanHidden").appendingPathComponent("Data", isDirectory: true)
        try write("x", to: root.appendingPathComponent(".hidden-note"))
        try write("y", to: root.appendingPathComponent("Library/.DS_Store"))

        let paths = try DataDirectoryCopyPlan(of: root).items.map(\.relativePath)

        XCTAssertEqual(paths, ["Library", "Library/.DS_Store", ".hidden-note"])
    }

    // MARK: - Copying

    /// Each package is copied with one copy of the whole package, and each
    /// file outside a package with one of its own; ordinary folders are
    /// made, not copied. The published copy holds everything.
    func testEachPackageIsCopiedWholeWithOneCopy() throws {
        let base = try makeSandboxDirectory("CopyWhole")
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        let library = try makeLayeredLibrary(at: source)
        let fileManager = CopyRecordingFileManager()

        _ = try DataDirectoryMigrator.prepareMigration(
            from: source, to: destination, library: library, fileManager: fileManager
        )

        let copied = fileManager.copiedPaths.map { String($0.dropFirst(source.resolvingSymlinksInPath().path.count + 1)) }
        XCTAssertEqual(copied.sorted(), [
            "Library/Fiction/Tide.tmb",
            "Library/Harbor.tmb",
            "config.json",
        ])
        for book in try publishedLibrary(in: destination).books {
            XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath), book.title)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Library/Fiction/Tide.tmb/Tracks/01.txt").path))
    }

    /// The copy reports before its first item and after each one: the bytes
    /// and items copied only grow, every report counts the same totals, and
    /// the last says the copy is complete, at 100 percent.
    func testTheCopyReportsItsProgressAfterEveryItem() throws {
        let base = try makeSandboxDirectory("CopyProgress")
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        let library = try makeLayeredLibrary(at: source)
        let plan = try DataDirectoryCopyPlan(of: source)
        let reports = CopyReports()

        _ = try DataDirectoryMigrator.$copyObserver.withValue(reports.observer()) {
            try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)
        }

        let all = reports.all
        XCTAssertEqual(all.count, plan.items.count + 1, "one report before the first item and one after each")
        XCTAssertEqual(all.first, DataDirectoryCopyProgress(
            copiedBytes: 0, totalBytes: plan.totalBytes, copiedItems: 0, totalItems: plan.items.count
        ))
        XCTAssertEqual(all.map(\.copiedItems), Array(0...plan.items.count))
        XCTAssertEqual(all.map(\.copiedBytes), all.map(\.copiedBytes).sorted(), "the bytes copied only grow")
        XCTAssertTrue(all.allSatisfy { $0.totalBytes == plan.totalBytes && $0.totalItems == plan.items.count })
        XCTAssertEqual(all.last?.copiedBytes, plan.totalBytes)
        XCTAssertEqual(all.last?.isComplete, true)
        XCTAssertEqual(all.last?.percent, 100)
        XCTAssertEqual(all.dropLast().map(\.isComplete), Array(repeating: false, count: plan.items.count))
    }

    /// A copy with no observer bound, as every copy was before FR02, still
    /// publishes, and an observer bound for one copy is gone once it ends.
    func testACopyWithoutAnObserverStillPublishes() throws {
        let base = try makeSandboxDirectory("CopyUnobserved")
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        let library = try makeLayeredLibrary(at: source)

        XCTAssertNil(DataDirectoryMigrator.copyObserver)
        let migrated = try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)

        XCTAssertEqual(migrated.books.count, library.books.count)
        XCTAssertEqual(try publishedLibrary(in: destination).books.count, library.books.count)
    }

    /// Folders the copy makes take their originals' permissions and dates,
    /// as copying a whole folder did: a private folder stays private.
    func testFoldersTheCopyMakesKeepTheirPermissionsAndDates() throws {
        let base = try makeSandboxDirectory("CopyMetadata")
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        let library = try makeLayeredLibrary(at: source)
        let fiction = source.appendingPathComponent("Library/Fiction", isDirectory: true)
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o700, .modificationDate: past], ofItemAtPath: fiction.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: source.path)

        _ = try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)

        let copiedFiction = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent("Library/Fiction").path
        )
        XCTAssertEqual((copiedFiction[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(copiedFiction[.modificationDate] as? Date, past)
        let copiedRoot = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((copiedRoot[.posixPermissions] as? NSNumber)?.intValue, 0o750)
    }

    // MARK: - Cancel

    /// Cancel during the copy stops it before the next item: the move fails
    /// as cancelled, the partial copy is deleted, nothing appears at the new
    /// location, and the data directory is exactly as it was.
    func testCancelDuringTheCopyDeletesThePartialCopyAndChangesNothing() throws {
        let base = try makeSandboxDirectory("CopyCancel")
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        let library = try makeLayeredLibrary(at: source)
        let sourceBefore = try contents(of: source)
        let reports = CopyReports(cancellingAfterItems: 2)
        let fileManager = CopyRecordingFileManager()

        XCTAssertThrowsError(
            try DataDirectoryMigrator.$copyObserver.withValue(reports.observer()) {
                try DataDirectoryMigrator.prepareMigration(
                    from: source, to: destination, library: library, fileManager: fileManager
                )
            }
        ) { error in
            guard case DataDirectoryMigrationError.cancelled = error else {
                return XCTFail("Expected the cancellation, received \(error)")
            }
            XCTAssertEqual(error.localizedDescription, "The move was cancelled, so nothing changed.")
        }

        XCTAssertEqual(reports.all.last?.copiedItems, 2, "the copy stopped at the next item")
        XCTAssertEqual(stagingLeft(in: base), [], "the partial copy is deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(fileManager.moveAttempts, 0, "nothing was renamed into place")
        XCTAssertEqual(try contents(of: source), sourceBefore)
    }

    /// Cancel pressed while the last item was copied, which can be a large
    /// book, still stops the move before anything is published.
    func testCancelDuringTheLastItemStillStopsTheMove() throws {
        let base = try makeSandboxDirectory("CopyCancelLast")
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        let library = try makeLayeredLibrary(at: source)
        let itemCount = try DataDirectoryCopyPlan(of: source).items.count
        let reports = CopyReports(cancellingAfterItems: itemCount)

        XCTAssertThrowsError(
            try DataDirectoryMigrator.$copyObserver.withValue(reports.observer()) {
                try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)
            }
        ) { error in
            guard case DataDirectoryMigrationError.cancelled = error else {
                return XCTFail("Expected the cancellation, received \(error)")
            }
        }

        XCTAssertEqual(reports.all.last?.isComplete, true, "every item was copied before the Cancel was seen")
        XCTAssertEqual(stagingLeft(in: base), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// A move cancelled before its copy began copies nothing at all.
    func testCancelBeforeTheFirstItemCopiesNothing() throws {
        let base = try makeSandboxDirectory("CopyCancelFirst")
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        let library = try makeLayeredLibrary(at: source)
        let reports = CopyReports(cancellingAfterItems: 0)
        let fileManager = CopyRecordingFileManager()

        XCTAssertThrowsError(
            try DataDirectoryMigrator.$copyObserver.withValue(reports.observer()) {
                try DataDirectoryMigrator.prepareMigration(
                    from: source, to: destination, library: library, fileManager: fileManager
                )
            }
        )

        XCTAssertEqual(fileManager.copiedPaths, [])
        XCTAssertEqual(reports.all.map(\.copiedItems), [0])
        XCTAssertEqual(stagingLeft(in: base), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Progress

    /// The percentage counts bytes, or items when the items hold no bytes,
    /// rounds down, and reaches 100 only when every item is copied.
    func testThePercentageCountsBytesAndReachesOneHundredOnlyWhenComplete() {
        XCTAssertEqual(DataDirectoryCopyProgress(copiedBytes: 40, totalBytes: 100, copiedItems: 1, totalItems: 5).percent, 40)
        XCTAssertEqual(DataDirectoryCopyProgress(copiedBytes: 999, totalBytes: 1000, copiedItems: 4, totalItems: 5).percent, 99)
        XCTAssertEqual(
            DataDirectoryCopyProgress(copiedBytes: 1000, totalBytes: 1000, copiedItems: 4, totalItems: 5).percent,
            99,
            "an item still to copy, such as an empty file, keeps it below 100"
        )
        XCTAssertEqual(DataDirectoryCopyProgress(copiedBytes: 1000, totalBytes: 1000, copiedItems: 5, totalItems: 5).percent, 100)
        XCTAssertEqual(DataDirectoryCopyProgress(copiedBytes: 0, totalBytes: 0, copiedItems: 1, totalItems: 4).percent, 25)
        XCTAssertEqual(DataDirectoryCopyProgress(copiedBytes: 0, totalBytes: 0, copiedItems: 0, totalItems: 0).percent, 100)
    }

    // MARK: - Fixtures

    /// Writes `text` to `url`, making the folders above it.
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A data directory at `root` with two packaged books, one in a
    /// folder with a subfolder of tracks inside its package, a Logs folder,
    /// and config.json, and the library naming the books. The library is
    /// not written as `root`'s library.json.
    private func makeLayeredLibrary(at root: URL) throws -> Library {
        let tide = root.appendingPathComponent("Library/Fiction/Tide.tmb", isDirectory: true)
        let harbor = root.appendingPathComponent("Library/Harbor.tmb", isDirectory: true)
        try write("The tide turns at noon.", to: tide.appendingPathComponent("book.txt"))
        try write("track", to: tide.appendingPathComponent("Tracks/01.txt"))
        try write("The harbor master waves.", to: harbor.appendingPathComponent("book.txt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Logs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write("{}", to: root.appendingPathComponent("config.json"))
        return Library(books: [
            Book(
                title: "Tide",
                format: .txt,
                filePath: tide.appendingPathComponent("book.txt").path,
                md5Hash: "tide",
                folderPath: "Fiction",
                tmbDirectoryName: "Tide.tmb"
            ),
            Book(
                title: "Harbor",
                format: .txt,
                filePath: harbor.appendingPathComponent("book.txt").path,
                md5Hash: "harbor",
                tmbDirectoryName: "Harbor.tmb"
            ),
        ])
    }

    /// The library index published in the data directory at `root`.
    private func publishedLibrary(in root: URL) throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Library.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
    }

    /// The names in `folder` that a migration's staging copy goes by.
    private func stagingLeft(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(DataDirectoryMigrator.stagingNamePrefix) }
    }

    /// Every item under `folder` by its path inside it, with each file's
    /// bytes, so equal results mean nothing there changed.
    private func contents(of folder: URL) throws -> [String: Data] {
        var entries: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(atPath: folder.path)
        while let relativePath = enumerator?.nextObject() as? String {
            let item = folder.appendingPathComponent(relativePath)
            if enumerator?.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                entries[relativePath + "/"] = Data()
            } else {
                entries[relativePath] = try Data(contentsOf: item)
            }
        }
        return entries
    }
}

/// The reports a copy's observer heard, from any thread, and an observer
/// that cancels the move once a given number of items is copied.
final class CopyReports: @unchecked Sendable {
    /// Guards `reports`.
    private let lock = NSLock()
    /// Every report, in order.
    private var reports: [DataDirectoryCopyProgress] = []
    /// After how many items the observer says the move was cancelled, or
    /// nil for never.
    private let cancellingAfterItems: Int?

    /// A record whose observer cancels once `cancellingAfterItems` items are
    /// copied, or never when nil.
    init(cancellingAfterItems: Int? = nil) {
        self.cancellingAfterItems = cancellingAfterItems
    }

    /// Every report so far.
    var all: [DataDirectoryCopyProgress] {
        lock.withLock { reports }
    }

    /// An observer recording here.
    func observer() -> DataDirectoryCopyObserver {
        DataDirectoryCopyObserver(
            report: { [self] progress in lock.withLock { reports.append(progress) } },
            isCancelled: { [self] in
                guard let limit = cancellingAfterItems else { return false }
                return (all.last?.copiedItems ?? 0) >= limit
            }
        )
    }
}

/// A file manager that records each item it is asked to copy whole and
/// counts the renames into place.
final class CopyRecordingFileManager: FileManager, @unchecked Sendable {
    /// Guards the records.
    private let lock = NSLock()
    /// The paths copied whole, in order.
    private var copies: [String] = []
    /// The renames asked for.
    private var moves = 0

    /// The paths of the items copied whole, in order.
    var copiedPaths: [String] {
        lock.withLock { copies }
    }

    /// How many renames into place were asked for.
    var moveAttempts: Int {
        lock.withLock { moves }
    }

    /// Records the copy, then copies as FileManager does.
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        lock.withLock { copies.append(srcURL.resolvingSymlinksInPath().path) }
        try super.copyItem(at: srcURL, to: dstURL)
    }

    /// Records the rename, then renames as FileManager does.
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        lock.withLock { moves += 1 }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
