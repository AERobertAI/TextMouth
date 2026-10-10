import XCTest
@testable import TextMouth

/// The estimate of the time left that the import overlay and the feed
/// downloads section share (FR10, `TimeLeftEstimate`): each item left of
/// known size at the rate the items timed by size took their bytes, any
/// other at the average time of the items timed without a size, and the
/// result said in steps that suit its size.
final class TimeLeftEstimateTests: XCTestCase {

    // MARK: - The Estimate

    /// Nothing is estimated before an item has been timed, nor with nothing
    /// left.
    func testNoEstimateBeforeAnItemIsTimedOrWithNothingLeft() {
        var timing = WorkTiming()
        XCTAssertNil(TimeLeftEstimate.secondsLeft(after: timing, for: [.init(bytes: 1_000_000)]))
        timing.add(seconds: 30, bytes: 60_000_000)
        XCTAssertNil(TimeLeftEstimate.secondsLeft(after: timing, for: []))
    }

    /// An item of known size takes its bytes at the rate the items timed by
    /// size took theirs, the one under way only its bytes still to come.
    func testSizedItemsTakeTheirBytesAtTheRateSoFar() throws {
        var timing = WorkTiming()
        // 60 MB in 30 seconds: 2 MB a second.
        timing.add(seconds: 30, bytes: 60_000_000)

        let seconds = try XCTUnwrap(TimeLeftEstimate.secondsLeft(after: timing, for: [
            .init(bytes: 30_000_000, elapsed: 15),
            .init(bytes: 120_000_000),
        ]))

        XCTAssertEqual(seconds, 75, accuracy: 0.001)
        XCTAssertEqual(ImportProgressWording.timeLeft(seconds), "About 1 minute left")
    }

    /// An item without a size, an article or an audiobook's file, takes the
    /// average time of the items timed without one, less the time it has
    /// run, however long the sized items beside it took; before any such
    /// item was timed, it takes the average of every item timed, as an item
    /// of known size does before any was timed by size. Until October 10,
    /// 2026 it always took the average of every item, so an article left
    /// in a run of long episodes promised minutes.
    func testItemsWithoutASizeTakeTheirOwnAverageTime() throws {
        var timing = WorkTiming()
        // Only a sized item timed: no unsized average yet, so the overall
        // average, 30 seconds, serves an article left.
        timing.add(seconds: 30, bytes: 60_000_000)
        XCTAssertEqual(try XCTUnwrap(TimeLeftEstimate.secondsLeft(after: timing, for: [.init(bytes: nil)])), 30, accuracy: 0.001)

        // An article timed at 2 seconds: articles left take 2 seconds each,
        // less what they have run, and the episode left its bytes at 2 MB a
        // second.
        timing.add(seconds: 2, bytes: 0)
        let seconds = try XCTUnwrap(TimeLeftEstimate.secondsLeft(after: timing, for: [
            .init(bytes: nil, elapsed: 0.5),
            .init(bytes: nil),
            .init(bytes: 60_000_000),
        ]))
        XCTAssertEqual(seconds, 1.5 + 2 + 30, accuracy: 0.001)

        // An item that has run past the average counts as nothing more.
        XCTAssertEqual(try XCTUnwrap(TimeLeftEstimate.secondsLeft(after: timing, for: [.init(bytes: nil, elapsed: 600)])), 0, accuracy: 0.001)
    }

    /// An item of known size, before any item was timed by size, takes the
    /// average time, there being no rate yet.
    func testSizedItemsBeforeAnyRateTakeTheAverageTime() throws {
        var timing = WorkTiming()
        timing.add(seconds: 2, bytes: 0)
        XCTAssertEqual(try XCTUnwrap(TimeLeftEstimate.secondsLeft(after: timing, for: [.init(bytes: 50_000_000)])), 2, accuracy: 0.001)
    }

    /// A clock that moved back, or a time that is no number, is timed as no
    /// time; each item is counted, by size or without.
    func testTimesThatMakeNoSenseCountAsNone() {
        var timing = WorkTiming()
        timing.add(seconds: -5, bytes: 1_000)
        timing.add(seconds: .nan, bytes: 0)
        XCTAssertEqual(timing.items, 2)
        XCTAssertEqual(timing.seconds, 0)
        XCTAssertEqual(timing.sizedItems, 1)
        XCTAssertEqual(timing.sizedBytes, 1_000)
        XCTAssertEqual(timing.sizedSeconds, 0)
        XCTAssertEqual(timing.unsizedItems, 1)
        XCTAssertEqual(timing.unsizedSeconds, 0)
        // No seconds for any sized bytes: no rate, so the average, 0.
        XCTAssertEqual(TimeLeftEstimate.secondsLeft(after: timing, for: [.init(bytes: 5_000)]), 0)
        XCTAssertNil(TimeLeftEstimate.secondsLeft(after: WorkTiming(), for: [.init(bytes: nil)]))
    }

    // MARK: - Rounding

    /// The time left is rounded to steps that suit its size, under a minute
    /// to nothing, which is said as less than a minute; a time that is no
    /// number rounds to nothing too.
    func testTheTimeLeftIsRoundedToStepsThatSuitItsSize() {
        XCTAssertEqual(TimeLeftEstimate.rounded(59), 0)
        XCTAssertEqual(TimeLeftEstimate.rounded(89), 60)
        XCTAssertEqual(TimeLeftEstimate.rounded(12 * 60 + 30), 15 * 60)
        XCTAssertEqual(TimeLeftEstimate.rounded(70 * 60), 75 * 60)
        XCTAssertEqual(TimeLeftEstimate.rounded(.infinity), 0)
        XCTAssertEqual(TimeLeftEstimate.rounded(.nan), 0)
    }
}
