import XCTest
@testable import TextMouth

/// The lead before a chapter's end at which the next chapter's audio is
/// rendered (`LookAheadLead`, audit C11), and the watch that tells a reader
/// its pause has grown long (`LongPauseWatch`). Both are
/// plain rules: nothing here renders, speaks, or waits on a clock.
@MainActor
final class LookAheadLeadTests: XCTestCase {

    // MARK: - The lead

    /// However short the next chapter, the lead is never under its floor.
    func testAShortNextChapterStillGetsTheMinimumLead() {
        XCTAssertEqual(LookAheadLead.lead(forNextChapterOfLength: 0), LookAheadLead.minimum)
        XCTAssertEqual(LookAheadLead.lead(forNextChapterOfLength: 2_000), LookAheadLead.minimum)
        // A length that is not one is read as none, not as a negative time.
        XCTAssertEqual(LookAheadLead.lead(forNextChapterOfLength: -5), LookAheadLead.minimum)
    }

    /// The lead for every chapter that is rendered at all is several times
    /// its estimated render time, and never shrinks as the chapter grows.
    func testTheLeadIsSeveralTimesTheRenderTimeAndGrowsWithTheChapter() {
        var previous = 0.0
        for length in stride(from: 0, through: SpeechRenderCoordinator.maximumTextLength, by: 10_000) {
            let lead = LookAheadLead.lead(forNextChapterOfLength: length)
            let renderTime = Double(length) / LookAheadLead.assumedRenderUnitsPerSecond
            XCTAssertGreaterThanOrEqual(lead, LookAheadLead.renderTimeMultiple * renderTime, "\(length)")
            XCTAssertGreaterThanOrEqual(lead, previous, "\(length)")
            previous = lead
        }
        // The multiple is generous, never a bare margin.
        XCTAssertGreaterThanOrEqual(LookAheadLead.renderTimeMultiple, 3)
    }

    /// A chapter far beyond the floor's worth of render time takes the
    /// multiple of its render time, not the floor.
    func testAVeryLongRenderLengthensTheLeadBeyondTheMinimum() {
        let length = Int(LookAheadLead.assumedRenderUnitsPerSecond * LookAheadLead.minimum)
        XCTAssertEqual(
            LookAheadLead.lead(forNextChapterOfLength: length),
            LookAheadLead.renderTimeMultiple * LookAheadLead.minimum,
            accuracy: 0.001
        )
    }

    /// Listening time falls as the speed rises, and is none for text that is
    /// spent or a speed that is no speed, so a render never waits on either.
    func testListeningTimeFollowsTheSpeed() {
        let slow = LookAheadLead.listeningTime(forUnitsLeft: 30_000, wordsPerMinute: 150)
        let fast = LookAheadLead.listeningTime(forUnitsLeft: 30_000, wordsPerMinute: 600)
        XCTAssertEqual(slow, 4 * fast, accuracy: 0.001)
        XCTAssertEqual(slow, 30_000 / (150 * LookAheadLead.assumedUnitsPerWord / 60), accuracy: 0.001)

        XCTAssertEqual(LookAheadLead.listeningTime(forUnitsLeft: 0, wordsPerMinute: 200), 0)
        XCTAssertEqual(LookAheadLead.listeningTime(forUnitsLeft: -40, wordsPerMinute: 200), 0)
        XCTAssertEqual(LookAheadLead.listeningTime(forUnitsLeft: 30_000, wordsPerMinute: 0), 0)
        XCTAssertEqual(LookAheadLead.listeningTime(forUnitsLeft: 30_000, wordsPerMinute: -1), 0)
        XCTAssertEqual(LookAheadLead.listeningTime(forUnitsLeft: 30_000, wordsPerMinute: .nan), 0)
        XCTAssertEqual(LookAheadLead.listeningTime(forUnitsLeft: 30_000, wordsPerMinute: .infinity), 0)
    }

    /// The render is due exactly from the offset where the time left equals
    /// the lead, and stays due to the chapter's end and past it.
    func testTheLeadIsReachedFromItsEdgeToTheEnd() {
        let wordsPerMinute = 200.0
        let unitsPerSecond = wordsPerMinute * LookAheadLead.assumedUnitsPerWord / 60
        let edge = Int(LookAheadLead.minimum * unitsPerSecond)
        let isReached = { (unitsLeft: Int) in
            LookAheadLead.isReached(unitsLeft: unitsLeft, wordsPerMinute: wordsPerMinute, nextChapterLength: 3_000)
        }

        XCTAssertFalse(isReached(edge + 1_000))
        XCTAssertFalse(isReached(edge + 1))
        XCTAssertTrue(isReached(edge))
        XCTAssertTrue(isReached(edge - 1))
        XCTAssertTrue(isReached(0))
        XCTAssertTrue(isReached(-10))
    }

    /// A faster speed reaches the lead with more text still to speak.
    func testAFasterSpeedReachesTheLeadEarlierInTheText() {
        let unitsLeft = 20_000
        XCTAssertFalse(LookAheadLead.isReached(unitsLeft: unitsLeft, wordsPerMinute: 200, nextChapterLength: 3_000))
        XCTAssertTrue(LookAheadLead.isReached(unitsLeft: unitsLeft, wordsPerMinute: 650, nextChapterLength: 3_000))
    }

    /// A pause counts as long after the same few minutes as the lead's
    /// floor, so one number says what "a few minutes" means to playback.
    func testALongPauseIsAsLongAsTheSmallestLead() {
        XCTAssertEqual(LongPauseWatch.delay, LookAheadLead.minimum)
        XCTAssertGreaterThanOrEqual(LongPauseWatch.delay, 120)
    }

    // MARK: - The watch

    /// A watched pause that grows long tells its reader once.
    func testAWatchedPauseElapsesOnce() {
        let watch = LongPauseWatch()
        var elapsed = 0
        watch.begin(after: 3_600) { elapsed += 1 }

        XCTAssertTrue(watch.isWaiting)
        XCTAssertFalse(watch.hasElapsed)

        watch._elapseNowForTesting()
        watch._elapseNowForTesting()

        XCTAssertEqual(elapsed, 1)
        XCTAssertTrue(watch.hasElapsed)
        XCTAssertFalse(watch.isWaiting)
    }

    /// A pause that ends first tells nobody, then or later.
    func testAPauseThatEndsFirstNeverElapses() {
        let watch = LongPauseWatch()
        var elapsed = 0
        watch.begin(after: 3_600) { elapsed += 1 }

        watch.end()
        watch._elapseNowForTesting()

        XCTAssertEqual(elapsed, 0)
        XCTAssertFalse(watch.hasElapsed)
        XCTAssertFalse(watch.isWaiting)
    }

    /// Ending a long pause makes the next pause an ordinary one again.
    func testEndingALongPauseForgetsThatItElapsed() {
        let watch = LongPauseWatch()
        watch.begin(after: 3_600) {}
        watch._elapseNowForTesting()

        watch.end()

        XCTAssertFalse(watch.hasElapsed)
    }

    /// A pause watched anew replaces the one before: only the new one's
    /// reader is told.
    func testWatchingAgainReplacesTheEarlierPause() {
        let watch = LongPauseWatch()
        var first = 0
        var second = 0
        watch.begin(after: 3_600) { first += 1 }
        watch.begin(after: 3_600) { second += 1 }

        watch._elapseNowForTesting()

        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
    }

    /// The watch's own clock elapses it, on the main queue, with no help.
    func testTheWatchElapsesByItselfAfterItsDelay() {
        let watch = LongPauseWatch()
        let told = expectation(description: "the pause grew long")
        watch.begin(after: 0.05) { told.fulfill() }

        wait(for: [told], timeout: 5)

        XCTAssertTrue(watch.hasElapsed)
    }

    /// A watch let go of while it waits tells nobody.
    func testAWatchLetGoOfNeverElapses() {
        var elapsed = 0
        var watch: LongPauseWatch? = LongPauseWatch()
        watch?.begin(after: 0.05) { elapsed += 1 }
        watch = nil

        let waited = expectation(description: "the delay passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { waited.fulfill() }
        wait(for: [waited], timeout: 5)

        XCTAssertEqual(elapsed, 0)
    }
}
