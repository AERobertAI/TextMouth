import AppKit
import XCTest
@testable import TextMouth

/// A quit asked for while work TextMouth must finish is under way (feed
/// downloads, a book read again in another encoding, a speech export).
///
/// Two faults older than 0.4.2 are covered here, in the decisions only. The
/// AppKit behaviour they come from (a reply pending inside the main queue's
/// drain, a second Command-Q that quits at once) can only be shown by quitting
/// a process, which no test may do to the test host, so
/// `Scripts/test/quit-while-held.py` shows it in child processes with a
/// watchdog. What these tests pin is what makes that fix hold:
///
/// - every ask to quit again goes through `QuitRequest.ask()`;
/// - a quit the person asks for is cancelled while the work is finished, says
///   what it is finishing, and is asked again; a request that comes meanwhile
///   is cancelled too and says the same words again, never cutting the work
///   off; the work waits no longer than its longest wait;
/// - Quit Anyway reaches the request that follows the work;
/// - the system ending the session is answered later, not cancelled.
///
/// Nothing here quits, shows a panel, or speaks: the delegate's finisher,
/// work, and guard are the test's own, and `QuitRequest` is replaced or inert.
@MainActor
final class QuitWhileHeldTests: XCTestCase {

    // MARK: - Asking Again, Through One Helper

    /// A process hosting tests keeps a request to quit and quits nothing, so
    /// a test that asks without replacing the helper cannot end the host.
    func testUnderTestTheHelperKeepsTheRequestAndQuitsNothing() {
        let before = QuitRequest.heldBackUnderTest

        QuitRequest.ask()
        QuitRequest.makeDelivery(isHostedTest: true)()

        XCTAssertEqual(QuitRequest.heldBackUnderTest, before + 2, "a request under test was not kept: it may have quit")
    }

    /// The app delegate's request, the unsaved-changes guard's after Quit
    /// Anyway, and the finisher's after the work all ask through
    /// `QuitRequest.ask()`: none is a call of its own.
    func testEveryAskToQuitAgainGoesThroughTheHelper() async {
        let asked = Counter()
        let before = QuitRequest.deliver
        QuitRequest.deliver = { asked.count += 1 }
        defer { QuitRequest.deliver = before }

        // The delegate's, used by moves, editors, and the Record window.
        AppDelegate().requestTermination()
        XCTAssertEqual(asked.count, 1, "the delegate's request to quit again does not use QuitRequest")

        // The guard's, after Quit Anyway.
        let center = PersistenceFailureCenter()
        center.recordFailure(.substitutions, path: "/data/substitutions.json", error: WriteRefused())
        let guardWithDefaults = UnsavedChangesTerminationGuard(failureCenter: center, flush: {}, prompt: { _ in .quitAnyway })
        XCTAssertEqual(guardWithDefaults.reply(), .terminateCancel)
        let guardAsked = await eventually { asked.count == 2 }
        XCTAssertTrue(guardAsked, "Quit Anyway's request to quit again does not use QuitRequest (asked \(asked.count) times)")

        // The finisher's, after the work.
        let work = FakeWork("work")
        let finisher = QuitFinisher(tell: { _ in }, finished: {})
        XCTAssertTrue(finisher.finish([work.work()]))
        work.released = true
        let finisherAsked = await eventually { asked.count == 3 }
        XCTAssertTrue(finisherAsked, "the finisher's request to quit again does not use QuitRequest (asked \(asked.count) times)")
    }

    /// No app source asks AppKit to quit with `terminate(nil)` but the helper
    /// and the memory guard's own quit, which the delegate answers at once.
    /// The same check runs in `Scripts/test/quit-while-held.py`.
    func testNoSourceAsksAppKitToQuitExceptTheHelperAndTheMemoryGuard() throws {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TextMouth")
        guard let files = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil) else {
            throw XCTSkip("the app's sources are not beside the tests: \(appSources.path)")
        }
        let allowed: Set<String> = ["QuitRequest.swift", "PlaybackMemoryGuard.swift"]
        let call = try NSRegularExpression(pattern: #"\bterminate\((nil|self|sender)\)"#)
        var stray: [String] = []
        var scanned = 0
        for case let file as URL in files where file.pathExtension == "swift" && !allowed.contains(file.lastPathComponent) {
            scanned += 1
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // The line without its indentation, as a String so the range matches.
                let code = String(line.drop { $0 == " " })
                let range = NSRange(code.startIndex..., in: code)
                if !code.hasPrefix("//"), call.firstMatch(in: code, range: range) != nil {
                    stray.append("\(file.lastPathComponent):\(number + 1): \(code)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan found only \(scanned) sources, so it looked in the wrong place")
        XCTAssertEqual(stray, [], "these ask AppKit to quit other than through QuitRequest.ask()")
    }

    // MARK: - The Words

    /// The words list what is under way, and say TextMouth quits afterwards.
    func testTheWordsNameWhatIsFinishingAndThatTextMouthQuitsAfterwards() {
        XCTAssertEqual(
            QuitHoldWording.message(finishing: ["saving a"]),
            "TextMouth is finishing up before it quits: saving a. It will quit as soon as that is done."
        )
        XCTAssertEqual(QuitHoldWording.list([]), "")
        XCTAssertEqual(QuitHoldWording.list(["a"]), "a")
        XCTAssertEqual(QuitHoldWording.list(["a", "b"]), "a and b")
        XCTAssertEqual(QuitHoldWording.list(["a", "b", "c"]), "a, b, and c")
        XCTAssertEqual(QuitHoldWording.list(["a", "b", "c", "d"]), "a, b, c, and d")
    }

    /// The app's three kinds of work each give a phrase of their own.
    func testEachKindOfWorkSaysWhatItIsDoing() {
        let phrases = [
            FeedQuitHold.work(FeedCenter.shared.downloads).finishing,
            TextRereads.shared.quitWork().finishing,
            SpeechExportsUnderWay.shared.quitWork().finishing,
        ]
        XCTAssertEqual(Set(phrases).count, 3, "two kinds of work say the same thing: \(phrases)")
        XCTAssertFalse(phrases.contains(""), "a kind of work says nothing: \(phrases)")
    }

    // MARK: - The Finisher

    /// With no work running, nothing is finished, said, or asked, and the
    /// quit goes ahead.
    func testWithNoWorkRunningTheQuitGoesAhead() {
        let log = FinisherLog()
        let finisher = log.finisher()

        XCTAssertFalse(finisher.finish([FakeWork("idle", running: false).work()]))
        XCTAssertFalse(finisher.isFinishing)
        XCTAssertFalse(finisher.answerRepeatedRequest())
        XCTAssertFalse(finisher.takeFinished())
        XCTAssertEqual(log.told, [])
        XCTAssertEqual(log.asks, 0)
    }

    /// Work that runs is finished, and the words say so at once; when it
    /// ends, the notice comes down and TextMouth asks to quit again, once;
    /// the request that follows is told the work is done, once.
    func testRunningWorkIsFinishedThenTheQuitIsAskedAgain() async {
        let log = FinisherLog()
        let finisher = log.finisher()
        let downloads = FakeWork("keeping downloads")

        XCTAssertTrue(finisher.finish([downloads.work()]), "a quit was not held for work that runs")
        XCTAssertTrue(finisher.isFinishing)
        XCTAssertEqual(log.told, [QuitHoldWording.message(finishing: ["keeping downloads"])])
        XCTAssertEqual(log.asks, 0, "asked to quit again before the work ended")

        downloads.released = true
        let asked = await eventually { log.asks == 1 }

        XCTAssertTrue(asked, "never asked to quit again; the work ended \(downloads.ended) time(s)")
        XCTAssertEqual(downloads.started, 1)
        XCTAssertEqual(downloads.ended, 1)
        XCTAssertEqual(log.finishedNotices, 1, "the notice was not taken down once")
        XCTAssertFalse(finisher.isFinishing)
        XCTAssertTrue(finisher.takeFinished(), "the request after the work was not told it is done")
        XCTAssertFalse(finisher.takeFinished(), "the answer was given twice")
    }

    /// Each piece of work is finished in turn, and the words name them all.
    func testEachPieceOfWorkIsFinishedInTurnAndNamed() async {
        let log = FinisherLog()
        let finisher = log.finisher()
        let order = Order()
        let first = FakeWork("first", order: order)
        let second = FakeWork("second", order: order)
        let idle = FakeWork("idle", running: false)

        XCTAssertTrue(finisher.finish([first.work(), idle.work(), second.work()]))
        XCTAssertEqual(log.told, [QuitHoldWording.message(finishing: ["first", "second"])], "the idle work was named")

        let firstStarted = await eventually { first.started == 1 }
        XCTAssertTrue(firstStarted)
        XCTAssertEqual(second.started, 0, "the second began before the first ended")
        first.released = true
        let secondStarted = await eventually { second.started == 1 }
        XCTAssertTrue(secondStarted, "the second never began after the first")
        second.released = true
        let asked = await eventually { log.asks == 1 }
        XCTAssertTrue(asked)
        XCTAssertEqual(order.events, ["first started", "first ended", "second started", "second ended"])
        XCTAssertEqual(idle.started, 0)
    }

    /// A second request while the work is finished says the same words again,
    /// is cancelled, and starts nothing more.
    func testARepeatedRequestSaysTheSameWordsAgainAndStartsNothing() async {
        let log = FinisherLog()
        let finisher = log.finisher()
        let downloads = FakeWork("keeping downloads")
        XCTAssertTrue(finisher.finish([downloads.work()]))

        XCTAssertTrue(finisher.answerRepeatedRequest(), "a request while finishing was not cancelled")
        XCTAssertTrue(finisher.finish([downloads.work()]), "finishing again was not held")

        let words = QuitHoldWording.message(finishing: ["keeping downloads"])
        XCTAssertEqual(log.told, [words, words], "the second request did not say the same words again")
        let started = await eventually { downloads.started == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(downloads.started, 1, "the work was started twice")
        downloads.released = true
        let asked = await eventually { log.asks == 1 }
        XCTAssertTrue(asked)
        XCTAssertEqual(log.asks, 1, "TextMouth asked to quit again more than once")
    }

    /// Work that cannot end is waited for no longer than its longest wait:
    /// then the quit is asked again and goes ahead on that request, once.
    func testWorkThatNeverEndsIsGivenUpOnAfterItsLongestWait() async {
        let log = FinisherLog()
        let finisher = log.finisher()
        let stuck = FakeWork("stuck")
        let started = Date()

        XCTAssertTrue(finisher.finish([stuck.work(longestWait: .milliseconds(50))]))
        let asked = await eventually { log.asks == 1 }

        XCTAssertTrue(asked, "a quit was held past the work's longest wait")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the wait was far longer than 50 ms")
        XCTAssertEqual(stuck.ended, 0, "the stuck work ended")
        XCTAssertTrue(stuck.running)
        XCTAssertTrue(finisher.takeFinished(), "the request after the wait was not told to go ahead")
        stuck.released = true
    }

    // MARK: - The Delegate

    /// The person's quit while work runs is cancelled, says what it is
    /// finishing, and a second Command-Q meanwhile is cancelled with the same
    /// words again, without the work ever being cut off; when the work has
    /// ended TextMouth asks again and that request quits.
    func testASecondQuitWhileWorkIsFinishedIsCancelledAndNothingIsCutOff() async {
        let world = DelegateWorld()
        let downloads = FakeWork("keeping downloads")
        world.delegate.heldWork = { [downloads.work()] }

        XCTAssertEqual(world.ask(), .terminateCancel, "the first quit was not held for work that runs")
        XCTAssertEqual(world.ask(), .terminateCancel, "a second quit while the work is finished was not cancelled")

        let words = QuitHoldWording.message(finishing: ["keeping downloads"])
        XCTAssertEqual(world.log.told, [words, words])
        // The work starts in a task of its own, a turn after the quit is answered.
        let started = await eventually { downloads.started >= 1 }
        XCTAssertTrue(started, "the work never started")
        XCTAssertEqual(downloads.started, 1, "the second quit started the work again")
        XCTAssertEqual(downloads.ended, 0)
        XCTAssertEqual(world.log.asks, 0, "asked to quit again before the work ended")

        downloads.released = true
        let asked = await eventually { world.log.asks == 1 }
        XCTAssertTrue(asked, "never asked to quit again after the work")
        XCTAssertEqual(downloads.ended, 1, "the work was cut off")
        XCTAssertEqual(world.ask(), .terminateNow, "the request after the work did not quit")
    }

    /// The request that follows work that gave up waiting goes ahead once;
    /// a quit after that holds again for work still running.
    func testWorkThatGaveUpWaitingDoesNotHoldTheNextRequestButHoldsTheOneAfter() async {
        let world = DelegateWorld()
        let stuck = FakeWork("stuck")
        world.delegate.heldWork = { [stuck.work(longestWait: .milliseconds(50))] }

        XCTAssertEqual(world.ask(), .terminateCancel)
        let asked = await eventually { world.log.asks == 1 }
        XCTAssertTrue(asked)

        XCTAssertEqual(world.ask(), .terminateNow, "a quit held past the work's longest wait")
        XCTAssertEqual(world.ask(), .terminateCancel, "a later quit with work still running was not held")
        stuck.released = true
    }

    /// Quit Anyway answers the request that follows the work too: the
    /// unsaved-changes prompt is not shown a second time.
    func testQuitAnywayReachesTheRequestThatFollowsTheWork() async {
        let center = PersistenceFailureCenter()
        center.recordFailure(.substitutions, path: "/data/substitutions.json", error: WriteRefused())
        let prompts = Counter()
        let guardAsks = Counter()
        let world = DelegateWorld(terminationGuard: UnsavedChangesTerminationGuard(
            failureCenter: center,
            flush: {},
            prompt: { _ in
                prompts.count += 1
                return .quitAnyway
            },
            requestTermination: { guardAsks.count += 1 }
        ))
        let downloads = FakeWork("keeping downloads")
        world.delegate.heldWork = { [downloads.work()] }

        XCTAssertEqual(world.ask(), .terminateCancel, "unsaved changes did not cancel the quit")
        let quitAnyway = await eventually { guardAsks.count == 1 }
        XCTAssertTrue(quitAnyway, "Quit Anyway never asked to quit again")
        XCTAssertEqual(world.ask(), .terminateCancel, "the request Quit Anyway makes did not hold for the work")
        XCTAssertEqual(world.log.told.count, 1)

        downloads.released = true
        let asked = await eventually { world.log.asks == 1 }
        XCTAssertTrue(asked)
        XCTAssertEqual(world.ask(), .terminateNow, "Quit Anyway was forgotten while the work was finished")
        XCTAssertEqual(prompts.count, 1, "the prompt was shown again")
    }

    /// Nothing running holds nothing: the quit goes ahead at once.
    func testNothingRunningHoldsNothing() {
        let world = DelegateWorld()
        world.delegate.heldWork = { [FakeWork("idle", running: false).work()] }

        XCTAssertEqual(world.ask(), .terminateNow)
        XCTAssertEqual(world.log.told, [])
    }

    /// The system ending the session (a log out) is answered later with the
    /// work ended, not cancelled, which would stop the log out.
    func testTheSystemEndingTheSessionIsAnsweredLaterNotCancelled() async {
        let log = FinisherLog()
        let finisher = log.finisher()
        let downloads = FakeWork("keeping downloads")
        let replies = Replies()

        let answer = finisher.reply(
            forQuitWith: [downloads.work()],
            workIsDone: false,
            endsTheSession: true,
            replyLater: { replies.values.append($0) }
        )

        XCTAssertEqual(answer, .terminateLater, "a log out was cancelled or let through")
        XCTAssertEqual(log.told, [], "the log out was told to the listener as a quit")
        XCTAssertFalse(finisher.isFinishing)
        XCTAssertEqual(replies.values, [])
        downloads.released = true
        let replied = await eventually { replies.values == [true] }
        XCTAssertTrue(replied, "the log out's reply never came: \(replies.values)")
        XCTAssertEqual(downloads.ended, 1)
    }

    /// The finisher's answers by case: work done, no work, and work.
    func testTheFinisherAnswersByCase() {
        let finisher = FinisherLog().finisher()
        let running = FakeWork("running")

        XCTAssertEqual(
            finisher.reply(forQuitWith: [running.work()], workIsDone: true, endsTheSession: false, replyLater: { _ in }),
            .terminateNow, "work the request already waited for held it again"
        )
        XCTAssertEqual(
            finisher.reply(forQuitWith: [], workIsDone: false, endsTheSession: true, replyLater: { _ in }),
            .terminateNow, "a log out with no work was held"
        )
        XCTAssertEqual(
            finisher.reply(forQuitWith: [running.work()], workIsDone: false, endsTheSession: false, replyLater: { _ in }),
            .terminateCancel
        )
        running.released = true
    }

    // MARK: - Why a Quit Came

    /// Log out, restart, and shut down end the session; a plain quit, the
    /// Dock's (which names no reason), and no event do not.
    func testOnlyTheSystemsReasonsEndTheSession() {
        for reason in ["logo", "rlgo", "rest", "shut"] {
            XCTAssertTrue(QuitReason.endsTheSession(QuitReason.fourCharCode(reason)), "\(reason) does not end the session")
        }
        XCTAssertFalse(QuitReason.endsTheSession(QuitReason.fourCharCode("quit")))
        XCTAssertFalse(QuitReason.endsTheSession(nil))
        XCTAssertEqual(QuitReason.reasonKeyword, 0x7768_7920, "'why ' is the Apple event attribute of a quit's reason")
        XCTAssertFalse(QuitReason.currentRequestEndsTheSession, "a test, with no Apple event, ended the session")
    }

    // MARK: - Fakes

    /// A count a closure can add to.
    @MainActor
    private final class Counter {
        var count = 0
    }

    /// The replies a held quit gave.
    @MainActor
    private final class Replies {
        var values: [Bool] = []
    }

    /// The order things happened in, across pieces of work.
    @MainActor
    private final class Order {
        var events: [String] = []
    }

    /// A piece of work that runs until the test releases it, for a limit.
    @MainActor
    private final class FakeWork {
        /// What it says it is doing.
        let name: String
        /// Whether it runs now.
        var running: Bool
        /// Set by the test to let the work end.
        var released = false
        /// How many times it was started and how many times it ended.
        private(set) var started = 0
        private(set) var ended = 0
        /// Where it records its starts and ends, if the test cares.
        private let order: Order?

        init(_ name: String, running: Bool = true, order: Order? = nil) {
            self.name = name
            self.running = running
            self.order = order
        }

        /// The work as a quit sees it. Its end waits for `released`, but for
        /// no longer than ten seconds, so a test that forgets cannot hang.
        func work(longestWait: Duration = .seconds(5)) -> QuitHold.Work {
            QuitHold.Work(
                isRunning: { self.running },
                end: {
                    self.started += 1
                    self.order?.events.append("\(self.name) started")
                    for _ in 0..<1_000 where !self.released {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    self.running = false
                    self.ended += 1
                    self.order?.events.append("\(self.name) ended")
                },
                longestWait: longestWait,
                finishing: name
            )
        }
    }

    /// What a finisher said and asked, in place of a panel, VoiceOver, and AppKit.
    @MainActor
    private final class FinisherLog {
        /// The words said, in order.
        var told: [String] = []
        /// How many times the notice was taken down.
        var finishedNotices = 0
        /// How many times TextMouth asked to quit again.
        var asks = 0

        /// A finisher that records into this log.
        func finisher() -> QuitFinisher {
            QuitFinisher(
                tell: { self.told.append($0) },
                finished: { self.finishedNotices += 1 },
                askAgain: { self.asks += 1 }
            )
        }
    }

    /// An app delegate whose guard, work, finisher, moves, editors, and Record
    /// window are the test's own, so a quit asked of it shows, says, and writes
    /// nothing.
    @MainActor
    private final class DelegateWorld {
        let delegate = AppDelegate()
        let log = FinisherLog()

        /// A delegate over `terminationGuard`, by default one with nothing unsaved.
        init(terminationGuard: UnsavedChangesTerminationGuard? = nil) {
            delegate.terminationGuard = terminationGuard ?? UnsavedChangesTerminationGuard(
                failureCenter: PersistenceFailureCenter(),
                flush: {},
                prompt: { _ in .cancel },
                requestTermination: {}
            )
            delegate.quitFinisher = log.finisher()
            delegate.recordingWindows = RecordingWindowController()
            delegate.audioEditors = AudioEditorWindowController()
            delegate.requestTermination = {}
        }

        /// The delegate's answer to a request to quit.
        func ask() -> NSApplication.TerminateReply {
            delegate.applicationShouldTerminate(NSApplication.shared)
        }
    }
}
