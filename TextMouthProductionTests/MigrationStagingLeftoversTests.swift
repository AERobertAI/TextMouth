import os
import XCTest
@testable import TextMouth

/// The journal of a data-directory move's staging folders and the sweep that
/// removes what an interrupted move left (the storage drill's finding: a
/// destination volume unplugged mid-copy kept a library-sized hidden copy
/// for good). Everything happens in sandbox folders; the journal is under
/// the sandboxed `MachineLocalPaths.root`.
final class MigrationStagingLeftoversTests: XCTestCase {
    /// A fixed moment the dated tests count from.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// A staging name that is valid, for fixtures that need one.
    private let validName = DataDirectoryMigrator.stagingNamePrefix + "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"

    /// Starts and ends every test with no journal, so none sees another's.
    override func setUpWithError() throws {
        try super.setUpWithError()
        removeMoveLeftoversJournal()
        addTeardownBlock { removeMoveLeftoversJournal() }
    }

    // MARK: - Names

    /// Only the exact form is a staging name: the prefix, then a UUID, in
    /// either case.
    func testOnlyTheExactFormIsAStagingName() {
        let prefix = DataDirectoryMigrator.stagingNamePrefix
        let id = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
        XCTAssertTrue(MigrationStagingLeftovers.isStagingName(prefix + id))
        XCTAssertTrue(MigrationStagingLeftovers.isStagingName(prefix + id.lowercased()))
        XCTAssertTrue(MigrationStagingLeftovers.isStagingName(prefix + UUID().uuidString))

        let refused = [
            prefix,
            prefix + "notauuid",
            prefix + id + "x",
            prefix + id + ".tmb",
            String(prefix.dropFirst()) + id,
            "Copy of " + prefix + id,
            "x" + prefix + id,
            "Archive",
            "",
        ]
        for name in refused {
            XCTAssertFalse(MigrationStagingLeftovers.isStagingName(name), name)
        }
    }

    // MARK: - A Move's Part

    /// A move that publishes its copy leaves no staging folder and no note,
    /// and the note was already made when the copy began.
    func testAPublishedMoveLeavesNoFolderAndNoNote() throws {
        let (source, destination, base) = try makeMoveLocations()
        let noted = OSAllocatedUnfairLock(initialState: [MigrationStagingLeftovers.Entry]())
        let observer = DataDirectoryCopyObserver(
            report: { _ in
                let current = MigrationStagingLeftovers.readEntries()
                noted.withLock { if $0.isEmpty { $0 = current } }
            },
            isCancelled: { false }
        )

        _ = try DataDirectoryMigrator.$copyObserver.withValue(observer) {
            try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: try makeLibrary(at: source))
        }

        let seen = noted.withLock { $0 }
        XCTAssertEqual(seen.count, 1, "the folder was not noted before the copy began")
        XCTAssertTrue(MigrationStagingLeftovers.isStagingName(URL(fileURLWithPath: seen.first?.path ?? "").lastPathComponent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("library.json").path))
        XCTAssertEqual(MigrationStagingLeftovers.readEntries(), [])
        XCTAssertEqual(stagingLeft(in: base), [])
    }

    /// A move cancelled after it created its folder removes the folder, and
    /// the removal having worked, no note stays.
    func testACancelledMoveLeavesNoFolderAndNoNote() throws {
        let (source, destination, base) = try makeMoveLocations()
        let library = try makeLibrary(at: source)

        XCTAssertThrowsError(try runCancelledMove(source: source, destination: destination, library: library))

        XCTAssertEqual(MigrationStagingLeftovers.readEntries(), [])
        XCTAssertEqual(stagingLeft(in: base), [])
    }

    /// A removal that fails keeps the folder and its note; the sweep then
    /// removes the folder and forgets the note.
    func testAFailedRemovalKeepsTheNoteUntilTheSweepRemovesTheFolder() throws {
        let (source, destination, base) = try makeMoveLocations()
        let library = try makeLibrary(at: source)

        XCTAssertThrowsError(
            try runCancelledMove(
                source: source, destination: destination, library: library, fileManager: RefusingRemovalFileManager()
            )
        )

        let left = stagingLeft(in: base)
        XCTAssertEqual(left.count, 1, "the folder whose removal failed is gone")
        let entries = MigrationStagingLeftovers.readEntries()
        XCTAssertEqual(entries.map { URL(fileURLWithPath: $0.path).lastPathComponent }, left)

        XCTAssertEqual(MigrationStagingLeftovers.sweep(), 1)

        XCTAssertEqual(stagingLeft(in: base), [])
        XCTAssertEqual(MigrationStagingLeftovers.readEntries(), [])
    }

    // MARK: - The Volume Away

    /// A note whose folder cannot be seen survives the sweep, whether its
    /// parent is missing or is an empty mount point, until it is 30 days
    /// old; it is then dropped.
    func testAFolderThatCannotBeSeenIsKeptThirtyDays() throws {
        let base = try makeSandboxDirectory("StagingAway")
        let mountPoint = base.appendingPathComponent("Volume", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let missingParent = base.appendingPathComponent("Gone", isDirectory: true).appendingPathComponent(validName)
        let emptyParent = mountPoint.appendingPathComponent(validName)
        try seedJournal([missingParent, emptyParent], noted: t0)
        let before = MigrationStagingLeftovers.readEntries()
        XCTAssertEqual(before.count, 2)

        XCTAssertEqual(MigrationStagingLeftovers.sweep(now: t0 + 29 * 86_400), 0)
        XCTAssertEqual(MigrationStagingLeftovers.readEntries(), before, "an entry was dropped too early")

        XCTAssertEqual(MigrationStagingLeftovers.sweep(now: t0 + 31 * 86_400), 0)
        XCTAssertEqual(MigrationStagingLeftovers.readEntries(), [])
    }

    /// When the volume returns, the next sweep removes the folder and
    /// forgets the note.
    func testTheFolderIsRemovedOnceTheVolumeReturns() throws {
        let base = try makeSandboxDirectory("StagingReturns")
        let mountPoint = base.appendingPathComponent("Volume", isDirectory: true)
        let folder = mountPoint.appendingPathComponent(validName, isDirectory: true)
        try seedJournal([folder], noted: t0)
        XCTAssertEqual(MigrationStagingLeftovers.sweep(now: t0 + 86_400), 0)
        XCTAssertEqual(MigrationStagingLeftovers.readEntries().count, 1)

        // The volume returns holding the half-copied library.
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Library", isDirectory: true), withIntermediateDirectories: true
        )
        try Data("half".utf8).write(to: folder.appendingPathComponent("Library/part.bin"))

        XCTAssertEqual(MigrationStagingLeftovers.sweep(now: t0 + 2 * 86_400), 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint.path), "the sweep removed more than the folder")
        XCTAssertEqual(MigrationStagingLeftovers.readEntries(), [])
    }

    // MARK: - Never More Than It Was Told

    /// A journal entry that names anything but a real staging folder is
    /// dropped and nothing it names is touched: a user's folder, a name
    /// that is not a staging name, a regular file, and a symbolic link
    /// (whose target is never followed).
    func testTheSweepNeverRemovesMoreThanAMoveMade() throws {
        let base = try makeSandboxDirectory("StagingNever")
        let fileManager = FileManager.default
        let archive = try makeFolder("Archive", holding: "diary.txt", in: base)
        let notAnId = try makeFolder(DataDirectoryMigrator.stagingNamePrefix + "notauuid", holding: "keep.txt", in: base)
        let regularFile = base.appendingPathComponent(DataDirectoryMigrator.stagingNamePrefix + UUID().uuidString)
        try Data("a file".utf8).write(to: regularFile)
        let target = try makeFolder("Target", holding: "precious.txt", in: base)
        let link = base.appendingPathComponent(DataDirectoryMigrator.stagingNamePrefix + UUID().uuidString)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        try seedJournal([archive, notAnId, regularFile, link], noted: t0)

        XCTAssertEqual(MigrationStagingLeftovers.sweep(now: t0), 0)

        XCTAssertTrue(fileManager.fileExists(atPath: archive.appendingPathComponent("diary.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: notAnId.appendingPathComponent("keep.txt").path))
        XCTAssertEqual(try String(contentsOf: regularFile, encoding: .utf8), "a file")
        XCTAssertNotNil(try? fileManager.destinationOfSymbolicLink(atPath: link.path), "the link was removed")
        XCTAssertTrue(fileManager.fileExists(atPath: target.appendingPathComponent("precious.txt").path), "the link was followed")
        XCTAssertEqual(MigrationStagingLeftovers.readEntries(), [], "an invalid entry stayed in the journal")
    }

    /// A folder a move in this process is using is left alone.
    func testAFolderInUseIsSkipped() throws {
        let base = try makeSandboxDirectory("StagingInUse")
        let folder = try makeFolder(validName, holding: "copy.bin", in: base)
        MigrationStagingLeftovers.note(folder, at: t0)

        XCTAssertEqual(MigrationStagingLeftovers.sweep(now: t0), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("copy.bin").path))
        XCTAssertEqual(MigrationStagingLeftovers.readEntries().count, 1)

        // Once the move ends and removes it, nothing remains.
        MigrationStagingLeftovers.discard(folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(MigrationStagingLeftovers.readEntries(), [])
    }

    /// Noting and discarding from many threads at once loses no entry.
    func testNotingAndDiscardingTogetherLosesNoEntry() throws {
        let base = try makeSandboxDirectory("StagingThreads")
        let count = MigrationStagingLeftovers.journalLimit - 5
        let start = t0
        let folders = try (0..<count).map { index in
            try makeFolder(DataDirectoryMigrator.stagingNamePrefix + UUID().uuidString, holding: "\(index)", in: base)
        }

        DispatchQueue.concurrentPerform(iterations: count) { index in
            MigrationStagingLeftovers.note(folders[index], at: start + TimeInterval(index))
        }
        XCTAssertEqual(
            Set(MigrationStagingLeftovers.readEntries().map(\.path)), Set(folders.map(\.path)),
            "an entry was lost while noting"
        )

        DispatchQueue.concurrentPerform(iterations: count) { index in
            MigrationStagingLeftovers.discard(folders[index])
        }
        XCTAssertEqual(MigrationStagingLeftovers.readEntries(), [], "an entry was kept after its folder was removed")
        XCTAssertEqual(stagingLeft(in: base), [])
    }

    // MARK: - The Journal

    /// A journal of garbage bytes, or of a JSON object instead of a list,
    /// reads as empty, the sweep over it does nothing, and the next note
    /// rewrites it well.
    func testADamagedJournalReadsAsEmptyAndTheNextNoteRepairsIt() throws {
        let journal = MachineLocalPaths.moveLeftovers
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged: [Data] = [
            Data([0xFF, 0x00, 0xFE, 0x01, 0x7B]),
            Data(#"{"path": "/x", "noted": "2026-01-01T00:00:00Z"}"#.utf8),
            Data(#"[{"path": 5}]"#.utf8),
            Data(),
        ]
        let base = try makeSandboxDirectory("StagingDamaged")
        let folder = base.appendingPathComponent(validName, isDirectory: true)

        for bytes in damaged {
            try bytes.write(to: journal)
            XCTAssertEqual(MigrationStagingLeftovers.readEntries(), [])
            XCTAssertEqual(MigrationStagingLeftovers.sweep(now: t0), 0)

            MigrationStagingLeftovers.note(folder, at: t0)
            XCTAssertEqual(MigrationStagingLeftovers.readEntries(), [.init(path: folder.path, noted: t0)])
            MigrationStagingLeftovers.forget(folder)
            XCTAssertEqual(MigrationStagingLeftovers.readEntries(), [])
        }
    }

    /// The journal keeps the newest 20 entries.
    func testTheJournalKeepsTheNewestTwenty() throws {
        let base = try makeSandboxDirectory("StagingCap")
        let total = MigrationStagingLeftovers.journalLimit + 5
        let folders = (0..<total).map { _ in
            base.appendingPathComponent(DataDirectoryMigrator.stagingNamePrefix + UUID().uuidString, isDirectory: true)
        }
        // Noted in a scrambled order, so the newest are told by date.
        for index in (0..<total).reversed() {
            MigrationStagingLeftovers.note(folders[index], at: t0 + TimeInterval(index * 60))
        }

        let kept = MigrationStagingLeftovers.readEntries()
        XCTAssertEqual(kept.count, MigrationStagingLeftovers.journalLimit)
        XCTAssertEqual(kept.map(\.path), folders.suffix(MigrationStagingLeftovers.journalLimit).map(\.path))
    }

    // MARK: - At Launch

    /// The launch sweep does nothing under a hosted test, and otherwise
    /// removes the leftovers in the background.
    func testTheBackgroundSweepRunsOnlyOutsideHostedTests() throws {
        let base = try makeSandboxDirectory("StagingBackground")
        let folder = try makeFolder(validName, holding: "copy.bin", in: base)
        // A journal an earlier run left: this process is using nothing.
        try seedJournal([folder], noted: t0)

        let hosted = expectation(description: "a hosted sweep ran")
        hosted.isInverted = true
        MigrationStagingLeftovers.sweepInBackground(isHostedTest: true) { hosted.fulfill() }
        wait(for: [hosted], timeout: 0.3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        let ran = expectation(description: "the sweep ran")
        MigrationStagingLeftovers.sweepInBackground(isHostedTest: false) { ran.fulfill() }
        wait(for: [ran], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(MigrationStagingLeftovers.readEntries(), [])
    }

    // MARK: - Fixtures

    /// Writes a journal listing `folders`, as an earlier run of the app
    /// left it: nothing in it is marked in use by this process.
    private func seedJournal(_ folders: [URL], noted: Date) throws {
        let journal = MachineLocalPaths.moveLeftovers
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(folders.map { MigrationStagingLeftovers.Entry(path: $0.path, noted: noted) }).write(to: journal)
    }

    /// A data directory's location, a move's new location, and the folder
    /// holding both (where the move stages its copy), all new and in the
    /// test's sandbox. The source is laid out; the destination is not.
    private func makeMoveLocations() throws -> (source: URL, destination: URL, base: URL) {
        let base = try makeSandboxDirectory("StagingMove")
        return (
            base.appendingPathComponent("Source", isDirectory: true),
            base.appendingPathComponent("Destination", isDirectory: true),
            base
        )
    }

    /// Runs a move that is cancelled once its first item is copied, so its
    /// staging folder exists when the move ends.
    private func runCancelledMove(
        source: URL,
        destination: URL,
        library: Library,
        fileManager: FileManager = .default
    ) throws {
        let copiedOne = OSAllocatedUnfairLock(initialState: false)
        let observer = DataDirectoryCopyObserver(
            report: { progress in
                if progress.copiedItems >= 1 { copiedOne.withLock { $0 = true } }
            },
            isCancelled: { copiedOne.withLock { $0 } }
        )
        _ = try DataDirectoryMigrator.$copyObserver.withValue(observer) {
            try DataDirectoryMigrator.prepareMigration(
                from: source, to: destination, library: library, fileManager: fileManager
            )
        }
    }

    /// The names of the hidden staging folders a move left in `folder`.
    private func stagingLeft(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(DataDirectoryMigrator.stagingNamePrefix) }
    }

    /// Makes the folder `name` in `parent` holding one file named `fileName`.
    private func makeFolder(_ name: String, holding fileName: String, in parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: folder.appendingPathComponent(fileName))
        return folder
    }
}

/// Removes the journal of staging folders. Free of the test class, so the
/// teardown block that calls it captures nothing.
private func removeMoveLeftoversJournal() {
    try? FileManager.default.removeItem(at: MachineLocalPaths.moveLeftovers)
}

/// A file manager that refuses, once, to remove a folder named as a move's
/// staging folder, as a vanished volume would, and removes everything else
/// as FileManager does.
final class RefusingRemovalFileManager: FileManager, @unchecked Sendable {
    /// How many more refusals remain. The lock guards it.
    private let refusals = OSAllocatedUnfairLock(initialState: 1)

    /// Refuses the first staging folder it is asked to remove.
    override func removeItem(at url: URL) throws {
        let refuse = MigrationStagingLeftovers.isStagingName(url.lastPathComponent)
            && refusals.withLock { remaining -> Bool in
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
        if refuse { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}
