import XCTest
@testable import TextMouth

/// When sync runs by itself (FR43, section 7): three minutes after a change,
/// hourly, and when the network is back, one run at a time and nothing while
/// sync is off. No test waits for time: each passes the times in.
final class SyncSchedulerTests: XCTestCase {
    /// A fixed starting time.
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A scheduler that is on from `t0`.
    private func scheduler() -> SyncScheduler {
        var scheduler = SyncScheduler()
        scheduler.turnOn(at: t0)
        return scheduler
    }

    /// R1: nothing is due, and nothing wakes, while sync is off.
    func testNothingIsDueWhileOff() {
        var off = SyncScheduler()
        off.noteChange(at: t0)
        off.notePath(satisfied: false, at: t0)
        off.notePath(satisfied: true, at: t0)
        XCTAssertNil(off.nextDue(at: t0.addingTimeInterval(100_000)))
        XCTAssertNil(off.nextWake(after: t0))
    }

    /// A change is sent three minutes after the first unsent change, not three after the last.
    func testChangeMomentCountsFromTheFirstChange() {
        var s = scheduler()
        s.noteChange(at: t0.addingTimeInterval(10))
        s.noteChange(at: t0.addingTimeInterval(150))
        XCTAssertNil(s.nextDue(at: t0.addingTimeInterval(189)))
        XCTAssertEqual(s.nextDue(at: t0.addingTimeInterval(190)), .afterChange)
        XCTAssertEqual(s.nextWake(after: t0), t0.addingTimeInterval(190))
    }

    /// After a run for a change, a later change waits its own three minutes, so such runs are at least three apart.
    func testChangeRunsAreThreeMinutesApart() {
        var s = scheduler()
        s.noteChange(at: t0)
        s.runStarted(for: .afterChange, at: t0.addingTimeInterval(180))
        s.noteChange(at: t0.addingTimeInterval(200))
        s.runFinished(at: t0.addingTimeInterval(210))
        XCTAssertNil(s.nextDue(at: t0.addingTimeInterval(379)))
        XCTAssertEqual(s.nextDue(at: t0.addingTimeInterval(380)), .afterChange)
    }

    /// Any run sends what is waiting, so a change made before it needs no moment of its own.
    func testARunSendsPendingChanges() {
        var s = scheduler()
        s.noteChange(at: t0)
        s.runStarted(for: .syncNow, at: t0.addingTimeInterval(30))
        s.runFinished(at: t0.addingTimeInterval(40))
        XCTAssertNil(s.nextDue(at: t0.addingTimeInterval(500)))
    }

    /// Nothing is due while a run is going; a change during it is due after.
    func testOneRunAtATime() {
        var s = scheduler()
        s.runStarted(for: .launch, at: t0)
        s.noteChange(at: t0.addingTimeInterval(1))
        XCTAssertNil(s.nextDue(at: t0.addingTimeInterval(10_000)))
        XCTAssertNil(s.nextWake(after: t0))
        s.runFinished(at: t0.addingTimeInterval(5))
        XCTAssertEqual(s.nextDue(at: t0.addingTimeInterval(181)), .afterChange)
    }

    /// The hourly moment is an hour after the last run, or after sync turned on.
    func testHourly() {
        var s = scheduler()
        XCTAssertNil(s.nextDue(at: t0.addingTimeInterval(3599)))
        XCTAssertEqual(s.nextDue(at: t0.addingTimeInterval(3600)), .hourly)
        s.runStarted(for: .hourly, at: t0.addingTimeInterval(3600))
        s.runFinished(at: t0.addingTimeInterval(3620))
        XCTAssertNil(s.nextDue(at: t0.addingTimeInterval(7000)))
        XCTAssertEqual(s.nextDue(at: t0.addingTimeInterval(7220)), .hourly)
    }

    /// The network's return counts only after it is held 30 seconds satisfied.
    func testNetworkBackIsHeld() {
        var s = scheduler()
        s.notePath(satisfied: true, at: t0)
        XCTAssertNil(s.nextDue(at: t0.addingTimeInterval(100)), "a satisfied path that was never lost is no return")
        s.notePath(satisfied: false, at: t0.addingTimeInterval(200))
        s.notePath(satisfied: true, at: t0.addingTimeInterval(300))
        XCTAssertNil(s.nextDue(at: t0.addingTimeInterval(329)))
        XCTAssertEqual(s.nextDue(at: t0.addingTimeInterval(330)), .networkBack)
    }

    /// A path lost again during the hold cancels it.
    func testALostPathCancelsTheHold() {
        var s = scheduler()
        s.notePath(satisfied: false, at: t0)
        s.notePath(satisfied: true, at: t0.addingTimeInterval(10))
        s.notePath(satisfied: false, at: t0.addingTimeInterval(20))
        XCTAssertNil(s.nextDue(at: t0.addingTimeInterval(100)))
    }

    /// At most one sync for the network's return in five minutes.
    func testNetworkSyncsAreFiveMinutesApart() {
        var s = scheduler()
        s.notePath(satisfied: false, at: t0)
        s.notePath(satisfied: true, at: t0.addingTimeInterval(10))
        s.runStarted(for: .networkBack, at: t0.addingTimeInterval(40))
        s.runFinished(at: t0.addingTimeInterval(50))
        s.notePath(satisfied: false, at: t0.addingTimeInterval(60))
        s.notePath(satisfied: true, at: t0.addingTimeInterval(70))
        XCTAssertNil(s.nextDue(at: t0.addingTimeInterval(339)))
        XCTAssertEqual(s.nextDue(at: t0.addingTimeInterval(340)), .networkBack)
    }

    /// Turning off forgets every pending moment.
    func testTurnOffForgets() {
        var s = scheduler()
        s.noteChange(at: t0)
        s.turnOff()
        XCTAssertFalse(s.isOn)
        XCTAssertNil(s.nextDue(at: t0.addingTimeInterval(100_000)))
    }
}
