import XCTest
@testable import TextMouth

/// Remove Download for a synced book (FR46): a device frees a book's files only when the sync folder
/// is proven to hold every one of them, and never removes the last copy. Each test names the behavior
/// it pins and fails when that behavior is taken out. Everything runs against the stand-in drive in
/// the test's own sandbox, never a real drive or the user's library.
final class StoreRemovalTests: XCTestCase {
    /// A made-up book.
    private let bookID = UUID(uuidString: "66666666-6666-6666-6666-666666666666") ?? UUID()

    /// The error a test throws from a checkpoint to stop a removal where a crash would.
    private struct Stop: Error {}

    /// A device that backed a book up and holds its package, over one stand-in drive.
    private struct World {
        var drive: SyncTestDrive
        var folder: SyncFolder
        var storeID: UUID
        var package: URL
        var staging: URL
        var backup: StoreBackupResult
        /// The bytes of each file of the package as it was made, by path.
        var originals: [String: Data]

        /// A removal over the world, which a test may change (a checkpoint, a smaller wait).
        var removal: StoreRemoval { StoreRemoval(folder: folder, storeID: storeID, staging: staging) }

        /// The URL of the file `path` in the package.
        func file(_ path: String) -> URL { package.appendingPathComponent(path) }

        /// The manifest's blob for `path`.
        func blob(of path: String) -> StoreManifest.File? { backup.manifest.files.first { $0.path == path } }

        /// Lets the files of the book's copy arrive again after a removal gave them up: the stand-in drive, unlike
        /// iCloud Drive, never downloads a file by being read, so a test that fetches says when it arrives.
        func letTheCopyArrive() {
            for entry in backup.manifest.files { drive.setNotDownloaded(entry.blob, false) }
            drive.setNotDownloaded(backup.manifestName, false)
        }
    }

    /// The book's own file, long enough to matter.
    private let text = Data("the book's own file, long enough to matter, and different from every other file".utf8)

    /// Backs a book of four files up and leaves the pointer as the backup wrote it.
    /// - Parameter content: The package's files by path; the book's own file and three others by default.
    private func makeWorld(content: [String: Data]? = nil) throws -> World {
        let sandbox = try makeSandboxDirectory("store-removal")
        let package = sandbox.appendingPathComponent("A.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let files = content ?? [
            "book.txt": text,
            "bookInfo.json": Data("{\"title\":\"Mine\"}".utf8),
            "content.md": Data("the text of the book, which stays".utf8),
            "contentIndex.json": Data("an index".utf8),
        ]
        for (path, data) in files {
            let url = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let drive = SyncTestDrive(root: sandbox.appendingPathComponent("cloud", isDirectory: true))
        let folder = SyncFolder(root: drive.root, access: drive)
        let storeID = UUID()
        let staging = sandbox.appendingPathComponent("Staging", isDirectory: true)
        let backup = try StoreBackup(folder: folder, storeID: storeID, staging: sandbox.appendingPathComponent("StagingBackup"))
            .back(up: package, bookID: bookID)
        return World(drive: drive, folder: folder, storeID: storeID, package: package, staging: staging, backup: backup, originals: files)
    }

    /// Everything about the package a refusal must leave alone: each file's bytes by path, and the pointer's.
    private func snapshot(of package: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let base = package.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey]) else { return result }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            result[String(url.standardizedFileURL.path.dropFirst(base.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }

    /// Runs the removal and checks it is refused with `expected`, leaving every file of the package, and the pointer,
    /// exactly as they were, and nothing in staging.
    private func assertRefused(
        _ expected: SyncRemovalRefusal, in world: World, mayDownload: Bool = true, removal: StoreRemoval? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let before = try snapshot(of: world.package)
        do {
            _ = try await (removal ?? world.removal).removeDownload(of: world.package, bookID: bookID, mayDownload: mayDownload)
            XCTFail("the removal was not refused", file: file, line: line)
        } catch let refusal as SyncRemovalRefusal {
            XCTAssertEqual(refusal, expected, file: file, line: line)
        }
        XCTAssertEqual(try snapshot(of: world.package), before, "a refusal changes nothing here", file: file, line: line)
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: world.staging.path)) ?? []
        XCTAssertEqual(staged, [], "nothing is left in staging", file: file, line: line)
    }

    // MARK: - What a removal does

    /// The book's own file goes; the record and the text stay; the pointer says the file is away and the rest is here;
    /// the folder's own copies are given up so the room is freed.
    func testTheBooksOwnFileGoesAndTheRecordAndTextStay() async throws {
        let world = try makeWorld()
        let outcome = try await world.removal.removeDownload(of: world.package, bookID: bookID, mayDownload: true)

        XCTAssertEqual(outcome.freedBytes, Int64(text.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.file("book.txt").path))
        for kept in ["bookInfo.json", "content.md", "contentIndex.json"] {
            XCTAssertEqual(try Data(contentsOf: world.file(kept)), world.originals[kept], kept)
        }
        let pointer = try XCTUnwrap(StoreFetch.pointer(in: world.package))
        XCTAssertEqual(pointer.manifest, world.backup.manifestName)
        XCTAssertEqual(pointer.uploaded, world.backup.manifestName)
        XCTAssertEqual(pointer.files.first { $0.path == "book.txt" }?.onThisDevice, false)
        XCTAssertEqual(pointer.files.filter(\.onThisDevice).map(\.path).sorted(), ["bookInfo.json", "content.md", "contentIndex.json"])
        XCTAssertTrue(StoreFetch.isMissingFiles(world.package), "the row says In Cloud")
        XCTAssertTrue(SyncPlaceholder.isPlaceholder(package: world.package, contentFile: world.file("book.txt")))
        // The folder's own copies of the blobs are given up, so the room is really freed.
        let listing = try world.drive.list(world.folder.bookFolder(bookID))
        XCTAssertTrue(listing.allSatisfy { !$0.isOnThisDevice }, "every blob was evicted")
    }

    /// Every wait is bounded (R2): each read of the folder was made with the removal's limit, and every blob was read.
    func testEveryBlobIsReadBackWithinTheLimit() async throws {
        let world = try makeWorld()
        _ = try await world.removal.removeDownload(of: world.package, bookID: bookID, mayDownload: true)
        let blobs = Set(world.backup.manifest.files.map(\.blob))
        // The manifest and each distinct blob: one read each.
        XCTAssertEqual(world.drive.readLimits.count, blobs.count + 1)
        XCTAssertTrue(world.drive.readLimits.allSatisfy { $0 == world.removal.perFile })
    }

    /// A book whose files are already away has nothing to remove: it is refused as such, never counted as removed
    /// with 0 bytes, and nothing changes.
    func testABookAlreadyAwayIsRefusedAsNothingToRemove() async throws {
        let world = try makeWorld()
        _ = try await world.removal.removeDownload(of: world.package, bookID: bookID, mayDownload: true)
        try await assertRefused(.nothingToRemove, in: world)
    }

    /// A book of tracks (its own files in a folder) goes as a folder, and one stray file in it blocks the removal.
    func testAFolderOfTracksGoesWholeAndAStrayFileBlocksIt() async throws {
        let tracks: [String: Data] = [
            "tracks/01.mp3": Data("track one".utf8), "tracks/02.mp3": Data("track two, longer".utf8),
            "bookInfo.json": Data("{\"title\":\"Tracks\"}".utf8),
        ]
        let world = try makeWorld(content: tracks)
        try Data("not in the store".utf8).write(to: world.file("tracks/extra.mp3"))
        try await assertRefused(.changedHere("tracks/extra.mp3"), in: world)

        try FileManager.default.removeItem(at: world.file("tracks/extra.mp3"))
        let outcome = try await world.removal.removeDownload(of: world.package, bookID: bookID, mayDownload: true)
        XCTAssertEqual(outcome.freedBytes, Int64(tracks["tracks/01.mp3"]?.count ?? 0) + Int64(tracks["tracks/02.mp3"]?.count ?? 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.file("tracks").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.file("bookInfo.json").path))
    }

    // MARK: - The review's fixes

    /// An edit rendered into the book's own file while its copy was read back is the only copy of that change: the
    /// removal stops, leaving the new file and the pointer as they were.
    func testAFileEditedDuringTheReadBackIsNotRemoved() async throws {
        let world = try makeWorld()
        let pointerBefore = try Data(contentsOf: world.file(StorePointer.fileName))
        var removal = world.removal
        let edited = world.file("book.txt")
        removal.checkpoint = { step in
            // After the read-back: the editor writes a new render over the file.
            if step == .proven { try Data("a new render, written meanwhile".utf8).write(to: edited) }
        }
        do {
            _ = try await removal.removeDownload(of: world.package, bookID: bookID, mayDownload: true)
            XCTFail("an edited file was removed")
        } catch let refusal as SyncRemovalRefusal {
            XCTAssertEqual(refusal, .changedHere("book.txt"))
        }
        XCTAssertEqual(try Data(contentsOf: edited), Data("a new render, written meanwhile".utf8))
        XCTAssertEqual(try Data(contentsOf: world.file(StorePointer.fileName)), pointerBefore, "the pointer was never written")
    }

    /// A file changed in place without a new size (only its time), a file replaced by another, and a track added
    /// during the read-back each stop the removal too.
    func testAnyChangeToTheBooksFilesDuringTheReadBackStopsTheRemoval() async throws {
        let tracks: [String: Data] = ["tracks/01.mp3": Data("track one".utf8), "bookInfo.json": Data("{}".utf8)]
        let changes: [(String, @Sendable (World) throws -> Void)] = [
            ("its time", { world in
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: world.file("tracks/01.mp3").path)
            }),
            ("replaced", { world in
                let data = try Data(contentsOf: world.file("tracks/01.mp3"))
                try FileManager.default.removeItem(at: world.file("tracks/01.mp3"))
                try data.write(to: world.file("tracks/01.mp3"))
            }),
            ("a track added", { world in try Data("track two".utf8).write(to: world.file("tracks/02.mp3")) }),
        ]
        for (name, change) in changes {
            let world = try makeWorld(content: tracks)
            var removal = world.removal
            removal.checkpoint = { step in if step == .proven { try change(world) } }
            do {
                _ = try await removal.removeDownload(of: world.package, bookID: bookID, mayDownload: true)
                XCTFail("\(name): the removal went on")
            } catch let refusal as SyncRemovalRefusal {
                guard case .changedHere = refusal else { return XCTFail("\(name): \(refusal)") }
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: world.file("tracks/01.mp3").path), name)
        }
    }

    /// A file of the book gone by the last look is a change too (an edit took a track away, or the package moved or
    /// went): the removal stops, the pointer is never written, and nothing is reported freed that it did not free.
    func testAFileDeletedHereDuringTheReadBackStopsTheRemoval() async throws {
        let world = try makeWorld()
        let pointerBefore = try Data(contentsOf: world.file(StorePointer.fileName))
        var removal = world.removal
        let gone = world.file("book.txt")
        removal.checkpoint = { step in if step == .proven { try FileManager.default.removeItem(at: gone) } }
        do {
            let outcome = try await removal.removeDownload(of: world.package, bookID: bookID, mayDownload: true)
            XCTFail("reported \(outcome.freedBytes) bytes freed for a file it never removed")
        } catch let refusal as SyncRemovalRefusal {
            XCTAssertEqual(refusal, .changedHere("book.txt"))
        }
        XCTAssertEqual(try Data(contentsOf: world.file(StorePointer.fileName)), pointerBefore, "the pointer was never written")
    }

    /// The library's last word stops the removal before the pointer is written: nothing here changes. With a yes it
    /// goes. It is asked on the main actor, about the package that is about to change.
    func testTheLibrarysLastWordStopsTheRemoval() async throws {
        let world = try makeWorld()
        var no = world.removal
        no.finalCheck = { _ in false }
        try await assertRefused(.busy, in: world, removal: no)

        var yes = world.removal
        let asked = NoteLog()
        yes.finalCheck = { package in
            asked.note(Thread.isMainThread ? package.standardizedFileURL.path : "off the main thread")
            return true
        }
        let outcome = try await yes.removeDownload(of: world.package, bookID: bookID, mayDownload: true)
        XCTAssertEqual(outcome.freedBytes, Int64(text.count))
        XCTAssertEqual(asked.notes, [world.package.standardizedFileURL.path])
    }

    // MARK: - The storage boundary

    /// While an operation holds the storage work (a data-directory move), the last look and the removal wait: the
    /// proof may run, but nothing in the package changes until the hold is released; then the book is freed.
    func testTheLastLookAndTheRemovalWaitWhileAMoveHoldsTheWork() async throws {
        let world = try makeWorld()
        let pointerBefore = try Data(contentsOf: world.file(StorePointer.fileName))
        let boundary = StorageBoundary(root: world.package.deletingLastPathComponent())
        let hold = try boundary.holdWork(for: .movingDataDirectory)
        let waiting = expectation(description: "the removal waits for the storage work")
        // Told once a removal meets the hold; never twice, but a second telling must not end the test host.
        waiting.assertForOverFulfill = false
        let asked = NoteLog()
        var removal = world.removal
        removal.boundary = boundary
        removal.whileHeld = { waiting.fulfill() }
        removal.finalCheck = { _ in asked.note("asked"); return true }
        let id = bookID
        let package = world.package
        let running = Task { try await removal.removeDownload(of: package, bookID: id, mayDownload: true) }

        await fulfillment(of: [waiting], timeout: 30)
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.file("book.txt").path), "nothing goes while the work is held")
        XCTAssertEqual(try Data(contentsOf: world.file(StorePointer.fileName)), pointerBefore, "nor is the pointer written")
        XCTAssertEqual(asked.notes, [], "the last look waits too")

        hold.release()
        let outcome = try await running.value
        XCTAssertEqual(outcome.freedBytes, Int64(text.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.file("book.txt").path))
        XCTAssertEqual(asked.notes, ["asked"])
    }

    /// A data-directory move published while the removal waited took the package to its new place: the last look is
    /// at the package there, whose files are other files than the ones hashed, so the removal stops, and neither copy
    /// of the package changes.
    func testAMovePublishedWhileTheRemovalWaitedIsSeenAtTheNewPlace() async throws {
        let world = try makeWorld()
        let oldRoot = world.package.deletingLastPathComponent()
        let newRoot = try makeSandboxDirectory("store-removal-moved")
        let moved = newRoot.appendingPathComponent(world.package.lastPathComponent, isDirectory: true)
        let boundary = StorageBoundary(root: oldRoot)
        let hold = try boundary.holdWork(for: .movingDataDirectory)
        let waiting = expectation(description: "the removal waits for the move")
        waiting.assertForOverFulfill = false
        var removal = world.removal
        removal.boundary = boundary
        removal.whileHeld = { waiting.fulfill() }
        let id = bookID
        let package = world.package
        let running = Task { try await removal.removeDownload(of: package, bookID: id, mayDownload: true) }

        await fulfillment(of: [waiting], timeout: 30)
        // The move copies the package and publishes the copy, as a data-directory move does.
        try FileManager.default.copyItem(at: world.package, to: moved)
        let movedBefore = try snapshot(of: moved)
        let oldBefore = try snapshot(of: world.package)
        boundary.publish(root: newRoot)
        hold.release()
        do {
            _ = try await running.value
            XCTFail("the removal went on at a package it never proved")
        } catch let refusal as SyncRemovalRefusal {
            guard case .changedHere = refusal else { return XCTFail("\(refusal)") }
        }
        XCTAssertEqual(try snapshot(of: moved), movedBefore, "the package where the move put it is whole")
        XCTAssertEqual(try snapshot(of: world.package), oldBefore, "and nothing was removed from the old place")
    }

    /// On a connection that costs, the refusal comes before anything is hashed: a changed file does not hide it.
    func testTheCostlyConnectionIsSaidBeforeAnythingIsHashed() async throws {
        let world = try makeWorld()
        try Data("edited here".utf8).write(to: world.file("book.txt"))
        world.drive.setNotDownloaded(try XCTUnwrap(world.blob(of: "content.md")).blob)
        try await assertRefused(.needsDownload, in: world, mayDownload: false)
    }

    /// A file's name is the book's title: no refusal's log line holds one.
    func testNoLogReasonNamesAFile() {
        let refusals: [SyncRemovalRefusal] = [
            .missingFromFolder("Secret Title.epub"), .notUploaded("Secret Title.epub"), .uploadFailed("Secret Title.epub"),
            .changedHere("Secret Title.epub"), .doesNotMatch("Secret Title.epub"), .couldNotRemove("Secret Title.epub"),
        ]
        for refusal in refusals { XCTAssertFalse(refusal.logReason.contains("Secret"), "\(refusal)") }
    }

    /// A backup never makes a manifest from a package whose pointer says a file is away: the file would be left out
    /// of what every device takes for the book's copy.
    func testABackupRefusesAPackageWithAFileAway() async throws {
        let world = try makeWorld()
        _ = try await world.removal.removeDownload(of: world.package, bookID: bookID, mayDownload: true)
        let backup = StoreBackup(folder: world.folder, storeID: world.storeID, staging: world.staging)
        XCTAssertThrowsError(try backup.back(up: world.package, bookID: bookID)) { error in
            XCTAssertEqual(error as? StoreBackup.FilesAreAway, StoreBackup.FilesAreAway())
        }
    }

    /// Recording that a book's copy has uploaded, after its own file was freed, does not mark the file as here: the
    /// row still says In Cloud, and Download Now still has the file to fetch.
    func testMarkingAnUploadAfterARemovalKeepsTheFileAway() async throws {
        let world = try makeWorld()
        _ = try await world.removal.removeDownload(of: world.package, bookID: bookID, mayDownload: true)
        let backup = StoreBackup(folder: world.folder, storeID: world.storeID, staging: world.staging)
        try backup.markUploaded(package: world.package, bookID: bookID, result: world.backup)
        let pointer = try XCTUnwrap(StoreFetch.pointer(in: world.package))
        XCTAssertEqual(pointer.files.first { $0.path == "book.txt" }?.onThisDevice, false)
        XCTAssertEqual(pointer.files.first { $0.path == "bookInfo.json" }?.onThisDevice, true)
        XCTAssertTrue(StoreFetch.isMissingFiles(world.package))
    }

    /// A book the backup still has queued, or whose upload is awaited, or that the registers do not hold, is not freed.
    func testTheBackupsStateForbidsFreeing() {
        let id = UUID()
        XCTAssertTrue(SyncCenter.backupForbidsFreeing(id, queued: [id], awaiting: [], recordedContent: [id]))
        XCTAssertTrue(SyncCenter.backupForbidsFreeing(id, queued: [], awaiting: [id], recordedContent: [id]))
        XCTAssertTrue(SyncCenter.backupForbidsFreeing(id, queued: [], awaiting: [], recordedContent: []))
        XCTAssertFalse(SyncCenter.backupForbidsFreeing(id, queued: [], awaiting: [], recordedContent: [id]))
    }

    // MARK: - The proof's every failure

    /// A book never backed up has no pointer: it stays, and it is not taken for backed up.
    func testNoPointerMeansNotBackedUp() async throws {
        let world = try makeWorld()
        try FileManager.default.removeItem(at: world.file(StorePointer.fileName))
        try await assertRefused(.notBackedUp, in: world)
    }

    /// A pointer of another store proves nothing about this one.
    func testAPointerOfAnotherStoreIsRefused() async throws {
        let world = try makeWorld()
        let other = StoreRemoval(folder: world.folder, storeID: UUID(), staging: world.staging)
        try await assertRefused(.notBackedUp, in: world, removal: other)
    }

    /// A blob the manifest names that is not in the folder: the book stays.
    func testAMissingBlobIsRefused() async throws {
        let world = try makeWorld()
        let blob = try XCTUnwrap(world.blob(of: "content.md")).blob
        try FileManager.default.removeItem(at: world.folder.bookFolder(bookID).appendingPathComponent(blob))
        try await assertRefused(.missingFromFolder(blob), in: world)
    }

    /// The manifest itself missing from the folder.
    func testAMissingManifestIsRefused() async throws {
        let world = try makeWorld()
        try FileManager.default.removeItem(at: world.folder.bookFolder(bookID).appendingPathComponent(world.backup.manifestName))
        try await assertRefused(.missingFromFolder(world.backup.manifestName), in: world)
    }

    /// An upload still going, or one the drive says nothing about, is no proof: only "uploaded" is.
    func testOnlyAnUploadTheDriveReportsDoneIsProof() async throws {
        let blob = try XCTUnwrap(try makeWorld().blob(of: "book.txt")).blob
        for state in [SyncTestDrive.Upload.uploading, .notReported] {
            let world = try makeWorld()
            world.drive.setUpload(state, forName: blob)
            try await assertRefused(.notUploaded(blob), in: world)
        }
        // A blob that is not the book's own still has to be uploaded: the whole copy is proven.
        let world = try makeWorld()
        let recordBlob = try XCTUnwrap(world.blob(of: "contentIndex.json")).blob
        world.drive.setUpload(.uploading, forName: recordBlob)
        try await assertRefused(.notUploaded(recordBlob), in: world)
    }

    /// The manifest not uploaded yet is no proof either.
    func testAManifestStillUploadingIsRefused() async throws {
        let world = try makeWorld()
        world.drive.setUpload(.uploading, forName: world.backup.manifestName)
        try await assertRefused(.notUploaded(world.backup.manifestName), in: world)
    }

    /// An upload the drive says failed (its room) is told apart from one still going.
    func testAFailedUploadIsRefused() async throws {
        let world = try makeWorld()
        let blob = try XCTUnwrap(world.blob(of: "book.txt")).blob
        world.drive.setUpload(.failed(.outOfSpace), forName: blob)
        try await assertRefused(.uploadFailed(blob), in: world)
    }

    /// A blob whose bytes are not the manifest's, of another size or of the same size, is refused: the read-back is
    /// the proof, whichever file of the copy it is.
    func testABlobThatDiffersWhenReadBackIsRefused() async throws {
        for path in ["book.txt", "content.md"] {
            for sameSize in [false, true] {
                let world = try makeWorld()
                let entry = try XCTUnwrap(world.blob(of: path))
                let tampered = sameSize ? Data(repeating: 0x58, count: Int(entry.size)) : Data("tampered, and a different size".utf8)
                try world.drive.write(tampered, to: world.folder.bookFolder(bookID).appendingPathComponent(entry.blob), replacing: true)
                try await assertRefused(.doesNotMatch(entry.blob), in: world)
            }
        }
    }

    /// A manifest whose bytes are not what its name says is refused.
    func testADamagedManifestIsRefused() async throws {
        let world = try makeWorld()
        try world.drive.write(Data("{}".utf8), to: world.folder.bookFolder(bookID).appendingPathComponent(world.backup.manifestName), replacing: true)
        try await assertRefused(.doesNotMatch(world.backup.manifestName), in: world)
    }

    /// A file here that is not the backed-up file, whether another size or the same size, is a change the folder does
    /// not hold: the book stays, so the change is not lost.
    func testAFileChangedHereIsRefused() async throws {
        for sameSize in [false, true] {
            let world = try makeWorld()
            let edited = sameSize ? Data(repeating: 0x59, count: text.count) : Data("edited here".utf8)
            try edited.write(to: world.file("book.txt"))
            try await assertRefused(.changedHere("book.txt"), in: world)
        }
    }

    /// A symbolic link in the package is never followed: the book stays.
    func testASymbolicLinkInThePackageIsRefused() async throws {
        let world = try makeWorld()
        try FileManager.default.createSymbolicLink(at: world.file("link"), withDestinationURL: world.file("book.txt"))
        try await assertRefused(.changedHere("link"), in: world)
    }

    /// Offline, with the blob away in the cloud, the copy can't be read back: the book stays, and it is said to be offline.
    func testOfflineWithABlobAwayIsRefused() async throws {
        let world = try makeWorld()
        let blob = try XCTUnwrap(world.blob(of: "book.txt")).blob
        world.drive.setNotDownloaded(blob)
        world.drive.setOffline(true)
        try await assertRefused(.offline, in: world)
    }

    /// A blob that never arrives within the limit: the book stays.
    func testABlobThatNeverArrivesIsRefused() async throws {
        let world = try makeWorld()
        let blob = try XCTUnwrap(world.blob(of: "book.txt")).blob
        world.drive.setNotDownloaded(blob)
        try await assertRefused(.folderUnreachable, in: world)
    }

    /// On a connection that costs, a copy that has to be downloaded to be read back waits: nothing is downloaded, and
    /// a copy already on this device is read back without a download.
    func testACostlyConnectionNeverDownloadsToProve() async throws {
        let world = try makeWorld()
        let blob = try XCTUnwrap(world.blob(of: "book.txt")).blob
        world.drive.setNotDownloaded(blob)
        try await assertRefused(.needsDownload, in: world, mayDownload: false)

        world.drive.setNotDownloaded(blob, false)
        let outcome = try await world.removal.removeDownload(of: world.package, bookID: bookID, mayDownload: false)
        XCTAssertEqual(outcome.freedBytes, Int64(text.count))
    }

    // MARK: - The order, and a stop at each step

    /// For every content file of the manifest, the book is whole here or its blob in the folder is whole; and the
    /// pointer never says a file is here that is not.
    private func assertNeitherLost(_ world: World, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        for entry in world.backup.manifest.files where StoreBackup.role(of: entry.path) == "content" {
            let local = world.file(entry.path)
            let hereWhole = (try? FileDigest.sha256(of: local)) == entry.sha256
            let blobURL = world.folder.bookFolder(bookID).appendingPathComponent(entry.blob)
            let blobWhole = (try? FileDigest.sha256(of: blobURL)) == entry.sha256
            XCTAssertTrue(hereWhole || blobWhole, "\(entry.path) is neither here nor in the folder: \(message)", file: file, line: line)
        }
        if let pointer = StoreFetch.pointer(in: world.package) {
            for entry in pointer.files where entry.onThisDevice {
                XCTAssertTrue(FileManager.default.fileExists(atPath: world.file(entry.path).path), "the pointer says \(entry.path) is here: \(message)", file: file, line: line)
            }
        }
    }

    /// A stop at each step, as a crash would, leaves the book whole or a placeholder whose blobs are proven, never
    /// neither; the pointer is written only after the proof and before the first file goes; and starting again
    /// finishes, and the book comes back whole through a fetch.
    func testAStopAtEveryStepLeavesTheBookWholeOrProven() async throws {
        let steps: [StoreRemoval.Step] = [.proven, .pointerWritten, .removed("book.txt"), .allRemoved]
        for stopAt in steps {
            let world = try makeWorld()
            let pointerBefore = try Data(contentsOf: world.file(StorePointer.fileName))
            var removal = world.removal
            removal.checkpoint = { step in if step == stopAt { throw Stop() } }
            do {
                _ = try await removal.removeDownload(of: world.package, bookID: bookID, mayDownload: true)
                XCTFail("the run was not stopped at \(stopAt)")
            } catch is Stop {}

            try assertNeitherLost(world, "stopped at \(stopAt)")
            let pointerNow = try Data(contentsOf: world.file(StorePointer.fileName))
            switch stopAt {
            case .proven:
                XCTAssertEqual(pointerNow, pointerBefore, "the pointer is written only after the proof")
                XCTAssertEqual(try snapshot(of: world.package), world.originals.merging([StorePointer.fileName: pointerBefore]) { $1 }, "nothing has changed yet")
            case .pointerWritten:
                XCTAssertNotEqual(pointerNow, pointerBefore)
                XCTAssertTrue(FileManager.default.fileExists(atPath: world.file("book.txt").path), "the pointer comes before the first file goes")
            case .removed, .allRemoved:
                XCTAssertFalse(FileManager.default.fileExists(atPath: world.file("book.txt").path))
            }

            // Starting again finishes the removal whatever the stop left; a stop after the last file went has nothing left
            // to remove, which is said as such.
            do {
                _ = try await world.removal.removeDownload(of: world.package, bookID: bookID, mayDownload: true)
            } catch SyncRemovalRefusal.nothingToRemove {
                XCTAssertFalse(FileManager.default.fileExists(atPath: world.file("book.txt").path), "nothing was left after \(stopAt)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: world.file("book.txt").path), "finished after a stop at \(stopAt)")
            try assertNeitherLost(world, "finished after a stop at \(stopAt)")

            // And a fetch brings the whole book back, byte for byte.
            world.letTheCopyArrive()
            let fetch = StoreFetch(folder: world.folder, storeID: world.storeID, staging: world.staging)
            try await fetch.fetch(package: world.package)
            XCTAssertEqual(try Data(contentsOf: world.file("book.txt")), text, "reopened after a stop at \(stopAt)")
            XCTAssertFalse(StoreFetch.isMissingFiles(world.package))
        }
    }

    /// A stop after the pointer says the file is away, with the file still here, is mended by a fetch with no copy of
    /// the file: it is the same file, so it is kept, and the book is whole again.
    func testAFetchAfterAStopKeepsTheFileThatIsStillHere() async throws {
        let world = try makeWorld()
        var removal = world.removal
        removal.checkpoint = { step in if step == .pointerWritten { throw Stop() } }
        do { _ = try await removal.removeDownload(of: world.package, bookID: bookID, mayDownload: true) } catch is Stop {}
        XCTAssertTrue(StoreFetch.isMissingFiles(world.package), "the pointer says the file is away")

        // Offline, nothing can be read from the folder, yet the fetch finishes: it needs no blob it already has here.
        world.drive.setOffline(true)
        for entry in world.backup.manifest.files { world.drive.setNotDownloaded(entry.blob) }
        let fetch = StoreFetch(folder: world.folder, storeID: world.storeID, staging: world.staging)
        try await fetch.fetch(package: world.package)
        XCTAssertFalse(StoreFetch.isMissingFiles(world.package))
        XCTAssertEqual(try Data(contentsOf: world.file("book.txt")), text)
    }

    // MARK: - Through the book storage

    /// The storage over a synced library: the live storage answers every book, the removal goes through `remover`.
    private func storage(
        isSyncOn: Bool = true, live: FakeBookCloudStorage = FakeBookCloudStorage(location: .local),
        fetcher: @escaping @Sendable (BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error> = { _ in AsyncThrowingStream { $0.finish() } },
        remover: @escaping @Sendable (BookPackage, Bool) async throws -> Void
    ) -> StoreBookStorage {
        StoreBookStorage(wrapping: live, isSyncOn: { isSyncOn }, fetcher: fetcher, remover: remover)
    }

    /// A package at `url` for the book.
    private func package(_ url: URL) -> BookPackage {
        BookPackage(bookID: bookID, url: url, isPackage: true, isAudio: false)
    }

    /// With sync off the live storage answers, and the proof is not asked for.
    func testWithSyncOffTheLiveStorageRemoves() async throws {
        let live = FakeBookCloudStorage(location: .cloud(.iCloudDrive))
        let asked = AskedLog()
        let storage = storage(isSyncOn: false, live: live) { _, _ in asked.note() }
        try await storage.removeDownloadAsync(of: package(URL(fileURLWithPath: "/Users/reader/A.tmb")), mayDownload: true)
        XCTAssertEqual(live.downloadsRemoved, [bookID])
        XCTAssertEqual(asked.count, 0, "no proof is made for a library that is not synced")
    }

    /// With sync off, a library that is not in a cloud folder has nothing to prove: the removal is refused, never
    /// reported done when nothing was removed.
    func testWithSyncOffALocalLibraryRefusesInsteadOfReportingSuccess() async throws {
        let live = FakeBookCloudStorage(location: .local)
        let storage = storage(isSyncOn: false, live: live) { _, _ in }
        do {
            try await storage.removeDownloadAsync(of: package(URL(fileURLWithPath: "/Users/reader/A.tmb")), mayDownload: true)
            XCTFail("nothing was removed, and success was reported")
        } catch let error as BookCloudError {
            XCTAssertEqual(error, .syncRemoval(.notBackedUp))
        }
        XCTAssertEqual(live.downloadsRemoved, [])
    }

    /// An error that is none of the proof's is said in the app's words, never the system's, which names a file.
    func testAnUnexpectedErrorBecomesTheAppsWords() async throws {
        struct Odd: LocalizedError { var errorDescription: String? { "The file “Secret Title.epub” could not be opened." } }
        let storage = storage { _, _ in throw Odd() }
        do {
            try await storage.removeDownloadAsync(of: package(URL(fileURLWithPath: "/Users/reader/A.tmb")), mayDownload: true)
            XCTFail("the removal threw")
        } catch let error as BookCloudError {
            XCTAssertEqual(error, .syncRemoval(.couldNotRemove("")))
            XCTAssertFalse(error.explanation(in: nil, isPhone: false).contains("Secret"))
        }
    }

    /// A proof that falls short reaches the caller as the cloud error that names it, whose words are the sync's.
    func testARefusalBecomesTheCloudErrorWithItsWords() async throws {
        let storage = storage { _, _ in throw SyncRemovalRefusal.offline }
        do {
            try await storage.removeDownloadAsync(of: package(URL(fileURLWithPath: "/Users/reader/A.tmb")), mayDownload: true)
            XCTFail("the proof fell short")
        } catch let error as BookCloudError {
            XCTAssertEqual(error, .syncRemoval(.offline))
            XCTAssertEqual(error.explanation(in: nil, isPhone: false), SyncWording.removalRefusal(.offline, isPhone: false))
            XCTAssertEqual(error.explanation(in: nil, isPhone: true), SyncWording.removalRefusal(.offline, isPhone: true))
        }
    }

    /// A book being fetched now keeps its files: the removal is refused without asking the proof.
    func testABookBeingFetchedIsNotRemoved() async throws {
        // A placeholder made by a removal, so that a download of it goes through the fetcher.
        let world = try makeWorld()
        _ = try await world.removal.removeDownload(of: world.package, bookID: bookID, mayDownload: true)
        let asked = AskedLog()
        let held = HeldFetch()
        let storage = storage(fetcher: { _ in held.stream() }, remover: { _, _ in asked.note() })
        let target = package(world.package)
        var iterator = storage.download(target).makeAsyncIterator()
        _ = try await iterator.next()
        do {
            try await storage.removeDownloadAsync(of: target, mayDownload: true)
            XCTFail("the book was being fetched")
        } catch let error as BookCloudError {
            XCTAssertEqual(error, .bookInUse)
        }
        XCTAssertEqual(asked.count, 0)
        held.finish()
    }

    /// A placeholder made here by a removal reopens as one fetched from another device does: it says In Cloud, knows
    /// its size, the download restores the file byte for byte, and then the book is whole.
    func testAPlaceholderMadeHereReopensThroughTheDownload() async throws {
        let world = try makeWorld()
        let removal = world.removal
        let fetch = StoreFetch(folder: world.folder, storeID: world.storeID, staging: world.staging)
        let storage = StoreBookStorage(
            wrapping: FakeBookCloudStorage(location: .local),
            isSyncOn: { true },
            fetcher: { target in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        do {
                            try await fetch.fetch(package: target.url) { files, bytes, totalFiles, totalBytes in
                                continuation.yield(BookDownloadProgress(completedFiles: files, totalFiles: totalFiles, completedBytes: bytes, totalBytes: totalBytes))
                            }
                            continuation.finish()
                        } catch { continuation.finish(throwing: error) }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            remover: { target, mayDownload in _ = try await removal.removeDownload(of: target.url, bookID: target.bookID, mayDownload: mayDownload) }
        )
        let target = package(world.package)
        XCTAssertEqual(storage.state(of: target), .downloaded, "whole here, the live storage's answer")

        try await storage.removeDownloadAsync(of: target, mayDownload: true)
        XCTAssertEqual(storage.state(of: target), .inCloud)
        XCTAssertEqual(storage.bytesToDownload(of: target), Int64(text.count))

        world.letTheCopyArrive()
        for try await _ in storage.download(target) {}
        XCTAssertEqual(try Data(contentsOf: world.file("book.txt")), text)
        XCTAssertEqual(storage.state(of: target), .downloaded, "whole again")
    }
}

/// How many times a closure was asked, from any thread.
/// The notes a test's closures make, in order, from any thread.
private final class NoteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String] = []
    func note(_ text: String) { lock.lock(); kept.append(text); lock.unlock() }
    var notes: [String] { lock.lock(); defer { lock.unlock() }; return kept }
}

private final class AskedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = 0
    func note() { lock.lock(); asked += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return asked }
}

/// A fetch that reports one step and then waits to be finished, so a test can act while a book is being fetched.
private final class HeldFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<BookDownloadProgress, Error>.Continuation?

    /// A stream that has yielded one step and stays open.
    func stream() -> AsyncThrowingStream<BookDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
            continuation.yield(BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 10, totalBytes: 20))
        }
    }

    /// Ends the stream.
    func finish() {
        lock.lock(); let held = continuation; lock.unlock()
        held?.finish()
    }
}
