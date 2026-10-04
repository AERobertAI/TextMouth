import AppKit
import XCTest
@testable import TextMouth

/// Quitting while the Record window holds a take (FR04), through the app's
/// quit hold, `AppDelegate.applicationShouldTerminate`: the quit is
/// cancelled and the window asks Stop and Save, Discard, or Cancel; a quit
/// that saves asks to quit again only once the save is done; a save under
/// way finishes first; a save that fails keeps TextMouth open and is asked
/// about again; and nothing else is held. Closing the window asks the same
/// question. The test answers each question, nothing is shown, and nothing
/// quits: the app delegate's request to quit again is the test's own.
@MainActor
final class RecordingQuitTests: XCTestCase {

    // MARK: - Quitting

    /// Stop and Save stops the take and saves it, then asks to quit again:
    /// the save is done before TextMouth would end.
    func testStopAndSaveSavesBeforeQuitting() async throws {
        let quit = try QuitHarness(test: self, answers: [.save])
        await quit.window.model.record()
        await quit.window.backend.record(seconds: 2)

        XCTAssertEqual(quit.delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)

        let askedAgain = await eventually { !quit.quitRequests.isEmpty }
        XCTAssertTrue(askedAgain, "TextMouth never asked to quit again")
        XCTAssertEqual(quit.questions, [CloseQuestion(need: .stopOrDiscard)])
        XCTAssertEqual(quit.quitRequests, [1], "TextMouth asked to quit again before the take was saved")
        XCTAssertEqual(quit.window.saver.calls.first?.take.duration ?? 0, 2, accuracy: 0.01)
        guard case .saved = quit.window.model.phase else {
            return XCTFail("not saved: \(quit.window.model.phase)")
        }
        XCTAssertFalse(quit.controller.holdQuit(then: {}), "the quit TextMouth asks for again is held too")
    }

    /// Discard deletes the take, saves nothing, and asks to quit again.
    func testDiscardDeletesTheTakeThenQuits() async throws {
        let quit = try QuitHarness(test: self, answers: [.discard])
        await quit.window.model.record()
        await quit.window.backend.record(seconds: 1)
        let recorded = await quit.window.backend.url
        let take = try XCTUnwrap(recorded)

        XCTAssertEqual(quit.delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)

        let askedAgain = await eventually { !quit.quitRequests.isEmpty }
        XCTAssertTrue(askedAgain, "TextMouth never asked to quit again")
        XCTAssertEqual(quit.quitRequests, [0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: take.path), "Discard kept the take")
        XCTAssertEqual(quit.window.model.closeNeed, .nothing)
    }

    /// Cancel keeps the take, still recording, and TextMouth open; the next
    /// quit asks again.
    func testCancelKeepsRecordingAndAsksAgainNextTime() async throws {
        let quit = try QuitHarness(test: self, answers: [.cancel, .discard])
        await quit.window.model.record()

        XCTAssertEqual(quit.delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        let answered = await eventually { quit.questions.count == 1 && !quit.controller.isAsking }
        XCTAssertTrue(answered)
        XCTAssertEqual(quit.quitRequests, [], "Cancel quit")
        XCTAssertEqual(quit.window.model.service.state, .recording, "Cancel stopped the recording")

        XCTAssertEqual(quit.delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        let askedAgain = await eventually { !quit.quitRequests.isEmpty }
        XCTAssertTrue(askedAgain)
        XCTAssertEqual(quit.questions.count, 2)
    }

    /// A quit while a save is under way asks nothing: the save finishes,
    /// then TextMouth asks to quit again.
    func testAQuitDuringASaveWaitsForTheSave() async throws {
        let quit = try QuitHarness(test: self, answers: [])
        quit.window.saver.holdsSaves = true
        await quit.window.model.record()
        await quit.window.backend.record(seconds: 1)
        let stopping = Task { await quit.window.model.stop() }
        let saving = await eventually { quit.window.saver.isHoldingASave }
        XCTAssertTrue(saving)

        XCTAssertEqual(quit.delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(quit.questions, [], "a save under way was asked about")
        XCTAssertEqual(quit.quitRequests, [], "TextMouth quit during the save")

        quit.window.saver.releaseSaves()
        await stopping.value
        let askedAgain = await eventually { !quit.quitRequests.isEmpty }
        XCTAssertTrue(askedAgain, "TextMouth never asked to quit again once the save was done")
        XCTAssertEqual(quit.quitRequests, [1])
    }

    /// A save that fails keeps TextMouth open, the window saying why; the
    /// next quit asks to save or discard it, and a save then quits.
    func testAFailedSaveKeepsTextMouthOpenAndIsAskedAboutAgain() async throws {
        let quit = try QuitHarness(test: self, answers: [.save, .save])
        quit.window.saver.failure = CocoaError(.fileWriteOutOfSpace)
        await quit.window.model.record()
        await quit.window.backend.record(seconds: 1)

        XCTAssertEqual(quit.delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        let failed = await eventually { quit.window.model.hasUnsavedTake && !quit.controller.isAsking }
        XCTAssertTrue(failed, "the save did not fail: \(quit.window.model.phase)")
        XCTAssertEqual(quit.quitRequests, [], "TextMouth quit with the take unsaved")

        quit.window.saver.failure = nil
        XCTAssertEqual(quit.delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        let askedAgain = await eventually { !quit.quitRequests.isEmpty }
        XCTAssertTrue(askedAgain)
        XCTAssertEqual(quit.questions, [CloseQuestion(need: .stopOrDiscard), CloseQuestion(need: .saveOrDiscard)])
        XCTAssertEqual(quit.quitRequests, [2])
    }

    /// A question already on screen, as closing the window asked it,
    /// answers for a quit that comes meanwhile: no second question, and its
    /// Stop and Save quits once saved.
    func testAQuestionOnScreenAnswersTheQuitToo() async throws {
        let quit = try QuitHarness(test: self, answers: [nil])
        await quit.window.model.record()
        await quit.window.backend.record(seconds: 1)

        XCTAssertFalse(quit.controller.windowShouldClose(quit.nsWindow))
        XCTAssertEqual(quit.delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(quit.questions.count, 1, "the quit asked a second question")

        quit.answerPendingQuestion(.save)
        let askedAgain = await eventually { !quit.quitRequests.isEmpty }
        XCTAssertTrue(askedAgain)
        XCTAssertEqual(quit.quitRequests, [1])
    }

    /// Nothing is held without a take of the window's: no window, a window
    /// ready to record, or one listing only takes left behind, which stay
    /// safe on disk.
    func testNothingIsHeldWithoutATakeOfTheWindows() async throws {
        XCTAssertFalse(RecordingWindowController().holdQuit(then: {}))

        let quit = try QuitHarness(test: self, answers: [])
        XCTAssertFalse(quit.controller.holdQuit(then: {}))
        let left = try RecordingTakeFiles.newTakeURL(startedAt: RecordingWindowHarness.opensAt, in: quit.window.takesFolder)
        try RecordingAudioFixtures.writeTake(to: left, duration: 1)
        await quit.window.model.refreshRecoveredTakes()
        XCTAssertEqual(quit.window.model.recoveredTakes.map(\.url), [left])
        XCTAssertFalse(quit.controller.holdQuit(then: {}), "a take left behind held the quit")
        XCTAssertEqual(quit.questions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: left.path))
    }

    // MARK: - Closing

    /// Closing the window while recording asks the same question; Stop and
    /// Save saves the take, then closes the window.
    func testClosingWhileRecordingSavesThenCloses() async throws {
        let quit = try QuitHarness(test: self, answers: [.save])
        await quit.window.model.record()
        await quit.window.backend.record(seconds: 1)

        XCTAssertFalse(quit.controller.windowShouldClose(quit.nsWindow))

        let closed = await eventually { quit.controller.window == nil }
        XCTAssertTrue(closed, "the window did not close")
        XCTAssertEqual(quit.window.saver.calls.count, 1)
        XCTAssertEqual(quit.quitRequests, [], "closing the window quit")
    }
}

// MARK: - The Quit's Collaborators

/// A Record window shown by a controller of its own in a window kept off
/// screen, and an app delegate quitting through that controller, as the app
/// wires them; the close question answered by the test, in turn, and each
/// request to quit again noted with how many saves were made by then.
@MainActor
private final class QuitHarness {
    /// The Record window's model and its fakes.
    let window: RecordingWindowHarness
    /// The controller answering for the window.
    let controller = RecordingWindowController()
    /// The app delegate whose quit hold asks the controller.
    let delegate = AppDelegate()
    /// The window, never shown.
    let nsWindow: NSWindow
    /// The questions asked, in order.
    private(set) var questions: [CloseQuestion] = []
    /// For each request to quit again, how many saves had been made.
    private(set) var quitRequests: [Int] = []
    /// The answers to give, in turn; nil leaves the question on screen.
    private var answers: [CloseAnswer?]
    /// What answers the question left on screen.
    private var pendingAnswer: (@MainActor (CloseAnswer) -> Void)?

    init(test: XCTestCase, answers: [CloseAnswer?]) throws {
        window = try RecordingWindowHarness(test: test)
        self.answers = answers
        nsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        nsWindow.isReleasedWhenClosed = false
        controller.bringForward = { _ in }
        controller.askQuestion = { [weak self] question, _, answered in
            self?.asked(question, answered)
        }
        controller.present(window.model, in: nsWindow)
        delegate.recordingWindows = controller
        delegate.requestTermination = { [weak self] in
            guard let self else { return }
            quitRequests.append(window.saver.calls.count)
        }
    }

    /// Notes `question`, and answers it with the next answer, or leaves it
    /// on screen.
    private func asked(_ question: CloseQuestion, _ answered: @escaping @MainActor (CloseAnswer) -> Void) {
        questions.append(question)
        let answer = answers.isEmpty ? nil : answers.removeFirst()
        if let answer {
            answered(answer)
        } else {
            pendingAnswer = answered
        }
    }

    /// Answers the question left on screen with `answer`.
    func answerPendingQuestion(_ answer: CloseAnswer) {
        let answered = pendingAnswer
        pendingAnswer = nil
        answered?(answer)
    }
}
