import XCTest
@testable import TextMouth

/// The device's own sync files, the names of a sync folder, the preferences,
/// and the outbox (FR43, sections 3 and 4): a change is on the device's disk
/// before any copy, stays there offline, and leaves only once uploaded.
final class SyncOutboxTests: XCTestCase {
    /// A made-up book.
    private let book = UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID()

    /// One stamped entry, numbered by `n`.
    private func entry(_ n: Int) -> SyncEntry {
        SyncEntry(key: .book(book, .title), value: .string("Title \(n)"),
                  stamp: SyncStamp(wall: Int64(n), counter: 0, device: "dev-a"), byHand: false)
    }

    /// An outbox over a sandbox folder, plus a drive and the device's folder in it.
    private func makeWorld() throws -> (outbox: SyncOutbox, drive: SyncTestDrive, deviceFolder: URL, local: SyncLocalFiles) {
        let sandbox = try makeSandboxDirectory("sync-outbox")
        let local = SyncLocalFiles(root: sandbox.appendingPathComponent("own", isDirectory: true))
        let device = SyncDeviceState(deviceID: "dev-a", incarnation: UUID(), installID: "install", lastSeq: 0)
        let drive = SyncTestDrive(root: sandbox.appendingPathComponent("cloud", isDirectory: true))
        let deviceFolder = drive.root.appendingPathComponent("Devices/dev-a", isDirectory: true)
        try FileManager.default.createDirectory(at: deviceFolder, withIntermediateDirectories: true)
        return (SyncOutbox(local: local, device: device), drive, deviceFolder, local)
    }

    // MARK: - Names

    /// A change file's name has a 12-digit seq, and parses back.
    func testChangeFileNames() {
        XCTAssertEqual(SyncNames.changeFile(seq: 42, kind: .changes), "000000000042.changes.json")
        XCTAssertEqual(SyncNames.changeFile(seq: 7, kind: .snapshot), "000000000007.snapshot.json")
        XCTAssertEqual(SyncNames.parseChangeFile("000000000042.changes.json")?.seq, 42)
        XCTAssertEqual(SyncNames.parseChangeFile("000000000042.snapshot.json")?.kind, .snapshot)
        XCTAssertNil(SyncNames.parseChangeFile("42.changes.json"))
        XCTAssertNil(SyncNames.parseChangeFile("00000000004x.changes.json"))
        XCTAssertNil(SyncNames.parseChangeFile("000000000042.other.json"))
        XCTAssertNil(SyncNames.parseChangeFile("device.json"))
    }

    /// A blob's extension is 1 to 8 lower-case letters or digits, else `bin`.
    func testBlobNames() {
        let digest = String(repeating: "a", count: 64)
        XCTAssertTrue(SyncNames.isDigest(digest))
        XCTAssertFalse(SyncNames.isDigest(digest.uppercased()))
        XCTAssertEqual(SyncNames.blobName(sha256: digest, pathExtension: "EPUB"), digest + ".epub")
        XCTAssertEqual(SyncNames.blobName(sha256: digest, pathExtension: ""), digest + ".bin")
        XCTAssertEqual(SyncNames.blobName(sha256: digest, pathExtension: "toolongext"), digest + ".bin")
        XCTAssertEqual(SyncNames.blobName(sha256: digest, pathExtension: "m-4"), digest + ".bin")
        XCTAssertEqual(SyncNames.manifestName(sha256: digest), digest + ".manifest.json")
    }

    /// The sync preferences' keys are in the machine-local list, so config.json never carries them.
    func testPreferencesAreMachineLocal() {
        for key in SyncPreferences.keys {
            XCTAssertTrue(ConfigService.AppConfig.Portability.localStoreKeys.contains(key), key)
        }
        let store = makeSandboxedPreferences("sync-prefs")
        let first = SyncPreferences.installIDCreatingIfNeeded(in: store)
        XCTAssertEqual(SyncPreferences.installIDCreatingIfNeeded(in: store), first, "made once")
        XCTAssertNil(SyncPreferences.storeID.read(from: store), "inert until set up")
    }

    // MARK: - Local files

    /// Every local file reads back what it wrote; a missing file reads as nothing.
    func testLocalFilesRoundTrip() throws {
        let (_, _, _, local) = try makeWorld()
        XCTAssertNil(local.loadDevice())
        XCTAssertEqual(local.loadRegisters(), SyncRegisters())
        XCTAssertEqual(local.loadCursors(), SyncCursors())
        let state = SyncDeviceState(deviceID: "d", incarnation: UUID(), installID: "i", lastSeq: 4)
        try local.saveDevice(state)
        XCTAssertEqual(local.loadDevice(), state)
        let key = SyncKey.bookmark(book: book, id: book)
        let registers = SyncRegisters(entries: [key: SyncEntry(key: key, value: .null, stamp: SyncStamp(wall: 1, counter: 0, device: "d"), byHand: true)], throughSeq: 2)
        try local.saveRegisters(registers)
        XCTAssertEqual(local.loadRegisters(), registers)
        var baseline = SyncProjection()
        baseline.absorb([SyncEntry(key: .folder(book, .name), value: .string("F"), stamp: SyncStamp(wall: 1, counter: 0, device: "d"), byHand: false)])
        try local.saveBaseline(baseline)
        XCTAssertEqual(local.loadBaseline(), baseline)
        XCTAssertEqual(local.loadBaseline().values[.folder(book, .name)], .string("F"))
    }

    /// A damaged file reads as nothing, not a trap.
    func testDamagedLocalFileReadsAsNothing() throws {
        let (_, _, _, local) = try makeWorld()
        try local.prepare()
        try Data("{not json".utf8).write(to: local.registersURL)
        XCTAssertEqual(local.loadRegisters(), SyncRegisters())
    }

    // MARK: - The outbox

    /// A change is in the device's own outbox, numbered, before any copy exists (R3).
    func testAppendWritesTheOutboxFileFirst() throws {
        var (outbox, drive, deviceFolder, _) = try makeWorld()
        let seq = try outbox.append([entry(1), entry(2)])
        XCTAssertEqual(seq, 1)
        XCTAssertEqual(outbox.file(1, kind: .changes)?.entries.count, 2)
        XCTAssertEqual(outbox.file(1, kind: .changes)?.count, 2)
        XCTAssertEqual(outbox.pendingChanges, 2)
        XCTAssertEqual(try drive.list(deviceFolder), [], "nothing in the cloud yet")
        XCTAssertEqual(try outbox.append([entry(3)]), 2)
    }

    /// Offline, the copy is local and the file stays in the outbox until uploaded.
    func testChangesWaitUntilUploaded() async throws {
        var (outbox, drive, deviceFolder, _) = try makeWorld()
        drive.setOffline(true)
        drive.setUpload(.uploading)
        try outbox.append([entry(1)])
        let copied1 = try await outbox.copy(into: deviceFolder, using: drive)
        XCTAssertEqual(copied1, 1)
        try outbox.refreshUploads(in: deviceFolder, using: drive)
        XCTAssertEqual(outbox.pendingChanges, 1, "uploading still counts as waiting")
        XCTAssertNotNil(outbox.file(1, kind: .changes), "the file stays")
        drive.setUpload(.uploaded)
        try outbox.refreshUploads(in: deviceFolder, using: drive)
        XCTAssertEqual(outbox.pendingChanges, 0)
    }

    /// A file sent again keeps its name and bytes, and goes only once.
    func testNothingIsSentTwice() async throws {
        var (outbox, drive, deviceFolder, _) = try makeWorld()
        drive.setUpload(.uploading)
        try outbox.append([entry(1)])
        try await outbox.copy(into: deviceFolder, using: drive)
        let copied2 = try await outbox.copy(into: deviceFolder, using: drive)
        XCTAssertEqual(copied2, 0)
        XCTAssertEqual(drive.copiedNames, ["000000000001.changes.json"])
    }

    /// A copy deleted "in the cloud" before it uploaded is copied again, with the same bytes.
    func testAMissingCopyIsSentAgain() async throws {
        var (outbox, drive, deviceFolder, _) = try makeWorld()
        drive.setUpload(.uploading)
        try outbox.append([entry(1)])
        try await outbox.copy(into: deviceFolder, using: drive)
        let copy = deviceFolder.appendingPathComponent("000000000001.changes.json")
        let before = try Data(contentsOf: copy)
        try FileManager.default.removeItem(at: copy)
        let copied3 = try await outbox.copy(into: deviceFolder, using: drive)
        XCTAssertEqual(copied3, 1)
        XCTAssertEqual(try Data(contentsOf: copy), before)
    }

    /// Where the drive reports no state, a copy counts as sent but not confirmed.
    func testUnreportedUploadCountsAsSent() async throws {
        var (outbox, drive, deviceFolder, _) = try makeWorld()
        drive.setUpload(.notReported)
        try outbox.append([entry(1)])
        try await outbox.copy(into: deviceFolder, using: drive)
        try outbox.refreshUploads(in: deviceFolder, using: drive)
        XCTAssertEqual(outbox.pendingChanges, 0)
        XCTAssertEqual(outbox.index.items.first?.confirmed, false)
    }

    /// A refused upload stays counted as waiting, and the reason is returned.
    func testFailedUploadStaysAndSaysWhy() async throws {
        var (outbox, drive, deviceFolder, _) = try makeWorld()
        drive.setUpload(.failed(.outOfSpace))
        try outbox.append([entry(1)])
        try await outbox.copy(into: deviceFolder, using: drive)
        XCTAssertEqual(try outbox.refreshUploads(in: deviceFolder, using: drive), .outOfSpace)
        XCTAssertEqual(outbox.pendingChanges, 1)
    }

    /// A copy that stops half way records the files already copied and throws.
    func testInterruptedCopyKeepsWhatWasCopied() async throws {
        var (outbox, drive, deviceFolder, local) = try makeWorld()
        try outbox.append([entry(1)])
        try outbox.append([entry(2)])
        drive.failCopies(after: 1)
        do {
            _ = try await outbox.copy(into: deviceFolder, using: drive)
            XCTFail("the copy was stopped")
        } catch {}
        // A fresh start, as after a crash, reads the index from disk.
        var restarted = SyncOutbox(local: local, device: SyncDeviceState(deviceID: "dev-a", incarnation: UUID(), installID: "i", lastSeq: 0))
        XCTAssertEqual(restarted.index.items.map(\.state), [.copied, .written])
        drive.failCopies(after: nil)
        let copied4 = try await restarted.copy(into: deviceFolder, using: drive)
        XCTAssertEqual(copied4, 1)
        XCTAssertEqual(drive.copiedNames, ["000000000001.changes.json", "000000000002.changes.json"])
    }

    /// A file leaves the outbox only once it and a later snapshot have uploaded.
    func testFilesLeaveAfterALaterSnapshotUploaded() async throws {
        var (outbox, drive, deviceFolder, _) = try makeWorld()
        try outbox.append([entry(1)])
        try await outbox.copy(into: deviceFolder, using: drive)
        try outbox.refreshUploads(in: deviceFolder, using: drive)
        XCTAssertEqual(try outbox.retireUploaded(), 0, "no snapshot yet")
        try outbox.append([entry(1)], kind: .snapshot)
        try await outbox.copy(into: deviceFolder, using: drive)
        try outbox.refreshUploads(in: deviceFolder, using: drive)
        XCTAssertEqual(try outbox.retireUploaded(), 1)
        XCTAssertNil(outbox.file(1, kind: .changes))
        XCTAssertNotNil(outbox.file(2, kind: .snapshot), "the newest snapshot stays")
    }

    /// A file in the folder under an outbox name that can't be verified is not copied over and not marked: it is unreadable.
    func testAnUnverifiedPresentFileIsLeftPending() async throws {
        var (outbox, drive, deviceFolder, _) = try makeWorld()
        try outbox.append([entry(1)])
        // Another writer's file of the same name is in the folder and cannot be read yet.
        try drive.write(Data("theirs".utf8), to: deviceFolder.appendingPathComponent(SyncNames.changeFile(seq: 1, kind: .changes)), replacing: false)
        drive.setNotDownloaded(SyncNames.changeFile(seq: 1, kind: .changes))
        let verified = try await outbox.verifiedPresent(in: deviceFolder, using: drive)
        XCTAssertTrue(verified.isEmpty)
        let plan = outbox.copyPlan(into: deviceFolder, using: drive, verified: verified)
        XCTAssertTrue(plan.toCopy.isEmpty)
        XCTAssertEqual(plan.unreadable, [SyncNames.changeFile(seq: 1, kind: .changes)])
        XCTAssertEqual(outbox.pendingChanges, 1, "still waiting, not marked sent")
    }

    /// A file a crash left unindexed is found and copied.
    func testUnindexedFileIsAdopted() async throws {
        var (outbox, drive, deviceFolder, local) = try makeWorld()
        try outbox.append([entry(1)])
        // The crash: the file exists, but the index and lastSeq never saw it.
        let orphan = SyncChangeFile(formatVersion: 1, deviceID: "dev-a", incarnation: outbox.device.incarnation,
                                    seq: 2, kind: .changes, count: 1, entries: [entry(2)])
        try SyncFormats.encode(orphan).write(to: local.outboxFolder.appendingPathComponent(SyncNames.changeFile(seq: 2, kind: .changes)))
        var restarted = SyncOutbox(local: local, device: outbox.device)
        XCTAssertEqual(try restarted.adoptUnindexedFiles(), 1)
        XCTAssertEqual(restarted.device.lastSeq, 2)
        let copied5 = try await restarted.copy(into: deviceFolder, using: drive)
        XCTAssertEqual(copied5, 2)
        XCTAssertEqual(restarted.entries(after: 1).count, 1, "what goes back into the registers")
    }
}
