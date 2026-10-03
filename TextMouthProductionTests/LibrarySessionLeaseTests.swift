import XCTest
@testable import TextMouth

/// The session lease of a library two Macs can open (FR02): this Mac's file
/// is written with its name, time, and version, refreshed on its interval,
/// and removed at quit; another Mac active in the last three minutes is
/// warned about once a session, a stale one is not, and leases untouched for
/// 30 days are removed. A library only this Mac can open gets no lease.
@MainActor
final class LibrarySessionLeaseTests: XCTestCase {

    // MARK: - This Mac's File

    /// Refreshing writes this Mac's file, named by its ID, with its name,
    /// the time, and the app's version.
    func testThisMacsFileHoldsItsNameTimeAndVersion() throws {
        let harness = try LeaseHarness(test: self)

        harness.lease.refresh()

        let record = try XCTUnwrap(harness.ownRecord(), "no lease was written")
        XCTAssertEqual(record, LibrarySessionLease.Record(computerName: "Chart Room", lastActive: harness.now, appVersion: "9.9"))
        XCTAssertEqual(harness.lease.heldRoot?.path, harness.root.path)
        XCTAssertEqual(harness.warnings, [])
    }

    /// This Mac's file is removed at quit.
    func testThisMacsFileIsRemovedAtQuit() throws {
        let harness = try LeaseHarness(test: self)
        harness.lease.refresh()
        XCTAssertNotNil(try harness.ownRecord())

        harness.lease.end()

        XCTAssertNil(try harness.ownRecord())
        XCTAssertNil(harness.lease.heldRoot)
    }

    /// A library only this Mac can open gets no lease at all.
    func testALibraryOnlyThisMacCanOpenGetsNoLease() throws {
        let harness = try LeaseHarness(test: self, shared: false)

        harness.lease.refresh()

        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.sessions.path))
        XCTAssertNil(harness.lease.heldRoot)
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

    // MARK: - Other Macs

    /// Another Mac active two minutes ago is warned about, once a session,
    /// by its name and how long ago it was active.
    func testARecentOtherMacIsWarnedAboutOnce() throws {
        let harness = try LeaseHarness(test: self)
        try harness.writeOtherMac(named: "Galley", activeSecondsAgo: 125)

        harness.lease.refresh()
        harness.lease.refresh()

        XCTAssertEqual(harness.warnings, [LibrarySessionLease.OtherMac(computerName: "Galley", minutesAgo: 2)])
        XCTAssertTrue(harness.lease.hasWarned)
    }

    /// Another Mac last active ten minutes ago is not warned about, and its
    /// lease stays.
    func testAStaleOtherMacIsNotWarnedAbout() throws {
        let harness = try LeaseHarness(test: self)
        let file = try harness.writeOtherMac(named: "Galley", activeSecondsAgo: 600)

        harness.lease.refresh()

        XCTAssertEqual(harness.warnings, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// Leases untouched for more than 30 days are removed.
    func testLeasesUntouchedForThirtyDaysAreRemoved() throws {
        let harness = try LeaseHarness(test: self)
        let file = try harness.writeOtherMac(named: "Old Laptop", activeSecondsAgo: 31 * 24 * 60 * 60)

        harness.lease.refresh()

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(harness.warnings, [])
    }

    /// A lease that can't be read yet, as one only in the cloud, is judged
    /// by its modification date, naming no computer.
    func testAnUnreadableLeaseIsJudgedByItsDate() throws {
        let harness = try LeaseHarness(test: self)
        try FileManager.default.createDirectory(at: harness.sessions, withIntermediateDirectories: true)
        let file = harness.sessions.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not yet downloaded".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: harness.now.addingTimeInterval(-30)], ofItemAtPath: file.path)

        harness.lease.refresh()

        XCTAssertEqual(harness.warnings, [LibrarySessionLease.OtherMac(computerName: "another Mac", minutesAgo: 0)])
    }

    /// Choosing Quit TextMouth in the warning quits; Continue doesn't.
    func testChoosingQuitInTheWarningQuits() throws {
        let continuing = try LeaseHarness(test: self, answer: .continueHere)
        try continuing.writeOtherMac(named: "Galley", activeSecondsAgo: 10)
        continuing.lease.refresh()
        XCTAssertEqual(continuing.quits, 0)

        let quitting = try LeaseHarness(test: self, answer: .quit)
        try quitting.writeOtherMac(named: "Galley", activeSecondsAgo: 10)
        quitting.lease.refresh()
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
        XCTAssertNotNil(try harness.ownRecord(), "opening the library wrote no lease")
        harness.lease.end()
    }
}

/// A lease over a data directory of the test's own: a clock the test sets,
/// its own preferences, a computer named "Chart Room" running version 9.9,
/// and a warning that records what it was shown and answers as told. The
/// multi-Mac tests (MultiMacCrashSafetyTests) use it too.
@MainActor
final class LeaseHarness {
    /// The data directory.
    let root: URL
    /// The time the lease reads.
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    /// The other Macs the lease warned about, in order.
    private(set) var warnings: [LibrarySessionLease.OtherMac] = []
    /// How many times the lease asked to quit.
    private(set) var quits = 0
    /// The lease under test.
    private(set) var lease: LibrarySessionLease!

    /// The data directory's Sessions folder.
    var sessions: URL {
        root.appendingPathComponent(LibrarySessionLease.folderName, isDirectory: true)
    }

    init(
        test: XCTestCase,
        shared: Bool = true,
        refreshInterval: TimeInterval = 60,
        answer: LibrarySessionLease.Choice = .continueHere
    ) throws {
        root = try test.makeSandboxDirectory("Lease")
        let root = root
        lease = LibrarySessionLease(
            preferences: test.makeSandboxedPreferences("lease"),
            clock: { [unowned self] in self.now },
            refreshInterval: refreshInterval,
            rootProvider: { root },
            isShared: { _ in shared },
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
