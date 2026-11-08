import XCTest
@testable import TextMouth

/// `PhoneReaderWording`: the reader's new words, each as the spec gives it,
/// and the sentence a paused move says.
@MainActor
final class PhoneReaderWordingTests: XCTestCase {
    /// The hints and labels the spec lists under "New words, in one place".
    func testTheSpecsWords() {
        XCTAssertEqual(PhoneReaderWording.playHint(movingBy: .sentence), "Moves back or forward by sentence.")
        XCTAssertEqual(PhoneReaderWording.navigationUnitHint, "Chooses what Play and the skip buttons move by.")
        XCTAssertEqual(PhoneReaderWording.textSpeedHint, "Changes the speed in steps of 25 words per minute.")
        XCTAssertEqual(PhoneReaderWording.bookContentPausedHint, "Plays from here.")
        XCTAssertEqual(PhoneReaderWording.bookContentPlayingHint, "Brings the text to the sentence being spoken.")
        XCTAssertEqual(PhoneReaderWording.sleepTimerOff, "Off")
    }

    /// No hint names a gesture (principle 7).
    func testNoHintNamesAGesture() {
        let hints = [
            PhoneReaderWording.playHint(movingBy: .heading),
            PhoneReaderWording.navigationUnitHint,
            PhoneReaderWording.textSpeedHint,
            PhoneReaderWording.previousHeadingHint,
            PhoneReaderWording.nextHeadingHint,
            PhoneReaderWording.bookContentPausedHint,
            PhoneReaderWording.bookContentPlayingHint,
            PhoneReaderWording.bookmarksHint,
            PhoneReaderWording.headingsHint,
            PhoneReaderWording.goToHint,
            PhoneReaderWording.returnHint,
            PhoneReaderWording.sleepTimerHint,
        ]
        for hint in hints {
            for gesture in ["tap", "swipe", "flick", "double", "press"] {
                XCTAssertFalse(hint.lowercased().contains(gesture), hint)
            }
            XCTAssertTrue(hint.hasSuffix("."), hint)
        }
    }

    /// What a move that went nowhere says.
    func testNothingThatWay() {
        XCTAssertEqual(PhoneReaderWording.nothingThatWay(unit: .heading, forward: true), "No next heading.")
        XCTAssertEqual(PhoneReaderWording.nothingThatWay(unit: .page, forward: false), "No previous page.")
        XCTAssertEqual(PhoneReaderWording.nothingThatWay(unit: .bookmark, forward: true), "No next bookmark.")
        XCTAssertEqual(PhoneReaderWording.nothingThatWay(unit: .seconds10, forward: false), "Start of the book.")
        XCTAssertEqual(PhoneReaderWording.nothingThatWay(unit: .seconds60, forward: true), "End of the book.")
    }

    /// Headings' value: the heading and its place, or the Mac's words before
    /// the first, or nothing for a book without headings.
    func testHeadingsValue() {
        let headings = [
            Heading(level: 1, text: "One", chapterIndex: 0, characterOffset: 10),
            Heading(level: 1, text: "  ", chapterIndex: 1, characterOffset: 0),
        ]
        XCTAssertEqual(
            PhoneReaderWording.headingsValue(HeadingPosition(in: headings, chapterIndex: 0, characterOffset: 20)),
            "One, 1 of 2"
        )
        XCTAssertEqual(
            PhoneReaderWording.headingsValue(HeadingPosition(in: headings, chapterIndex: 1, characterOffset: 5)),
            "2 of 2"
        )
        XCTAssertEqual(
            PhoneReaderWording.headingsValue(HeadingPosition(in: headings, chapterIndex: 0, characterOffset: 0)),
            "Before heading 1 of 2"
        )
        XCTAssertEqual(PhoneReaderWording.headingsValue(HeadingPosition(in: [], chapterIndex: 0, characterOffset: 0)), "")
    }

    /// An audiobook with no text says so, with the heading as a sentence.
    func testAnAudiobookWithNoText() {
        XCTAssertEqual(PhoneReaderWording.audiobookHasNoText(heading: "The Battle"), "This audiobook has no text. The Battle.")
        XCTAssertEqual(PhoneReaderWording.audiobookHasNoText(heading: "Why?"), "This audiobook has no text. Why?")
        XCTAssertEqual(PhoneReaderWording.audiobookHasNoText(heading: nil), "This audiobook has no text.")
        XCTAssertEqual(PhoneReaderWording.audiobookHasNoText(heading: " "), "This audiobook has no text.")
    }

    /// A paused move's sentence runs from the place to the sentence's end,
    /// its whitespace closed up.
    func testTheSentenceAtThePlace() {
        let text = "Call me Ishmael. Some years ago,\nnever mind how long. Precisely"
        XCTAssertEqual(PhoneReaderWording.sentence(in: text, from: 0), "Call me Ishmael.")
        XCTAssertEqual(PhoneReaderWording.sentence(in: text, from: 17), "Some years ago, never mind how long.")
        // The last sentence runs to the chapter's end.
        XCTAssertEqual(PhoneReaderWording.sentence(in: text, from: 54), "Precisely")
        // A place in the middle of a sentence gives the rest of it.
        XCTAssertEqual(PhoneReaderWording.sentence(in: text, from: 8), "Ishmael.")
    }

    /// Nothing at or past the end, nor only whitespace, gives a sentence.
    func testNoSentenceWhereThereIsNone() {
        XCTAssertNil(PhoneReaderWording.sentence(in: "End.   ", from: 4))
        XCTAssertNil(PhoneReaderWording.sentence(in: "End.", from: 4))
        XCTAssertNil(PhoneReaderWording.sentence(in: "End.", from: -1))
        XCTAssertNil(PhoneReaderWording.sentence(in: "", from: 0))
    }

    /// A run-on sentence is cut at a whole word within the limit, then "…".
    func testALongSentenceIsCappedAtAWord() {
        let long = Array(repeating: "word", count: 100).joined(separator: " ")
        let capped = PhoneReaderWording.capped(long)
        XCTAssertTrue(capped.hasSuffix("word…"))
        XCTAssertLessThanOrEqual(capped.count, PhoneReaderWording.movedSentenceCharacterLimit + 1)
        let unbroken = String(repeating: "x", count: 400)
        XCTAssertEqual(PhoneReaderWording.capped(unbroken).count, PhoneReaderWording.movedSentenceCharacterLimit + 1)
        XCTAssertEqual(PhoneReaderWording.capped("Short."), "Short.")
    }

    /// An audiobook's place in its recording.
    func testTimeIntoTheRecording() {
        XCTAssertEqual(PhoneReaderWording.timeIntoRecording(7_980), "2 hours, 13 minutes in")
    }
}
