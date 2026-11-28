import XCTest
@testable import TextMouth

/// Stamps and the clock (FR43): the order of changes on every device.
final class SyncStampTests: XCTestCase {
    /// A date `seconds` after 1970, to the millisecond.
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    /// Stamps order by wall time, then counter, then device.
    func testStampOrder() {
        XCTAssertLessThan(SyncStamp(wall: 1, counter: 9, device: "z"), SyncStamp(wall: 2, counter: 0, device: "a"))
        XCTAssertLessThan(SyncStamp(wall: 2, counter: 0, device: "z"), SyncStamp(wall: 2, counter: 1, device: "a"))
        XCTAssertLessThan(SyncStamp(wall: 2, counter: 1, device: "a"), SyncStamp(wall: 2, counter: 1, device: "b"))
    }

    /// A new clock starts below any stamp of a real time.
    func testNextUsesTheClock() {
        var clock = SyncClock(device: "a")
        let stamp = clock.next(at: date(10))
        XCTAssertEqual(stamp, SyncStamp(wall: 10_000, counter: 0, device: "a"))
        XCTAssertEqual(clock.last, stamp)
    }

    /// Two changes in one millisecond are told apart by the counter.
    func testNextInOneMillisecondCounts() {
        var clock = SyncClock(device: "a")
        let first = clock.next(at: date(10))
        let second = clock.next(at: date(10))
        XCTAssertLessThan(first, second)
        XCTAssertEqual(second.wall, first.wall)
        XCTAssertEqual(second.counter, 1)
    }

    /// A clock set back never dates a change before an earlier one.
    func testNextAfterTheClockMovedBackStaysAbove() {
        var clock = SyncClock(device: "a")
        let first = clock.next(at: date(100))
        let second = clock.next(at: date(5))
        XCTAssertLessThan(first, second)
        XCTAssertEqual(second.wall, first.wall)
    }

    /// Observing a later stamp puts the next change above it, even with a slow clock.
    func testObserveRaisesTheClockPastARemoteStamp() {
        var clock = SyncClock(device: "a")
        _ = clock.next(at: date(10))
        let remote = SyncStamp(wall: 50_000, counter: 3, device: "b")
        clock.observe(remote, at: date(11))
        XCTAssertLessThan(remote, clock.next(at: date(11)))
    }

    /// A stamp the clock is already past changes nothing.
    func testObserveOfAnEarlierStampChangesNothing() {
        var clock = SyncClock(device: "a")
        let latest = clock.next(at: date(100))
        clock.observe(SyncStamp(wall: 1, counter: 0, device: "b"), at: date(100))
        XCTAssertEqual(clock.last, latest)
    }

    /// A clock far ahead of a remote stamp starts its counter again.
    func testObserveWithALaterClockResetsTheCounter() {
        var clock = SyncClock(device: "a")
        clock.observe(SyncStamp(wall: 1_000, counter: 7, device: "b"), at: date(500))
        XCTAssertEqual(clock.last, SyncStamp(wall: 500_000, counter: 0, device: "a"))
    }

    /// A clock reads back from the file it was saved in.
    func testClockRoundTrips() throws {
        var clock = SyncClock(device: "a")
        _ = clock.next(at: date(10))
        let data = try SyncFormats.encode(clock)
        XCTAssertEqual(try SyncValueCoding.makeDecoder().decode(SyncClock.self, from: data).last, clock.last)
    }

    /// A hand edit outranks a later stamp; then the later stamp wins.
    func testEntriesOutrankByHandThenStamp() {
        let key = SyncKey.book(UUID(), .title)
        let early = SyncEntry(key: key, value: .string("a"), stamp: SyncStamp(wall: 1, counter: 0, device: "a"), byHand: true)
        let late = SyncEntry(key: key, value: .string("b"), stamp: SyncStamp(wall: 9, counter: 0, device: "b"), byHand: false)
        XCTAssertTrue(early.outranks(late))
        XCTAssertFalse(late.outranks(early))
        var later = late
        later.byHand = true
        XCTAssertTrue(later.outranks(early))
        XCTAssertFalse(early.outranks(later))
        XCTAssertFalse(early.outranks(early))
    }

    /// Two entries of one stamp are told apart the same way both ways round.
    func testEqualStampsAreTiedByValue() {
        let key = SyncKey.book(UUID(), .title)
        let stamp = SyncStamp(wall: 1, counter: 0, device: "a")
        let one = SyncEntry(key: key, value: .string("a"), stamp: stamp, byHand: false)
        let two = SyncEntry(key: key, value: .string("b"), stamp: stamp, byHand: false)
        XCTAssertNotEqual(one.outranks(two), two.outranks(one))
    }
}
