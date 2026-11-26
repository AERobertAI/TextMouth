import XCTest
@testable import TextMouth

/// The iPhone's Sync section (FR43, sync-iphone): which controls it holds in
/// each state, the status line in the iPhone's words (the Mac's own function), the
/// Mac's model run for the phone, with the picker's scope kept open around it,
/// and Keep on All Devices. Everything runs with stand-in services, so nothing
/// here touches iCloud Drive, a folder picker, or the user's library.
@MainActor
final class PhoneSyncSettingsTests: XCTestCase {
    /// Writes a date as a fixed time, so no test depends on the machine's locale.
    private let time: (Date) -> String = { _ in "9:41 AM" }

    // MARK: - The Controls

    /// Off, the section offers Set Up Sync… and Join Sync Folder…; on, Sync Now and Stop Syncing…, each with its title and a hint.
    func testControlsFollowWhetherSyncIsOn() {
        XCTAssertEqual(PhoneSyncSettingsModel.controls(isOn: false), [.setUp, .join])
        XCTAssertEqual(PhoneSyncSettingsModel.controls(isOn: true), [.syncNow, .stop])
        XCTAssertEqual(PhoneSyncControl.setUp.title, "Set Up Sync…")
        XCTAssertEqual(PhoneSyncControl.join.title, "Join Sync Folder…")
        XCTAssertEqual(PhoneSyncControl.syncNow.title, "Sync Now")
        XCTAssertEqual(PhoneSyncControl.stop.title, "Stop Syncing…")
        XCTAssertEqual(PhoneSyncControl.setUp.hint, SyncWording.setUpHint)
        XCTAssertEqual(PhoneSyncControl.join.hint, SyncWording.joinHint)
        // Sync Now has a hint too, as the Mac's has: what sync does.
        XCTAssertEqual(PhoneSyncControl.syncNow.hint, SyncWording.sectionSummary)
        XCTAssertFalse(PhoneSyncControl.stop.hint.isEmpty)
    }

    /// The library's summary offers Sync Now only once sync is on (R1: nothing before a folder is chosen).
    func testSummaryOffersSyncNowOnlyWhenOn() {
        XCTAssertFalse(PhoneSyncSettingsModel.offersSyncNowOnSummary(SyncStatus()))
        XCTAssertTrue(PhoneSyncSettingsModel.offersSyncNowOnSummary(SyncStatus(isOn: true)))
    }

    // MARK: - The Status Line

    /// The section's lines are the Mac's function in the iPhone's words: this iPhone, and the Mac named as the other device.
    func testLinesAreTheSharedFunctionInThePhonesWords() {
        func lines(_ status: SyncStatus) -> [String] { PhoneSyncSettingsModel.lines(for: status, isPhone: true, time: time) }
        XCTAssertEqual(lines(SyncStatus()), ["Sync is off."])
        XCTAssertEqual(
            lines(SyncStatus(isOn: true, isOffline: true, pendingChanges: 3, problem: .offline)),
            ["Offline. 3 changes wait on this iPhone, and will be sent when the network is back."]
        )
        XCTAssertEqual(
            lines(SyncStatus(isOn: true, problem: .folderMissing)),
            ["TextMouth can't find the TextMouth Sync folder in iCloud Drive. It may have been moved or deleted, or iCloud Drive signed out. Your library on this iPhone is as it was."]
        )
        XCTAssertEqual(
            lines(SyncStatus(isOn: true, problem: .notDownloaded(device: "x"))),
            ["Some changes from your Mac haven't downloaded yet. TextMouth will try again."]
        )
        XCTAssertEqual(
            lines(SyncStatus(isOn: true, lastSynced: Date(timeIntervalSince1970: 0), lastHeard: ["Study Mac": Date(timeIntervalSince1970: 1)], booksBackedUp: 612, booksToBackUp: 750)),
            ["Up to date. Last synced at 9:41 AM.", "Last heard from Study Mac at 9:41 AM.", "Backing up books: 612 of 750."]
        )
        // After Sync Now the center speaks the same line: the Mac's function with the phone flag says the same.
        XCTAssertEqual(
            SyncStatusLine.text(for: SyncStatus(isOn: true, problem: .notDownloaded(device: "x")), isPhone: true, time: time),
            "Some changes from your Mac haven't downloaded yet. TextMouth will try again."
        )
        XCTAssertEqual(
            SyncStatusLine.text(for: SyncStatus(isOn: true, problem: .notDownloaded(device: "x")), isPhone: false, time: time),
            SyncWording.statusNotDownloaded
        )
    }

    // MARK: - Wording

    /// The iPhone's own sentences, and the cloud sentences that name this device, in both forms.
    func testSentencesNameThisDevice() {
        XCTAssertEqual(SyncWording.stopQuestion(isPhone: true), "Stop syncing this library? Nothing is deleted, on this iPhone or in iCloud Drive.")
        XCTAssertEqual(SyncWording.stopQuestion(isPhone: false), SyncWording.stopQuestion)
        XCTAssertEqual(SyncWording.stopButton, "Stop Syncing")
        XCTAssertEqual(ReaderCloudWording.partNotOnThisMac(title: "Tides", isPhone: true), "Part of Tides isn't on this iPhone.")
        XCTAssertEqual(ReaderCloudWording.partNotOnThisMac(title: "Tides", isPhone: false), "Part of Tides isn't on this Mac.")
        XCTAssertEqual(
            ReaderCloudWording.waitingForSync(title: "Tides", provider: .iCloudDrive, isPhone: true),
            "Tides hasn't arrived on this iPhone yet. iCloud Drive may still be syncing it."
        )
        XCTAssertEqual(
            ReaderCloudWording.waitingForSync(title: "Tides", provider: .iCloudDrive, isPhone: false),
            "Tides hasn't arrived on this Mac yet. iCloud Drive may still be syncing it."
        )
        XCTAssertTrue(ReaderCloudWording.downloadStarted(title: "Tides", provider: nil, chapterNumber: 6, isPhone: true).contains("Chapter 6 isn't on this iPhone."))
        XCTAssertTrue(ReaderCloudWording.downloadStarted(title: "Tides", provider: nil, chapterNumber: 6, isPhone: false).contains("Chapter 6 isn't on this Mac."))
        XCTAssertEqual(
            BookCloudError.offline.explanation(in: .iCloudDrive, isPhone: true),
            "This iPhone is offline, so the book can't be downloaded from iCloud Drive. Connect to the internet and try again."
        )
        XCTAssertEqual(
            BookCloudError.packageMissing.explanation(in: .iCloudDrive, isPhone: true),
            "The book's files aren't on this iPhone yet. iCloud Drive may still be syncing them."
        )
        XCTAssertEqual(
            BookCloudError.packageMissing.explanation(in: .iCloudDrive, isPhone: false),
            "The book's files aren't on this Mac yet. iCloud Drive may still be syncing them."
        )
    }

    // MARK: - The Steps

    /// What the stand-in services were asked, in order.
    private final class Record {
        var calls: [String] = []
        var scopesOpen = 0
        var failure: Error?
        var listing = ["store.json"]
        var isInICloudDrive = true
        var onlyInCloud = 0
    }

    /// A controller over the Mac's model with stand-in services that record what they are asked.
    private func controller(_ record: Record) -> PhoneSyncSettingsController {
        let model = SyncSettingsModel(
            libraryLocation: { .local },
            locationOf: { _ in record.isInICloudDrive ? .cloud(.iCloudDrive) : .local },
            exists: { _ in false },
            listFolder: { _ in record.listing },
            setUp: { url in
                record.calls.append("setUp \(url.lastPathComponent) scope \(record.scopesOpen)")
                if let failure = record.failure { throw failure }
            },
            join: { url in
                record.calls.append("join \(url.lastPathComponent) scope \(record.scopesOpen)")
                if let failure = record.failure { throw failure }
            },
            stop: { record.calls.append("stop") },
            syncNow: { record.calls.append("syncNow") },
            isPhone: true
        )
        return PhoneSyncSettingsController(model: model, openScope: { _ in
            record.scopesOpen += 1
            return { record.scopesOpen -= 1 }
        }, countOnlyInCloud: {
            record.calls.append("count")
            return record.onlyInCloud
        })
    }

    private let folder = URL(fileURLWithPath: "/Users/reader/Library/Mobile Documents/com~apple~CloudDocs/Books", isDirectory: true)
    private let syncFolder = URL(fileURLWithPath: "/Users/reader/Library/Mobile Documents/com~apple~CloudDocs/TextMouth Sync", isDirectory: true)

    /// Set Up makes the folder with the picked folder's scope open, and closes it after.
    func testSetUpKeepsTheScopeOpen() async {
        let record = Record()
        let steps = controller(record)
        let worked = await steps.picked(.success([folder]), for: .setUp)
        XCTAssertTrue(worked)
        XCTAssertEqual(record.calls, ["setUp Books scope 1"])
        XCTAssertEqual(record.scopesOpen, 0)
        XCTAssertNil(steps.model.message)
        XCTAssertFalse(steps.isWorking)
    }

    /// Join joins the picked folder the same way.
    func testJoinJoinsThePickedFolder() async {
        let record = Record()
        let steps = controller(record)
        let worked = await steps.picked(.success([syncFolder]), for: .join)
        XCTAssertTrue(worked)
        XCTAssertEqual(record.calls, ["join TextMouth Sync scope 1"])
        XCTAssertEqual(record.scopesOpen, 0)
    }

    /// While a step runs, the status says what the step does: Set Up begins to sync, and only Join waits for the folder's files.
    func testTheWorkingLineIsForTheStepThatRuns() async {
        XCTAssertEqual(PhoneSyncSettingsController.workingLine(for: .setUp), "Syncing…")
        XCTAssertEqual(PhoneSyncSettingsController.workingLine(for: .join), "Waiting for the sync folder's files to arrive from iCloud Drive.")
        // And the controller says which step it is in while the sync's own call runs.
        let record = Record()
        var during: [PhoneSyncPick?] = []
        var steps: PhoneSyncSettingsController?
        let model = SyncSettingsModel(
            libraryLocation: { .local },
            locationOf: { _ in .cloud(.iCloudDrive) },
            exists: { _ in false },
            listFolder: { _ in ["store.json"] },
            setUp: { _ in during.append(steps?.working) },
            join: { _ in during.append(steps?.working) },
            isPhone: true
        )
        steps = PhoneSyncSettingsController(model: model, openScope: { _ in { record.scopesOpen -= 1 } })
        await steps?.picked(.success([folder]), for: .setUp)
        await steps?.picked(.success([syncFolder]), for: .join)
        XCTAssertEqual(during, [.setUp, .join])
        XCTAssertNil(steps?.working)
    }

    /// iCloud Drive full is said so; a library kept elsewhere is said in the iPhone's words, with no Mac or Change Location.
    func testRefusalsInThePhonesWords() {
        XCTAssertEqual(SyncSettingsModel.sentence(for: SyncProblem.outOfSpace, isPhone: true), SyncWording.iCloudDriveFull)
        XCTAssertEqual(SyncWording.iCloudDriveFull, "iCloud Drive is full. Free some space in iCloud Drive, then try again.")
        XCTAssertEqual(SyncSettingsModel.sentence(for: SyncProblem.libraryNotLocal, isPhone: true), "Sync needs a library kept on this iPhone, and this one isn't.")
        XCTAssertEqual(SyncSettingsModel.sentence(for: SyncProblem.libraryNotLocal, isPhone: false), SyncWording.libraryNotLocal)
        XCTAssertEqual(
            SyncStatusLine.text(for: SyncStatus(isOn: true, problem: .libraryNotLocal), isPhone: true, time: time),
            "Sync needs a library kept on this iPhone, and this one isn't."
        )
    }

    /// A folder that is no sync folder is refused at once, not after the minute joining waits (the Mac's model does it).
    func testJoinRefusesAFolderThatIsNoSyncFolderAtOnce() async {
        let record = Record()
        record.listing = ["notes.txt"]
        let steps = controller(record)
        let worked = await steps.picked(.success([folder]), for: .join)
        XCTAssertFalse(worked)
        XCTAssertEqual(record.calls, [])
        XCTAssertEqual(steps.model.message, SyncWording.notASyncFolder)
    }

    /// A folder outside iCloud Drive is refused, with nothing made, in words, and the scope is closed.
    func testRefusesAFolderOutsideICloudDrive() async {
        let record = Record()
        record.isInICloudDrive = false
        let steps = controller(record)
        let worked = await steps.picked(.success([folder]), for: .setUp)
        XCTAssertFalse(worked)
        XCTAssertEqual(record.calls, [])
        XCTAssertEqual(steps.model.message, "That folder isn't in iCloud Drive. Choose a folder in iCloud Drive.")
        XCTAssertEqual(record.scopesOpen, 0)
    }

    /// A step that fails says why in the iPhone's words, and any other error says the folder is no sync folder, never the system's text.
    func testAFailedStepSaysWhyInThePhonesWords() async {
        let record = Record()
        record.failure = SyncProblem.folderMissing
        let steps = controller(record)
        await steps.picked(.success([folder]), for: .setUp)
        XCTAssertEqual(steps.model.message, SyncWording.statusFolderMissing(device: "this iPhone"))
        XCTAssertFalse(steps.isWorking)

        record.failure = CocoaError(.fileReadUnknown)
        await steps.picked(.success([folder]), for: .setUp)
        XCTAssertEqual(steps.model.message, SyncWording.notASyncFolder)
    }

    /// A cancelled picker says nothing; a picker that failed says it is no sync folder; no folder chosen does nothing.
    func testPickerCancelAndFailure() async {
        let record = Record()
        let steps = controller(record)
        await steps.picked(.failure(CocoaError(.userCancelled)), for: .setUp)
        await steps.picked(.success([]), for: .join)
        XCTAssertEqual(record.calls, [])
        XCTAssertNil(steps.model.message)
        await steps.picked(.failure(CocoaError(.fileReadNoPermission)), for: .join)
        XCTAssertEqual(steps.model.message, SyncWording.notASyncFolder)
    }

    /// Sync Now goes to the sync, which announces its own outcome; Stop Syncing counts the books only in the sync folder,
    /// then asks, its question naming them, and nothing stops until yes.
    func testSyncNowAndStop() async {
        let record = Record()
        record.onlyInCloud = 12
        let steps = controller(record)
        steps.syncNow()
        XCTAssertEqual(record.calls, ["syncNow"])
        await steps.askToStop()
        XCTAssertTrue(steps.isAskingToStop)
        XCTAssertEqual(steps.onlyInCloud, 12, "counted as Stop was pressed, for the question")
        XCTAssertEqual(record.calls, ["syncNow", "count"])
        steps.confirmStop()
        XCTAssertFalse(steps.isAskingToStop)
        XCTAssertEqual(record.calls, ["syncNow", "count", "stop"])
    }

    // MARK: - Keep on All Devices

    /// With sync off a book's row offers neither keep command (R1); with it on, one of the two by whether the book is kept,
    /// after the reading list's and before Move to Folder.
    func testRowCommandsOfferKeepOnlyWithSyncOn() {
        func titles(isKept: Bool?) -> [String] {
            PhoneLibraryOffer.bookCommands(
                for: PhoneLibraryFixture.book("Dune"),
                isInReadingList: false,
                moves: nil,
                removal: PhoneLibraryFixture.phoneRemoval,
                isKeptOnAllDevices: isKept
            ).map(\.title)
        }
        XCTAssertEqual(titles(isKept: nil), ["Book Info", "Add to Reading List", "Move to Folder...", "Export…", "Remove from Library..."])
        XCTAssertEqual(titles(isKept: false), ["Book Info", "Add to Reading List", "Keep on All Devices", "Move to Folder...", "Export…", "Remove from Library..."])
        XCTAssertEqual(titles(isKept: true), ["Book Info", "Add to Reading List", "Stop Keeping on All Devices", "Move to Folder...", "Export…", "Remove from Library..."])
    }

    /// A book only in the cloud offers Download Now, as the Mac does, before the keep commands; one on the phone offers none.
    func testRowCommandsOfferDownloadNowForABookInTheCloud() {
        func titles(canDownload: Bool) -> [String] {
            PhoneLibraryOffer.bookCommands(
                for: PhoneLibraryFixture.book("Dune"),
                isInReadingList: false,
                moves: nil,
                removal: PhoneLibraryFixture.phoneRemoval,
                isKeptOnAllDevices: false,
                canDownload: canDownload
            ).map(\.title)
        }
        XCTAssertEqual(titles(canDownload: true), ["Book Info", "Add to Reading List", "Download Now", "Keep on All Devices", "Move to Folder...", "Export…", "Remove from Library..."])
        XCTAssertEqual(titles(canDownload: false), ["Book Info", "Add to Reading List", "Keep on All Devices", "Move to Folder...", "Export…", "Remove from Library..."])
    }

    /// The choice follows at once, so the switch and the row read the new value as VoiceOver asks; one that is already so
    /// changes nothing and says nothing. (With sync off nothing is stamped, which the center's guard keeps.)
    func testKeepingFollowsAtOnceAndSaysNothingTwice() {
        let book = PhoneLibraryFixture.book("Dune")
        let before = KeptBooks.shared.syncedBookIDs
        defer { KeptBooks.shared.setSyncedBooks(before) }
        KeptBooks.shared.setSyncedBooks([])
        XCTAssertFalse(PhoneKeepOnAllDevices.isKept(book.id))
        XCTAssertTrue(PhoneKeepOnAllDevices.set(true, book))
        XCTAssertTrue(PhoneKeepOnAllDevices.isKept(book.id))
        XCTAssertFalse(PhoneKeepOnAllDevices.set(true, book), "keeping a kept book changes nothing")
        XCTAssertTrue(PhoneKeepOnAllDevices.set(false, book))
        XCTAssertFalse(PhoneKeepOnAllDevices.isKept(book.id))
        XCTAssertFalse(PhoneKeepOnAllDevices.set(false, book))
    }

    /// What is said when keeping ends.
    func testStoppedKeepingIsSaid() {
        XCTAssertEqual(SyncWording.announceStoppedKeeping(title: "Dune"), "No longer keeping Dune on all devices.")
        XCTAssertEqual(SyncWording.announceKeeping(title: "Dune"), "Keeping Dune on all devices.")
        XCTAssertEqual(SyncWording.keptState, "Kept on all devices")
    }

    // MARK: - The Section in Settings

    /// The Sync section comes after About, with its own heading.
    func testTheSectionComesLast() {
        XCTAssertEqual(PhoneSettingsSection.allCases.last, .sync)
        XCTAssertEqual(PhoneSettingsSection.sync.title, "Sync")
    }
}
