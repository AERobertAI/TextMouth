import os
import XCTest
@testable import TextMouth

/// The session lease of a library two Macs can open (FR02): this Mac's file
/// is written with its name, time, and version, refreshed on its interval,
/// and removed at quit; another Mac active in the last three minutes is
/// warned about once a session, a stale one is not, and leases untouched for
/// 30 days are removed. A library only this Mac can open gets no lease. The
/// disk work runs off the main thread, in order, so a refresh is awaited
/// before what it wrote and found is looked at.
@MainActor
final class LibrarySessionLeaseTests: XCTestCase {

    // MARK: - This Mac's File

    /// Refreshing writes this Mac's file, named by its ID, with its name,
    /// the time, and the app's version.
    func testThisMacsFileHoldsItsNameTimeAndVersion() async throws {
        let harness = try LeaseHarness(test: self)

        await harness.lease.refresh()

        let record = try XCTUnwrap(harness.ownRecord(), "no lease was written")
        XCTAssertEqual(record, LibrarySessionLease.Record(computerName: "Chart Room", lastActive: harness.now, appVersion: "9.9"))
        XCTAssertEqual(harness.lease.heldRoot?.path, harness.root.path)
        XCTAssertEqual(harness.warnings, [])
    }

    /// This Mac's file is removed at quit.
    func testThisMacsFileIsRemovedAtQuit() async throws {
        let harness = try LeaseHarness(test: self)
        await harness.lease.refresh()
        XCTAssertNotNil(try harness.ownRecord())

        harness.lease.end()

        XCTAssertNil(try harness.ownRecord())
        XCTAssertNil(harness.lease.heldRoot)
    }

    /// A library only this Mac can open gets no lease at all.
    func testALibraryOnlyThisMacCanOpenGetsNoLease() async throws {
        let harness = try LeaseHarness(test: self, shared: false)

        await harness.lease.refresh()

        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.sessions.path))
        XCTAssertNil(harness.lease.heldRoot)
    }

    /// A data directory that another Mac can no longer open, as one moved
    /// out of the cloud by its sync service, keeps no lease: the file written
    /// there before is removed.
    func testALibraryNoLongerSharedKeepsNoLease() async throws {
        let harness = try LeaseHarness(test: self)
        await harness.lease.refresh()
        XCTAssertNotNil(try harness.ownRecord())

        harness.setLocation(.local, of: harness.root)
        await harness.lease.refresh()

        XCTAssertNil(try harness.ownRecord(), "the lease was kept in a library only this Mac can open")
        XCTAssertNil(harness.lease.heldRoot)
    }

    /// After a move of the data directory, this Mac's file is written in the
    /// new one and removed from the old one.
    func testAMovedDataDirectoryLeavesNoLeaseBehind() async throws {
        let harness = try LeaseHarness(test: self)
        await harness.lease.refresh()
        let oldSessions = harness.sessions

        let moved = try makeSandboxDirectory("LeaseMoved")
        harness.setLocation(.cloud(.iCloudDrive), of: moved)
        harness.root = moved
        await harness.lease.refresh()

        XCTAssertNotNil(try harness.ownRecord(), "no lease was written in the new data directory")
        XCTAssertEqual(harness.lease.heldRoot?.path, moved.path)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldSessions.appendingPathComponent("\(harness.lease.macID).json").path),
            "the lease was left in the old data directory"
        )
    }

    /// The lease refreshes itself on its interval while the library is
    /// open, and stops when the session ends.
    func testTheLeaseRefreshesOnItsInterval() throws {
        let harness = try LeaseHarness(test: self, refreshInterval: 0.05)
        harness.lease.begin()
        let later = harness.now.addingTimeInterval(60)
        harness.now = later

        XCTAssertTrue(
            waitUntil(timeout: 5) { (try? harness.ownRecord())?.lastActive == later },
            "the lease was not refreshed on its interval"
        )
        harness.lease.end()
    }

    // MARK: - Off the Main Thread

    /// The lease's disk work runs off the main thread: where the data
    /// directory lives is judged there, together with the writing of this
    /// Mac's file and the reading of the Sessions folder, so a Sessions
    /// folder that has not synced down yet never holds the interface. What
    /// the refresh found is published back on the main actor.
    func testTheLeasesDiskWorkRunsOffTheMainThread() async throws {
        let itemStatus = RecordingItemStatus()
        let harness = try LeaseHarness(test: self, itemStatus: itemStatus)
        try harness.writeOtherMac(named: "Galley", activeSecondsAgo: 30)

        await harness.lease.refresh()

        XCTAssertEqual(itemStatus.askedOnTheMainThread, [false], "where the data directory lives was asked on the main thread")
        XCTAssertNotNil(try harness.ownRecord(), "no lease was written")
        XCTAssertEqual(harness.warnings.map(\.computerName), ["Galley"])
    }

    /// A lease that ends while a refresh's disk work is still under way, as
    /// at a quit while the Sessions folder waits on the network, removes the
    /// file that work writes, once it is written, and the refresh publishes
    /// nothing: no file is left, none is held, and no warning comes.
    ///
    /// Synchronous, so that the main run loop, turned while the test waits,
    /// runs the refresh's main-actor steps.
    func testALeaseEndedDuringARefreshKeepsNoFile() throws {
        let itemStatus = RecordingItemStatus()
        let gate = DispatchSemaphore(value: 0)
        // Opened when the test ends too, so no thread is left waiting.
        addTeardownBlock { gate.signal() }
        itemStatus.waitBeforeAnswering(at: gate)
        let harness = try LeaseHarness(test: self, itemStatus: itemStatus)
        try harness.writeOtherMac(named: "Galley", activeSecondsAgo: 30)
        let refreshed = OSAllocatedUnfairLock(initialState: false)

        Task {
            await harness.lease.refresh()
            refreshed.withLock { $0 = true }
        }
        XCTAssertTrue(waitUntil(timeout: 5) { !itemStatus.askedOnTheMainThread.isEmpty }, "the refresh never began")
        // The disk work goes on a moment after the lease ends.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { gate.signal() }
        harness.lease.end()
        XCTAssertTrue(waitUntil(timeout: 5) { refreshed.withLock { $0 } }, "the refresh never ended")

        XCTAssertNil(try harness.ownRecord(), "the lease written as the lease ended was left")
        XCTAssertNil(harness.lease.heldRoot)
        XCTAssertEqual(harness.warnings, [], "a refresh begun before the end warned after it")
    }

    // MARK: - Other Macs

    /// Another Mac active two minutes ago is warned about, once a session,
    /// by its name and how long ago it was active.
    func testARecentOtherMacIsWarnedAboutOnce() async throws {
        let harness = try LeaseHarness(test: self)
        try harness.writeOtherMac(named: "Galley", activeSecondsAgo: 125)

        await harness.lease.refresh()
        await harness.lease.refresh()

        XCTAssertEqual(harness.warnings, [LibrarySessionLease.OtherMac(computerName: "Galley", minutesAgo: 2)])
        XCTAssertTrue(harness.lease.hasWarned)
    }

    /// Another Mac last active ten minutes ago is not warned about, and its
    /// lease stays.
    func testAStaleOtherMacIsNotWarnedAbout() async throws {
        let harness = try LeaseHarness(test: self)
        let file = try harness.writeOtherMac(named: "Galley", activeSecondsAgo: 600)

        await harness.lease.refresh()

        XCTAssertEqual(harness.warnings, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// Leases untouched for more than 30 days are removed.
    func testLeasesUntouchedForThirtyDaysAreRemoved() async throws {
        let harness = try LeaseHarness(test: self)
        let file = try harness.writeOtherMac(named: "Old Laptop", activeSecondsAgo: 31 * 24 * 60 * 60)

        await harness.lease.refresh()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(harness.warnings, [])
    }

    /// A lease that can't be read yet, as one only in the cloud, is judged
    /// by its modification date, naming no computer.
    func testAnUnreadableLeaseIsJudgedByItsDate() async throws {
        let harness = try LeaseHarness(test: self)
        try FileManager.default.createDirectory(at: harness.sessions, withIntermediateDirectories: true)
        let file = harness.sessions.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not yet downloaded".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: harness.now.addingTimeInterval(-30)], ofItemAtPath: file.path)

        await harness.lease.refresh()

        XCTAssertEqual(harness.warnings, [LibrarySessionLease.OtherMac(computerName: "another Mac", minutesAgo: 0)])
    }

    /// Choosing Quit TextMouth in the warning quits; Continue doesn't.
    func testChoosingQuitInTheWarningQuits() async throws {
        let continuing = try LeaseHarness(test: self, answer: .continueHere)
        try continuing.writeOtherMac(named: "Galley", activeSecondsAgo: 10)
        await continuing.lease.refresh()
        XCTAssertEqual(continuing.quits, 0)

        let quitting = try LeaseHarness(test: self, answer: .quit)
        try quitting.writeOtherMac(named: "Galley", activeSecondsAgo: 10)
        await quitting.lease.refresh()
        XCTAssertEqual(quitting.quits, 1)
    }

    // MARK: - Wording

    /// The warning names the other Mac and how long ago it was active, and
    /// says what using one library on two Macs can do.
    func testTheWarningIsWordedForTheListener() {
        let consequence = "Using one library on two Macs at the same time can lose reading positions and changes."
        XCTAssertEqual(
            LibrarySessionLease.warningMessage(about: .init(computerName: "Galley", minutesAgo: 2)),
            "TextMouth is also open on “Galley” (active 2 minutes ago). " + consequence
        )
        XCTAssertEqual(
            LibrarySessionLease.warningMessage(about: .init(computerName: "Galley", minutesAgo: 1)),
            "TextMouth is also open on “Galley” (active 1 minute ago). " + consequence
        )
        XCTAssertEqual(
            LibrarySessionLease.warningMessage(about: .init(computerName: "Galley", minutesAgo: 0)),
            "TextMouth is also open on “Galley” (active less than a minute ago). " + consequence
        )
        XCTAssertEqual(LibrarySessionLease.continueTitle, "Continue")
        XCTAssertEqual(LibrarySessionLease.quitTitle, "Quit TextMouth")
        XCTAssertEqual(LibrarySessionLease.choice(after: .alertFirstButtonReturn), .continueHere)
        XCTAssertEqual(LibrarySessionLease.choice(after: .alertSecondButtonReturn), .quit)
    }

    // MARK: - The Library Model

    /// Opening the library begins the lease, and losing it pauses the lease
    /// with its file left in place.
    func testTheLibraryHoldsTheLeaseWhileItIsOpen() throws {
        let harness = try LeaseHarness(test: self)
        try FileManager.default.createDirectory(at: harness.root.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try Data("{\"books\": [], \"folders\": []}".utf8).write(to: harness.root.appendingPathComponent("library.json"))
        let preferences = makeSandboxedPreferences("lease-model")
        TextMouthPaths.setCustomRoot(harness.root, in: preferences)
        _ = try makeDataDirectoryMoveDestination("LeaseModel")
        StorageBoundary.shared.publish(root: harness.root)
        addTeardownBlock { [root = harness.root] in DataDirectoryGate.open(root) }
        let environment = DataDirectoryEnvironment(
            preferences: preferences,
            volumeNotifications: NotificationCenter(),
            sessionLease: harness.lease
        )

        let model = LibraryViewModel(dataDirectoryEnvironment: environment)

        XCTAssertNil(model.dataDirectoryUnavailability)
        XCTAssertTrue(
            waitUntil(timeout: 5) { (try? harness.ownRecord()) != nil },
            "opening the library wrote no lease"
        )
        harness.lease.end()
    }
}

/// A lease over a data directory of the test's own: a clock the test sets,
/// its own preferences, a computer named "Chart Room" running version 9.9,
/// a sync service that says the data directory is in iCloud Drive unless the
/// test says otherwise, and a warning that records what it was shown and
/// answers as told. The multi-Mac tests (MultiMacCrashSafetyTests) use it
/// too.
@MainActor
final class LeaseHarness {
    /// The data directory in use; a test sets another to move it.
    var root: URL
    /// The time the lease reads.
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    /// The other Macs the lease warned about, in order.
    private(set) var warnings: [LibrarySessionLease.OtherMac] = []
    /// How many times the lease asked to quit.
    private(set) var quits = 0
    /// The lease under test.
    private(set) var lease: LibrarySessionLease!
    /// The sync service saying where each data directory lives, unless the
    /// test gave its own.
    private let locations = FakeCloudItemStatusProvider()

    /// The data directory's Sessions folder.
    var sessions: URL {
        root.appendingPathComponent(LibrarySessionLease.folderName, isDirectory: true)
    }

    /// - Parameters:
    ///   - test: The test the harness belongs to, which ends the lease.
    ///   - shared: Whether another Mac can open the data directory.
    ///   - itemStatus: The sync service, when the test has its own; it
    ///     decides by itself whether another Mac can open the data directory.
    ///   - refreshInterval: Seconds between the lease's refreshes.
    ///   - answer: How the warning is answered.
    init(
        test: XCTestCase,
        shared: Bool = true,
        itemStatus: (any CloudItemStatusProviding)? = nil,
        refreshInterval: TimeInterval = 60,
        answer: LibrarySessionLease.Choice = .continueHere
    ) throws {
        root = try test.makeSandboxDirectory("Lease")
        locations.setLocation(shared ? .cloud(.iCloudDrive) : .local, of: root)
        let provider = itemStatus ?? locations
        lease = LibrarySessionLease(
            preferences: test.makeSandboxedPreferences("lease"),
            clock: { [unowned self] in self.now },
            refreshInterval: refreshInterval,
            rootProvider: { [unowned self] in self.root },
            itemStatus: { provider },
            computerName: { "Chart Room" },
            appVersion: "9.9",
            warn: { [unowned self] other, respond in
                self.warnings.append(other)
                respond(answer)
            },
            quit: { [unowned self] in self.quits += 1 }
        )
        let lease = lease!
        test.addTeardownBlock { @MainActor in lease.end() }
    }

    /// Has the harness's sync service say the data directory at `folder`
    /// lives at `location`.
    func setLocation(_ location: StorageLocation, of folder: URL) {
        locations.setLocation(location, of: folder)
    }

    /// This Mac's lease as it is on disk, or nil when there is none.
    func ownRecord() throws -> LibrarySessionLease.Record? {
        let file = sessions.appendingPathComponent("\(lease.macID).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibrarySessionLease.Record.self, from: Data(contentsOf: file))
    }

    /// Writes another Mac's lease, active `activeSecondsAgo` before `now`,
    /// and returns its file.
    @discardableResult
    func writeOtherMac(named name: String, activeSecondsAgo: TimeInterval) throws -> URL {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = LibrarySessionLease.Record(
            computerName: name,
            lastActive: now.addingTimeInterval(-activeSecondsAgo),
            appVersion: "1.0"
        )
        try encoder.encode(record).write(to: file)
        return file
    }
}

/// A sync service saying every folder is in iCloud Drive, which records
/// whether each question of where a folder lives came on the main thread,
/// and can hold each answer until a gate opens, as one waiting on the
/// network does. Every variable is guarded by a lock, since the lease asks
/// from its own queue.
private final class RecordingItemStatus: CloudItemStatusProviding {
    /// Whether each question came on the main thread, in order.
    private let questions = OSAllocatedUnfairLock<[Bool]>(initialState: [])
    /// The gate each answer waits at, if any.
    private let gate = OSAllocatedUnfairLock<DispatchSemaphore?>(initialState: nil)

    /// Whether each question of where a folder lives came on the main
    /// thread, in order.
    var askedOnTheMainThread: [Bool] {
        questions.withLock { $0 }
    }

    /// Has each answer wait until `gate` opens.
    func waitBeforeAnswering(at gate: DispatchSemaphore) {
        self.gate.withLock { $0 = gate }
    }

    func location(of folder: URL) -> StorageLocation {
        questions.withLock { $0.append(pthread_main_np() != 0) }
        gate.withLock { $0 }?.wait()
        return .cloud(.iCloudDrive)
    }

    func status(of file: URL) -> CloudItemStatus {
        .missing
    }

    func requestDownload(of file: URL) throws {}

    func removeLocalCopy(of file: URL) throws {}
}
