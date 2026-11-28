import XCTest
@testable import TextMouth

/// The status line (FR43, section 7): the first state that holds is the one spoken, in the words
/// `SyncWording` pins, for the Mac and the iPhone alike (R9).
final class SyncStatusLineTests: XCTestCase {
    /// A time formatter that needs no zone.
    private let time: (Date) -> String = { _ in "9:41 AM" }

    /// The line for `status` on a Mac.
    private func line(_ status: SyncStatus, phone: Bool = false) -> String {
        SyncStatusLine.text(for: status, isPhone: phone, time: time)
    }

    /// A status that is on and has synced.
    private var upToDate: SyncStatus {
        var status = SyncStatus()
        status.isOn = true
        status.lastSynced = Date(timeIntervalSince1970: 100)
        return status
    }

    /// Off, syncing, and up to date, in that order of precedence.
    func testTheBasicStates() {
        XCTAssertEqual(line(SyncStatus()), SyncWording.statusOff)
        var syncing = upToDate
        syncing.isSyncing = true
        syncing.problem = .offline
        XCTAssertEqual(line(syncing), SyncWording.statusSyncing, "syncing outranks a problem")
        XCTAssertEqual(line(upToDate), SyncWording.statusUpToDate(at: "9:41 AM"))
    }

    /// Each problem has its own sentence, with this device named.
    func testEachProblemHasItsSentence() {
        var status = upToDate
        status.pendingChanges = 3
        status.problem = .offline
        XCTAssertEqual(line(status), SyncWording.statusOffline(changes: 3, device: SyncWording.thisDevice(isPhone: false)))
        XCTAssertEqual(line(status, phone: true), SyncWording.statusOffline(changes: 3, device: SyncWording.thisDevice(isPhone: true)))
        status.problem = .folderMissing
        XCTAssertEqual(line(status), SyncWording.statusFolderMissing(device: SyncWording.thisDevice(isPhone: false)))
        status.problem = .outOfSpace
        status.booksToBackUp = 150
        status.booksBackedUp = 12
        XCTAssertEqual(line(status), SyncWording.statusOutOfSpace(changes: 3, books: 138, device: SyncWording.thisDevice(isPhone: false)))
        status.problem = .laterVersion
        XCTAssertEqual(line(status), SyncWording.statusLaterVersion)
        status.problem = .notDownloaded(device: "iPhone")
        XCTAssertEqual(line(status), SyncWording.statusUploading(changes: 3), "uploads waiting come first (section 7's order)")
        status.pendingChanges = 0
        XCTAssertEqual(line(status), SyncWording.statusNotDownloaded)
        status.problem = .anotherStore
        XCTAssertEqual(line(status), SyncWording.anotherStore)
    }

    /// Held-back removals are said, with how many and what to do, before "up to date".
    func testHeldRemovalsAreSpoken() {
        var status = upToDate
        status.heldRemovals = 42
        let spoken = line(status)
        XCTAssertEqual(spoken, SyncWording.heldRemovals(books: 42, device: SyncWording.thisDevice(isPhone: false)))
        XCTAssertTrue(spoken.contains("42"))
        XCTAssertTrue(spoken.contains(SyncWording.thisDevice(isPhone: false)))
        status.heldRemovals = 0
        XCTAssertEqual(line(status), SyncWording.statusUpToDate(at: "9:41 AM"))
    }

    /// Feed removals held back are said too (FR56), counted as feeds, never as books.
    func testHeldFeedRemovalsAreSpoken() {
        var status = upToDate
        status.heldFeedRemovals = 5
        XCTAssertEqual(
            line(status),
            "TextMouth held back removing 5 feeds, since it looked like a mistake. Check the library on this Mac, then choose Sync Now."
        )
        status.heldRemovals = 42
        XCTAssertTrue(line(status).contains("42 books, 5 feeds"))
    }

    /// The new lines' English, pinned: what a person hears when keeping stops, and when a fetch stalls.
    func testTheNewLinesInEnglish() {
        XCTAssertEqual(SyncWording.announceStoppedKeeping(title: "Moby-Dick"), "No longer keeping Moby-Dick on all devices.")
        XCTAssertEqual(SyncWording.fetchStalled, "iCloud Drive stopped sending this book's files.")
        XCTAssertEqual(SyncWording.fetchCellularHint, "If iCloud Drive can't use cellular data, connect to Wi-Fi.")
        XCTAssertEqual(SyncWording.heldRemovals(books: 42, device: "this Mac"),
                       "TextMouth held back removing 42 books, since it looked like a mistake. Check the library on this Mac, then choose Sync Now.")
        XCTAssertFalse(StoreBookStorage.stalledSentence(onCostlyPath: false).contains("cellular"))
        XCTAssertTrue(StoreBookStorage.stalledSentence(onCostlyPath: true).hasSuffix(SyncWording.fetchCellularHint))
    }

    /// Changes waiting to upload are said when nothing is wrong.
    func testWaitingChanges() {
        var status = upToDate
        status.pendingChanges = 3
        XCTAssertEqual(line(status), SyncWording.statusUploading(changes: 3))
    }

    /// The detail lines name the devices heard from, and the backup's progress while it goes on.
    func testDetailLines() {
        var status = upToDate
        status.lastHeard = ["iPhone": Date(timeIntervalSince1970: 50)]
        status.booksBackedUp = 612
        status.booksToBackUp = 750
        let lines = SyncStatusLine.detailLines(for: status, time: time)
        XCTAssertEqual(lines, [SyncWording.lastHeard(from: "iPhone", at: "9:41 AM"), SyncWording.backingUp(done: 612, total: 750)])
        status.booksBackedUp = 750
        XCTAssertEqual(SyncStatusLine.detailLines(for: status, time: time).count, 1, "a finished backup says nothing")
    }
}
