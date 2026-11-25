import XCTest
@testable import TextMouth

/// The baseline, kept through its two ways in; the launch hold (R7); the stamps
/// of a joining device; and the clock's limits (FR43, the early review's items 1, 3, 6, 7).
final class SyncBaselineTests: XCTestCase {
    private typealias Fixtures = SyncTestFixtures

    /// A baseline made the way a caller makes one: the first record absorbed.
    private func recorded(_ library: Library) -> SyncProjection {
        var baseline = SyncProjection()
        let now = SyncProjection.of(library, contents: [:])
        let entries = SyncMerge.changes(from: baseline, to: now, atLaunch: false).map { Fixtures.entry($0.key, $0.value, wall: 1, byHand: now.byHand.contains($0.key)) }
        baseline.absorb(entries)
        return baseline
    }

    // MARK: - Item 1: the baseline

    /// Recording a library and looking again finds nothing to record: removals, hand edits, and list keys all settle.
    func testRecordedLibraryHasNothingMoreToRecord() {
        var book = Fixtures.book()
        book.markEditedByHand([.title])
        let other = Fixtures.book()
        var library = Fixtures.library(books: [book, other], folders: [BookFolder(name: "Fiction")])
        library.readingList = ReadingList(bookIDs: [other.id, book.id])
        let baseline = recorded(library)
        XCTAssertTrue(SyncMerge.changes(from: baseline, to: SyncProjection.of(library, contents: [:]), atLaunch: false).isEmpty)
    }

    /// A removal mark absorbed leaves no trace of the book, and the next look does not record the removal again.
    func testRemovalIsRecordedOnce() {
        let book = Fixtures.book()
        var baseline = recorded(Fixtures.library(books: [book]))
        let now = SyncProjection.of(Fixtures.library(), contents: [:])
        let removal = SyncMerge.changes(from: baseline, to: now, atLaunch: false)
        XCTAssertEqual(removal, [.book(book.id, .presence): .null])
        baseline.absorb([Fixtures.entry(.book(book.id, .presence), .null, wall: 2)])
        XCTAssertTrue(SyncMerge.changes(from: baseline, to: now, atLaunch: false).isEmpty)
    }

    /// A removal mark stored in a baseline by a caller is not recorded again either.
    func testRemovalMarkAlreadyInTheBaselineIsSkipped() throws {
        let book = Fixtures.book()
        let stored = #"{"byHand":[],"values":[{"key":"book/\#(book.id.uuidString.lowercased())/presence","value":null}]}"#
        let baseline = try SyncValueCoding.makeDecoder().decode(SyncProjection.self, from: Data(stored.utf8))
        let changes = SyncMerge.changes(from: baseline, to: SyncProjection.of(Fixtures.library(), contents: [:]), atLaunch: false)
        XCTAssertNil(changes[.book(book.id, .presence)], "the removal is not recorded again")
    }

    /// A baseline reads back as it was written, in the same bytes.
    func testBaselineRoundTrips() throws {
        var book = Fixtures.book()
        book.markEditedByHand([.author])
        let baseline = recorded(Fixtures.library(books: [book], folders: [BookFolder(name: "F")]))
        let data = try SyncFormats.encode(baseline)
        XCTAssertEqual(try SyncValueCoding.makeDecoder().decode(SyncProjection.self, from: data), baseline)
        XCTAssertEqual(try SyncFormats.encode(baseline), data)
    }

    /// Applied keys are absorbed from the winners, with their hand-edit flags and order keys.
    func testAbsorbAppliedTakesTheWinners() {
        let book = Fixtures.book()
        let registers = Fixtures.registers([
            Fixtures.entry(.book(book.id, .title), .string("T"), wall: 3, byHand: true),
            Fixtures.entry(.readingList(book: book.id), .string("V"), wall: 3),
            Fixtures.entry(.book(book.id, .rate), .integer(200), wall: 3),
        ])
        var baseline = SyncProjection()
        baseline.absorbApplied([.book(book.id, .title), .readingList(book: book.id)], from: registers)
        XCTAssertEqual(baseline.values[.book(book.id, .title)], .string("T"))
        XCTAssertTrue(baseline.byHand.contains(.book(book.id, .title)))
        XCTAssertEqual(baseline.values[.readingList(book: book.id)], .string("V"))
        XCTAssertNil(baseline.values[.book(book.id, .rate)], "a key not applied stays out")
    }

    /// A folder's removal mark, naming its survivor, is a removal in a baseline too.
    func testFoldedFolderMarkForgetsTheFolder() {
        let folder = BookFolder(name: "A")
        var baseline = recorded(Fixtures.library(folders: [folder]))
        baseline.absorb([Fixtures.entry(.folder(folder.id, .presence), SyncValueCoding.id(UUID()), wall: 5)])
        XCTAssertNil(baseline.values[.folder(folder.id, .name)])
    }

    // MARK: - Item 3: missing at launch

    /// A book missing at launch is held back at every record until the first apply, and put back by it.
    func testOfflineLaunchNeverReportsAMissingBookAsRemoved() {
        let book = Fixtures.book(), stays = Fixtures.book()
        let baseline = recorded(Fixtures.library(books: [book, stays]))
        let atLaunch = SyncProjection.of(Fixtures.library(books: [stays]), contents: [:])
        var hold = SyncLaunchHold()
        hold.observeLaunch(baseline: baseline, now: atLaunch)
        XCTAssertTrue(SyncMerge.changes(from: baseline, to: atLaunch, hold: hold).isEmpty)
        // A later record, still before any apply (an offline launch, or a change made while the sync reads).
        var later = Fixtures.library(books: [stays])
        later.books[0].title = "Changed meanwhile"
        let laterChanges = SyncMerge.changes(from: baseline, to: SyncProjection.of(later, contents: [:]), hold: hold)
        XCTAssertEqual(laterChanges, [.book(stays.id, .title): .string("Changed meanwhile")])
    }

    /// A book a person removes in the running app is reported, even before the first apply.
    func testRemovalInTheRunningAppIsNotHeld() {
        let book = Fixtures.book(), other = Fixtures.book()
        let baseline = recorded(Fixtures.library(books: [book, other]))
        var hold = SyncLaunchHold()
        hold.observeLaunch(baseline: baseline, now: SyncProjection.of(Fixtures.library(books: [book, other]), contents: [:]))
        let removed = SyncProjection.of(Fixtures.library(books: [other]), contents: [:])
        XCTAssertEqual(SyncMerge.changes(from: baseline, to: removed, hold: hold), [.book(book.id, .presence): .null])
    }

    /// After the first apply a book that came back is whole again, and one still missing is forgotten, not removed.
    func testSettleForgetsWhatIsStillMissing() {
        let gone = Fixtures.book(), back = Fixtures.book()
        var baseline = recorded(Fixtures.library(books: [gone, back]))
        var hold = SyncLaunchHold()
        hold.observeLaunch(baseline: baseline, now: SyncProjection.of(Fixtures.library(), contents: [:]))
        let afterApply = SyncProjection.of(Fixtures.library(books: [back]), contents: [:])
        hold.settle(baseline: &baseline, now: afterApply)
        XCTAssertTrue(hold.held.isEmpty)
        XCTAssertNil(baseline.values[.book(gone.id, .presence)])
        XCTAssertNotNil(baseline.values[.book(back.id, .presence)])
        XCTAssertTrue(SyncMerge.changes(from: baseline, to: afterApply, hold: hold).isEmpty)
    }

    /// The launch is looked at once: a later call does not hold what then goes missing.
    func testLaunchIsObservedOnce() {
        let book = Fixtures.book()
        let baseline = recorded(Fixtures.library(books: [book]))
        var hold = SyncLaunchHold()
        hold.observeLaunch(baseline: baseline, now: SyncProjection.of(Fixtures.library(books: [book]), contents: [:]))
        hold.observeLaunch(baseline: baseline, now: SyncProjection.of(Fixtures.library(), contents: [:]))
        XCTAssertTrue(hold.held.isEmpty)
    }

    // MARK: - Item 6: a joining device's stamps

    /// A place is stamped at its own date, a bookmark at its own, and what has no date at the lowest stamp.
    func testJoiningStampsUseTheValuesOwnDate() {
        let id = UUID()
        var book = Fixtures.book(id: id)
        var place = ReadingPosition(chapterIndex: 1, characterOffset: 5)
        place.lastUpdated = Date(timeIntervalSince1970: 1_000)
        book.readingPosition = place
        let bookmark = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0, dateCreated: Date(timeIntervalSince1970: 2_000))
        book.bookmarks = [bookmark]
        let projection = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        func stamp(_ key: SyncKey) -> SyncStamp {
            SyncMerge.joiningStamp(for: key, value: projection.values[key] ?? .null, device: "d")
        }
        XCTAssertEqual(stamp(.book(id, .position)), SyncStamp(wall: 1_000_000, counter: 0, device: "d"))
        XCTAssertEqual(stamp(.bookmark(book: id, id: bookmark.id)), SyncStamp(wall: 2_000_000, counter: 0, device: "d"))
        XCTAssertEqual(stamp(.book(id, .title)), SyncStamp(wall: 0, counter: 0, device: "d"))
        XCTAssertEqual(stamp(.book(id, .presence)), SyncStamp(wall: 0, counter: 0, device: "d"))
    }

    /// A joining device's older place loses to a newer one in the store, and its presence to a removal.
    func testJoiningDeviceDoesNotOutrankTheStore() {
        let book = Fixtures.book()
        var older = ReadingPosition(chapterIndex: 1)
        older.lastUpdated = Date(timeIntervalSince1970: 100)
        let theirs = Fixtures.entry(.book(book.id, .position), SyncValueCoding.json(ReadingPosition(chapterIndex: 9)), wall: 500_000, device: "other")
        let removal = Fixtures.entry(.book(book.id, .presence), .null, wall: 10, device: "other")
        let mine = [
            SyncEntry(key: .book(book.id, .position), value: SyncValueCoding.json(older),
                      stamp: SyncMerge.joiningStamp(for: .book(book.id, .position), value: SyncValueCoding.json(older), device: "me"), byHand: false),
            SyncEntry(key: .book(book.id, .presence), value: .bool(true),
                      stamp: SyncMerge.joiningStamp(for: .book(book.id, .presence), value: .bool(true), device: "me"), byHand: false),
        ]
        let registers = Fixtures.registers([theirs, removal] + mine)
        XCTAssertEqual(registers.entries[.book(book.id, .position)]?.value, theirs.value)
        XCTAssertEqual(registers.entries[.book(book.id, .presence)]?.value, .null)
    }

    // MARK: - Item 7: the clock

    /// A remote counter at its limit does not wrap: the next stamp is above the remote.
    func testObserveAtTheCounterLimitStaysAbove() {
        var clock = SyncClock(device: "a")
        let remote = SyncStamp(wall: 5_000, counter: UInt32.max, device: "b")
        XCTAssertTrue(clock.observe(remote, at: Date(timeIntervalSince1970: 1)))
        XCTAssertLessThan(remote, clock.next(at: Date(timeIntervalSince1970: 1)))
    }

    /// A stamp more than a day ahead is refused, and the clock is left as it was.
    func testObserveRefusesAStampFarAhead() {
        var clock = SyncClock(device: "a")
        let now = Date(timeIntervalSince1970: 1_000_000)
        _ = clock.next(at: now)
        let before = clock.last
        XCTAssertFalse(clock.observe(SyncStamp(wall: Int64(now.timeIntervalSince1970 * 1000) + SyncClock.maximumAhead + 1, counter: 0, device: "b"), at: now))
        XCTAssertEqual(clock.last, before)
        XCTAssertTrue(clock.observe(SyncStamp(wall: Int64(now.timeIntervalSince1970 * 1000) + SyncClock.maximumAhead, counter: 0, device: "b"), at: now))
    }
}
