import AppKit
import XCTest
@testable import TextMouth

/// A request to quit while changes are unsaved is cancelled once, with a
/// prompt naming them, and Retry, Quit Anyway, and Cancel do what they say
/// (TODO S09). The decision is a pure function. The guard is driven with a
/// center of the test's own and stand-ins for the flush, the prompt, and
/// the request to quit, so nothing is shown and nothing quits. The flush
/// itself runs for real on a reader in an integration world of its own.
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

    // MARK: - A Quit Held for Work

    /// A second request to quit while a quit is held starts no second hold
    /// and replies to AppKit no second time, for each kind of work a quit
    /// holds for: a stand-in for any work, and a speech export under way
    /// (the third and fourth kinds, feed downloads and a re-read, are the
    /// same `QuitHold.Work`). The work is ended once; the one reply is true;
    /// and once it was given a later hold holds afresh.
    func testASecondQuitWhileOneIsHeldRepliesToAppKitOnce() async throws {
        // Any work: it ends when the test lets it.
        var endings = 0
        var isEnded = false
        let standIn = QuitHold.Work(
            isRunning: { !isEnded },
            end: {
                endings += 1
                while !isEnded { try? await Task.sleep(for: .milliseconds(5)) }
            },
            longestWait: .seconds(30)
        )
        // A speech export under way: ending is the export's own business.
        let underWay = SpeechExportsUnderWay()
        let exportID = underWay.begin(BookExportCancellation())
        let kinds: [(name: String, work: QuitHold.Work, finish: () -> Void)] = [
            ("any work", standIn, { isEnded = true }),
            ("a speech export", underWay.quitWork(), { underWay.ended(exportID) }),
        ]
        for (name, work, finish) in kinds {
            let holder = QuitHold.Holder()
            var replies: [Bool] = []

            XCTAssertTrue(holder.hold([work]) { replies.append($0) }, "\(name): the first quit was not held")
            XCTAssertTrue(holder.hold([work]) { replies.append($0) }, "\(name): the second quit was not held")
            XCTAssertTrue(holder.hold([work]) { replies.append($0) }, "\(name): the third quit was not held")
            finish()
            for _ in 0..<500 where replies.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            // Time for a second reply to come, were one coming.
            try await Task.sleep(for: .milliseconds(100))

            XCTAssertEqual(replies, [true], "\(name): AppKit was replied to \(replies.count) times, not once")
        }
        XCTAssertEqual(endings, 1, "any work was ended more than once by the repeated quits")
    }

    /// Once a held quit has been answered, the holder holds a later quit
    /// afresh when work runs again, and holds none when nothing runs.
    func testAHolderHoldsAgainOnceItsHoldIsAnswered() async throws {
        let holder = QuitHold.Holder()
        var isRunning = true
        let work = QuitHold.Work(isRunning: { isRunning }, end: { isRunning = false }, longestWait: .seconds(30))
        var replies: [Bool] = []

        XCTAssertTrue(holder.hold([work]) { replies.append($0) })
        for _ in 0..<500 where replies.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(replies, [true])
        XCTAssertFalse(holder.hold([work]) { _ in XCTFail("a quit with nothing running was held") })

        isRunning = true
        XCTAssertTrue(holder.hold([work]) { replies.append($0) }, "a later quit was not held afresh")
        for _ in 0..<500 where replies.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(replies, [true, true])
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

    // MARK: - The Flush

    /// The flush saves every open reader's place first, so a book heard on
    /// since its last checkpoint (a playing reader saves one only every
    /// thirty seconds, and no reader window closes as TextMouth quits) opens
    /// at the next launch where it was left: by the time the flush returns,
    /// the library's row holds the place and the book's record has it on
    /// disk. The reader stays open, should the quit then be cancelled.
    func testTheFlushSavesEveryOpenReadersPlaceFirst() throws {
        let world = try makeIntegrationWorld("Quit Saves Places")
        let book = try world.makeSilentAudioBook(title: "Harbour Dues", trackDurations: [10])
        let reader = world.openReader(for: book)
        reader.soundEffectService = RecordedSoundEffects()
        waitForReaderToLoad(reader)
        // Seven seconds in, at ten offsets a second, with no checkpoint made.
        reader.currentCharacterOffset = 70
        XCTAssertNotEqual(world.library.bookByID(book.id)?.readingPosition?.characterOffset, 70, "The place was saved before the quit")

        UnsavedChangesTerminationGuard.flushPendingWrites()

        XCTAssertEqual(world.library.bookByID(book.id)?.readingPosition?.characterOffset, 70, "The library's row")
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).state.readingPosition?.characterOffset, 70, "The book's record")
        XCTAssertFalse(reader.hasClosed, "The flush closed the reader")
    }

    /// A reader at rest, whose place has not moved since it was saved, is not
    /// saved again by the flush: saving it would date its place and its
    /// opening anew, and write this Mac's library index over a newer one
    /// that another Mac on a shared library had saved since (data review,
    /// finding 1). The row's place date, its last opening, and library.json
    /// are all left as they were.
    func testTheFlushWritesNothingForAReaderWhosePlaceHasNotMoved() throws {
        let world = try makeIntegrationWorld("Quit Leaves Rest")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [10])
        let reader = world.openReader(for: book)
        reader.soundEffectService = RecordedSoundEffects()
        waitForReaderToLoad(reader)
        // The load saved the place once: let that write reach the disk.
        LibraryPersistenceService.flushPendingSave()
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        let placeDate = try XCTUnwrap(row.readingPosition?.lastUpdated)
        let openedDate = row.lastOpened
        let indexBytes = try Data(contentsOf: TextMouthPaths.libraryIndexFile)
        // Let the clock tick past the second the library's JSON stores.
        Thread.sleep(forTimeInterval: 1.1)

        UnsavedChangesTerminationGuard.flushPendingWrites()

        let after = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(after.readingPosition?.lastUpdated, placeDate, "The quit dated the place anew")
        XCTAssertEqual(after.lastOpened, openedDate, "The quit dated the opening anew")
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.libraryIndexFile), indexBytes, "The quit rewrote library.json")
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
