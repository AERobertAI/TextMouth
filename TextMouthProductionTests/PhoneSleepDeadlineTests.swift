import XCTest
@testable import TextMouth

/// `PhoneSleepDeadline`, the iPhone sleep timer's countdown held as a deadline.
/// Every test reads a clock it moves itself, so none waits for real time.
final class PhoneSleepDeadlineTests: XCTestCase {
    /// The moment each test's deadline is set from.
    private let start = ContinuousClock.now

    /// `start` moved on by `seconds`, which may hold a fraction.
    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(Int((seconds * 1_000).rounded())))
    }

    // MARK: - What Is Left

    /// What is left is rounded up, so each tick shows what the Mac's would: a
    /// moment after the first second of a 30-minute timer shows 29:59, and the
    /// countdown shows zero only once the deadline has passed.
    func testSecondsLeftAreRoundedUp() {
        let deadline = PhoneSleepDeadline(secondsLeft: 1_800, from: start)

        XCTAssertEqual(deadline.secondsLeft(at: start), 1_800)
        XCTAssertEqual(deadline.secondsLeft(at: at(0.4)), 1_800)
        XCTAssertEqual(deadline.secondsLeft(at: at(1.0)), 1_799)
        XCTAssertEqual(deadline.secondsLeft(at: at(1.001)), 1_799)
        XCTAssertEqual(deadline.secondsLeft(at: at(1_799.5)), 1)
        XCTAssertEqual(deadline.secondsLeft(at: at(1_800)), 0)
        XCTAssertFalse(deadline.hasRunOut(at: at(1_799.999)))
        XCTAssertTrue(deadline.hasRunOut(at: at(1_800)))
    }

    /// Long after the deadline, nothing is left, never less than nothing: a
    /// phone that comes back an hour late finds a timer that has run out.
    func testNothingIsLeftLongAfterTheDeadline() {
        let deadline = PhoneSleepDeadline(secondsLeft: 60, from: start)

        XCTAssertEqual(deadline.secondsLeft(at: at(3_600)), 0)
        XCTAssertTrue(deadline.hasRunOut(at: at(3_600)))
    }

    /// A count below zero is read as zero, a countdown that has run out.
    func testANegativeCountHasRunOut() {
        let deadline = PhoneSleepDeadline(secondsLeft: -5, from: start)

        XCTAssertEqual(deadline.endsAt, start)
        XCTAssertTrue(deadline.hasRunOut(at: start))
    }

    /// A deadline set again on resuming counts from the resume, as the Mac's
    /// countdown keeps its seconds through a pause.
    func testADeadlineSetOnResumingCountsFromThere() {
        let resumed = PhoneSleepDeadline(secondsLeft: 90, from: at(600))

        XCTAssertEqual(resumed.secondsLeft(at: at(600)), 90)
        XCTAssertEqual(resumed.secondsLeft(at: at(630)), 60)
        XCTAssertTrue(resumed.hasRunOut(at: at(690)))
    }

    // MARK: - Milestones

    /// The milestones are the Mac's own: five minutes, one minute, thirty and
    /// ten seconds.
    func testTheMilestonesAreTheMacs() {
        XCTAssertEqual(PhoneSleepDeadline.milestones, [300, 60, 30, 10])
    }

    /// A tick on time passes a milestone exactly as the Mac's matching does.
    func testATickOnTimePassesAMilestoneItReaches() {
        XCTAssertEqual(PhoneSleepDeadline.milestonesPassed(from: 301, to: 300), [300])
        XCTAssertEqual(PhoneSleepDeadline.milestonesPassed(from: 61, to: 60), [60])
        XCTAssertEqual(PhoneSleepDeadline.milestonesPassed(from: 11, to: 10), [10])
        XCTAssertEqual(PhoneSleepDeadline.milestonesPassed(from: 300, to: 299), [])
        XCTAssertEqual(PhoneSleepDeadline.milestonesPassed(from: 59, to: 58), [])
    }

    /// A late tick that jumps past a milestone still passes it, where the
    /// Mac's exact match would miss it; a long jump passes several, earliest
    /// first.
    func testALateTickPassesTheMilestonesItJumpsOver() {
        XCTAssertEqual(PhoneSleepDeadline.milestonesPassed(from: 302, to: 299), [300])
        XCTAssertEqual(PhoneSleepDeadline.milestonesPassed(from: 400, to: 25), [300, 60, 30])
        XCTAssertEqual(PhoneSleepDeadline.milestonesPassed(from: 400, to: 0), [300, 60, 30, 10])
    }

    /// A timer started at a milestone has not passed it, as on the Mac, whose
    /// five-minute timer never says "5 minutes remaining"; and a tick that
    /// shows no less time passes nothing.
    func testStartingAtAMilestoneDoesNotPassIt() {
        XCTAssertEqual(PhoneSleepDeadline.milestonesPassed(from: 300, to: 300), [])
        XCTAssertEqual(PhoneSleepDeadline.milestonesPassed(from: 60, to: 59), [])
        XCTAssertEqual(PhoneSleepDeadline.milestonesPassed(from: 10, to: 12), [])
    }

    // MARK: - Ticks

    /// Ticks on time count down a second each, skip nothing, and run out at
    /// the deadline, as the Mac's ticks do.
    func testTicksOnTimeCountDownOneSecondEach() {
        let deadline = PhoneSleepDeadline(secondsLeft: 3, from: start)

        let first = deadline.tick(at: at(1.002), after: 3)
        XCTAssertEqual(first.secondsLeft, 2)
        XCTAssertEqual(first.skippedSeconds, 0)
        XCTAssertFalse(first.hasRunOut)

        let second = deadline.tick(at: at(2.002), after: first.secondsLeft)
        XCTAssertEqual(second.secondsLeft, 1)
        XCTAssertFalse(second.hasRunOut)

        let third = deadline.tick(at: at(3.002), after: second.secondsLeft)
        XCTAssertEqual(third.secondsLeft, 0)
        XCTAssertEqual(third.skippedSeconds, 0)
        XCTAssertEqual(third.milestonesPassed, [])
        XCTAssertTrue(third.hasRunOut)
    }

    /// A tick that comes late shows what the deadline leaves, says how many
    /// seconds it jumped, and passes the milestones on the way: the Mac's
    /// countdown would have lost those seconds and played on past its time.
    func testALateTickJumpsToWhatTheDeadlineLeaves() {
        let deadline = PhoneSleepDeadline(secondsLeft: 600, from: start)

        let late = deadline.tick(at: at(330.5), after: 310)

        XCTAssertEqual(late.secondsLeft, 270)
        XCTAssertEqual(late.skippedSeconds, 39)
        XCTAssertEqual(late.milestonesPassed, [300])
        XCTAssertTrue(late.isWorthTracing, "A jump is the evidence the first run should log")
    }

    /// A tick after the deadline has passed runs the timer out at once, having
    /// passed every milestone left.
    func testATickAfterTheDeadlineRunsOut() {
        let deadline = PhoneSleepDeadline(secondsLeft: 600, from: start)

        let tick = deadline.tick(at: at(5_000), after: 320)

        XCTAssertTrue(tick.hasRunOut)
        XCTAssertEqual(tick.milestonesPassed, [300, 60, 30, 10])
    }

    /// A clock read a moment early never makes the countdown go back up.
    func testATickNeverShowsMoreThanTheTickBefore() {
        let deadline = PhoneSleepDeadline(secondsLeft: 100, from: start)

        let tick = deadline.tick(at: at(0.5), after: 99)

        XCTAssertEqual(tick.secondsLeft, 99)
        XCTAssertEqual(tick.skippedSeconds, 0)
        XCTAssertEqual(tick.milestonesPassed, [])
    }

    /// A countdown resumed with nothing left runs out at its first tick.
    func testACountdownResumedWithNothingLeftRunsOutAtOnce() {
        let deadline = PhoneSleepDeadline(secondsLeft: 0, from: start)

        let tick = deadline.tick(at: start, after: 0)

        XCTAssertTrue(tick.hasRunOut)
        XCTAssertEqual(tick.skippedSeconds, 0)
    }

    /// The trace keeps the Mac's lines, minute boundaries and the last ten
    /// seconds, and adds jumps; an ordinary second in mid-countdown is not
    /// traced.
    func testWhichTicksAreTraced() {
        func tick(_ secondsLeft: Int, skipped: Int = 0) -> PhoneSleepDeadline.Tick {
            PhoneSleepDeadline.Tick(secondsLeft: secondsLeft, milestonesPassed: [], skippedSeconds: skipped)
        }

        XCTAssertTrue(tick(120).isWorthTracing)
        XCTAssertTrue(tick(10).isWorthTracing)
        XCTAssertTrue(tick(0).isWorthTracing)
        XCTAssertTrue(tick(95, skipped: 4).isWorthTracing)
        XCTAssertFalse(tick(95).isWorthTracing)
        XCTAssertFalse(tick(11).isWorthTracing)
    }
}
