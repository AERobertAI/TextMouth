import XCTest
@testable import TextMouth

/// `PhoneGoToModel`: the phone's Go To sheet's fields, words, focus, and
/// what taking a field does, by the spec's "The Go To sheet" and the Mac's
/// rule for its jump panels.
@MainActor
final class PhoneGoToModelTests: XCTestCase {
    /// A book of three pages, numbered i, ii, and 1.
    private let threePages = BookPages(breaks: [
        PageBreak(label: "i", characterOffset: 0),
        PageBreak(label: "ii", characterOffset: 100),
        PageBreak(label: "1", characterOffset: 200),
    ])

    /// A model for a text book read at 500 words a minute, with `pages`.
    private func textBook(pages: BookPages) -> PhoneGoToModel {
        PhoneGoToModel(
            isAudioBook: false,
            pages: pages,
            timeCount: .words(perMinute: 500),
            startingTexts: [.page: "ii", .percent: "47.0", .time: "12:04"]
        )
    }

    /// A model for an audiobook, which has no pages.
    private var audiobook: PhoneGoToModel {
        PhoneGoToModel(isAudioBook: true, pages: .none, timeCount: .recording, startingTexts: [.time: "1:02:03"])
    }

    // MARK: Fields and focus

    /// Page is offered only in a book of more than one page.
    func testPageIsOfferedOnlyForSeveralPages() {
        XCTAssertEqual(textBook(pages: threePages).fields, [.page, .percent, .time])
        XCTAssertEqual(textBook(pages: BookPages(breaks: [PageBreak(label: "1", characterOffset: 0)])).fields, [.percent, .time])
        XCTAssertEqual(textBook(pages: .none).fields, [.percent, .time])
    }

    /// Focus lands on Page, else Percent; in an audiobook, on the time.
    func testFocusLandsOnPageOrTheTimeOfAnAudiobook() {
        XCTAssertEqual(textBook(pages: threePages).initialFocus, .page)
        XCTAssertEqual(textBook(pages: .none).initialFocus, .percent)
        XCTAssertEqual(audiobook.initialFocus, .time)
    }

    /// Each field has the Mac's label and hint.
    func testTheFieldsSayWhatTheMacsPanelsSay() {
        let model = textBook(pages: threePages)

        XCTAssertEqual(model.label(of: .page), "Page")
        XCTAssertEqual(model.label(of: .percent), "Percent through the book")
        XCTAssertEqual(model.label(of: .time), "Time at 500 words a minute")
        XCTAssertEqual(audiobook.label(of: .time), "Time in the recording")
        XCTAssertEqual(model.hint(of: .page), ReaderPageWording.fieldHint(for: threePages))
        XCTAssertEqual(model.hint(of: .percent), "Type a percent from 0 to 100, such as 47.5.")
        XCTAssertEqual(model.hint(of: .time), "Type a time, such as 12:04.3, 1:02:03, or 75.5.")
    }

    /// Each Jump button names its field, in the spec's words.
    func testEachJumpButtonNamesItsField() {
        XCTAssertEqual(PhoneGoToField.allCases.map(\.jumpLabel), ["Jump to page", "Jump to percent", "Jump to time"])
        XCTAssertEqual(PhoneGoToModel.title, "Go To")
    }

    /// Each field starts at the place being read.
    func testEachFieldStartsAtThePlace() {
        let model = textBook(pages: threePages)

        XCTAssertEqual(model.startingText(of: .page), "ii")
        XCTAssertEqual(model.startingText(of: .percent), "47.0")
        XCTAssertEqual(audiobook.startingText(of: .percent), "")
    }

    // MARK: Taking a field

    /// A field left at its starting value closes without moving: the jump
    /// isn't asked for.
    func testAnUnchangedFieldClosesWithoutMoving() {
        var model = textBook(pages: threePages)
        var submitted: [String] = []

        let outcome = model.take(" 47.0 ", from: .percent) { text in
            submitted.append(text)
            return nil
        }

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(submitted, [])
    }

    /// A label the book uses twice is an answer as it stands.
    func testARepeatedLabelIsTakenUnchanged() {
        var model = textBook(pages: threePages)
        var submitted: [String] = []

        let outcome = model.take("ii", from: .page, submitsUnchanged: true) { text in
            submitted.append(text)
            return nil
        }

        XCTAssertEqual(outcome, .jumped)
        XCTAssertEqual(submitted, ["ii"])
    }

    /// A refusal stays under its field, in the Mac's words, until the field
    /// is edited.
    func testARefusalStaysUntilTheFieldIsEdited() {
        var model = textBook(pages: threePages)
        let problem = "There is no page 400 in this book. Its pages run from i to 1."

        let outcome = model.take("400", from: .page) { _ in problem }

        XCTAssertEqual(outcome, .refused(problem))
        XCTAssertEqual(model.refusalText(of: .page), "Error: \(problem)")
        XCTAssertNil(model.refusalText(of: .percent))

        model.noteEdited(.page)
        XCTAssertNil(model.refusalText(of: .page))
    }

    /// One refusal shows at a time: taking another field forgets the first.
    func testTakingAnotherFieldForgetsTheFirstRefusal() {
        var model = textBook(pages: threePages)

        _ = model.take("400", from: .page) { _ in "No such page." }
        let outcome = model.take("50", from: .percent) { _ in nil }

        XCTAssertEqual(outcome, .jumped)
        XCTAssertNil(model.refusalText(of: .page))
        XCTAssertNil(model.refusalText(of: .percent))
    }
}

/// `PhoneGoToVocabulary`: each word is the Mac's jump panel's, read from its
/// own source.
final class PhoneGoToVocabularyTests: XCTestCase {
    /// Every inline word is in `JumpFieldPanel` as the phone has it.
    func testEveryWordIsTheMacsJumpPanels() throws {
        let macView = try String(
            contentsOf: AppSourceFile.folder.appendingPathComponent("Views/Reader/ReaderJumpPanels.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(macView.contains("Button(\"\(PhoneGoToVocabulary.jump)\", action: take)"))
        XCTAssertTrue(macView.contains("Button(\"\(PhoneAppWording.cancel)\", action: onCancel)"))
        XCTAssertTrue(macView.contains(".accessibilityLabel(\"Error: \\(errorMessage)\")"))
        XCTAssertEqual(PhoneGoToVocabulary.refusal("Enter a percent."), "Error: Enter a percent.")
    }
}
