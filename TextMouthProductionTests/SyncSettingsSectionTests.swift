import XCTest
@testable import TextMouth

/// The Sync section of Storage settings (FR43): the status line's sentence
/// for each state, the refusals of a folder chosen, the commands' errors in
/// words, and the folder panels' settings. The model gets stand-ins for the
/// sync and the drive, so nothing touches iCloud Drive or a library.
@MainActor
final class SyncSettingsSectionTests: XCTestCase {
    /// A time written the same way in every test.
    private let time: (Date) -> String = { _ in "9:41 AM" }

    // MARK: - The Status Line

    /// Each state speaks its own sentence, the first that holds.
    func testTheStatusLineSpeaksTheFirstStateThatHolds() {
        func say(_ edit: (inout SyncStatus) -> Void) -> String {
            var status = SyncStatus(isOn: true)
            status.lastSynced = Date(timeIntervalSince1970: 1_790_000_000)
            edit(&status)
            return SyncStatusLine.sentence(for: status, isPhone: false, time: time)
        }
        XCTAssertEqual(SyncStatusLine.sentence(for: SyncStatus(), isPhone: false), SyncWording.statusOff)
        XCTAssertEqual(say { $0.isSyncing = true }, SyncWording.statusSyncing)
        XCTAssertEqual(say { $0.isOffline = true; $0.pendingChanges = 3 },
                       SyncWording.statusOffline(changes: 3, device: SyncWording.thisDevice(isPhone: false)))
        XCTAssertEqual(say { $0.problem = .folderMissing },
                       SyncWording.statusFolderMissing(device: SyncWording.thisDevice(isPhone: false)))
        XCTAssertEqual(say { $0.problem = .outOfSpace; $0.pendingChanges = 3; $0.booksToBackUp = 150; $0.booksBackedUp = 12 },
                       SyncWording.statusOutOfSpace(changes: 3, books: 138, device: SyncWording.thisDevice(isPhone: false)))
        XCTAssertEqual(say { $0.problem = .laterVersion }, SyncWording.statusLaterVersion)
        XCTAssertEqual(say { $0.pendingChanges = 3 }, SyncWording.statusUploading(changes: 3))
        XCTAssertEqual(say { $0.problem = .notDownloaded(device: "iPhone") }, SyncWording.statusNotDownloaded)
        XCTAssertEqual(say { _ in }, SyncWording.statusUpToDate(at: "9:41 AM"))
    }

    /// An offline iPhone says "this iPhone", a Mac "this Mac".
    func testThePhoneSaysThisIPhone() {
        var status = SyncStatus(isOn: true)
        status.isOffline = true
        status.pendingChanges = 1
        XCTAssertTrue(SyncStatusLine.sentence(for: status, isPhone: true).contains(SyncWording.thisDevice(isPhone: true)))
        XCTAssertTrue(SyncStatusLine.sentence(for: status, isPhone: false).contains(SyncWording.thisDevice(isPhone: false)))
    }

    /// After the sentence come when each device was last heard from, newest
    /// first, and how far the backup of books has got while it is behind.
    func testTheDetailsFollowTheSentence() {
        var status = SyncStatus(isOn: true)
        status.lastHeard = ["iPad": Date(timeIntervalSince1970: 100), "iPhone": Date(timeIntervalSince1970: 200)]
        status.booksBackedUp = 612
        status.booksToBackUp = 750
        XCTAssertEqual(SyncStatusLine.details(for: status, time: time), [
            SyncWording.lastHeard(from: "iPhone", at: "9:41 AM"),
            SyncWording.lastHeard(from: "iPad", at: "9:41 AM"),
            SyncWording.backingUp(done: 612, total: 750),
        ])
        status.booksBackedUp = 750
        XCTAssertEqual(SyncStatusLine.details(for: status, time: time).count, 2)
    }

    // MARK: - The Commands

    /// A model over stand-ins that count what the sync was asked to do.
    private final class Calls {
        var setUps: [URL] = []
        var joins: [URL] = []
        var stops = 0
        var syncNows = 0
        var existing: Set<String> = []
        var error: Error?
    }

    /// A model whose library is at `library` and whose chosen folders are at `chosen`.
    private func makeModel(
        library: StorageLocation = .local, chosen: StorageLocation = .cloud(.iCloudDrive), calls: Calls
    ) -> SyncSettingsModel {
        SyncSettingsModel(
            libraryLocation: { library },
            locationOf: { _ in chosen },
            exists: { calls.existing.contains($0.lastPathComponent) },
            setUp: { calls.setUps.append($0); if let error = calls.error { throw error } },
            join: { calls.joins.append($0); if let error = calls.error { throw error } },
            stop: { calls.stops += 1 },
            syncNow: { calls.syncNows += 1 }
        )
    }

    private let folder = URL(fileURLWithPath: "/Users/reader/iCloud/Folder")

    /// Set Up Sync in an iCloud Drive folder asks the sync to set up there.
    func testSetUpAsksTheSync() async {
        let calls = Calls()
        let model = makeModel(calls: calls)
        let worked = await model.setUp(in: folder)
        XCTAssertTrue(worked)
        XCTAssertEqual(calls.setUps, [folder])
        XCTAssertNil(model.message)
    }

    /// A library kept in a cloud folder, or on another volume, is refused
    /// before anything is made or read.
    func testALibraryNotKeptHereIsRefused() async {
        for location in [StorageLocation.cloud(.dropbox), .otherVolume(name: "Backup")] {
            let calls = Calls()
            let model = makeModel(library: location, calls: calls)
            let setUp = await model.setUp(in: folder)
            let joined = await model.join(folder)
            XCTAssertFalse(setUp)
            XCTAssertFalse(joined)
            XCTAssertEqual(model.message, SyncWording.libraryNotLocal)
            XCTAssertTrue(calls.setUps.isEmpty && calls.joins.isEmpty)
        }
    }

    /// A folder outside iCloud Drive is refused, whichever cloud it is in.
    func testAFolderOutsideICloudDriveIsRefused() async {
        for location in [StorageLocation.local, .cloud(.googleDrive), .otherVolume(name: "Backup")] {
            let calls = Calls()
            let model = makeModel(chosen: location, calls: calls)
            let worked = await model.setUp(in: folder)
            XCTAssertFalse(worked)
            XCTAssertEqual(model.message, SyncWording.notInICloudDrive)
            XCTAssertTrue(calls.setUps.isEmpty)
        }
    }

    /// Set Up Sync finding a TextMouth Sync folder already there says to join it.
    func testSetUpNeverMakesAFolderOverOneThatIsThere() async {
        let calls = Calls()
        calls.existing = [SyncSettingsModel.folderName]
        let model = makeModel(calls: calls)
        let worked = await model.setUp(in: folder)
        XCTAssertFalse(worked)
        XCTAssertEqual(model.message, SyncWording.folderAlreadyThere)
        XCTAssertTrue(calls.setUps.isEmpty)
    }

    /// What the sync throws is said in words: not a sync folder, another
    /// store, a later TextMouth, files not here yet, the folder gone.
    func testWhatTheSyncThrowsIsSaidInWords() async {
        let cases: [(SyncProblem, String)] = [
            (.notASyncFolder, SyncWording.notASyncFolder),
            (.anotherStore, SyncWording.anotherStore),
            (.laterVersion, SyncWording.statusLaterVersion),
            (.notDownloaded(device: "iPhone"), SyncWording.waitingForFiles),
            (.exists, SyncWording.folderAlreadyThere),
            (.folderMissing, SyncWording.statusFolderMissing(device: SyncWording.thisDevice(isPhone: false))),
        ]
        for (problem, sentence) in cases {
            let calls = Calls()
            calls.error = problem
            let model = makeModel(calls: calls)
            let worked = await model.join(folder)
            XCTAssertFalse(worked)
            XCTAssertEqual(model.message, sentence)
        }
    }

    /// Stop Syncing and Sync Now go to the sync, and clear what was said.
    func testStopAndSyncNowGoToTheSync() async {
        let calls = Calls()
        let model = makeModel(chosen: .local, calls: calls)
        _ = await model.setUp(in: folder)
        XCTAssertNotNil(model.message)
        model.syncNow()
        XCTAssertNil(model.message)
        model.stop()
        XCTAssertEqual(calls.syncNows, 1)
        XCTAssertEqual(calls.stops, 1)
    }

    // MARK: - Keep on All Devices

    /// A book with no file, for the command lists.
    private func makeBook(_ title: String) -> Book {
        Book(title: title, format: .txt, filePath: "/nonexistent/\(UUID().uuidString).txt", md5Hash: UUID().uuidString)
    }

    /// Keep on All Devices is offered only while sync is on; a library
    /// that is not synced offers neither it nor Stop Keeping.
    func testKeepOnAllDevicesIsOfferedOnlyWhileSyncIsOn() {
        let book = makeBook("Kept Everywhere")
        let states = BookCloudStates()
        states.record(.downloaded, for: book.id)
        func kinds(kept: Set<UUID> = []) -> [LibraryCloudCommand.Kind] {
            LibraryCloudCommand.commands(for: [book], isSelection: false, states: states, kept: [], keptOnAllDevices: kept).map(\.kind)
        }
        XCTAssertFalse(kinds().contains(.keepOnAllDevices))
        states.setSyncIsOn(true)
        XCTAssertTrue(kinds().contains(.keepOnAllDevices))
        XCTAssertFalse(kinds().contains(.stopKeepingOnAllDevices))
        XCTAssertTrue(kinds(kept: [book.id]).contains(.stopKeepingOnAllDevices))
        XCTAssertFalse(kinds(kept: [book.id]).contains(.keepOnAllDevices))
    }

    /// A synced library is on this device's disk, so Keep on This Mac and
    /// Remove Download, which are for a library in a cloud folder, are not offered.
    func testASyncedLibraryOffersNeitherKeepOnThisMacNorRemoveDownload() {
        let book = makeBook("Synced Only")
        let states = BookCloudStates()
        states.setSyncIsOn(true)
        states.record(.downloaded, for: book.id)
        let kinds = LibraryCloudCommand.commands(for: [book], isSelection: false, states: states, kept: []).map(\.kind)
        XCTAssertFalse(kinds.contains(.keepOnThisMac))
        XCTAssertFalse(kinds.contains(.removeDownload))
        XCTAssertTrue(kinds.contains(.keepOnAllDevices))
    }

    /// The commands are titled in SyncWording's words, counted for a selection.
    func testTheKeepCommandsAreTitledInSyncWordingsWords() {
        XCTAssertEqual(LibraryCloudCommand.Kind.keepOnAllDevices.title(count: 1, forSelection: false), "Keep on All Devices")
        XCTAssertEqual(LibraryCloudCommand.Kind.stopKeepingOnAllDevices.title(count: 1, forSelection: false), "Stop Keeping on All Devices")
        XCTAssertEqual(LibraryCloudCommand.Kind.keepOnAllDevices.title(count: 3, forSelection: true), SyncWording.keepTitle(count: 3))
        XCTAssertEqual(LibraryCloudCommand.Kind.stopKeepingOnAllDevices.title(count: 3, forSelection: true), SyncWording.stopKeepingTitle(count: 3))
    }

    // MARK: - The Folder Panels

    /// Each panel chooses one folder, never a file, and says what for in
    /// the command's words without its ellipsis; only Set Up can make a folder.
    func testThePanelsChooseOneFolder() {
        let setUp = SyncSettingsSection.panelSettings(joining: false)
        let join = SyncSettingsSection.panelSettings(joining: true)
        for settings in [setUp, join] {
            XCTAssertTrue(settings.canChooseDirectories)
            XCTAssertFalse(settings.canChooseFiles)
            XCTAssertFalse(settings.allowsMultipleSelection)
            XCTAssertFalse(settings.title.hasSuffix("…"))
            XCTAssertEqual(settings.prompt, settings.title)
        }
        XCTAssertEqual(setUp.title, "Set Up Sync")
        XCTAssertEqual(join.title, "Join Sync Folder")
        XCTAssertEqual(setUp.message, SyncWording.setUpHint)
        XCTAssertEqual(join.message, SyncWording.joinHint)
        XCTAssertTrue(setUp.canCreateDirectories)
        XCTAssertFalse(join.canCreateDirectories)
    }
}
