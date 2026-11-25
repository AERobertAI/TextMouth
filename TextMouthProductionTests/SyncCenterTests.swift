import XCTest
@testable import TextMouth

/// The app's one sync (FR43): inert until a folder is chosen (R1), refusals
/// that name their reason (R6), set up, join, stop (which deletes nothing),
/// and what Sync Now says. Every folder is in the test's sandbox; the
/// location of a folder is a test's answer, so no iCloud Drive is touched.
@MainActor
final class SyncCenterTests: XCTestCase {
    /// A library host that holds an empty library and applies nothing.
    private final class StubHost: SyncLibraryHost {
        var library = Library()
        var maySyncNow = true
        var appliedCount = 0
        var lastKept: Set<UUID>?
        /// How often the center asked for the device's voices, and which it has.
        var voiceReads = 0
        var availableVoiceIDs: Set<String>? {
            voiceReads += 1
            return ["voice-1"]
        }
        func applySync(_ application: SyncApplication) async -> Set<SyncKey> {
            appliedCount += 1
            return application.appliedKeys
        }
        func syncDidApply(keptBookIDs: Set<UUID>, mayDownload: Bool) { lastKept = keptBookIDs }
    }

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
        renewedBookmark: @escaping @Sendable @MainActor (Data) -> Data? = { _ in nil }
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
        second.install(host: StubHost(), dataDirectory: world.dataDirectory)
        XCTAssertTrue(second.status.isOn)
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
