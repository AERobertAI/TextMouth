import XCTest
@testable import TextMouth

/// A library host that holds an empty library and applies nothing.
@MainActor private final class StubHost: SyncLibraryHost {
    var library = Library()
    var maySyncNow = true
    var appliedCount = 0
    var lastKept: Set<UUID>?
    /// The library the last merge was computed from, as the center handed it over.
    var lastStart: Library?
    /// Whether the host leaves every key alone, as a busy library does.
    var defersEverything = false
    /// A pause a test puts in the apply, to look at what happens while it runs.
    var pauseApply: (@MainActor () async -> Void)?
    /// How often the center asked for the device's voices, and which it has.
    var voiceReads = 0
    var availableVoiceIDs: Set<String>? {
        voiceReads += 1
        return ["voice-1"]
    }
    func applySync(_ application: SyncApplication, from start: Library) async -> Set<SyncKey> {
        appliedCount += 1
        lastStart = start
        if let pauseApply { await pauseApply() }
        return defersEverything ? [] : application.appliedKeys
    }
    func syncDidApply(keptBookIDs: Set<UUID>, mayDownload: Bool) { lastKept = keptBookIDs }
}

/// The app's one sync (FR43): inert until a folder is chosen (R1), refusals
/// that name their reason (R6), set up, join, stop (which deletes nothing),
/// and what Sync Now says. Every folder is in the test's sandbox; the
/// location of a folder is a test's answer, so no iCloud Drive is touched.
@MainActor
final class SyncCenterTests: XCTestCase {
    /// Collects what the center says aloud.
    private final class Spoken: @unchecked Sendable {
        // `@unchecked Sendable`: `lines` is read and changed only on the main actor, where every test and the center run.
        var lines: [String] = []
    }

    /// A center in a sandbox, with the answers a test chooses.
    private struct World {
        var center: SyncCenter
        var host: StubHost
        var dataDirectory: URL
        var parent: URL
        var preferences: UserDefaults
        var spoken: Spoken
    }

    /// Makes a center whose library is at `library` and whose iCloud Drive folder is `drive`, by the answers of `locate`.
    private func makeWorld(
        library: StorageLocation = .local, folder: StorageLocation = .cloud(.iCloudDrive),
        renewedBookmark: @escaping @Sendable (Data) -> Data? = { _ in nil }
    ) throws -> World {
        let sandbox = try makeSandboxDirectory("sync-center")
        let dataDirectory = sandbox.appendingPathComponent("data", isDirectory: true)
        let parent = sandbox.appendingPathComponent("iCloud Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let preferences = makeSandboxedPreferences("sync-center")
        let spoken = Spoken()
        let dataPath = dataDirectory.standardizedFileURL.path
        let environment = SyncCenterEnvironment(
            preferences: preferences, deviceName: "Test Mac", platform: "macos", appVersion: "0.6.0", isPhone: false,
            makeAccess: { PlainSyncFolderAccess(bookmark: $0) },
            locate: { $0.standardizedFileURL.path.hasPrefix(dataPath) ? library : folder },
            makeBookmark: { DataDirectoryPreferences.makeBookmark(of: $0) },
            reachability: .online, now: { Date(timeIntervalSince1970: 1_700_000_000) },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            announce: { spoken.lines.append($0) },
            freeSpace: { _ in 100_000_000_000 },
            pauseWhileJoining: { _ in },
            renewedBookmark: renewedBookmark
        )
        return World(center: SyncCenter(environment: environment), host: StubHost(), dataDirectory: dataDirectory, parent: parent, preferences: preferences, spoken: spoken)
    }

    // MARK: - Inert until set up (R1)

    /// Before a folder is chosen: off, no file or folder made, and a moment does nothing.
    func testInertUntilSetUp() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        world.center.moment(.launch)
        world.center.libraryDidChange()
        world.center.syncNow()
        XCTAssertFalse(world.center.status.isOn)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: world.dataDirectory.path), [], "no Sync folder, nothing")
        XCTAssertTrue(world.spoken.lines.isEmpty)
        XCTAssertEqual(world.host.appliedCount, 0)
    }

    // MARK: - Refusals (R6)

    /// A library kept in a cloud folder is refused, in the words the section speaks.
    func testALibraryInTheCloudIsRefused() async throws {
        let world = try makeWorld(library: .cloud(.iCloudDrive))
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        do {
            try await world.center.setUp(in: world.parent)
            XCTFail("refused")
        } catch { XCTAssertEqual(error as? SyncProblem, .libraryNotLocal) }
        XCTAssertFalse(world.center.status.isOn)
        XCTAssertNil(SyncPreferences.storeID.read(from: world.preferences))
    }

    /// A folder outside iCloud Drive is refused.
    func testAFolderOutsideICloudDriveIsRefused() async throws {
        let world = try makeWorld(folder: .local)
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        do {
            try await world.center.setUp(in: world.parent)
            XCTFail("refused")
        } catch { XCTAssertEqual(error as? SyncProblem, .notInICloudDrive) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: world.parent.path), [], "no folder made")
    }

    // MARK: - Set up, join, stop

    /// Set Up Sync makes the folder and its store, joins it, and syncs once.
    func testSetUpMakesTheFolderAndJoinsIt() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        let folder = world.parent.appendingPathComponent("TextMouth Sync")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("store.json").path))
        XCTAssertTrue(world.center.status.isOn)
        XCTAssertNotNil(SyncPreferences.bookmark.read(from: world.preferences))
        XCTAssertNotNil(SyncPreferences.storeID.read(from: world.preferences))
        // The first run publishes this device.
        let deviceFolder = folder.appendingPathComponent("Devices", isDirectory: true)
        await world.center.waitUntilIdle()
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: deviceFolder.path))?.count, 1)
        XCTAssertFalse(world.center.status.isSyncing)
    }

    /// A second Set Up Sync into the same parent is refused (the folder is already there).
    func testSetUpTwiceIsRefused() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        world.center.stop()
        do {
            try await world.center.setUp(in: world.parent)
            XCTFail("refused")
        } catch { XCTAssertEqual(error as? SyncProblem, .exists) }
    }

    /// Joining a folder another device made uses its store; one with no store.json is not a sync folder.
    func testJoinNeedsAStore() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        let empty = world.parent.appendingPathComponent("Not Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        // Join waits a bounded time for a store that has not arrived; the test's pause is instant, so the wait ends at once.
        try Data("{oops".utf8).write(to: empty.appendingPathComponent("store.json"))
        do {
            try await world.center.join(empty)
            XCTFail("not a sync folder")
        } catch { XCTAssertEqual(error as? SyncProblem, .notASyncFolder) }
        XCTAssertFalse(world.center.status.isOn)
    }

    /// Stop forgets the folder and deletes nothing: the folder and the device's own files stay.
    func testStopDeletesNothing() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        let folder = world.parent.appendingPathComponent("TextMouth Sync")
        await world.center.waitUntilIdle()
        world.center.stop()
        XCTAssertFalse(world.center.status.isOn)
        XCTAssertNil(SyncPreferences.bookmark.read(from: world.preferences))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("store.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: world.dataDirectory.appendingPathComponent("Sync").path))
    }

    /// A launch after a join picks the folder up again by itself.
    func testALaterLaunchRejoins() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        let second = SyncCenter(environment: SyncCenterEnvironment(
            preferences: world.preferences, deviceName: "Test Mac", platform: "macos", appVersion: "0.6.0", isPhone: false,
            makeAccess: { PlainSyncFolderAccess(bookmark: $0) }, locate: { _ in .local },
            makeBookmark: { _ in nil }, reachability: .online, now: { Date() },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, announce: { _ in }, freeSpace: { _ in 100_000_000_000 }, pauseWhileJoining: { _ in }
        ))
        let host = StubHost()
        second.install(host: host, dataDirectory: world.dataDirectory)
        await second.waitUntilIdle()
        XCTAssertTrue(second.status.isOn)
        withExtendedLifetime(host) {}
    }

    // MARK: - Sync Now

    /// Sync Now says "Syncing." at once, then "Nothing new" when a run finds none.
    func testSyncNowAnnouncesItsOutcome() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        world.spoken.lines = []
        world.center.syncNow()
        XCTAssertEqual(world.spoken.lines.first, SyncWording.announceSyncing)
        try await waitUntil { world.spoken.lines.count >= 2 }
        XCTAssertEqual(world.spoken.lines, [SyncWording.announceSyncing, SyncWording.announceNothingNew])
    }

    /// While the host may not sync, a run does nothing and Sync Now says the state.
    func testNoRunWhileTheLibraryIsBusy() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        world.host.maySyncNow = false
        world.spoken.lines = []
        let before = world.host.appliedCount
        world.center.syncNow()
        try await waitUntil { world.spoken.lines.count >= 2 }
        XCTAssertEqual(world.host.appliedCount, before)
    }

    /// Keep on All Devices is stamped and shows in `keptBookIDs`.
    func testSetKeepShowsInTheKeptSet() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        let book = UUID()
        world.center.setKeep(true, for: [book])
        try await waitUntil { world.center.keptBookIDs == [book] }
    }

    /// An offline launch (the folder lost), and more moments after it, never record a book missing at launch as removed (R7).
    func testAnOfflineLaunchNeverRemovesWhatWasMissing() async throws {
        let world = try makeWorld()
        let book = SyncTestFixtures.book()
        world.host.library = SyncTestFixtures.library(books: [book])
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()

        // The next launch, with the folder lost and the book gone from the library.
        let storeID = try XCTUnwrap(world.center.storeID)
        let lost = SyncTestDrive(root: world.parent.appendingPathComponent("TextMouth Sync", isDirectory: true))
        lost.setFolderLost(true)
        let second = SyncCenter(environment: SyncCenterEnvironment(
            preferences: world.preferences, deviceName: "Test Mac", platform: "macos", appVersion: "0.6.0", isPhone: false,
            makeAccess: { _ in lost }, locate: { _ in .local }, makeBookmark: { _ in nil }, reachability: .online,
            now: { Date() }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, announce: { _ in },
            freeSpace: { _ in 100_000_000_000 }, pauseWhileJoining: { _ in }
        ))
        let emptyHost = StubHost()
        second.install(host: emptyHost, dataDirectory: world.dataDirectory)
        await second.waitUntilIdle()
        second.moment(.active)
        await second.waitUntilIdle()
        second.moment(.hourly)
        await second.waitUntilIdle()
        XCTAssertEqual(second.status.problem, .folderMissing)

        let files = SyncLocalFiles(syncFolder: world.dataDirectory.appendingPathComponent("Sync", isDirectory: true), storeID: storeID)
        let presence = files.loadRegisters().entries[.book(book.id, .presence)]
        XCTAssertEqual(presence?.value, .bool(true), "the book is not marked removed")
        withExtendedLifetime(emptyHost) {}
    }

    /// A bookmark the system found stale is replaced by the renewed one, in the preferences, at the next run.
    func testAStaleBookmarkIsRenewedAndKept() async throws {
        let renewed = Renewal()
        let world = try makeWorld(renewedBookmark: { _ in renewed.next() })
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        let folder = world.parent.appendingPathComponent("TextMouth Sync", isDirectory: true)
        let fresh = try XCTUnwrap(DataDirectoryPreferences.makeBookmark(of: folder))
        renewed.offer(fresh)
        world.center.moment(.active)
        await world.center.waitUntilIdle()
        XCTAssertEqual(SyncPreferences.bookmark.read(from: world.preferences), fresh)
        XCTAssertNil(world.center.status.problem, "the renewed bookmark still finds the folder")
    }

    // MARK: - Recording (review items 1, 3, 4, 5)

    /// A book, as a one-book library.
    private func library(_ books: [Book]) -> Library { SyncTestFixtures.library(books: books) }

    /// What the registers on disk say about a book's presence: nil when nothing was recorded.
    private func presence(of book: Book, in world: World) throws -> JSONValue? {
        let storeID = try XCTUnwrap(SyncPreferences.storeID.read(from: world.preferences))
        let files = SyncLocalFiles(syncFolder: world.dataDirectory.appendingPathComponent("Sync", isDirectory: true), storeID: storeID)
        return files.loadRegisters().entries[.book(book.id, .presence)]?.value
    }

    /// While the library may not sync (index recovery), nothing is recorded.
    func testNothingIsRecordedWhileTheLibraryMayNotSync() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        let book = SyncTestFixtures.book()
        world.host.library = library([book])
        world.host.maySyncNow = false
        await world.center.recordNow()
        XCTAssertNil(try presence(of: book, in: world), "not recorded while the library may not sync")
        world.host.maySyncNow = true
        await world.center.recordNow()
        XCTAssertEqual(try presence(of: book, in: world), .bool(true))
    }

    /// While a merge is applied, a record is put off: the library's change then is the merge's, not the person's.
    func testNothingIsRecordedWhileAMergeIsApplied() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        let book = SyncTestFixtures.book()
        let center = world.center
        let host = world.host
        var recordedDuring: JSONValue?
        host.pauseApply = { [self] in
            host.library = library([book])
            await center.recordNow()
            recordedDuring = try? presence(of: book, in: world)
        }
        center.applyAtNextSync()
        center.moment(.active)
        await center.waitUntilIdle()
        XCTAssertNil(recordedDuring, "put off while the merge was applied")
    }

    /// The host is handed the library that was recorded, and a deferred key is applied at the next sync.
    func testTheHostGetsTheRecordedLibraryAndDeferredKeysAreAppliedAgain() async throws {
        let world = try makeWorld()
        let book = SyncTestFixtures.book()
        world.host.library = library([book])
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        world.host.defersEverything = true
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        XCTAssertEqual(world.host.lastStart, world.host.library, "the start is the library that was recorded")
        XCTAssertEqual(try presence(of: book, in: world), .bool(true), "and it was recorded before the merge was computed")
        // The host left keys alone (here every key); the next sync applies again although nothing new came.
        let before = world.host.appliedCount
        world.host.defersEverything = false
        world.center.moment(.active)
        await world.center.waitUntilIdle()
        XCTAssertGreaterThan(world.host.appliedCount, before)
        // Nothing was left alone this time: the following sync does not apply.
        let settled = world.host.appliedCount
        world.center.moment(.active)
        await world.center.waitUntilIdle()
        XCTAssertEqual(world.host.appliedCount, settled)
    }

    /// Removals held back are reported in the status, and Sync Now, chosen while they are held, sends them.
    func testHeldRemovalsAreReportedAndSyncNowSendsThem() async throws {
        let world = try makeWorld()
        let books = (0..<6).map { _ in SyncTestFixtures.book() }
        world.host.library = library(books)
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        XCTAssertEqual(try presence(of: books[0], in: world), .bool(true))

        // The library empties at once, as index recovery does, and is allowed to sync.
        world.host.library = library([])
        await world.center.recordNow()
        XCTAssertEqual(world.center.status.heldRemovals, 6)
        XCTAssertEqual(try presence(of: books[0], in: world), .bool(true), "nothing was sent")

        // Sync Now, chosen while they are held, is the person's word.
        world.center.syncNow()
        await world.center.waitUntilIdle()
        XCTAssertEqual(try presence(of: books[0], in: world), .null)
        XCTAssertEqual(world.center.status.heldRemovals, 0)
    }

    /// A record that fails during the apply does not leave recording off for good.
    func testARecordThatFailsDoesNotLeaveRecordingOff() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        let storeID = try XCTUnwrap(SyncPreferences.storeID.read(from: world.preferences))
        let own = SyncLocalFiles(syncFolder: world.dataDirectory.appendingPathComponent("Sync", isDirectory: true), storeID: storeID)

        // The device's folder cannot be written: the record in the apply throws.
        // Restored however the test ends, so the sandbox can be cleared.
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: own.outboxFolder.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: own.outboxFolder.path)
        let book = SyncTestFixtures.book()
        world.host.library = library([book])
        world.center.applyAtNextSync()
        world.center.moment(.active)
        await world.center.waitUntilIdle()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: own.outboxFolder.path)

        await world.center.recordNow()
        XCTAssertEqual(try presence(of: book, in: world), .bool(true), "recording works again")
    }

    // MARK: - A folder in a trash (sync-iphone review item 10)

    /// A folder that was deleted in Files or Finder, and is in a trash, is not a place to set up or join.
    func testAFolderInATrashIsRefused() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        let trashed = world.parent.deletingLastPathComponent().appendingPathComponent(".Trash/Drive", isDirectory: true)
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
        do {
            try await world.center.setUp(in: trashed)
            XCTFail("a folder in a trash")
        } catch { XCTAssertEqual(error as? SyncProblem, .notInICloudDrive) }
    }

    /// An override of the renewal that is set after the center was built is the one used.
    func testARenewalOverrideSetLaterIsUsed() async throws {
        let original = SyncFolderAccessFactory.renewedBookmark
        addTeardownBlock { SyncFolderAccessFactory.renewedBookmark = original }
        let world = try makeWorld(renewedBookmark: SyncCenterEnvironment.renewalThroughFactory)
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        let folder = world.parent.appendingPathComponent("TextMouth Sync", isDirectory: true)
        let fresh = try XCTUnwrap(DataDirectoryPreferences.makeBookmark(of: folder))
        // Set after the center exists, as the iPhone's launch does.
        SyncFolderAccessFactory.renewedBookmark = { _ in fresh }
        world.center.moment(.active)
        await world.center.waitUntilIdle()
        XCTAssertEqual(SyncPreferences.bookmark.read(from: world.preferences), fresh)
    }

    /// A Sync Now that ends early does not leave a confirmation behind: the removals are still held afterwards.
    func testASyncNowThatEndsEarlyConfirmsNothing() async throws {
        let world = try makeWorld()
        let books = (0..<6).map { _ in SyncTestFixtures.book() }
        world.host.library = library(books)
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        world.host.library = library([])
        await world.center.recordNow()
        XCTAssertEqual(world.center.status.heldRemovals, 6)

        // Sync Now while the library may not sync: the run ends at once.
        world.host.maySyncNow = false
        world.center.syncNow()
        await world.center.waitUntilIdle()
        world.host.maySyncNow = true
        await world.center.recordNow()
        XCTAssertEqual(world.center.status.heldRemovals, 6, "nothing was confirmed")
        XCTAssertEqual(try presence(of: books[0], in: world), .bool(true))
    }

    // MARK: - Installing again (sync-mac review item 9)

    /// A second center over the same preferences, as a later launch is.
    private func laterLaunch(_ world: World, library: StorageLocation = .local) -> SyncCenter {
        SyncCenter(environment: SyncCenterEnvironment(
            preferences: world.preferences, deviceName: "Test Mac", platform: "macos", appVersion: "0.6.0", isPhone: false,
            makeAccess: { PlainSyncFolderAccess(bookmark: $0) }, locate: { _ in library },
            makeBookmark: { _ in nil }, reachability: .online, now: { Date() },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, announce: { _ in }, freeSpace: { _ in 100_000_000_000 },
            pauseWhileJoining: { _ in }
        ))
    }

    /// A library opened later, whose data directory holds none of this store's files, never joins the store.
    func testAnotherLibraryNeverJoinsTheStore() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        let other = try makeSandboxDirectory("sync-center-other-library")
        let later = laterLaunch(world)
        let host = StubHost()
        later.install(host: host, dataDirectory: other)
        await later.waitUntilIdle()
        XCTAssertFalse(later.status.isOn)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), [], "nothing was made there")
        withExtendedLifetime(host) {}
    }

    /// Installing again for the same library keeps sync on, and a library that is now in a cloud folder is refused (R6).
    func testInstallingAgainChecksTheLibraryAgain() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        await world.center.waitUntilIdle()
        XCTAssertTrue(world.center.status.isOn)

        let moved = laterLaunch(world, library: .cloud(.iCloudDrive))
        let host = StubHost()
        moved.install(host: host, dataDirectory: world.dataDirectory)
        await moved.waitUntilIdle()
        XCTAssertFalse(moved.status.isOn, "a library in a cloud folder is refused")
        withExtendedLifetime(host) {}
    }

    /// The device that wrote a merged value is named for the host's words.
    func testTheWritersNameIsGivenToTheHost() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        // Another device wrote a keep; this center merges it and can say who wrote it.
        let storeID = try XCTUnwrap(SyncPreferences.storeID.read(from: world.preferences))
        let folder = SyncFolder(root: world.parent.appendingPathComponent("TextMouth Sync"), access: PlainSyncFolderAccess(bookmark: try XCTUnwrap(SyncPreferences.bookmark.read(from: world.preferences))))
        let otherFiles = SyncLocalFiles(root: world.dataDirectory.deletingLastPathComponent().appendingPathComponent("other-device", isDirectory: true))
        let other = try SyncEngine(local: otherFiles, identity: SyncDeviceIdentity(name: "Phone Name", platform: "ios", appVersion: "0.6.0", installID: "other-install"))
        let book = UUID()
        try await other.recordKeep(true, for: [book])
        _ = try await other.exchange(in: folder)
        XCTAssertNotNil(storeID)
        world.center.moment(.active)
        await world.center.waitUntilIdle()
        XCTAssertEqual(world.center.deviceName(forKey: .book(book, .keep)), "Phone Name")
    }

    /// `waitUntilIdle` sleeps until a run ends, for as many callers as there are, and returns at once when nothing runs.
    func testWaitUntilIdleSleepsUntilTheRunEnds() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        await world.center.waitUntilIdle()   // nothing runs: it returns at once

        // A run held in its apply, until the test lets it go. The held run says when it is there, through the gate it waits
        // on: the test waits for that signal (with a fixed timeout), and counts nothing.
        var release: CheckedContinuation<Void, Never>?
        let reached = AsyncStream<Void>.makeStream()
        world.host.pauseApply = {
            await withCheckedContinuation { gate in
                release = gate
                reached.continuation.yield()
            }
        }
        world.center.applyAtNextSync()
        world.center.moment(.active)
        let signalled = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in reached.stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(60))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(signalled, "the run never reached its apply")
        // Named `continuation`, the one form of `resume(` the unit tests' sound check lets through (ios_ui_tests.py).
        let continuation = try XCTUnwrap(release, "the held run's gate")

        var finished = 0
        let first = Task { @MainActor in await world.center.waitUntilIdle(); finished += 1 }
        let second = Task { @MainActor in await world.center.waitUntilIdle(); finished += 1 }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(finished, 0, "both wait while the run is held")
        world.host.pauseApply = nil
        continuation.resume()
        await first.value
        await second.value
        XCTAssertEqual(finished, 2)
    }

    /// The host's voices are asked for when a merge is applied.
    func testTheHostsVoicesAreAskedFor() async throws {
        let world = try makeWorld()
        world.center.install(host: world.host, dataDirectory: world.dataDirectory)
        try await world.center.setUp(in: world.parent)
        await world.center.waitUntilIdle()
        XCTAssertGreaterThan(world.host.voiceReads, 0)
    }

    /// Hands out a renewed bookmark once.
    ///
    /// `@unchecked Sendable`: `pending` is read and changed only on the main actor, where the test and the center run.
    private final class Renewal: @unchecked Sendable {
        private var pending: Data?
        func offer(_ data: Data) { pending = data }
        func next() -> Data? {
            defer { pending = nil }
            return pending
        }
    }

    // MARK: - Helpers

    /// Looks at `condition` on every turn of the main queue, up to a limit, never sleeping a guessed time.
    private func waitUntil(limit: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        while !condition() {
            if clock.now - started > limit { return XCTFail("the condition never held within \(limit)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
