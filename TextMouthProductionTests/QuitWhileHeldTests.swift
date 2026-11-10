import AppKit
import CoreServices
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

    /// No line of the app quits or ends it but the helper's own, and the few
    /// lines that say `quit-ok:` and why (the memory guard's emergency quits,
    /// a helper Process being ended): `terminate(` in any form, a `#selector`
    /// naming terminate (for `perform` or `sendAction`), `exit(`, and `_exit(`.
    /// The same check runs in `Scripts/test/quit-while-held.py`.
    func testNoSourceAsksAppKitToQuitExceptTheHelperAndTheMemoryGuard() throws {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TextMouth")
        guard let files = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil) else {
            throw XCTSkip("the app's sources are not beside the tests: \(appSources.path)")
        }
        let call = try NSRegularExpression(pattern: #"terminate\(|#selector\([^)]*terminate|\b_?exit\("#)
        var stray: [String] = []
        var scanned = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            scanned += 1
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // The line without its indentation, as a String so the range matches.
                let code = String(line.drop { $0 == " " })
                let range = NSRange(code.startIndex..., in: code)
                if !code.hasPrefix("//"), !code.contains("quit-ok:"), call.firstMatch(in: code, range: range) != nil {
                    stray.append("\(file.lastPathComponent):\(number + 1): \(code)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan found only \(scanned) sources, so it looked in the wrong place")
        XCTAssertEqual(stray, [], "these lines quit or end the app other than through QuitRequest.ask()")
        // A scan that matched nothing would pass whatever the sources hold.
        for sample in [
            "NSApp.terminate(nil)", "NSRunningApplication.current.terminate()",
            "app.perform(#selector(NSApplication.terminate(_:)))", "_exit(0)", "exit(1)",
        ] {
            let found = call.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample))
            XCTAssertNotNil(found, "the scan misses \(sample)")
        }
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
            FeedQuitHold.work(FeedCenter.shared.downloads).finishing(),
            TextRereads().quitWork().finishing(),
            SpeechExportsUnderWay().quitWork().finishing(),
        ]
        XCTAssertEqual(Set(phrases).count, 3, "two kinds of work say the same thing: \(phrases)")
        XCTAssertFalse(phrases.contains(""), "a kind of work says nothing: \(phrases)")
        let kinds = [
            FeedQuitHold.work(FeedCenter.shared.downloads).kind,
            TextRereads().quitWork().kind,
            SpeechExportsUnderWay().quitWork().kind,
        ]
        XCTAssertEqual(Set(kinds).count, 3, "two kinds of work share a kind: \(kinds)")
    }

    /// Several books read again, or several speech exports, are said as
    /// several: the words name the count, not "a book" or "a speech export".
    func testSeveralPiecesOfWorkAreSaidAsSeveral() {
        let rereads = TextRereads()
        rereads.bookIDs = [UUID()]
        let oneBook = rereads.quitWork().finishing()
        rereads.bookIDs = [UUID(), UUID(), UUID()]
        let threeBooks = rereads.quitWork().finishing()
        XCTAssertTrue(oneBook.contains("a book's text"), "one re-read: \(oneBook)")
        XCTAssertTrue(threeBooks.contains("3 books"), "three re-reads: \(threeBooks)")
        XCTAssertFalse(threeBooks.contains("a book"), "three re-reads said as one: \(threeBooks)")

        let underWay = SpeechExportsUnderWay()
        let first = underWay.begin(BookExportCancellation())
        let oneExport = underWay.quitWork().finishing()
        let second = underWay.begin(BookExportCancellation())
        let twoExports = underWay.quitWork().finishing()
        XCTAssertTrue(oneExport.contains("a speech export"), "one export: \(oneExport)")
        XCTAssertTrue(twoExports.contains("2 speech exports"), "two exports: \(twoExports)")
        XCTAssertFalse(twoExports.contains("a speech export"), "two exports said as one: \(twoExports)")
        underWay.ended(first)
        underWay.ended(second)
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
        XCTAssertEqual(finisher.takeFinished(), [])
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
        XCTAssertEqual(finisher.takeFinished(), ["keeping downloads"], "the request after the work was not told which work it waited for")
        XCTAssertEqual(finisher.takeFinished(), [], "the answer was given twice")
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
        XCTAssertEqual(finisher.takeFinished(), ["stuck"], "the request after the wait was not told to go ahead")
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

    /// A Quit Anyway kept for the request that follows the work belongs to that
    /// quit: when a library move, begun during the wait, cancels that request,
    /// the choice is forgotten, and the next quit asks about the unsaved
    /// changes again.
    func testAKeptQuitAnywayIsForgottenWhenTheFollowUpIsCancelled() async {
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
        XCTAssertEqual(world.ask(), .terminateCancel)
        let chosen = await eventually { guardAsks.count == 1 }
        XCTAssertTrue(chosen, "Quit Anyway was never chosen")
        XCTAssertEqual(world.ask(), .terminateCancel, "the work was not held")
        downloads.released = true
        let followUp = await eventually { world.log.asks == 1 }
        XCTAssertTrue(followUp)

        let move = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Backup/Library"))
        move.begin()
        move.beginCopying()
        XCTAssertEqual(world.ask(), .terminateCancel, "a copying library move did not hold the follow-up")
        move.end()

        XCTAssertEqual(world.ask(), .terminateCancel, "Quit Anyway outlived the quit it was chosen for")
        let asked = await eventually { prompts.count == 2 }
        XCTAssertTrue(asked, "the unsaved changes were not asked about again (prompts: \(prompts.count))")
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
            waitedFor: [],
            endsTheSession: true,
            replyLater: { replies.values.append($0) }
        )

        XCTAssertEqual(answer, .terminateLater, "a log out was cancelled or let through")
        XCTAssertEqual(
            log.told, [QuitHoldWording.message(finishing: ["keeping downloads"])],
            "the log out was not told to the listener in the words of any held quit"
        )
        XCTAssertFalse(finisher.isFinishing)
        XCTAssertEqual(replies.values, [])
        downloads.released = true
        let replied = await eventually { replies.values == [true] }
        XCTAssertTrue(replied, "the log out's reply never came: \(replies.values)")
        XCTAssertEqual(downloads.ended, 1)
        XCTAssertEqual(log.finishedNotices, 1, "the notice stayed up after the log out's work")
        XCTAssertEqual(log.asks, 0, "a log out asked to quit again")
    }

    /// A log out that comes while the person's quit is being finished is not
    /// cancelled: it says the same words again, is answered later, and is
    /// replied to as the work ends, in place of asking to quit again.
    func testALogOutDuringAHeldQuitIsAnsweredLaterAndRepliedToWhenTheWorkEnds() async {
        let log = FinisherLog()
        let finisher = log.finisher()
        let downloads = FakeWork("keeping downloads")
        let replies = Replies()
        XCTAssertFalse(finisher.answerSessionEnd(replyLater: { _ in }), "a log out with nothing to finish was held")
        XCTAssertTrue(finisher.finish([downloads.work()]))

        XCTAssertTrue(finisher.answerSessionEnd(replyLater: { replies.values.append($0) }), "a log out during a held quit was not answered later")
        XCTAssertTrue(finisher.answerSessionEnd(replyLater: { _ in XCTFail("a second log out replaced the first's reply") }))

        let words = QuitHoldWording.message(finishing: ["keeping downloads"])
        XCTAssertEqual(log.told, [words, words, words], "each request did not say the same words")
        downloads.released = true
        let replied = await eventually { replies.values == [true] }
        XCTAssertTrue(replied, "the log out's reply never came: \(replies.values)")
        XCTAssertEqual(log.asks, 0, "TextMouth asked to quit again beside the log out's reply")
        XCTAssertEqual(log.finishedNotices, 1)
        XCTAssertEqual(finisher.takeFinished(), [], "the log out left a mark for a request that never comes")
    }

    /// Work that begins while the notice is up is waited for by the request
    /// that follows; only the kinds already waited for are let go.
    func testWorkThatBeganDuringTheWaitIsNotCutOff() async {
        let log = FinisherLog()
        let finisher = log.finisher()
        let downloads = FakeWork("downloads")
        XCTAssertTrue(finisher.finish([downloads.work()]))
        downloads.released = true
        let asked = await eventually { log.asks == 1 }
        XCTAssertTrue(asked)
        let waited = finisher.takeFinished()
        XCTAssertEqual(waited, ["downloads"])

        let export = FakeWork("exports")
        XCTAssertEqual(
            finisher.reply(forQuitWith: [downloads.work(), export.work()], waitedFor: waited, endsTheSession: false, replyLater: { _ in }),
            .terminateCancel, "an export begun during the wait was cut off"
        )
        XCTAssertEqual(
            log.told.last, QuitHoldWording.message(finishing: ["exports"]),
            "the words named the downloads already waited for, or not the export"
        )
        export.released = true
        let again = await eventually { log.asks == 2 }
        XCTAssertTrue(again)
        XCTAssertEqual(
            finisher.reply(forQuitWith: [downloads.work(), export.work()], waitedFor: finisher.takeFinished(), endsTheSession: false, replyLater: { _ in }),
            .terminateNow
        )
    }

    /// The finisher's answers by case: work done, no work, and work.
    func testTheFinisherAnswersByCase() {
        let finisher = FinisherLog().finisher()
        let running = FakeWork("running")

        XCTAssertEqual(
            finisher.reply(forQuitWith: [running.work()], waitedFor: ["running"], endsTheSession: false, replyLater: { _ in }),
            .terminateNow, "work the request already waited for held it again"
        )
        XCTAssertEqual(
            finisher.reply(forQuitWith: [], waitedFor: [], endsTheSession: true, replyLater: { _ in }),
            .terminateNow, "a log out with no work was held"
        )
        XCTAssertEqual(
            finisher.reply(forQuitWith: [running.work()], waitedFor: [], endsTheSession: false, replyLater: { _ in }),
            .terminateCancel
        )
        running.released = true
    }

    // MARK: - Why a Quit Came

    /// The keyword of a quit's reason is the SDK's `kAEQuitReason` (`'why?'`),
    /// and the test names it by its own bytes besides, so a keyword changed in
    /// both places cannot pass.
    func testTheReasonKeywordIsTheSDKs() {
        XCTAssertEqual(QuitReason.reasonKeyword, AEKeyword(kAEQuitReason))
        XCTAssertEqual(QuitReason.reasonKeyword, 0x7768_793F, "kAEQuitReason is 'why?', not 'why '")
    }

    /// Log out, restart, and shut down end the session; a plain quit, the
    /// reason of quitting everything, and no reason do not.
    func testOnlyTheSystemsReasonsEndTheSession() {
        for reason in [kAELogOut, kAEReallyLogOut, kAERestart, kAEShutDown] {
            XCTAssertTrue(QuitReason.endsTheSession(OSType(reason)), "\(String(reason, radix: 16)) does not end the session")
        }
        XCTAssertFalse(QuitReason.endsTheSession(OSType(kAEQuitAll)))
        XCTAssertFalse(QuitReason.endsTheSession(nil))
    }

    /// Quit Apple events built from the SDK's keyword, as loginwindow sends
    /// them, are recognised whether the reason is an attribute or a
    /// parameter; the keyword this code once used, `'why '`, is not one.
    func testAQuitEventNamingASessionEndingReasonIsRecognised() {
        func quitEvent(reason: OSType?, key: AEKeyword, asParameter: Bool) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            if let reason {
                let described = NSAppleEventDescriptor(enumCode: reason)
                if asParameter {
                    event.setParam(described, forKeyword: key)
                } else {
                    event.setAttribute(described, forKeyword: key)
                }
            }
            return event
        }
        let sdkKey = AEKeyword(kAEQuitReason)
        let logOut = OSType(kAEReallyLogOut)

        XCTAssertTrue(QuitReason.endsTheSession(event: quitEvent(reason: logOut, key: sdkKey, asParameter: false)), "a log out as an attribute")
        XCTAssertTrue(QuitReason.endsTheSession(event: quitEvent(reason: logOut, key: sdkKey, asParameter: true)), "a log out as a parameter")
        XCTAssertTrue(QuitReason.endsTheSession(event: quitEvent(reason: OSType(kAEShutDown), key: sdkKey, asParameter: false)))
        XCTAssertFalse(QuitReason.endsTheSession(event: quitEvent(reason: nil, key: sdkKey, asParameter: false)), "the Dock's quit names no reason")
        XCTAssertFalse(QuitReason.endsTheSession(event: quitEvent(reason: OSType(kAEQuitAll), key: sdkKey, asParameter: false)))
        XCTAssertFalse(
            QuitReason.endsTheSession(event: quitEvent(reason: logOut, key: 0x7768_7920, asParameter: false)),
            "a reason under 'why ' is not the system's"
        )
        XCTAssertFalse(QuitReason.endsTheSession(event: nil))
    }

    /// A quit soon after the system said it is powering off is the system's,
    /// whatever its event names; one long after, or before any notice, is
    /// the person's. A test, with no Apple event, is never a session end.
    func testAQuitAfterThePowerOffNoticeIsTheSystems() {
        QuitReason.forgetPowerOff()
        defer { QuitReason.forgetPowerOff() }
        let now = Date()

        XCTAssertFalse(QuitReason.quitFollowsPowerOff(now: now), "a quit before any notice")
        XCTAssertFalse(QuitReason.currentRequestEndsTheSession, "a test, with no Apple event, ended the session")
        QuitReason.noteWillPowerOff(at: now.addingTimeInterval(-10))
        XCTAssertTrue(QuitReason.quitFollowsPowerOff(now: now), "a quit ten seconds after the notice")
        XCTAssertTrue(QuitReason.currentRequestEndsTheSession)
        XCTAssertFalse(QuitReason.quitFollowsPowerOff(now: now.addingTimeInterval(QuitReason.powerOffWindow + 1)), "a quit long after the notice")
        QuitReason.forgetPowerOff()
        XCTAssertFalse(QuitReason.currentRequestEndsTheSession)
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
                kind: name,
                finishing: { self.name }
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
