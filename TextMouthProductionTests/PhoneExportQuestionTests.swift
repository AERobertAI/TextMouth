import XCTest
@testable import TextMouth

/// `PhoneExportQuestion` and `PhoneExportQuestionPrompt`: the question an
/// export on the iPhone asks about a chapter nested too deeply (FR24, FR31),
/// the Mac's alert as the sheet's own: the Mac's words, the buttons in the
/// Mac's order, each answer, and a dismissal as Cancel Export.
@MainActor
final class PhoneExportQuestionTests: XCTestCase {
    /// The question about chapter 2 of a book, with more such chapters to come
    /// or not.
    private func question(offersEveryOne: Bool, chapter: Int? = 2) -> ExportDeepChapterQuestion {
        ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: chapter, limit: 128, offersEveryOne: offersEveryOne)
    }

    // MARK: - The Alert's Words and Buttons

    /// The title and message are the Mac's, and the message says what each
    /// button does, since an iOS alert's buttons have no hints.
    func testTheTitleAndMessageAreTheMacs() {
        let asked = question(offersEveryOne: true)
        let shown = PhoneExportQuestion(asked)

        XCTAssertEqual(shown.title, BookExportDeepChapterWording.title(for: asked))
        XCTAssertEqual(shown.title, "Chapter 2 of Deep Notes nests too deeply")
        XCTAssertEqual(shown.message, BookExportDeepChapterWording.message(for: asked))
        for button in ["Export as Written", "Export Every Such Chapter as Written", "Cancel Export"] {
            XCTAssertTrue(shown.message.contains(button), "the message does not say what \(button) does")
        }
    }

    /// The default button comes first, Cancel Export last, and the every-chapter
    /// button only while more such chapters may follow.
    func testTheButtonsInTheMacsOrder() {
        XCTAssertEqual(
            PhoneExportQuestion(question(offersEveryOne: true)).choices,
            [.exportAsWritten, .exportEveryOneAsWritten, .cancelExport]
        )
        XCTAssertEqual(
            PhoneExportQuestion(question(offersEveryOne: false)).choices,
            [.exportAsWritten, .cancelExport]
        )
        XCTAssertEqual(
            PhoneExportQuestion(question(offersEveryOne: true)).choices.map(\.title),
            ["Export as Written", "Export Every Such Chapter as Written", "Cancel Export"]
        )
        XCTAssertFalse(PhoneExportQuestion(question(offersEveryOne: false)).message.contains("Export Every Such Chapter as Written"))
    }

    /// Each button gives the answer its name says, and a dismissal is Cancel
    /// Export.
    func testEachButtonsAnswerAndADismissalIsCancelExport() {
        XCTAssertEqual(PhoneExportQuestion.Choice.exportAsWritten.answer, .exportAsWritten)
        XCTAssertEqual(PhoneExportQuestion.Choice.exportEveryOneAsWritten.answer, .exportEveryOneAsWritten)
        XCTAssertEqual(PhoneExportQuestion.Choice.cancelExport.answer, .cancelExport)
        XCTAssertEqual(PhoneExportQuestion.dismissalChoice, .cancelExport)
    }

    /// A text with no chapter markers is named by its book, as the Mac names it.
    func testATextWithNoChaptersIsNamedByItsBook() {
        let shown = PhoneExportQuestion(question(offersEveryOne: false, chapter: nil))

        XCTAssertEqual(shown.title, "The text of Deep Notes nests too deeply")
    }

    // MARK: - The Prompt

    /// The prompt shows the question while the export waits, and each answer
    /// reaches the export, once, taking the question down.
    func testEachAnswerReachesTheExportAndTakesTheQuestionDown() async {
        for choice in [PhoneExportQuestion.Choice.exportAsWritten, .exportEveryOneAsWritten, .cancelExport] {
            let prompt = PhoneExportQuestionPrompt()
            let asked = question(offersEveryOne: true)

            let waiting = Task { await prompt.ask(asked) }
            await eventuallyPending(prompt)
            XCTAssertEqual(prompt.pending?.question, asked)
            prompt.answer(choice)
            let answer = await waiting.value

            XCTAssertEqual(answer, choice.answer, "\(choice)")
            XCTAssertNil(prompt.pending)
        }
    }

    /// Stop, or the sheet closing, takes the question down answered as Cancel
    /// Export, so the export that waits is released; a second dismissal, or a
    /// button pressed after it, changes nothing.
    func testDismissingAnswersCancelExportOnce() async {
        let prompt = PhoneExportQuestionPrompt()
        let waiting = Task { await prompt.ask(question(offersEveryOne: true)) }
        await eventuallyPending(prompt)

        prompt.dismiss()
        prompt.dismiss()
        prompt.answer(.exportAsWritten)
        let answer = await waiting.value

        XCTAssertEqual(answer, .cancelExport)
        XCTAssertNil(prompt.pending)
    }

    /// Dismissing with no question shown does nothing, and the next question
    /// is asked as usual.
    func testDismissingWithNothingShownDoesNothing() async {
        let prompt = PhoneExportQuestionPrompt()

        prompt.dismiss()
        let waiting = Task { await prompt.ask(question(offersEveryOne: false)) }
        await eventuallyPending(prompt)
        prompt.answer(.exportAsWritten)
        let answer = await waiting.value

        XCTAssertEqual(answer, .exportAsWritten)
    }

    /// A question asked while another still waits is answered Cancel Export
    /// at once, so no export can wait for ever, and the first question stays.
    func testASecondQuestionWhileOneWaitsCancels() async {
        let prompt = PhoneExportQuestionPrompt()
        let first = Task { await prompt.ask(question(offersEveryOne: true)) }
        await eventuallyPending(prompt)

        let second = await prompt.ask(question(offersEveryOne: false))
        XCTAssertEqual(second, .cancelExport)
        XCTAssertNotNil(prompt.pending, "the first question was taken down")

        prompt.answer(.exportAsWritten)
        let answer = await first.value
        XCTAssertEqual(answer, .exportAsWritten)
    }

    /// Waits, in turns of the main queue and for a bounded time, until the
    /// prompt shows a question.
    private func eventuallyPending(_ prompt: PhoneExportQuestionPrompt, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 where prompt.pending == nil {
            await waitForMainQueueTurnAsync()
        }
        XCTAssertNotNil(prompt.pending, "the question was never shown", file: file, line: line)
    }

    // MARK: - With the Sheet Closed

    /// Once the sheet that shows the alert has closed, a question cannot be put to anyone: it is answered Cancel Export at
    /// once, never waited on, and the end of the export says so. Before that the prompt waits for a person as ever, and
    /// says nothing of it.
    func testAQuestionWithTheSheetClosedIsAnsweredCancelExportAtOnce() async {
        let prompt = PhoneExportQuestionPrompt()
        XCTAssertNil(prompt.wordsAfterTheEnd, "words about a question that was never asked")

        prompt.sheetClosed()
        let answer = await prompt.ask(question(offersEveryOne: true))

        XCTAssertEqual(answer, .cancelExport)
        XCTAssertNil(prompt.pending, "a question was put on a sheet that is gone")
        XCTAssertEqual(prompt.wordsAfterTheEnd, PhoneExportWording.questionWithNoSheet)
    }

    /// A sheet that closes after its question was answered leaves no words: only a question that came too late counts.
    func testClosingTheSheetAfterAnAnswerSaysNothing() async {
        let prompt = PhoneExportQuestionPrompt()
        let asked = Task { await prompt.ask(question(offersEveryOne: false)) }
        await eventuallyPending(prompt)

        prompt.answer(.exportAsWritten)
        let answer = await asked.value
        prompt.sheetClosed()

        XCTAssertEqual(answer, .exportAsWritten)
        XCTAssertNil(prompt.wordsAfterTheEnd)
    }
}
