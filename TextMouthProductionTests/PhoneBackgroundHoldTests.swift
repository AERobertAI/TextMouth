import XCTest
@testable import TextMouth

/// `PhoneBackgroundHold`: when the iPhone app is held running through the
/// book's silent gaps, and when the place is flushed as the book stops, over a
/// stand-in for the life cycle's holds that records each one.
@MainActor
final class PhoneBackgroundHoldTests: XCTestCase {
    /// The names of the holds begun, in order.
    private var begun: [String] = []
    /// The names of the holds ended, in order.
    private var ended: [String] = []
    /// What happened, in order: holds begun and ended, and flushes.
    private var events: [String] = []
    /// Whether the stand-in app is in the background.
    private var inBackground = false

    /// A hold over the test's stand-ins.
    private func makeHold() -> PhoneBackgroundHold {
        // Weak, so a closure the hold keeps can never reach a test case
        // that's gone: it then records nothing, and a test fails, not traps.
        PhoneBackgroundHold(
            beginHold: { [weak self] name in
                self?.begun.append(name)
                self?.events.append("begin \(name)")
                return { [weak self] in
                    self?.ended.append(name)
                    self?.events.append("end \(name)")
                }
            },
            isInBackground: { [weak self] in self?.inBackground ?? false },
            flush: { [weak self] in self?.events.append("flush") }
        )
    }

    // MARK: - Silent Gaps

    /// A gap begins one hold, which audio that may start again ends.
    func testAGapIsHeldUntilAudioMayStart() {
        let hold = makeHold()

        hold.silentGapBegan()
        XCTAssertTrue(hold.isHoldingAGap)
        XCTAssertEqual(begun, [PhoneBackgroundHold.gapHoldName])

        hold.audioMayStartAnswered(true)
        XCTAssertFalse(hold.isHoldingAGap)
        XCTAssertEqual(ended, [PhoneBackgroundHold.gapHoldName])
    }

    /// Gaps that begin before audio comes back stay in the one hold, so no
    /// hold is ever left that nothing ends.
    func testGapsBeforeAudioComesBackShareOneHold() {
        let hold = makeHold()

        hold.silentGapBegan()
        hold.silentGapBegan()
        hold.audioMayStartAnswered(true)
        hold.audioMayStartAnswered(true)

        XCTAssertEqual(begun.count, 1)
        XCTAssertEqual(ended.count, 1, "Each hold ended once")
    }

    /// Audio refused, as during a call, leaves the gap held: the reader's own
    /// refusal ends its playback, and with it the hold (`audioEnded`).
    func testARefusedStartLeavesTheGapHeld() {
        let hold = makeHold()
        hold.silentGapBegan()

        hold.audioMayStartAnswered(false)

        XCTAssertTrue(hold.isHoldingAGap)
        XCTAssertEqual(ended, [])
    }

    /// Audio that ends for good ends the gap's hold; in the foreground,
    /// nothing is flushed, as the app is not about to be suspended.
    func testAudioEndingForGoodEndsTheGapWithoutAFlushInFront() {
        let hold = makeHold()
        hold.silentGapBegan()

        hold.audioEnded()

        XCTAssertFalse(hold.isHoldingAGap)
        XCTAssertEqual(events, ["begin \(PhoneBackgroundHold.gapHoldName)", "end \(PhoneBackgroundHold.gapHoldName)"])
    }

    /// Audio that may start with no gap held ends nothing.
    func testAudioStartingWithNoGapEndsNothing() {
        let hold = makeHold()

        hold.audioMayStartAnswered(true)

        XCTAssertEqual(events, [])
    }

    // MARK: - Saving as the Book Stops

    /// The book stopping in the background flushes the place inside a hold of
    /// its own, begun before the flush and ended after it.
    func testAStopInTheBackgroundFlushesInsideAHold() {
        inBackground = true
        let hold = makeHold()

        hold.audioEnded()

        XCTAssertEqual(
            events,
            ["begin \(PhoneBackgroundHold.saveHoldName)", "flush", "end \(PhoneBackgroundHold.saveHoldName)"]
        )
    }

    /// A gap ending as the book stops in the background ends the gap's hold
    /// first, then flushes inside the save's hold.
    func testAGapEndingInTheBackgroundEndsItsHoldThenFlushes() {
        let hold = makeHold()
        hold.silentGapBegan()
        inBackground = true

        hold.audioEnded()

        XCTAssertEqual(events, [
            "begin \(PhoneBackgroundHold.gapHoldName)",
            "end \(PhoneBackgroundHold.gapHoldName)",
            "begin \(PhoneBackgroundHold.saveHoldName)",
            "flush",
            "end \(PhoneBackgroundHold.saveHoldName)",
        ])
    }

    /// The holds' names are the ones the system's diagnostics show.
    func testTheHoldsNames() {
        XCTAssertEqual(PhoneBackgroundHold.gapHoldName, "Waiting for the book's next audio")
        XCTAssertEqual(PhoneBackgroundHold.saveHoldName, "Saving the book's place")
    }
}
