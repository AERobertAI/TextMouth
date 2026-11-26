import XCTest
@testable import TextMouth

/// The sync folder and the reading of other devices' files (FR43, sections 3
/// and 7), on the stand-in drive: store.json is made once, Join waits a
/// bounded time, and a file not here yet holds a cursor, never the library.
final class SyncFolderTests: XCTestCase {
    /// A made-up book.
    private let book = UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID()

    /// A folder over a fresh sandbox drive.
    private func makeFolder() throws -> (folder: SyncFolder, drive: SyncTestDrive) {
        let drive = SyncTestDrive(root: try makeSandboxDirectory("sync-folder").appendingPathComponent("TextMouth Sync", isDirectory: true))
        return (SyncFolder(root: drive.root, access: drive), drive)
    }

    /// A change file of `device` with `seq`, holding one entry.
    private func changeFile(device: String, seq: Int, kind: SyncChangeFile.Kind = .changes, count: Int? = nil) -> SyncChangeFile {
        let entry = SyncEntry(key: .book(book, .title), value: .string("T\(seq)"),
                              stamp: SyncStamp(wall: Int64(seq), counter: 0, device: device), byHand: false)
        return SyncChangeFile(formatVersion: 1, deviceID: device, incarnation: UUID(), seq: seq, kind: kind, count: count ?? 1, entries: [entry])
    }

    /// Puts a change file into a device's folder, as another device's upload would.
    private func put(_ file: SyncChangeFile, in folder: SyncFolder) throws {
        try folder.access.write(SyncFormats.encode(file),
                                to: folder.deviceFolder(file.deviceID).appendingPathComponent(SyncNames.changeFile(seq: file.seq, kind: file.kind)),
                                replacing: false)
    }

    // MARK: - Making and reading the store

    /// Set Up Sync makes the folder and store.json; a second one is refused.
    func testCreateMakesTheStoreOnceAndRefusesAnExistingFolder() throws {
        let parent = try makeSandboxDirectory("sync-create")
        let made = try SyncFolder.create(in: parent, creator: "Mac", version: "0.6.0")
        XCTAssertEqual(made.folder.lastPathComponent, "TextMouth Sync")
        XCTAssertEqual(made.store.formatVersion, 1)
        XCTAssertThrowsError(try SyncFolder.create(in: parent, creator: "Mac", version: "0.6.0")) {
            XCTAssertEqual($0 as? SyncProblem, SyncProblem.exists)
        }
    }

    /// The store reads back; another store is told from this one; a later TextMouth's file is left alone.
    func testReadStore() async throws {
        let (folder, drive) = try makeFolder()
        let store = SyncStoreFile(formatVersion: 1, storeID: UUID(), created: Date(timeIntervalSince1970: 100), createdBy: "Mac", createdByVersion: "0.6.0")
        try drive.write(SyncFormats.encode(store), to: folder.storeURL, replacing: false)
        let read = try await folder.readStore(expecting: store.storeID, within: .seconds(1))
        XCTAssertEqual(read, store)
        do {
            _ = try await folder.readStore(expecting: UUID(), within: .seconds(1))
            XCTFail("another store")
        } catch { XCTAssertEqual(error as? SyncProblem, .anotherStore) }
    }

    /// A folder with no store.json, or a damaged one, is not a sync folder; a higher version is a later TextMouth's.
    func testNotASyncFolderAndLaterVersion() async throws {
        let (folder, drive) = try makeFolder()
        do {
            _ = try await folder.readStore(within: .seconds(1))
            XCTFail("missing")
        } catch { XCTAssertEqual(error as? SyncProblem, .notASyncFolder) }
        try drive.write(Data("{oops".utf8), to: folder.storeURL, replacing: true)
        do {
            _ = try await folder.readStore(within: .seconds(1))
            XCTFail("damaged")
        } catch { XCTAssertEqual(error as? SyncProblem, .notASyncFolder) }
        try drive.write(Data(#"{"formatVersion":2,"somethingNew":true}"#.utf8), to: folder.storeURL, replacing: true)
        do {
            _ = try await folder.readStore(within: .seconds(1))
            XCTFail("later")
        } catch { XCTAssertEqual(error as? SyncProblem, .laterVersion) }
    }

    /// Join waits for store.json in bounded steps, finds it when it arrives, and never makes one.
    func testJoinWaitsABoundedTimeAndNeverMakesTheStore() async throws {
        let (folder, drive) = try makeFolder()
        let slept = SleepLog()
        do {
            _ = try await folder.waitForStore(timeout: .seconds(60), interval: .seconds(2)) { await slept.add($0) }
            XCTFail("no store arrived")
        } catch { XCTAssertEqual(error as? SyncProblem, .notASyncFolder) }
        let total = await slept.total
        XCTAssertEqual(total, .seconds(60), "waited its limit, no longer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.storeURL.path), "Join never makes a store")

        // It arrives while waiting.
        let store = SyncStoreFile(formatVersion: 1, storeID: UUID(), created: Date(timeIntervalSince1970: 1), createdBy: "Mac", createdByVersion: "0.6.0")
        let data = try SyncFormats.encode(store)
        let arrived = try await folder.waitForStore(timeout: .seconds(60), interval: .seconds(2)) { _ in
            try drive.write(data, to: folder.storeURL, replacing: true)
        }
        XCTAssertEqual(arrived, store)
    }

    /// A store file still in the cloud only is waited for, too.
    func testJoinWaitsForAStoreNotDownloaded() async throws {
        let (folder, drive) = try makeFolder()
        let store = SyncStoreFile(formatVersion: 1, storeID: UUID(), created: Date(timeIntervalSince1970: 1), createdBy: "Mac", createdByVersion: "0.6.0")
        try drive.write(SyncFormats.encode(store), to: folder.storeURL, replacing: false)
        drive.setNotDownloaded(SyncNames.storeFile)
        let arrived = try await folder.waitForStore(timeout: .seconds(60), interval: .seconds(2)) { _ in
            drive.setNotDownloaded(SyncNames.storeFile, false)
        }
        XCTAssertEqual(arrived, store)
    }

    /// A missing folder is a problem the engine can say.
    func testFolderMissing() async throws {
        let (_, drive) = try makeFolder()
        drive.setFolderLost(true)
        do {
            _ = try await drive.withFolder { $0 }
            XCTFail("lost")
        } catch { XCTAssertEqual(error as? SyncProblem, .folderMissing) }
    }

    // MARK: - Reading other devices

    /// A reader of the folder as device `own`, with a test clock.
    private func reader(_ folder: SyncFolder, own: String = "dev-a", clock: TestClock? = nil, limits: SyncReadLimits = SyncReadLimits()) -> SyncReader {
        var reader = SyncReader(folder: folder, ownDeviceID: own, limits: limits)
        if let clock { reader.now = { clock.now } }
        return reader
    }

    /// Files read in order from the cursor; this device's own folder is skipped; a re-read changes nothing.
    func testReadsInOrderFromTheCursor() async throws {
        let (folder, _) = try makeFolder()
        for seq in 1...3 { try put(changeFile(device: "dev-b", seq: seq), in: folder) }
        try put(changeFile(device: "dev-a", seq: 1), in: folder)
        let first = try await reader(folder).read(after: SyncCursors())
        XCTAssertEqual(first.entries.map(\.stamp.wall), [1, 2, 3])
        XCTAssertEqual(first.cursors.merged, ["dev-b": 3])
        let again = try await reader(folder).read(after: first.cursors)
        XCTAssertTrue(again.entries.isEmpty)
        XCTAssertEqual(again.cursors, first.cursors)
    }

    /// A file not downloaded holds that device's cursor, and is read once it arrives.
    func testAFileNotDownloadedHoldsTheCursor() async throws {
        let (folder, drive) = try makeFolder()
        for seq in 1...3 { try put(changeFile(device: "dev-b", seq: seq), in: folder) }
        drive.setNotDownloaded(SyncNames.changeFile(seq: 2, kind: .changes))
        let held = try await reader(folder).read(after: SyncCursors())
        XCTAssertEqual(held.cursors.merged["dev-b"], 1)
        XCTAssertEqual(held.notArrived, ["dev-b"])
        drive.setNotDownloaded(SyncNames.changeFile(seq: 2, kind: .changes), false)
        let caughtUp = try await reader(folder).read(after: held.cursors)
        XCTAssertEqual(caughtUp.entries.map(\.stamp.wall), [2, 3])
        XCTAssertEqual(caughtUp.cursors.merged["dev-b"], 3)
        XCTAssertTrue(caughtUp.notArrived.isEmpty)
    }

    /// A file half there (undecodable, or the wrong count) is not here yet.
    func testAHalfWrittenFileIsNotHereYet() async throws {
        let (folder, drive) = try makeFolder()
        try put(changeFile(device: "dev-b", seq: 1), in: folder)
        try drive.write(Data("{\"half".utf8), to: folder.deviceFolder("dev-b").appendingPathComponent(SyncNames.changeFile(seq: 2, kind: .changes)), replacing: false)
        try put(changeFile(device: "dev-b", seq: 3, count: 5), in: folder)
        let result = try await reader(folder).read(after: SyncCursors())
        XCTAssertEqual(result.cursors.merged["dev-b"], 1)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.notArrived, ["dev-b"])
    }

    /// A later snapshot covers a file that never reads, and the cursor moves past it.
    func testALaterSnapshotCoversAFileThatNeverReads() async throws {
        let (folder, drive) = try makeFolder()
        try put(changeFile(device: "dev-b", seq: 1), in: folder)
        let first = try await reader(folder).read(after: SyncCursors())
        XCTAssertEqual(first.cursors.merged["dev-b"], 1)
        drive.setNotDownloaded(SyncNames.changeFile(seq: 2, kind: .changes))
        try put(changeFile(device: "dev-b", seq: 2), in: folder)
        try put(changeFile(device: "dev-b", seq: 3, kind: .snapshot), in: folder)
        try put(changeFile(device: "dev-b", seq: 4), in: folder)
        let result = try await reader(folder).read(after: first.cursors)
        XCTAssertEqual(result.cursors.merged["dev-b"], 4)
        XCTAssertEqual(result.entries.map(\.stamp.wall), [3, 4])
        XCTAssertTrue(result.notArrived.isEmpty)
    }

    /// iCloud Drive keeps no order: a small seq 3 that is listed before the large seq 1 and 2 never moves the
    /// cursor past them; they are read when they arrive, and nothing is skipped.
    func testAFileListedBeforeEarlierOnesDoesNotSkipThem() async throws {
        let (folder, _) = try makeFolder()
        try put(changeFile(device: "dev-b", seq: 3), in: folder)
        let early = try await reader(folder).read(after: SyncCursors())
        XCTAssertEqual(early.cursors.merged["dev-b"] ?? 0, 0, "seq 1 and 2 are not here yet")
        XCTAssertTrue(early.entries.isEmpty)
        XCTAssertEqual(early.notArrived, ["dev-b"])
        try put(changeFile(device: "dev-b", seq: 1), in: folder)
        try put(changeFile(device: "dev-b", seq: 2), in: folder)
        let later = try await reader(folder).read(after: early.cursors)
        XCTAssertEqual(later.entries.map(\.stamp.wall), [1, 2, 3])
        XCTAssertEqual(later.cursors.merged["dev-b"], 3)
    }

    /// A seq the device says it wrote but no listing shows yet holds the cursor too.
    func testTheDevicesOwnLastSeqIsExpected() async throws {
        let (folder, _) = try makeFolder()
        try put(changeFile(device: "dev-b", seq: 1), in: folder)
        try await folder.publishDevice(SyncDeviceFile(formatVersion: 1, deviceID: "dev-b", name: "iPhone", platform: "ios", appVersion: "0.6.0", lastSeq: 2, updated: Date(timeIntervalSince1970: 1)))
        let held = try await reader(folder).read(after: SyncCursors())
        XCTAssertEqual(held.cursors.merged["dev-b"], 1)
        XCTAssertEqual(held.notArrived, ["dev-b"], "seq 2 is promised but not listed")
        try put(changeFile(device: "dev-b", seq: 2), in: folder)
        let caught = try await reader(folder).read(after: held.cursors)
        XCTAssertEqual(caught.cursors.merged["dev-b"], 2)
        XCTAssertTrue(caught.notArrived.isEmpty)
    }

    /// A read that is refused for want of a network is noted, so the status can say offline.
    func testAnOfflineReadIsNoted() async throws {
        let (folder, drive) = try makeFolder()
        try put(changeFile(device: "dev-b", seq: 1), in: folder)
        drive.setNotDownloaded(SyncNames.changeFile(seq: 1, kind: .changes))
        drive.setOffline(true)
        let result = try await reader(folder).read(after: SyncCursors())
        XCTAssertTrue(result.sawOffline)
        XCTAssertEqual(result.cursors.merged["dev-b"] ?? 0, 0)
    }

    /// A device read for the first time starts at its newest snapshot.
    func testAFirstReadStartsAtTheNewestSnapshot() async throws {
        let (folder, _) = try makeFolder()
        try put(changeFile(device: "dev-b", seq: 1), in: folder)
        try put(changeFile(device: "dev-b", seq: 2, kind: .snapshot), in: folder)
        try put(changeFile(device: "dev-b", seq: 3), in: folder)
        let result = try await reader(folder).read(after: SyncCursors())
        XCTAssertEqual(result.entries.map(\.stamp.wall), [2, 3])
        XCTAssertEqual(result.cursors.merged["dev-b"], 3)
    }

    /// A later TextMouth's change file is left alone, and said.
    func testALaterFormatIsLeftAlone() async throws {
        let (folder, _) = try makeFolder()
        var later = changeFile(device: "dev-b", seq: 1)
        later.formatVersion = 2
        try put(later, in: folder)
        let result = try await reader(folder).read(after: SyncCursors())
        XCTAssertEqual(result.laterVersionFrom, "dev-b")
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.cursors.merged["dev-b"] ?? 0, 0, "the cursor stays at the start")
    }

    /// The device's name and last publish time are read from device.json.
    func testLastHeardFromDeviceFile() async throws {
        let (folder, _) = try makeFolder()
        let updated = Date(timeIntervalSince1970: 1_700_000_000)
        try await folder.publishDevice(SyncDeviceFile(formatVersion: 1, deviceID: "dev-b", name: "iPhone", platform: "ios", appVersion: "0.6.0", lastSeq: 0, updated: updated))
        let result = try await reader(folder).read(after: SyncCursors())
        XCTAssertEqual(result.lastHeard["dev-b"], updated)
        XCTAssertEqual(result.names["dev-b"], "iPhone")
    }

    /// Every read is bounded by the file limit, and a moment stops at its own limit.
    func testEveryWaitIsBounded() async throws {
        let (folder, drive) = try makeFolder()
        for device in ["dev-b", "dev-c"] { try put(changeFile(device: device, seq: 1), in: folder) }
        let clock = TestClock()
        var limits = SyncReadLimits()
        limits.perMoment = .seconds(120)
        _ = try await reader(folder, clock: clock, limits: limits).read(after: SyncCursors())
        XCTAssertFalse(drive.readLimits.isEmpty)
        XCTAssertTrue(drive.readLimits.allSatisfy { $0 <= .seconds(30) })

        // A clock that jumps 100 seconds at each reading: the moment's 120 seconds run out at once.
        var ticking = reader(folder, limits: limits)
        ticking.now = { clock.tick(.seconds(100)) }
        let result = try await ticking.read(after: SyncCursors())
        XCTAssertTrue(result.ranOutOfTime)
    }
}

/// Counts the time a waiting loop asked to sleep, without sleeping.
private actor SleepLog {
    private(set) var total = Duration.zero
    func add(_ duration: Duration) { total += duration }
}

/// A clock a test moves, so no test waits for real time.
///
/// `@unchecked Sendable`: `offset` is read and changed only under `lock`.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset = Duration.zero
    /// The current instant.
    var now: ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return origin + offset }
    /// Moves time on.
    func advance(_ duration: Duration) { lock.lock(); offset += duration; lock.unlock() }
    /// Moves time on and returns the new instant.
    func tick(_ duration: Duration) -> ContinuousClock.Instant { advance(duration); return now }
}
