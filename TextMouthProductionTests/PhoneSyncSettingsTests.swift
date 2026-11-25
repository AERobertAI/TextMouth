import XCTest
@testable import TextMouth

/// The iPhone's Sync section (FR43, sync-iphone): which controls it holds in
/// each state, the words of its status line in the plan's order, the refusals,
/// and each step of setting up, joining, and stopping, run with stand-in
/// services so that nothing here touches iCloud Drive, a folder picker, or the
/// user's library.
@MainActor
final class PhoneSyncSettingsTests: XCTestCase {
    /// Writes a date as a fixed time, so no test depends on the machine's locale.
    private let time: (Date) -> String = { _ in "9:41 AM" }

    // MARK: - The Controls

    /// Off, the section offers Set Up Sync… and Join Sync Folder…; on, Sync Now and Stop Syncing…, each with its title and hint.
    func testControlsFollowWhetherSyncIsOn() {
        XCTAssertEqual(PhoneSyncSettingsModel.controls(isOn: false), [.setUp, .join])
        XCTAssertEqual(PhoneSyncSettingsModel.controls(isOn: true), [.syncNow, .stop])
        XCTAssertEqual(PhoneSyncControl.setUp.title, "Set Up Sync…")
        XCTAssertEqual(PhoneSyncControl.join.title, "Join Sync Folder…")
        XCTAssertEqual(PhoneSyncControl.syncNow.title, "Sync Now")
        XCTAssertEqual(PhoneSyncControl.stop.title, "Stop Syncing…")
        XCTAssertEqual(PhoneSyncControl.setUp.hint, SyncWording.setUpHint)
        XCTAssertEqual(PhoneSyncControl.join.hint, SyncWording.joinHint)
        XCTAssertNil(PhoneSyncControl.syncNow.hint)
        XCTAssertNil(PhoneSyncControl.stop.hint)
    }

    /// The library's summary offers Sync Now only once sync is on (R1: nothing before a folder is chosen).
    func testSummaryOffersSyncNowOnlyWhenOn() {
        XCTAssertFalse(PhoneSyncSettingsModel.offersSyncNowOnSummary(SyncStatus()))
        XCTAssertTrue(PhoneSyncSettingsModel.offersSyncNowOnSummary(SyncStatus(isOn: true)))
    }

    // MARK: - The Status Line

    /// Each state says its words, in the plan's order, in the iPhone's form.
    func testHeadlineSaysTheFirstStateThatHolds() {
        func headline(_ status: SyncStatus) -> String { PhoneSyncSettingsModel.headline(for: status, time: time) }
        XCTAssertEqual(headline(SyncStatus()), "Sync is off.")
        XCTAssertEqual(headline(SyncStatus(isOn: true, isSyncing: true, isOffline: true)), "Syncing…")
        XCTAssertEqual(
            headline(SyncStatus(isOn: true, isOffline: true, pendingChanges: 3)),
            "Offline. 3 changes wait on this iPhone, and will be sent when the network is back."
        )
        XCTAssertEqual(
            headline(SyncStatus(isOn: true, problem: .folderMissing)),
            "TextMouth can't find the TextMouth Sync folder in iCloud Drive. It may have been moved or deleted, or iCloud Drive signed out. Your library on this iPhone is as it was."
        )
        XCTAssertEqual(
            headline(SyncStatus(isOn: true, pendingChanges: 3, problem: .outOfSpace, booksBackedUp: 612, booksToBackUp: 750)),
            "iCloud Drive is full, so 3 changes and 138 books aren't uploaded. Your library on this iPhone is as it was."
        )
        XCTAssertEqual(headline(SyncStatus(isOn: true, problem: .laterVersion)), "A later TextMouth made this sync folder. Update TextMouth to use it.")
        XCTAssertEqual(headline(SyncStatus(isOn: true, pendingChanges: 3)), "3 changes are waiting for iCloud Drive to upload them.")
        XCTAssertEqual(
            headline(SyncStatus(isOn: true, problem: .notDownloaded(device: "x"))),
            "Some changes from your Mac haven't downloaded yet. TextMouth will try again."
        )
        XCTAssertEqual(headline(SyncStatus(isOn: true, lastSynced: Date(timeIntervalSince1970: 0))), "Up to date. Last synced at 9:41 AM.")
        // On, with no sync finished yet: one is on its way, not "up to date" with no time.
        XCTAssertEqual(headline(SyncStatus(isOn: true)), "Syncing…")
    }

    /// Who was last heard from, and the backup's count, follow the headline; with sync off nothing but the headline.
    func testLinesAddWhoWasHeardAndTheBackup() {
        let status = SyncStatus(
            isOn: true,
            lastSynced: Date(timeIntervalSince1970: 0),
            lastHeard: ["Mac": Date(timeIntervalSince1970: 1)],
            booksBackedUp: 612,
            booksToBackUp: 750
        )
        XCTAssertEqual(
            PhoneSyncSettingsModel.lines(for: status, time: time),
            ["Up to date. Last synced at 9:41 AM.", "Last heard from Mac at 9:41 AM.", "Backing up books: 612 of 750."]
        )
        XCTAssertEqual(PhoneSyncSettingsModel.lines(for: SyncStatus(), time: time), ["Sync is off."])
        // A finished backup says nothing more.
        var done = status
        done.booksBackedUp = 750
        XCTAssertEqual(PhoneSyncSettingsModel.lines(for: done, time: time).count, 2)
        // A device with no name is the Mac, which is the only other kind a phone hears from.
        XCTAssertEqual(PhoneSyncSettingsModel.heardDeviceName(""), "Mac")
        XCTAssertEqual(PhoneSyncSettingsModel.heardDeviceName("Study Mac"), "Study Mac")
    }

    // MARK: - Wording

    /// The iPhone's own sentences, and the cloud sentences that name this device, in both forms.
    func testSentencesNameThisDevice() {
        XCTAssertEqual(PhoneSyncWording.stopQuestion, "Stop syncing this library? Nothing is deleted, on this iPhone or in iCloud Drive.")
        XCTAssertEqual(PhoneSyncWording.stopButton, "Stop Syncing")
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
        XCTAssertTrue(
            ReaderCloudWording.downloadStarted(title: "Tides", provider: nil, chapterNumber: 6, isPhone: true).contains("Chapter 6 isn't on this iPhone.")
        )
        XCTAssertTrue(
            ReaderCloudWording.downloadStarted(title: "Tides", provider: nil, chapterNumber: 6, isPhone: false).contains("Chapter 6 isn't on this Mac.")
        )
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

    /// Each problem a step can end in has words, the system's own for an error that is not one of ours.
    func testMessagesForProblems() {
        XCTAssertEqual(PhoneSyncSettingsModel.message(for: SyncProblem.exists), SyncWording.folderAlreadyThere)
        XCTAssertEqual(PhoneSyncSettingsModel.message(for: SyncProblem.notASyncFolder), SyncWording.notASyncFolder)
        XCTAssertEqual(PhoneSyncSettingsModel.message(for: SyncProblem.anotherStore), SyncWording.anotherStore)
        XCTAssertEqual(PhoneSyncSettingsModel.message(for: SyncProblem.laterVersion), SyncWording.statusLaterVersion)
        XCTAssertEqual(PhoneSyncSettingsModel.message(for: SyncProblem.offline), SyncWording.waitingForFiles)
        XCTAssertEqual(PhoneSyncSettingsModel.message(for: SyncProblem.damaged(file: "a")), SyncWording.notASyncFolder)
        XCTAssertTrue(PhoneSyncSettingsModel.message(for: SyncProblem.folderMissing).hasSuffix("Your library on this iPhone is as it was."))
        XCTAssertEqual(PhoneSyncSettingsModel.message(for: CocoaError(.fileReadUnknown)), CocoaError(.fileReadUnknown).localizedDescription)
    }

    // MARK: - Where the Folder Is

    /// A folder is in iCloud Drive by its path through `Mobile Documents`; one elsewhere is refused with the plan's words.
    func testRefusesAFolderOutsideICloudDrive() {
        let inDrive = URL(fileURLWithPath: "/Users/reader/Library/Mobile Documents/com~apple~CloudDocs/Books", isDirectory: true)
        let elsewhere = URL(fileURLWithPath: "/Users/reader/Documents/Books", isDirectory: true)
        XCTAssertTrue(PhoneSyncSettingsModel.isInICloudDrive(inDrive))
        XCTAssertFalse(PhoneSyncSettingsModel.isInICloudDrive(elsewhere))
        XCTAssertNil(PhoneSyncSettingsModel.refusal(forFolderInICloudDrive: true))
        XCTAssertEqual(PhoneSyncSettingsModel.refusal(forFolderInICloudDrive: false), "That folder isn't in iCloud Drive. Choose a folder in iCloud Drive.")
    }

    // MARK: - The Steps

    /// What the stand-in services were asked and said, in order.
    private final class Record {
        var calls: [String] = []
        var heard: [String] = []
        var scopesOpen = 0
        var failure: Error?
    }

    /// A controller over stand-in services that record what they are asked.
    private func controller(_ record: Record, inICloudDrive: Bool = true) -> PhoneSyncSettingsController {
        PhoneSyncSettingsController(services: .init(
            setUp: { url in
                record.calls.append("setUp \(url.lastPathComponent) scope \(record.scopesOpen)")
                if let failure = record.failure { throw failure }
            },
            join: { url in
                record.calls.append("join \(url.lastPathComponent) scope \(record.scopesOpen)")
                if let failure = record.failure { throw failure }
            },
            syncNow: { record.calls.append("syncNow") },
            stop: { record.calls.append("stop") },
            isInICloudDrive: { _ in inICloudDrive },
            openScope: { _ in
                record.scopesOpen += 1
                return { record.scopesOpen -= 1 }
            },
            announce: { record.heard.append($0) }
        ))
    }

    private let folder = URL(fileURLWithPath: "/Users/reader/Library/Mobile Documents/com~apple~CloudDocs/Books", isDirectory: true)

    /// Set Up makes the folder with the picked folder's scope open, closes it after, and says "Syncing.".
    func testSetUpKeepsTheScopeOpenAndAnnounces() async {
        let record = Record()
        let steps = controller(record)
        await steps.picked(.success([folder]), for: .setUp)
        XCTAssertEqual(record.calls, ["setUp Books scope 1"])
        XCTAssertEqual(record.scopesOpen, 0)
        XCTAssertEqual(record.heard, ["Syncing."])
        XCTAssertNil(steps.alertMessage)
        XCTAssertFalse(steps.isWorking)
    }

    /// Join joins the picked folder the same way.
    func testJoinJoinsThePickedFolder() async {
        let record = Record()
        let steps = controller(record)
        await steps.picked(.success([folder]), for: .join)
        XCTAssertEqual(record.calls, ["join Books scope 1"])
        XCTAssertEqual(record.heard, ["Waiting for the sync folder's files to arrive from iCloud Drive.", "Syncing."])
    }

    /// A folder outside iCloud Drive is refused, with nothing made, in an alert and by voice.
    func testRefusesAFolderOutsideICloudDriveBeforeMakingAnything() async {
        let record = Record()
        let steps = controller(record, inICloudDrive: false)
        await steps.picked(.success([folder]), for: .setUp)
        XCTAssertEqual(record.calls, [])
        XCTAssertEqual(steps.alertMessage, SyncWording.notInICloudDrive)
        XCTAssertEqual(record.heard, [SyncWording.notInICloudDrive])
        XCTAssertEqual(record.scopesOpen, 0)
    }

    /// A failing step says why, in an alert and by voice, and is not announced as syncing.
    func testAFailedStepSaysWhy() async {
        let record = Record()
        record.failure = SyncProblem.exists
        let steps = controller(record)
        await steps.picked(.success([folder]), for: .setUp)
        XCTAssertEqual(steps.alertMessage, SyncWording.folderAlreadyThere)
        XCTAssertEqual(record.heard, [SyncWording.folderAlreadyThere])
        XCTAssertFalse(steps.isWorking)
        XCTAssertEqual(record.scopesOpen, 0)
    }

    /// A cancelled picker says nothing; a picker that failed says why; no folder chosen does nothing.
    func testPickerCancelAndFailure() async {
        let record = Record()
        let steps = controller(record)
        await steps.picked(.failure(CocoaError(.userCancelled)), for: .setUp)
        await steps.picked(.success([]), for: .join)
        XCTAssertEqual(record.calls, [])
        XCTAssertEqual(record.heard, [])
        XCTAssertNil(steps.alertMessage)
        await steps.picked(.failure(CocoaError(.fileReadNoPermission)), for: .join)
        XCTAssertEqual(steps.alertMessage, CocoaError(.fileReadNoPermission).localizedDescription)
    }

    /// Sync Now goes to the center, which announces its own outcome; Stop Syncing asks first, and nothing stops until yes.
    func testSyncNowAndStop() {
        let record = Record()
        let steps = controller(record)
        steps.syncNow()
        XCTAssertEqual(record.calls, ["syncNow"])
        steps.askToStop()
        XCTAssertTrue(steps.isAskingToStop)
        XCTAssertEqual(record.calls, ["syncNow"])
        steps.confirmStop()
        XCTAssertFalse(steps.isAskingToStop)
        XCTAssertEqual(record.calls, ["syncNow", "stop"])
        XCTAssertEqual(record.heard, ["Sync is off."])
    }

    // MARK: - The Section in Settings

    /// The Sync section comes after About, with its own heading.
    func testTheSectionComesLast() {
        XCTAssertEqual(PhoneSettingsSection.allCases.last, .sync)
        XCTAssertEqual(PhoneSettingsSection.sync.title, "Sync")
    }
}
