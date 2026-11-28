import XCTest
@testable import TextMouth

/// Pins `SyncWording`'s English (FR43, rule R9): the lines the plan's sections
/// 7 and 10 give, word for word.
final class SyncWordingTests: XCTestCase {
    /// The section's commands and their hints.
    func testCommandsAndHints() {
        XCTAssertEqual(SyncWording.sectionTitle, "Sync")
        XCTAssertEqual(SyncWording.setUpTitle, "Set Up Sync…")
        XCTAssertEqual(SyncWording.joinTitle, "Join Sync Folder…")
        XCTAssertEqual(SyncWording.syncNowTitle, "Sync Now")
        XCTAssertEqual(SyncWording.stopTitle, "Stop Syncing…")
        XCTAssertEqual(SyncWording.stopQuestion, "Stop syncing this library? Nothing is deleted, on this Mac or in iCloud Drive.")
        XCTAssertEqual(SyncWording.setUpHint, "Makes a folder named TextMouth Sync in the iCloud Drive folder you choose, and copies your books into it.")
        XCTAssertEqual(SyncWording.joinHint, "Chooses the TextMouth Sync folder that another device set up.")
    }

    /// The refusals.
    func testRefusals() {
        XCTAssertEqual(SyncWording.notInICloudDrive, "That folder isn't in iCloud Drive. Choose a folder in iCloud Drive.")
        XCTAssertEqual(SyncWording.libraryNotLocal, "Sync is for a library kept on this Mac. Move this one here with Change Location first.")
        XCTAssertEqual(SyncWording.folderAlreadyThere, "A folder named TextMouth Sync is already there. To use it, choose Join Sync Folder.")
        XCTAssertEqual(SyncWording.notASyncFolder, "That isn't a TextMouth Sync folder, or its files haven't arrived from iCloud Drive yet.")
        XCTAssertEqual(SyncWording.anotherStore, "The sync folder now holds another library's sync. Choose Join Sync Folder again.")
        XCTAssertEqual(SyncWording.waitingForFiles, "Waiting for the sync folder's files to arrive from iCloud Drive.")
    }

    /// The status line's states, for the Mac.
    func testStatusLines() {
        let mac = SyncWording.thisDevice(isPhone: false)
        XCTAssertEqual(mac, "this Mac")
        XCTAssertEqual(SyncWording.thisDevice(isPhone: true), "this iPhone")
        XCTAssertEqual(SyncWording.statusOff, "Sync is off.")
        XCTAssertEqual(SyncWording.statusSyncing, "Syncing…")
        XCTAssertEqual(SyncWording.statusOffline(changes: 3, device: mac), "Offline. 3 changes wait on this Mac, and will be sent when the network is back.")
        XCTAssertEqual(SyncWording.statusFolderMissing(device: mac), "TextMouth can't find the TextMouth Sync folder in iCloud Drive. It may have been moved or deleted, or iCloud Drive signed out. Your library on this Mac is as it was.")
        XCTAssertEqual(SyncWording.statusOutOfSpace(changes: 3, books: 138, device: mac), "iCloud Drive is full, so 3 changes and 138 books aren't uploaded. Your library on this Mac is as it was.")
        XCTAssertEqual(SyncWording.statusLaterVersion, "A later TextMouth made this sync folder. Update TextMouth to use it.")
        XCTAssertEqual(SyncWording.statusUploading(changes: 3), "3 changes are waiting for iCloud Drive to upload them.")
        XCTAssertEqual(SyncWording.statusNotDownloaded, "Some changes from iPhone haven't downloaded yet. TextMouth will try again.")
        XCTAssertEqual(SyncWording.statusUpToDate(at: "9:41 AM"), "Up to date. Last synced at 9:41 AM.")
        XCTAssertEqual(SyncWording.lastHeard(from: "iPhone", at: "9:40 AM"), "Last heard from iPhone at 9:40 AM.")
        XCTAssertEqual(SyncWording.backingUp(done: 612, total: 750), "Backing up books: 612 of 750.")
    }

    /// What Sync Now announces.
    func testAnnouncements() {
        XCTAssertEqual(SyncWording.announceSyncing, "Syncing.")
        XCTAssertEqual(SyncWording.announceSynced(changes: 4, from: "iPhone"), "Synced. 4 changes from iPhone.")
        XCTAssertEqual(SyncWording.announceNothingNew, "Synced. Nothing new.")
        XCTAssertEqual(SyncWording.announceMovedToPlace(from: "iPhone"), "Moved to the place saved on iPhone.")
    }

    /// Keep on All Devices (section 16 of the plan).
    func testKeepOnAllDevices() {
        XCTAssertEqual(SyncWording.keepTitle, "Keep on All Devices")
        XCTAssertEqual(SyncWording.stopKeepingTitle, "Stop Keeping on All Devices")
        XCTAssertEqual(SyncWording.keepTitle(count: 3), "Keep 3 Books on All Devices")
        XCTAssertEqual(SyncWording.stopKeepingTitle(count: 3), "Stop Keeping 3 Books on All Devices")
        XCTAssertEqual(SyncWording.keptState, "Kept on all devices")
        XCTAssertEqual(SyncWording.keepHint, "Every device that syncs keeps this book's files, and downloads them when it can.")
        XCTAssertEqual(SyncWording.announceKeeping(title: "Moby-Dick"), "Keeping Moby-Dick on all devices.")
    }
}
