import os
import XCTest
@testable import TextMouth

/// A scripted uptime a test moves by hand, starting at 1,000 seconds. At
/// file scope, as the iPhone's test counter reads a test class's tests
/// (Scripts/agents/ios_ui_tests.py).
private final class ScriptedUptime: Sendable {
    let seconds = OSAllocatedUnfairLock<TimeInterval>(initialState: 1_000)

    /// Moves the uptime on by `step` seconds.
    func advance(by step: TimeInterval) {
        seconds.withLock { $0 += step }
    }

    /// The uptime, as the clock reads it.
    var reading: @Sendable () -> TimeInterval {
        { [seconds] in seconds.withLock { $0 } }
    }
}

/// Tests of `RunningClock` (B18), the clock the in-app engines time their
/// calls by, which counts only the time TextMouth runs: each reading counts
/// the uptime since the one before up to its longest step, so a gap that
/// only a suspension makes counts no more than that, and its heartbeat reads
/// it while it is held, so the time the app runs is counted whole. Shared
/// with the iPhone's unit bundle.
///
/// The uptime is scripted, except where the heartbeat is the subject, which
/// waits a second and a half at most.
final class RunningClockTests: XCTestCase {
    /// Readings closer together than the longest step count the uptime
    /// between them whole; the first reading is 0.
    func testReadingsCloserThanTheLongestStepCountTheUptimeWhole() {
        let uptime = ScriptedUptime()
        let clock = RunningClock(uptime: uptime.reading, longestStep: 1, tick: nil)
        XCTAssertEqual(clock.now(), 0)
        uptime.advance(by: 0.4)
        XCTAssertEqual(clock.now(), 0.4, accuracy: 1e-9)
        uptime.advance(by: 0.9)
        XCTAssertEqual(clock.now(), 1.3, accuracy: 1e-9)
    }

    /// A gap longer than the longest step, as only a suspension makes while
    /// something times a call, counts the longest step and no more; the
    /// readings after it count whole again.
    func testAGapLongerThanTheLongestStepCountsOnlyTheLongestStep() {
        let uptime = ScriptedUptime()
        let clock = RunningClock(uptime: uptime.reading, longestStep: 1, tick: nil)
        XCTAssertEqual(clock.now(), 0)
        uptime.advance(by: 300)  // five minutes in another app
        XCTAssertEqual(clock.now(), 1, accuracy: 1e-9)
        uptime.advance(by: 0.5)
        XCTAssertEqual(clock.now(), 1.5, accuracy: 1e-9)
    }

    /// The clock never runs backwards, whatever its uptime says: a reading
    /// that goes back counts nothing, and the next counts from the latest.
    func testTheClockNeverRunsBackwards() {
        let uptime = ScriptedUptime()
        let clock = RunningClock(uptime: uptime.reading, longestStep: 1, tick: nil)
        uptime.advance(by: 0.5)
        XCTAssertEqual(clock.now(), 0)
        uptime.advance(by: -0.5)
        XCTAssertEqual(clock.now(), 0)
        uptime.advance(by: 0.75)
        XCTAssertEqual(clock.now(), 0.25, accuracy: 1e-9)
    }

    /// A clock counting every step whole (the Mac's, and a test's script)
    /// counts any gap as it is.
    func testAClockCountingWholeCountsEveryGap() {
        let uptime = ScriptedUptime()
        let clock = RunningClock(countingWhole: uptime.reading)
        XCTAssertEqual(clock.now(), 0)
        uptime.advance(by: 300)
        XCTAssertEqual(clock.now(), 300, accuracy: 1e-9)
    }

    /// While held, the heartbeat reads the clock every tick, so a stretch
    /// longer than the longest step in which nothing else reads it is still
    /// counted whole; released, it stops reading. Without the heartbeat the
    /// same stretch would count only the longest step.
    func testAHeldClockCountsTheTimeTheAppRunsWhole() {
        let readings = OSAllocatedUnfairLock(initialState: 0)
        let clock = RunningClock(
            uptime: { readings.withLock { $0 += 1 }; return ProcessInfo.processInfo.systemUptime },
            longestStep: 0.5,
            tick: 0.1
        )
        clock.hold()
        let start = clock.now()
        Thread.sleep(forTimeInterval: 1.2)
        let held = clock.now() - start
        clock.release()
        // Without the heartbeat the two readings, 1.2 seconds apart, would count only the longest step.
        XCTAssertGreaterThan(held, 0.9, "the heartbeat did not keep the clock counting")
        // The heartbeat ends at its next tick once nothing holds the clock.
        Thread.sleep(forTimeInterval: 0.3)
        let afterRelease = readings.withLock { $0 }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(readings.withLock { $0 }, afterRelease, "the heartbeat went on after the clock was released")
    }

    // MARK: - Its Holders (the check of the FMT54 review's fixes, item 5)

    /// A clock whose heartbeat reads it every 0.05 seconds while held, and how
    /// many times it has been read.
    private func countedClock() -> (clock: RunningClock, readings: @Sendable () -> Int) {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let clock = RunningClock(
            uptime: { count.withLock { $0 += 1 }; return ProcessInfo.processInfo.systemUptime },
            longestStep: 1,
            tick: 0.05
        )
        return (clock, { count.withLock { $0 } })
    }

    /// Whether the heartbeat reads the clock while the test waits 0.4
    /// seconds, eight ticks' time, in which nothing else reads it.
    private func heartbeatReads(_ readings: @Sendable () -> Int) -> Bool {
        let before = readings()
        Thread.sleep(forTimeInterval: 0.4)
        return readings() > before + 2
    }

    /// Two holders keep the heartbeat going until both have released: the
    /// first release leaves it reading the clock, and the second ends it at
    /// its next tick.
    func testTwoHoldersKeepTheHeartbeatUntilBothRelease() {
        let (clock, readings) = countedClock()
        clock.hold()
        clock.hold()
        clock.release()
        XCTAssertTrue(heartbeatReads(readings), "one release of two ended the heartbeat")
        clock.release()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(heartbeatReads(readings), "the heartbeat went on after both holders released")
    }

    /// A hold right after a release, before the heartbeat's next tick, keeps
    /// it going: the tick that would have ended it finds the clock held
    /// again, decided under the same lock as the hold.
    func testAHoldRightAfterAReleaseKeepsTheHeartbeat() {
        let (clock, readings) = countedClock()
        clock.hold()
        clock.release()
        clock.hold()
        XCTAssertTrue(heartbeatReads(readings), "a hold right after a release left the heartbeat ended")
        clock.release()
    }

    /// A hold after the heartbeat has stopped at rest starts it again.
    func testAHoldAfterTheHeartbeatStoppedStartsItAgain() {
        let (clock, readings) = countedClock()
        clock.hold()
        clock.release()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(heartbeatReads(readings), "the heartbeat went on at rest")
        clock.hold()
        XCTAssertTrue(heartbeatReads(readings), "a new hold did not start the heartbeat again")
        clock.release()
    }

    // MARK: - The App's

    /// The app's clock is the one every in-app engine is timed by.
    func testTheEnginesAreTimedByTheAppsClock() {
        XCTAssertTrue(InProcessEngine(name: "test-clock", work: "the test work").clock === RunningClock.app)
    }
}
