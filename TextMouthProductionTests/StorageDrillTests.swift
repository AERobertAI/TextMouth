import XCTest
@testable import TextMouth

/// The storage-failure drill: what TextMouth does when the volume under an
/// operation is unplugged part-way, or is full, tested on small disposable
/// disk images (`DiskImageDrill.swift`) rather than by renaming a folder.
/// What the user cares about most is checked each time by checksum: the
/// original files, and the library as it was before, survive every
/// reported failure.
///
/// Opt-in: every test skips unless `TEXTMOUTH_STORAGE_DRILL=1`, because
/// each makes and force-detaches disk images (a few MB each, in the test
/// sandbox, never anywhere else). Run it with `Scripts/test/storage-drill.sh`,
/// which also checks afterwards that no image of the drill is left attached.
///
/// The library under test is made inside the image; the originals being
/// imported live in the sandbox, outside it. Nothing here reads or writes
/// the user's live library or any volume but the drill's own images.
final class StorageDrillTests: XCTestCase {

    // MARK: - Set-up

    /// Skips unless the drill was asked for, then detaches the drill's
    /// images that an earlier crashed run left attached.
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TEXTMOUTH_STORAGE_DRILL"] == "1",
            "Set TEXTMOUTH_STORAGE_DRILL=1 to run the storage-failure drill (it makes and removes small disk images in the test sandbox); Scripts/test/storage-drill.sh does."
        )
        DiskImage.sweepLeftovers()
    }

    // MARK: - 1. Importing While the Volume Vanishes

    /// The volume is unplugged as the import reads the book's text. The
    /// import fails, naming the file; the original has the checksum it had;
    /// nothing was recreated on the Mac's own disk in the dead volume's
    /// place. With the volume back, no book was published, and the
    /// import staging leaves only what its promise allows: a hidden staged
    /// package that the next import into that folder removes.
    @MainActor
    func testImportWhileTheVolumeVanishesFailsAndKeepsTheOriginal() throws {
        let image = try DiskImage.make(for: self, name: "import-vanish", sizeMegabytes: 16)
        let root = try makeDataDirectory(on: image)
        let source = try makeOriginal("Harbour Ledger.txt", kilobytes: 200)
        let originalDigest = try FolderSnapshot.sha256(of: source)

        let unplugged = OneShot()
        let thrown = attemptImport(of: source) { step, _ in
            guard case .readingText = step, unplugged.fire() else { return }
            image.detach()
        }

        let failure = try XCTUnwrap(thrown as? ImportFailure, "the import did not fail with an ImportFailure: \(String(describing: thrown))")
        XCTAssertEqual(failure.fileName, "Harbour Ledger.txt")
        XCTAssertTrue(failure.errorDescription?.hasPrefix("Could not import “Harbour Ledger.txt”. ") == true, failure.errorDescription ?? "no description")
        XCTAssertFalse(image.isAttached, "the observer never unplugged the volume")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: image.mountPoint.path), [],
            "something was written on the Mac's own disk in the dead volume's place"
        )
        XCTAssertEqual(try FolderSnapshot.sha256(of: source), originalDigest, "the original changed")

        // The volume comes back: nothing was published.
        try image.attach()
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: library.path)
        XCTAssertEqual(leftovers.filter { !$0.hasPrefix(".") }, [], "a book was published by a failed import")
        XCTAssertTrue(
            leftovers.allSatisfy(ImportStaging.isStagedPackageName),
            "something other than a staged package was left: \(leftovers)"
        )

        // The promise (ImportStaging): the next import that stages in the
        // folder removes what an interrupted one left.
        let second = try makeOriginal("Second Ledger.txt", kilobytes: 50)
        let imported = try FileImportService.importFileWithReport(from: second)
        let after = try FileManager.default.contentsOfDirectory(atPath: library.path)
        XCTAssertEqual(after, [imported.book.tmbDirectoryName], "the next import left the old staging, or more than its own book")
    }

    // MARK: - 2. A Full Disk During Import

    /// A volume with a few KB free refuses a 200 KB book in the app's own
    /// plain words (no hidden staged name in them), publishes nothing, and
    /// leaves the ballast, the earlier contents, and the original exactly as
    /// they were (every file's checksum). Freeing the space lets the same
    /// import succeed.
    @MainActor
    func testAFullDiskRefusesTheImportAndChangesNothing() throws {
        let image = try DiskImage.make(for: self, name: "import-full", sizeMegabytes: 3)
        _ = try makeDataDirectory(on: image)
        let source = try makeOriginal("Salt Quay Diary.txt", kilobytes: 200)
        let originalDigest = try FolderSnapshot.sha256(of: source)
        let ballast = try image.fillToCapacity(leavingFree: 16 * 1024)
        let free = try XCTUnwrap(image.freeBytes)
        XCTAssertLessThan(free, 64 * 1024, "the volume is not nearly full")
        let before = try FolderSnapshot(of: image.mountPoint)

        let thrown = attemptImport(of: source, observer: nil)

        let failure = try XCTUnwrap(thrown as? ImportFailure, "the import did not fail with an ImportFailure: \(String(describing: thrown))")
        XCTAssertEqual(failure.fileName, "Salt Quay Diary.txt")
        XCTAssertTrue(ImportFailure.isOutOfSpace(failure.underlying), "the reason is not a full disk: \(failure.underlying)")
        let message = try XCTUnwrap(failure.errorDescription)
        // The wording the user hears: the plain sentence for a full disk. It
        // holds no id and no hidden staged name (".import-<UUID>.tmb"), which
        // the system's own sentence would have named.
        XCTAssertEqual(
            message,
            "Could not import “Salt Quay Diary.txt”. Copying it into the library failed: "
                + "There isn’t enough free space on the disk."
        )
        XCTAssertFalse(message.contains(".import-"), "the message names the hidden staged package: \(message)")
        // Only the debug log, which the app keeps in the data directory and
        // which records the failure, may differ; no package, no staging.
        let changes = try FolderSnapshot(of: image.mountPoint).differences(from: before)
        XCTAssertEqual(changes.filter { !$0.hasSuffix("TextMouth/Logs/textmouth_debug.log") }, [], "the failed import changed the volume")
        XCTAssertEqual(try FolderSnapshot.sha256(of: source), originalDigest, "the original changed")

        // With room again, the same import works: the refusal was the space.
        try FileManager.default.removeItem(at: ballast)
        let imported = try FileImportService.importFileWithReport(from: source)
        XCTAssertEqual(imported.book.title, "Salt Quay Diary")
    }

    // MARK: - 3. Saving While the Volume Vanishes

    /// The library is saved after the volume is unplugged: the save
    /// reports failure, the failure is recorded for the user to hear, and
    /// nothing is made on the Mac's disk in the volume's place. With the
    /// volume back, library.json is byte-for-byte the last good one, and a
    /// save then succeeds and settles the failure.
    @MainActor
    func testSavingWhileTheVolumeVanishesReportsItAndKeepsThePreviousIndex() throws {
        let image = try DiskImage.make(for: self, name: "save-vanish", sizeMegabytes: 8)
        let root = try makeDataDirectory(on: image)
        PersistenceFailureCenter.shared.reset()
        defer { PersistenceFailureCenter.shared.reset() }

        let good = Library(folders: [BookFolder(name: "Tide Tables")])
        XCTAssertTrue(LibraryPersistenceService.saveAndWait(good))
        let indexURL = root.appendingPathComponent("library.json")
        let goodBytes = try Data(contentsOf: indexURL)
        // The good index must be on the image, not in the kernel's cache,
        // before the volume is pulled.
        sync()
        let before = try FolderSnapshot(of: image.mountPoint)

        XCTAssertTrue(image.detach(), "the volume would not detach")
        let newer = Library(folders: [BookFolder(name: "Tide Tables"), BookFolder(name: "Harbour Notes")])
        XCTAssertFalse(LibraryPersistenceService.saveAndWait(newer), "a save to a missing volume claimed to succeed")

        let failure = try XCTUnwrap(PersistenceFailureCenter.shared.outstandingFailures().first, "no failure was recorded")
        XCTAssertEqual(failure.subsystem, .libraryIndex)
        XCTAssertEqual(
            failure.sentence,
            "Library changes could not be saved: The library at \(root.path) isn't available.",
            "the wording the user hears"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: image.mountPoint.path), [],
            "the save recreated the data directory on the Mac's own disk"
        )

        try image.attach()
        XCTAssertEqual(try Data(contentsOf: indexURL), goodBytes, "library.json is not the last good one")
        XCTAssertEqual(try FolderSnapshot(of: image.mountPoint).differences(from: before), [])

        XCTAssertTrue(LibraryPersistenceService.saveAndWait(newer), "the save did not succeed with the volume back")
        XCTAssertEqual(PersistenceFailureCenter.shared.outstandingFailures().count, 0, "the failure was not settled by the later save")
    }

    // MARK: - 4. A Move Whose Destination Vanishes

    /// A data-directory move copies into a volume that is unplugged after a
    /// few items. The move fails, every file of the source has the checksum
    /// it had, the data directory in use and the setting still name the
    /// source, and no published copy exists at the destination. The hidden
    /// staged copy, which the move could not remove while the volume was
    /// away, is on the volume when it returns, with its note on this Mac's
    /// journal; the launch sweep removes it and forgets the note.
    @MainActor
    func testAMoveWhoseDestinationVanishesLeavesTheSourceComplete() throws {
        let image = try DiskImage.make(for: self, name: "move-vanish", sizeMegabytes: 16)
        // Start and end with no journal of staging folders, so the notes
        // counted below are this move's alone.
        let journal = MachineLocalPaths.moveLeftovers
        try? FileManager.default.removeItem(at: journal)
        addTeardownBlock { try? FileManager.default.removeItem(at: journal) }
        let source = try makeSourceLibrary()
        let sourceBefore = try FolderSnapshot(of: source)
        let rootBefore = TextMouthPaths.root
        let settingBefore = ConfigService.shared.config.dataDirectoryPath
        let destination = image.mountPoint.appendingPathComponent("Moved Data", isDirectory: true)

        let unplugged = OneShot()
        let observer = DataDirectoryCopyObserver(
            report: { progress in
                if progress.copiedItems >= 3, unplugged.fire() { image.detach() }
            },
            isCancelled: { false }
        )
        let thrown: Error? = DataDirectoryMigrator.$copyObserver.withValue(observer) { () -> Error? in
            do {
                _ = try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: Library())
                return nil
            } catch {
                return error
            }
        }

        XCTAssertNotNil(thrown, "the move reported success although the destination vanished")
        XCTAssertFalse(image.isAttached, "the copy never unplugged the volume")
        XCTAssertEqual(try FolderSnapshot(of: source).differences(from: sourceBefore), [], "the source changed")
        XCTAssertEqual(TextMouthPaths.root, rootBefore, "the data directory in use moved")
        XCTAssertEqual(ConfigService.shared.config.dataDirectoryPath, settingBefore, "the setting changed")

        try image.attach()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a copy was published at the destination")

        // The move could not remove its hidden staged copy while the volume
        // was away, so the copy is on the volume now, and the move's note of
        // it is still on this Mac's journal.
        let stagedLeftovers = try stagedCopies(on: image)
        XCTAssertEqual(stagedLeftovers.count, 1, "the vanished move left \(stagedLeftovers.count) staged copies: \(stagedLeftovers)")
        XCTAssertEqual(MigrationStagingLeftovers.readEntries().count, 1, "the move's note was forgotten with its folder still there")

        // The launch sweep removes exactly that copy, and forgets the note.
        MigrationStagingLeftovers.sweep(fileManager: .default)
        XCTAssertEqual(try stagedCopies(on: image), [], "the sweep left a staged copy on the volume")
        XCTAssertEqual(MigrationStagingLeftovers.readEntries(), [], "the journal still lists a folder")
    }

    // MARK: - Helpers

    /// The names of the hidden staged copies a data-directory move left on
    /// `image`'s volume.
    private func stagedCopies(on image: DiskImage) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: image.mountPoint.path)
            .filter { $0.hasPrefix(DataDirectoryMigrator.stagingNamePrefix) }
    }

    /// Makes the data directory in use a folder on `image` until the test
    /// ends, when the test process's own is put back. The image's teardown
    /// was registered before this, so it runs after the data directory is
    /// restored.
    @MainActor
    private func makeDataDirectory(on image: DiskImage) throws -> URL {
        // Registers the restoring of the data directory and its settings.
        _ = try makeDataDirectoryMoveDestination("StorageDrill")
        let root = image.mountPoint.appendingPathComponent("TextMouth", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Library", isDirectory: true),
            withIntermediateDirectories: true
        )
        StorageBoundary.shared.publish(root: root)
        addTeardownBlock { DataDirectoryGate.open(root) }
        try TextMouthPaths.ensureDirectoryStructure()
        return root
    }

    /// Writes a text book of about `kilobytes` KB in the sandbox, outside
    /// every image, and returns it.
    private func makeOriginal(_ name: String, kilobytes: Int) throws -> URL {
        let folder = try makeSandboxDirectory("DrillOriginals")
        let url = folder.appendingPathComponent(name)
        try Self.text(kilobytes: kilobytes, seed: name).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A data directory of known contents in the sandbox: config.json,
    /// library.json, and five book packages of about 300 KB each in one
    /// folder of the library.
    private func makeSourceLibrary() throws -> URL {
        let root = try makeSandboxDirectory("DrillMoveSource").appendingPathComponent("TextMouth", isDirectory: true)
        let shelf = root.appendingPathComponent("Library/Shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        try "{\"example\": true}".write(to: root.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "{\"folders\": []}".write(to: root.appendingPathComponent("library.json"), atomically: true, encoding: .utf8)
        for number in 1...5 {
            let package = shelf.appendingPathComponent("Book \(number).tmb", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Self.text(kilobytes: 300, seed: "book \(number)").write(
                to: package.appendingPathComponent("book.txt"), atomically: true, encoding: .utf8
            )
            try "{\"title\": \"Book \(number)\"}".write(
                to: package.appendingPathComponent("bookInfo.json"), atomically: true, encoding: .utf8
            )
        }
        return root
    }

    /// Imports `source` into the data directory in use, with `observer`
    /// told as each step begins, and returns the error it fails with, or nil
    /// when it succeeds.
    private func attemptImport(of source: URL, observer: ImportStepObserver?) -> Error? {
        do {
            _ = try FileImportService.importFileWithReport(from: source, observer: observer)
            return nil
        } catch {
            return error
        }
    }

    /// About `kilobytes` KB of distinct lines of text, varied by `seed`.
    private static func text(kilobytes: Int, seed: String) -> String {
        var lines: [String] = []
        var size = 0
        var number = 0
        while size < kilobytes * 1024 {
            number += 1
            let line = "\(seed), line \(number): the tide came in over the quay and the lamps were lit.\n"
            lines.append(line)
            size += line.utf8.count
        }
        return lines.joined()
    }
}

/// A flag that is raised once, from any thread: `fire()` is true only the
/// first time, so an observer unplugs a volume once however often it is
/// called.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// True the first time it is called, false after.
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
