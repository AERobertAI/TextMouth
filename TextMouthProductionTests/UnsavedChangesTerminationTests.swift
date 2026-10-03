import AppKit
import XCTest
@testable import TextMouth

/// A request to quit while changes are unsaved is cancelled once, with a
/// prompt naming them, and Retry, Quit Anyway, and Cancel do what they say
/// (TODO S09). The decision is a pure function. The guard is driven with a
/// center of the test's own and stand-ins for the flush, the prompt, and
/// the request to quit, so nothing is shown and nothing quits.
@MainActor
final class UnsavedChangesTerminationTests: XCTestCase {
    /// This test's center.
    private let center = PersistenceFailureCenter()

    // MARK: - The Decision

    /// While changes are unsaved, a request to quit is cancelled with a
    /// prompt; with nothing unsaved, or on the request Quit Anyway makes,
    /// TextMouth quits.
    func testTheDecisionHoldsAQuitOnlyWhileChangesAreUnsaved() {
        XCTAssertEqual(TerminationDecision.decide(hasUnsavedChanges: true, userChoseQuitAnyway: false), .cancelAndPrompt)
        XCTAssertEqual(TerminationDecision.decide(hasUnsavedChanges: false, userChoseQuitAnyway: false), .terminate)
        XCTAssertEqual(TerminationDecision.decide(hasUnsavedChanges: true, userChoseQuitAnyway: true), .terminate)
        XCTAssertEqual(TerminationDecision.decide(hasUnsavedChanges: false, userChoseQuitAnyway: true), .terminate)
    }

    // MARK: - The Guard

    /// With nothing unsaved, the guard flushes and quits at once, asking
    /// nothing.
    func testWithNothingUnsavedTheGuardFlushesAndQuits() {
        let harness = Harness(center: center, answer: .cancel)

        XCTAssertEqual(harness.terminationGuard.reply(), .terminateNow)

        XCTAssertEqual(harness.flushes.calls.count, 1)
        XCTAssertTrue(harness.prompts.calls.isEmpty)
    }

    /// The flush runs before the decision, so a write that fails during the
    /// flush holds the quit.
    func testAFailureFromTheFlushHoldsTheQuit() {
        let center = self.center
        let harness = Harness(center: center, answer: .cancel) {
            center.recordFailure(.statistics, path: "/data/reading_stats.json", error: WriteRefused())
        }

        XCTAssertEqual(harness.terminationGuard.reply(), .terminateCancel)
        XCTAssertTrue(waitUntil(timeout: 5) { harness.prompts.calls == [[.statistics]] })
    }

    /// Unsaved changes cancel the request and show the prompt, naming them.
    /// Quit Anyway asks to quit again, and that second request quits; it
    /// answers only that one request.
    func testQuitAnywayQuitsOnTheRequestItMakes() {
        center.recordFailure(.libraryIndex, path: "/data/library.json", error: WriteRefused())
        let harness = Harness(center: center, answer: .quitAnyway)

        XCTAssertEqual(harness.terminationGuard.reply(), .terminateCancel)
        XCTAssertTrue(waitUntil(timeout: 5) { harness.terminationRequests.calls.count == 1 })

        XCTAssertEqual(harness.prompts.calls, [[.libraryIndex]])
        XCTAssertEqual(harness.terminationGuard.reply(), .terminateNow, "the request Quit Anyway makes quits")
        XCTAssertEqual(harness.terminationGuard.reply(), .terminateCancel, "Quit Anyway answered only that request")
    }

    /// Retry runs the unsaved writes again and asks to quit again; with
    /// them saved, that request quits.
    func testRetrySavesAndAsksToQuitAgain() {
        let center = self.center
        center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused()) { _ in
            center.recordSuccess(.configuration)
        }
        let harness = Harness(center: center, answer: .retry)

        XCTAssertEqual(harness.terminationGuard.reply(), .terminateCancel)
        XCTAssertTrue(waitUntil(timeout: 5) { harness.terminationRequests.calls.count == 1 })

        XCTAssertFalse(center.hasUnsavedChanges)
        XCTAssertEqual(harness.terminationGuard.reply(), .terminateNow)
    }

    /// Cancel keeps TextMouth open: nothing asks to quit, and the next
    /// request asks again.
    func testCancelKeepsTextMouthOpen() {
        center.recordFailure(.substitutions, path: "/data/substitutions.json", error: WriteRefused())
        let harness = Harness(center: center, answer: .cancel)

        XCTAssertEqual(harness.terminationGuard.reply(), .terminateCancel)
        XCTAssertTrue(waitUntil(timeout: 5) { harness.prompts.calls.count == 1 })
        XCTAssertTrue(harness.terminationRequests.calls.isEmpty)

        XCTAssertEqual(harness.terminationGuard.reply(), .terminateCancel)
        XCTAssertTrue(waitUntil(timeout: 5) { harness.prompts.calls.count == 2 })
    }

    /// A request that arrives before the prompt has been answered is
    /// cancelled without flushing again or stacking a second prompt.
    func testARequestWhileThePromptIsPendingAddsNoSecondPrompt() {
        center.recordFailure(.substitutions, path: "/data/substitutions.json", error: WriteRefused())
        let harness = Harness(center: center, answer: .cancel)

        XCTAssertEqual(harness.terminationGuard.reply(), .terminateCancel)
        XCTAssertEqual(harness.terminationGuard.reply(), .terminateCancel)

        XCTAssertEqual(harness.flushes.calls.count, 1)
        XCTAssertTrue(waitUntil(timeout: 5) { harness.prompts.calls.count == 1 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(harness.prompts.calls.count, 1)
    }

    /// Changes saved between the request and the prompt leave nothing to
    /// ask about: TextMouth asks to quit again without a prompt.
    func testChangesSavedBeforeThePromptQuitWithoutIt() {
        center.recordFailure(.statistics, path: "/data/reading_stats.json", error: WriteRefused())
        let harness = Harness(center: center, answer: .cancel)

        XCTAssertEqual(harness.terminationGuard.reply(), .terminateCancel)
        center.recordSuccess(.statistics)
        XCTAssertTrue(waitUntil(timeout: 5) { harness.terminationRequests.calls.count == 1 })

        XCTAssertTrue(harness.prompts.calls.isEmpty)
    }

    /// An original file left behind loses nothing, so it never holds a quit.
    func testAnOriginalFileLeftBehindDoesNotHoldAQuit() {
        center.recordFailure(
            .originalFile(path: "/Downloads/Atlas.epub", movesToTrash: true),
            path: "/Downloads/Atlas.epub",
            error: WriteRefused()
        )
        let harness = Harness(center: center, answer: .cancel)

        XCTAssertEqual(harness.terminationGuard.reply(), .terminateNow)
    }

    // MARK: - The Prompt

    /// The prompt names each unsaved subsystem as the banner does, leaves
    /// out an original file left behind, and says what each button does.
    func testThePromptNamesWhatIsUnsavedAndWhatEachChoiceDoes() {
        center.recordFailure(.configuration, path: "/data/config.json", error: WriteRefused())
        center.recordFailure(.libraryIndex, path: "/data/library.json", error: WriteRefused())
        center.recordFailure(
            .originalFile(path: "/Downloads/Atlas.epub", movesToTrash: true),
            path: "/Downloads/Atlas.epub",
            error: WriteRefused()
        )

        XCTAssertEqual(
            UnsavedChangesPrompt.message(for: center.unsavedFailures()),
            """
            Quitting now leaves these changes unsaved:

            Library changes could not be saved: The volume is read-only.

            Settings could not be saved: The volume is read-only.

            Choose Retry to try saving them again, Quit Anyway to quit without them, or Cancel to keep TextMouth open.
            """
        )
        XCTAssertEqual(UnsavedChangesPrompt.title, "Some Changes Could Not Be Saved")
    }

    // MARK: - Helpers

    /// A guard over a center, whose flush, prompt, and request to quit are
    /// recorded; the prompt answers `answer`.
    @MainActor
    private struct Harness {
        let terminationGuard: UnsavedChangesTerminationGuard
        /// One entry per flush.
        let flushes: CallLog<Int>
        /// The keys of the unsaved failures each prompt named.
        let prompts: CallLog<[PersistenceFailure.Key]>
        /// One entry per request to quit again.
        let terminationRequests: CallLog<Int>

        /// - Parameters:
        ///   - center: The center the guard asks.
        ///   - answer: The prompt's answer.
        ///   - flush: What the flush does besides being recorded.
        init(center: PersistenceFailureCenter, answer: UnsavedChangesChoice, flush: @escaping @MainActor () -> Void = {}) {
            let flushes = CallLog<Int>()
            let prompts = CallLog<[PersistenceFailure.Key]>()
            let terminationRequests = CallLog<Int>()
            terminationGuard = UnsavedChangesTerminationGuard(
                failureCenter: center,
                flush: {
                    flushes.record(flushes.calls.count + 1)
                    flush()
                },
                prompt: { unsaved in
                    prompts.record(unsaved.map(\.key))
                    return answer
                },
                requestTermination: { terminationRequests.record(terminationRequests.calls.count + 1) }
            )
            self.flushes = flushes
            self.prompts = prompts
            self.terminationRequests = terminationRequests
        }
    }
}
