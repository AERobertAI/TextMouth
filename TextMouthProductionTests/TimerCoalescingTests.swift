import XCTest
@testable import TextMouth

/// The audit's C16 (November 13, 2026): the app's background timers let
/// macOS coalesce their wake-ups, by a tolerance of a tenth of their
/// interval, while the sleep countdown's timer stays exact and acts on the
/// main thread at once.
@MainActor
final class TimerCoalescingTests: XCTestCase {

    // MARK: - The Rule

    /// A tenth of the interval, and none for an interval that is not positive.
    func testToleranceIsATenthOfTheInterval() {
        XCTAssertEqual(TimerCoalescing.tolerance(forInterval: 60), 6, accuracy: 0.000_001)
        XCTAssertEqual(TimerCoalescing.tolerance(forInterval: 0.5), 0.05, accuracy: 0.000_001)
        XCTAssertEqual(TimerCoalescing.tolerance(forInterval: 0), 0)
        XCTAssertEqual(TimerCoalescing.tolerance(forInterval: -3), 0)
    }

    /// Loosening a timer sets its tolerance from its own interval.
    func testLoosenSetsTheTimersTolerance() {
        let timer = Timer(timeInterval: 20, repeats: true) { _ in }
        XCTAssertEqual(timer.tolerance, 0)

        TimerCoalescing.loosen(timer)

        XCTAssertEqual(timer.tolerance, 2, accuracy: 0.000_001)
    }

    // MARK: - The Timers

    /// The statistics checkpoint timer is loosened.
    func testTheStatisticsCheckpointTimerIsLoosened() throws {
        let directory = try makeSandboxDirectory("CoalescingStats")
        let service = ReadingStatsService(
            fileURL: directory.appendingPathComponent("reading_stats.json"),
            checkpointInterval: 40
        )
        addTeardownBlock { @MainActor in service.shutdown() }

        let timer = try XCTUnwrap(service.checkpointTimer)
        XCTAssertEqual(timer.tolerance, 4, accuracy: 0.000_001)
    }

    /// The session lease's refresh timer is loosened.
    func testTheSessionLeaseTimerIsLoosened() throws {
        let harness = try LeaseHarness(test: self, refreshInterval: 30)

        harness.lease.begin()

        let timer = try XCTUnwrap(harness.lease.timer)
        XCTAssertEqual(timer.tolerance, 3, accuracy: 0.000_001)
    }

    /// The speech watchdogs' timer is loosened.
    func testTheSpeechWatchdogTimerIsLoosened() {
        let watchdog = RunLoopWatchdogTimer(interval: 2, tick: {})
        defer { watchdog.cancel() }

        XCTAssertEqual(watchdog.timer.tolerance, 0.2, accuracy: 0.000_001)
    }

    // MARK: - The Sleep Countdown

    /// The countdown's own timer keeps its interval exact: it has no
    /// tolerance, since its announcements and its expiry are heard.
    func testTheSleepCountdownKeepsAnExactInterval() throws {
        let service = SleepTimerService(
            userDefaults: makeSandboxedPreferences("coalescing-sleep"),
            registry: SleepTimerRegistry()
        )
        service.start(duration: .minutes(5), ownerID: UUID(), onExpire: {}, onFadeStep: { _ in }, fadeOutDuration: 0)
        addTeardownBlock { @MainActor in service._resetForTesting() }

        let tolerance = try XCTUnwrap(service._fireCountdownTimerForTesting())

        XCTAssertEqual(tolerance, 0)
    }

    /// A tick of the countdown acts in the timer's own turn, on the main
    /// thread, not on a later turn of the main queue: firing the timer
    /// counts one second down at once.
    func testTheSleepCountdownTickActsAtOnce() throws {
        let service = SleepTimerService(
            userDefaults: makeSandboxedPreferences("coalescing-sleep-tick"),
            registry: SleepTimerRegistry()
        )
        service.start(duration: .minutes(5), ownerID: UUID(), onExpire: {}, onFadeStep: { _ in }, fadeOutDuration: 0)
        addTeardownBlock { @MainActor in service._resetForTesting() }
        let before = service.remainingSeconds

        _ = try XCTUnwrap(service._fireCountdownTimerForTesting())

        XCTAssertEqual(service.remainingSeconds, before - 1)
    }
}
