import XCTest
@testable import TextMouth

/// The engine over the stand-in drive (FR43, sections 4 and 6): a device's
/// identity, what it keeps in its outbox, what an exchange copies, and what
/// two devices tell each other. The cases that need the merge itself
/// (`SyncRegisters.merge`) are marked, and pass once sync-core's branch is in.
final class SyncEngineTests: XCTestCase {
    /// A made-up book.
    private let book = UUID(uuidString: "66666666-6666-6666-6666-666666666666") ?? UUID()

    /// The identity of a device on install `install`.
    private func identity(_ name: String = "Mac", install: String = "install-1") -> SyncDeviceIdentity {
        SyncDeviceIdentity(name: name, platform: "macos", appVersion: "0.6.0", installID: install)
    }

    /// A device's own folder, in a sandbox.
    private func local(_ sandbox: URL, _ name: String) -> SyncLocalFiles {
        SyncLocalFiles(root: sandbox.appendingPathComponent(name, isDirectory: true))
    }

    /// A shared drive and a folder over it.
    private func makeDrive(_ sandbox: URL) -> (drive: SyncTestDrive, folder: SyncFolder) {
        let drive = SyncTestDrive(root: sandbox.appendingPathComponent("cloud", isDirectory: true))
        return (drive, SyncFolder(root: drive.root, access: drive))
    }

    // MARK: - Identity

    /// A new device makes its ID once, and a restart keeps it.
    func testADeviceKeepsItsIdentity() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-identity")
        let files = local(sandbox, "a")
        let first = try SyncEngine(local: files, identity: identity())
        let second = try SyncEngine(local: files, identity: identity())
        let firstID = await first.deviceID
        let secondID = await second.deviceID
        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(firstID, firstID.lowercased())
        XCTAssertEqual(files.loadDevice()?.installID, "install-1")
    }

    /// A library restored onto another install takes a new device ID and starts an empty outbox.
    func testAnotherInstallTakesANewID() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-restore")
        let files = local(sandbox, "a")
        let original = try SyncEngine(local: files, identity: identity(install: "install-1"))
        try await original.recordKeep(true, for: [book])
        let restored = try SyncEngine(local: files, identity: identity(install: "install-2"))
        let originalID = await original.deviceID
        let restoredID = await restored.deviceID
        XCTAssertNotEqual(originalID, restoredID)
        let pending = await restored.pendingChanges()
        XCTAssertEqual(pending, 0, "the old device's outbox is not this device's")
    }

    // MARK: - The outbox

    /// A change is in the device's own outbox before any copy exists, and counted as waiting.
    func testAChangeIsInTheOutboxFirst() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-outbox")
        let files = local(sandbox, "a")
        let engine = try SyncEngine(local: files, identity: identity())
        try await engine.recordKeep(true, for: [book, UUID()])
        let pending = await engine.pendingChanges()
        XCTAssertEqual(pending, 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: files.outboxFolder.path)
        XCTAssertEqual(names, [SyncNames.changeFile(seq: 1, kind: .changes)])
    }

    /// An exchange publishes the device, copies the outbox in, and a fresh device also publishes a snapshot.
    func testExchangeCopiesTheOutboxAndPublishesTheDevice() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-exchange")
        let (drive, folder) = makeDrive(sandbox)
        drive.setUpload(.uploading)
        let engine = try SyncEngine(local: local(sandbox, "a"), identity: identity())
        try await engine.recordKeep(true, for: [book])
        let result = try await engine.exchange(in: folder)
        XCTAssertEqual(result.pendingChanges, 1, "uploading counts as waiting")
        let id = await engine.deviceID
        let names = try drive.list(folder.deviceFolder(id)).map(\.name)
        XCTAssertTrue(names.contains(SyncNames.deviceFile))
        XCTAssertTrue(names.contains(SyncNames.changeFile(seq: 1, kind: .changes)))
        XCTAssertTrue(names.contains(SyncNames.changeFile(seq: 2, kind: .snapshot)), "a new device publishes a snapshot")
        // The device file says who this is.
        let data = try Data(contentsOf: folder.deviceFolder(id).appendingPathComponent(SyncNames.deviceFile))
        XCTAssertEqual((try? SyncFormats.decodeDeviceFile(data))?.name, "Mac")
    }

    /// Once uploaded, nothing waits.
    func testNothingWaitsOnceUploaded() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-uploaded")
        let (_, folder) = makeDrive(sandbox)
        let engine = try SyncEngine(local: local(sandbox, "a"), identity: identity())
        try await engine.recordKeep(true, for: [book])
        let result = try await engine.exchange(in: folder)
        XCTAssertEqual(result.pendingChanges, 0)
    }

    /// A device that only sends (the iPhone going to the background) reads nothing.
    func testSendOnlyReadsNothing() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-sendonly")
        let (drive, folder) = makeDrive(sandbox)
        let engine = try SyncEngine(local: local(sandbox, "a"), identity: identity())
        _ = try await engine.exchange(in: folder, readsOthers: false)
        XCTAssertTrue(drive.readLimits.isEmpty)
    }

    /// An offline drive: the copy is local, and the problem is the network's when a read is wanted.
    func testOfflineKeepsTheChangesAndCopiesThem() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-offline")
        let (drive, folder) = makeDrive(sandbox)
        drive.setOffline(true)
        drive.setUpload(.uploading)
        let engine = try SyncEngine(local: local(sandbox, "a"), identity: identity())
        try await engine.recordKeep(true, for: [book])
        let result = try await engine.exchange(in: folder)
        XCTAssertEqual(result.pendingChanges, 1)
        XCTAssertEqual(drive.copiedNames.count, 2, "the change file and the snapshot")
    }

    // MARK: - A book missing at launch (R7)

    /// A book missing at launch is not recorded as removed, however many times the library is recorded
    /// and even after the first apply (it is forgotten, not removed); a removal a person makes in the
    /// running app is recorded.
    func testAMissingBookIsNeverRemovedByTheLaunchButAPersonsRemovalIs() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-launch")
        let files = local(sandbox, "a")
        let kept = SyncTestFixtures.book()
        let engine = try SyncEngine(local: files, identity: identity())
        let recorded = try await engine.record(library: SyncTestFixtures.library(books: [kept])).recorded
        XCTAssertGreaterThan(recorded, 0)

        // The next launch: the book is missing, and stays so across several records.
        let relaunched = try SyncEngine(local: files, identity: identity())
        let empty = SyncTestFixtures.library()
        let first = try await relaunched.record(library: empty).recorded
        let second = try await relaunched.record(library: empty).recorded
        XCTAssertEqual([first, second], [0, 0])
        let presence = await relaunched.entry(for: .book(kept.id, .presence))
        XCTAssertEqual(presence?.value, .bool(true), "the book is still there in the registers")

        // The first apply could not put it back: it is forgotten, and no later record reports it removed.
        try await relaunched.settleLaunch(library: empty)
        let afterSettling = try await relaunched.record(library: empty).recorded
        XCTAssertEqual(afterSettling, 0)

        // A book a person removes in the running app is a removal.
        let other = SyncTestFixtures.book()
        let withOther = SyncTestFixtures.library(books: [other])
        let added = try await relaunched.record(library: withOther).recorded
        XCTAssertGreaterThan(added, 0)
        let removedCount = try await relaunched.record(library: empty).recorded
        XCTAssertEqual(removedCount, 1)
        let mark = await relaunched.entry(for: .book(other.id, .presence))
        XCTAssertEqual(mark?.value, .null)
    }

    // MARK: - Review items 2, 3, 4, 6, 15

    /// A library restored on the same install, whose folder already holds newer files of its device, takes a
    /// new identity and sends a snapshot, instead of finding its seqs "already there" and sending nothing.
    func testARestoredLibraryTakesANewIdentityAndIsHeard() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-restore-same-install")
        let (_, folder) = makeDrive(sandbox)
        let original = try SyncEngine(local: local(sandbox, "a"), identity: identity())
        let originalID = await original.deviceID
        for _ in 1...3 { try await original.recordKeep(true, for: [UUID()]) }
        _ = try await original.exchange(in: folder)

        // The library is restored from an older copy: it knows only the first file.
        let older = try makeSandboxDirectory("sync-engine-restore-copy")
        let restoredFiles = local(older, "a")
        try restoredFiles.prepare()
        try restoredFiles.saveDevice(SyncDeviceState(deviceID: originalID, incarnation: UUID(), installID: "install-1", lastSeq: 1))
        let restored = try SyncEngine(local: restoredFiles, identity: identity())
        let restoredBefore = await restored.deviceID
        XCTAssertEqual(restoredBefore, originalID)
        let result = try await restored.exchange(in: folder)
        XCTAssertTrue(result.tookNewIdentity)
        let restoredAfter = await restored.deviceID
        XCTAssertNotEqual(restoredAfter, originalID)
        let published = try FileManager.default.contentsOfDirectory(atPath: folder.deviceFolder(restoredAfter).path)
        XCTAssertTrue(published.contains(SyncNames.changeFile(seq: 1, kind: .snapshot)), "a snapshot under the new identity")
    }

    /// A mass removal, as index recovery makes, is held back and reported, not sent.
    func testAMassRemovalIsHeldBack() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-mass")
        let engine = try SyncEngine(local: local(sandbox, "a"), identity: identity())
        let books = (0..<6).map { _ in SyncTestFixtures.book() }
        let full = SyncTestFixtures.library(books: books)
        let initial = try await engine.record(library: full)
        XCTAssertGreaterThan(initial.recorded, 0)
        try await engine.settleLaunch(library: full)
        // The library empties at once, after the launch hold has settled.
        let emptied = try await engine.record(library: SyncTestFixtures.library())
        XCTAssertEqual(emptied.recorded, 0)
        XCTAssertEqual(emptied.heldRemovals, 6)
        let still = await engine.entry(for: .book(books[0].id, .presence))
        XCTAssertEqual(still?.value, .bool(true), "nothing was sent")
        // One or two removals are a person's.
        let two = SyncTestFixtures.library(books: Array(books.dropFirst(2)))
        let removed = try await engine.record(library: two)
        XCTAssertEqual(removed.recorded, 2)
        XCTAssertEqual(removed.heldRemovals, 0)
    }

    /// The feeds emptied at once are held back too (FR56), counted on their own, and one feed deleted is sent.
    func testAMassRemovalOfFeedsIsHeldBack() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-mass-feeds")
        let engine = try SyncEngine(local: local(sandbox, "a"), identity: identity())
        let library = SyncTestFixtures.library(books: (0..<6).map { _ in SyncTestFixtures.book() })
        let feeds = (0..<6).map { number in
            Feed(
                feedURL: URL(string: "https://example.com/\(number).xml") ?? URL(fileURLWithPath: "/"), folderID: UUID(),
                subscribedDate: Date(timeIntervalSince1970: 1_000)
            )
        }
        _ = try await engine.record(library: library, feeds: feeds)
        try await engine.settleLaunch(library: library, feeds: feeds)
        let emptied = try await engine.record(library: library, feeds: [])
        XCTAssertEqual(emptied.recorded, 0)
        XCTAssertEqual(emptied.heldFeedRemovals, 6)
        XCTAssertEqual(emptied.heldRemovals, 0, "no book was removed")
        let still = await engine.entry(for: .feed(feeds[0].id, .presence))
        XCTAssertEqual(still?.value, .bool(true), "nothing was sent")
        // Sync Now confirms them.
        await engine.confirmHeldRemovals()
        let sent = try await engine.record(library: library, feeds: [])
        XCTAssertEqual(sent.heldFeedRemovals, 0)
        XCTAssertEqual(sent.recorded, 6)
    }

    /// One feed deleted, the person's own, is sent at once.
    func testOneFeedRemovalIsSent() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-one-feed")
        let engine = try SyncEngine(local: local(sandbox, "a"), identity: identity())
        let feeds = (0..<6).map { number in
            Feed(
                feedURL: URL(string: "https://example.com/\(number).xml") ?? URL(fileURLWithPath: "/"), folderID: UUID(),
                subscribedDate: Date(timeIntervalSince1970: 1_000)
            )
        }
        _ = try await engine.record(library: SyncTestFixtures.library(), feeds: feeds)
        try await engine.settleLaunch(library: SyncTestFixtures.library(), feeds: feeds)
        let removed = try await engine.record(library: SyncTestFixtures.library(), feeds: Array(feeds.dropFirst()))
        XCTAssertEqual(removed.recorded, 1)
        XCTAssertEqual(removed.heldFeedRemovals, 0)
    }

    /// A confirmation is for the removals held when it was given: a different mass removal held later stays held.
    func testAConfirmationIsForTheHeldRemovalsOnly() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-confirm")
        let engine = try SyncEngine(local: local(sandbox, "a"), identity: identity())
        let first = (0..<6).map { _ in SyncTestFixtures.book() }
        let second = (0..<6).map { _ in SyncTestFixtures.book() }
        _ = try await engine.record(library: SyncTestFixtures.library(books: first))
        try await engine.settleLaunch(library: SyncTestFixtures.library(books: first))
        let held = try await engine.record(library: SyncTestFixtures.library())
        XCTAssertEqual(held.heldRemovals, 6)

        await engine.confirmHeldRemovals()
        let sent = try await engine.record(library: SyncTestFixtures.library())
        XCTAssertEqual(sent.heldRemovals, 0)
        XCTAssertEqual(sent.recorded, 6, "the confirmed removals were sent")

        // Another mass removal, not the one confirmed, is held although the confirmation is still in force.
        _ = try await engine.record(library: SyncTestFixtures.library(books: second))
        let other = try await engine.record(library: SyncTestFixtures.library())
        XCTAssertEqual(other.heldRemovals, 6, "a removal that was not held when Sync Now was pressed is held again")
    }

    /// The confirmation ends with its run: after it is cleared the same removals are held again.
    func testAConfirmationEndsWithItsRun() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-confirm-ends")
        let engine = try SyncEngine(local: local(sandbox, "a"), identity: identity())
        let books = (0..<6).map { _ in SyncTestFixtures.book() }
        _ = try await engine.record(library: SyncTestFixtures.library(books: books))
        try await engine.settleLaunch(library: SyncTestFixtures.library(books: books))
        _ = try await engine.record(library: SyncTestFixtures.library())
        await engine.confirmHeldRemovals()
        await engine.clearConfirmation()
        let again = try await engine.record(library: SyncTestFixtures.library())
        XCTAssertEqual(again.heldRemovals, 6, "the run ended; nothing is confirmed any more")
        XCTAssertEqual(again.recorded, 0)
    }

    /// A snapshot is due after 100 files, counted from the device's own record, so a restart doesn't forget them.
    func testASnapshotIsDueAfterManyFilesEvenAcrossRestarts() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-snapshots")
        let (_, folder) = makeDrive(sandbox)
        let files = local(sandbox, "a")
        var engine = try SyncEngine(local: files, identity: identity())
        _ = try await engine.exchange(in: folder)
        for index in 0..<100 {
            try await engine.recordKeep(true, for: [UUID()])
            if index % 40 == 39 { engine = try SyncEngine(local: files, identity: identity()) }
        }
        _ = try await engine.exchange(in: folder)
        let id = await engine.deviceID
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.deviceFolder(id).path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".snapshot.json") }.count, 2, "the first, and one after 100 files")
    }

    /// What was read is merged and the cursors are saved after the registers, so a crash between them never loses entries.
    func testTheCursorsAreSavedAfterTheRegisters() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-order")
        let (_, folder) = makeDrive(sandbox)
        let mac = try SyncEngine(local: local(sandbox, "mac"), identity: identity("Mac", install: "m"))
        let phoneFiles = local(sandbox, "phone")
        let phone = try SyncEngine(local: phoneFiles, identity: identity("iPhone", install: "p"))
        let book = UUID()
        try await mac.recordKeep(true, for: [book])
        _ = try await mac.exchange(in: folder)
        _ = try await phone.exchange(in: folder)
        // Whatever the cursors say was merged is in the saved registers.
        let cursors = phoneFiles.loadCursors()
        XCTAssertFalse(cursors.merged.isEmpty)
        XCTAssertNotNil(phoneFiles.loadRegisters().entries[.book(book, .keep)])
    }

    /// A save that fails after the outbox file was written does not make the next snapshot leave the change out: the
    /// same engine, not restarted, writes a snapshot, and a device that starts at it holds the change.
    func testASnapshotAfterAFailedSaveHoldsTheChange() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-snapshot-after-failed-save")
        let (_, folder) = makeDrive(sandbox)
        let mac = try SyncEngine(local: local(sandbox, "mac"), identity: identity("Mac", install: "m"))
        let phone = try SyncEngine(local: local(sandbox, "phone"), identity: identity("iPhone", install: "p"))
        let book = UUID()
        struct Stop: Error {}
        await mac.setStopAfter { step in if step == .outboxWrite { throw Stop() } }
        do {
            try await mac.recordKeep(true, for: [book])
            XCTFail("the save was stopped")
        } catch is Stop {}
        await mac.setStopAfter(nil)

        // Not restarted: its next exchange writes the snapshot a new device starts at.
        _ = try await mac.exchange(in: folder)
        _ = try await phone.exchange(in: folder)
        let kept = await phone.keptBookIDs()
        XCTAssertEqual(kept, [book], "the snapshot held the change the failed save left in memory")
    }

    /// A restore on the same install and the same incarnation, whose new records reach seqs the folder holds
    /// already with other bytes, is told from a copy of itself: it takes a new identity, and its changes are sent.
    func testARestoreThatRecordsPastTheFoldersNewestSeqIsHeard() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-restore-same-incarnation")
        let (_, folder) = makeDrive(sandbox)
        let originalFiles = local(sandbox, "a")
        let original = try SyncEngine(local: originalFiles, identity: identity())
        for _ in 1...3 { try await original.recordKeep(true, for: [UUID()]) }
        _ = try await original.exchange(in: folder)
        let originalID = await original.deviceID
        let incarnation = try XCTUnwrap(originalFiles.loadDevice()?.incarnation)

        // The library as it was after two files: the same ID and incarnation, an older outbox.
        let restoredFiles = local(try makeSandboxDirectory("sync-engine-restore-older"), "a")
        try restoredFiles.prepare()
        try restoredFiles.saveDevice(SyncDeviceState(deviceID: originalID, incarnation: incarnation, installID: "install-1", lastSeq: 2))
        let restored = try SyncEngine(local: restoredFiles, identity: identity())
        let mine = UUID()
        try await restored.recordKeep(true, for: [mine])
        try await restored.recordKeep(true, for: [UUID()])
        try await restored.recordKeep(true, for: [UUID()])
        // It now sits at seq 5; the folder holds 1 to 4 of the original, whose 3 and 4 are not its own.
        let result = try await restored.exchange(in: folder, readsOthers: false)
        XCTAssertTrue(result.tookNewIdentity)
        let newID = await restored.deviceID
        XCTAssertNotEqual(newID, originalID)
        let published = try FileManager.default.contentsOfDirectory(atPath: folder.deviceFolder(newID).path)
        XCTAssertTrue(published.contains(where: { $0.hasSuffix(".snapshot.json") }), "its state is sent, as a snapshot")
        let ownFolder = try FileManager.default.contentsOfDirectory(atPath: folder.deviceFolder(originalID).path)
        XCTAssertEqual(ownFolder.filter { $0.hasSuffix(".changes.json") }.count, 3, "the original's files were not touched")
    }

    /// The cursors are saved after the registers: a stop between the two saves leaves the merged entries on disk
    /// and the cursors where they were, so the next exchange reads again and loses nothing.
    func testAStopBetweenTheSavesLosesNothing() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-between-saves")
        let (_, folder) = makeDrive(sandbox)
        let mac = try SyncEngine(local: local(sandbox, "mac"), identity: identity("Mac", install: "m"))
        let phoneFiles = local(sandbox, "phone")
        let phone = try SyncEngine(local: phoneFiles, identity: identity("iPhone", install: "p"))
        let book = UUID()
        try await mac.recordKeep(true, for: [book])
        _ = try await mac.exchange(in: folder)

        struct Stop: Error {}
        await phone.setStopAfter { step in if step == .registers { throw Stop() } }
        do {
            _ = try await phone.exchange(in: folder)
            XCTFail("the stop was not reached")
        } catch is Stop {}
        XCTAssertTrue(phoneFiles.loadCursors().merged.isEmpty, "the cursors were not saved before the registers")
        XCTAssertNotNil(phoneFiles.loadRegisters().entries[.book(book, .keep)], "the registers already hold what was read")

        // Started afresh, the next exchange reads again and ends with the same state.
        let restarted = try SyncEngine(local: phoneFiles, identity: identity("iPhone", install: "p"))
        _ = try await restarted.exchange(in: folder)
        let kept = await restarted.keptBookIDs()
        XCTAssertEqual(kept, [book])
        XCTAssertFalse(phoneFiles.loadCursors().merged.isEmpty)
    }

    // MARK: - Two devices (these need sync-core's merge)

    /// Keep on All Devices set on one device is kept on the other after both exchange.
    func testKeepCrossesDevices() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-two")
        let (_, folder) = makeDrive(sandbox)
        let mac = try SyncEngine(local: local(sandbox, "mac"), identity: identity("Mac", install: "m"))
        let phone = try SyncEngine(local: local(sandbox, "phone"), identity: identity("iPhone", install: "p"))
        try await mac.recordKeep(true, for: [book])
        _ = try await mac.exchange(in: folder)
        let result = try await phone.exchange(in: folder)
        XCTAssertTrue(result.changedKeys.contains(.book(book, .keep)))
        let kept = await phone.keptBookIDs()
        XCTAssertEqual(kept, [book])
        // A second exchange changes nothing, and a later switch off wins.
        let again = try await phone.exchange(in: folder)
        XCTAssertTrue(again.changedKeys.isEmpty)
        try await mac.recordKeep(false, for: [book])
        _ = try await mac.exchange(in: folder)
        _ = try await phone.exchange(in: folder)
        let after = await phone.keptBookIDs()
        XCTAssertTrue(after.isEmpty)
    }

    /// After a crash that kept an outbox file out of the registers, the next start puts it back.
    func testACrashedRecordIsFoundAtTheNextStart() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-crash")
        let files = local(sandbox, "a")
        let engine = try SyncEngine(local: files, identity: identity())
        try await engine.recordKeep(true, for: [book])
        // The crash: the registers never saw the file.
        try files.saveRegisters(SyncRegisters())
        let restarted = try SyncEngine(local: files, identity: identity())
        let kept = await restarted.keptBookIDs()
        XCTAssertEqual(kept, [book])
    }

    /// A content entry recorded by the backup is handed back as the book's content.
    func testContentIsRecordedAndRead() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-content")
        let engine = try SyncEngine(local: local(sandbox, "a"), identity: identity())
        let content = SyncContent(manifest: "m.manifest.json", format: .epub, dateAdded: Date(timeIntervalSince1970: 100), md5Hash: "abc", totalWordCount: 5, audioDuration: nil)
        try await engine.recordContent(content, for: book)
        let contents = await engine.contents()
        XCTAssertEqual(contents[book], content)
    }
}
