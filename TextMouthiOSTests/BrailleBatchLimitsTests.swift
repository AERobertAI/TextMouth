import os
import XCTest
@testable import TextMouth

/// The limits of a whole braille translation on the iPhone (DR34; the review
/// of November 16, finding 2), which the Mac's watchdog keeps for its helper
/// and the iPhone keeps over the batches a book is sent to the library in:
/// the book's time, shared by its batches and counted in the library's own
/// time, never in a wait behind another call; the cap on the book's whole
/// output; and the library's own stops (statuses 8 and 9) said in the Mac's
/// words.
///
/// Each test binds a stand-in tool with tight limits through
/// `BrailleTranslator.$tool`, as the Mac's tests of the helper do, and an
/// engine of its own, so that nothing it does reaches another test. The
/// books are braille read back to print, about 50 ms a batch on GitHub's
/// simulator (November 16, 2026).
final class BrailleBatchLimitsTests: XCTestCase {
    /// The table every test reads with: Unified English Braille, uncontracted.
    private let table = "en-ueb-g1.ctb"

    /// A working folder, which the iPhone writes nothing in.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    override func setUpWithError() throws {
        work = try makeSandboxDirectory("BrailleBatchLimits")
    }

    // MARK: - Helpers

    /// The app's own tool, with `limits` tightening the app's limits, and a
    /// clock counting every step of `uptime` whole when one is given.
    private func tool(
        limits tighten: @escaping @Sendable (inout WatchedProcess.Limits, Int64) -> Void,
        uptime: (@Sendable () -> TimeInterval)? = nil
    ) -> BrailleTranslator.Tool {
        var tool = BrailleTranslator.Tool.helper
        tool.limits = { direction, bytes in
            var limits = BrailleTranslator.limits(for: direction, bytes: bytes)
            tighten(&limits, bytes)
            return limits
        }
        if let uptime { tool.clock = RunningClock(countingWhole: uptime) }
        return tool
    }

    /// `texts`, braille, read back with `tool` on `engine` (a new one of the
    /// test's own when nil).
    private func read(_ texts: [String], with tool: BrailleTranslator.Tool, on engine: InProcessEngine? = nil) throws -> [String] {
        let engine = engine ?? InProcessEngine(name: "test-batch-limits", work: "the braille translation")
        return try BrailleTranslator.$engine.withValue(engine) {
            try BrailleTranslator.$tool.withValue(tool) {
                try BrailleTranslator.translate(texts, table: table, direction: .brailleToPrint, workingIn: work)
            }
        }
    }

    /// Paragraphs of braille, "truth" 300 times each (about 5 KB), enough to
    /// fill `batches` batches and begin one more.
    private func book(filling batches: Int) -> [String] {
        let word = "\u{281E}\u{2817}\u{2825}\u{281E}\u{2813}"  // "truth"
        let paragraph = Array(repeating: word, count: 300).joined(separator: "\u{2800}")
        return Array(repeating: paragraph, count: batches * BrailleTranslator.batchBytes / paragraph.utf8.count + 1)
    }

    /// The failure of a translation stopped for `reason`, as the Mac words it.
    private func stopped(_ reason: WatchedProcess.KillReason) -> BrailleTranslator.Failure {
        .stopped(reason: reason.words)
    }

    // MARK: - The Library's Stops, in the Mac's Words

    /// A batch the library is told to stop for time (status 8) ends the
    /// translation as the Mac's watchdog ends its helper's: "TextMouth
    /// stopped the braille translation because it ran longer than 1 second."
    func testABatchStoppedForTimeIsSaidAsTheMacSaysIt() throws {
        let tight = tool(limits: { limits, _ in limits.maximumSeconds = 0.000_001 })
        XCTAssertThrowsError(try read(["\u{281E}\u{2817}\u{2825}\u{281E}\u{2813}"], with: tight)) {
            XCTAssertEqual($0 as? BrailleTranslator.Failure, stopped(.tookTooLong(seconds: 0.000_001)))
            XCTAssertEqual(
                ($0 as? LocalizedError)?.errorDescription,
                "TextMouth stopped the braille translation because it ran longer than 1 second."
            )
        }
    }

    /// A batch whose output passes its cap in the library (status 9) ends the
    /// translation as the Mac's watchdog ends a helper that wrote too much,
    /// naming the batch's cap.
    func testABatchPastItsOutputCapIsSaidAsTheMacSaysIt() throws {
        let tight = tool(limits: { limits, _ in limits.maximumOutputBytes = 64 })
        XCTAssertThrowsError(try read(book(filling: 0), with: tight)) {
            XCTAssertEqual($0 as? BrailleTranslator.Failure, stopped(.wroteTooMuch(bytes: 64)))
            let words = ($0 as? LocalizedError)?.errorDescription ?? "\($0)"
            XCTAssertTrue(words.hasPrefix("TextMouth stopped the braille translation because its output passed"), words)
        }
    }

    // MARK: - The Book's Own Limits

    /// The cap on a book's whole output holds across its batches: each batch
    /// is within its own cap, but once the book's output so far passes the
    /// cap for its input so far, the translation stops with that cap.
    func testTheBooksWholeOutputIsCappedAcrossItsBatches() throws {
        // A batch's input is at most about 265 KB, the book's after its second
        // batch at least 524 KB: only the cap on the whole book is small.
        let tight = tool(limits: { limits, bytes in limits.maximumOutputBytes = bytes < 400_000 ? 64 * 1_048_576 : 1_000 })
        XCTAssertThrowsError(try read(book(filling: 2), with: tight)) {
            XCTAssertEqual($0 as? BrailleTranslator.Failure, stopped(.wroteTooMuch(bytes: 1_000)))
        }
        // The same book with that cap lifted reads to its end.
        XCTAssertEqual(try read(book(filling: 2), with: tool(limits: { _, _ in })).count, book(filling: 2).count)
    }

    /// A book's time is shared by its batches: by a clock that moves ten
    /// seconds at each reading, each batch takes ten seconds of the library's
    /// time, so a book allowed five has none left for its second batch, which
    /// is stopped in the book's words; one batch alone reads.
    func testTheBooksTimeIsSharedByItsBatches() throws {
        let clock = OSAllocatedUnfairLock(initialState: TimeInterval(0))
        let tenSecondsAReading: @Sendable () -> TimeInterval = { clock.withLock { now -> TimeInterval in now += 10; return now } }
        let tight = tool(limits: { limits, _ in limits.maximumSeconds = 5 }, uptime: tenSecondsAReading)
        XCTAssertThrowsError(try read(book(filling: 2), with: tight)) {
            XCTAssertEqual($0 as? BrailleTranslator.Failure, stopped(.tookTooLong(seconds: 5)))
        }
        XCTAssertEqual(try read(["\u{281E}\u{2817}\u{2825}\u{281E}\u{2813}"], with: tight), ["truth"])
    }

    /// A batch frozen while iOS keeps TextMouth suspended has spent none of
    /// its book's time there (B18): by a clock whose uptime jumps five
    /// minutes inside the first batch, as while the listener is in another
    /// app, a book of two batches allowed five seconds still reads, where the
    /// system's uptime would have left the second batch no time at all.
    func testABookSuspendedInABatchHasSpentNoneOfItsTimeThere() throws {
        let readings = OSAllocatedUnfairLock(initialState: 0)
        // The first batch's two readings: as it starts, and as it ends five minutes of uptime later.
        let uptime: @Sendable () -> TimeInterval = {
            readings.withLock { count -> TimeInterval in
                count += 1
                return count == 1 ? 1_000 : 1_300 + Double(count) * 0.001
            }
        }
        var tight = tool(limits: { limits, _ in limits.maximumSeconds = 5 })
        tight.clock = RunningClock(uptime: uptime, longestStep: 1, tick: nil)
        let paragraphs = book(filling: 2)
        XCTAssertEqual(try read(paragraphs, with: tight).count, paragraphs.count)
    }

    /// The app's braille tool and engine count only the time TextMouth runs,
    /// by the app's one clock (B18).
    func testTheBrailleToolAndEngineAreTimedByTheAppsClock() {
        XCTAssertTrue(BrailleTranslator.Tool.helper.clock === RunningClock.app)
        XCTAssertTrue(BrailleTranslator.libraryEngine.clock === RunningClock.app)
    }

    /// A batch that waits its turn behind another call longer than the book's
    /// whole time still reads: only the library's own time counts against
    /// the book (review of commit 8049a5d4b, "a batch counts only the
    /// library's own time"). Measured around the wait, the first batch would
    /// spend the book's time, and the second would be stopped.
    func testABatchWaitingBehindAnotherCallCountsOnlyTheLibrarysTime() throws {
        let engine = InProcessEngine(name: "test-batch-limits-busy", work: "the braille translation")
        let started = DispatchSemaphore(value: 0)
        let busyDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? engine.run(limit: 30) { _ in
                started.signal()
                usleep(3_000_000)  // three seconds, more than the book's two
            }
            busyDone.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 30), .success, "the other call never started")
        let tight = tool(limits: { limits, _ in limits.maximumSeconds = 2 })
        let paragraphs = book(filling: 2)
        XCTAssertEqual(try read(paragraphs, with: tight, on: engine).count, paragraphs.count)
        XCTAssertEqual(busyDone.wait(timeout: .now() + 30), .success)
        XCTAssertFalse(engine.hasAbandonedACall)
    }
}
