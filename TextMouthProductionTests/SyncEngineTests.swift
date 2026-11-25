import XCTest
@testable import TextMouth

/// The engine over the stand-in drive (FR43, sections 4 and 6): a device's
/// identity, what it keeps in its outbox, what an exchange copies, and what
/// two devices tell each other. The cases that need the merge itself
/// (`SyncRegisters.merge`) are marked, and pass once sync-core's branch is in.
final class SyncEngineTests: XCTestCase {
    /// A made-up book.
    private let book = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

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
        XCTAssertEqual(first.deviceID, second.deviceID)
        XCTAssertEqual(first.deviceID, first.deviceID.lowercased())
        XCTAssertEqual(files.loadDevice()?.installID, "install-1")
    }

    /// A library restored onto another install takes a new device ID and starts an empty outbox.
    func testAnotherInstallTakesANewID() async throws {
        let sandbox = try makeSandboxDirectory("sync-engine-restore")
        let files = local(sandbox, "a")
        let original = try SyncEngine(local: files, identity: identity(install: "install-1"))
        try await original.recordKeep(true, for: [book])
        let restored = try SyncEngine(local: files, identity: identity(install: "install-2"))
        XCTAssertNotEqual(original.deviceID, restored.deviceID)
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
        let names = try drive.list(folder.deviceFolder(engine.deviceID)).map(\.name)
        XCTAssertTrue(names.contains(SyncNames.deviceFile))
        XCTAssertTrue(names.contains(SyncNames.changeFile(seq: 1, kind: .changes)))
        XCTAssertTrue(names.contains(SyncNames.changeFile(seq: 2, kind: .snapshot)), "a new device publishes a snapshot")
        // The device file says who this is.
        let data = try Data(contentsOf: folder.deviceFolder(engine.deviceID).appendingPathComponent(SyncNames.deviceFile))
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
        let recorded = try await engine.record(library: SyncTestFixtures.library(books: [kept]))
        XCTAssertGreaterThan(recorded, 0)

        // The next launch: the book is missing, and stays so across several records.
        let relaunched = try SyncEngine(local: files, identity: identity())
        let empty = SyncTestFixtures.library()
        let first = try await relaunched.record(library: empty)
        let second = try await relaunched.record(library: empty)
        XCTAssertEqual([first, second], [0, 0])
        let presence = await relaunched.entry(for: .book(kept.id, .presence))
        XCTAssertEqual(presence?.value, .bool(true), "the book is still there in the registers")

        // The first apply could not put it back: it is forgotten, and no later record reports it removed.
        try await relaunched.settleLaunch(library: empty)
        let afterSettling = try await relaunched.record(library: empty)
        XCTAssertEqual(afterSettling, 0)

        // A book a person removes in the running app is a removal.
        let other = SyncTestFixtures.book()
        let withOther = SyncTestFixtures.library(books: [other])
        XCTAssertGreaterThan(try await relaunched.record(library: withOther), 0)
        XCTAssertEqual(try await relaunched.record(library: empty), 1)
        let mark = await relaunched.entry(for: .book(other.id, .presence))
        XCTAssertEqual(mark?.value, .null)
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
