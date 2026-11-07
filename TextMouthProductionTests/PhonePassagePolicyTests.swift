import XCTest
@testable import TextMouth

/// `PhonePassagePolicy`: when Book content changes, the passage it holds,
/// Listen from Here's place, and the Sentences rotor's steps, by the spec's
/// "Book content".
final class PhonePassagePolicyTests: XCTestCase {
    // MARK: - When It Changes

    /// Loading, a paused move, focus leaving, and the listener's own request
    /// always change the passage.
    func testTheseEventsAlwaysChangeThePassage() {
        for event in [PhonePassagePolicy.Event.loaded, .movedWhilePaused, .focusLeft, .followAsked] {
            for hasFocus in [false, true] {
                XCTAssertTrue(changes(event, hasFocus: hasFocus, isPlaying: true), "\(event)")
            }
        }
    }

    /// A pause changes it unless Book content has focus.
    func testAPauseChangesItUnlessFocused() {
        XCTAssertTrue(changes(.paused, hasFocus: false, isPlaying: false))
        XCTAssertFalse(changes(.paused, hasFocus: true, isPlaying: false))
    }

    /// While the book plays, the tick changes it only without focus, or with
    /// Follow in Braille on; never while paused.
    func testTheTickFollowsTheBookOnlyWithoutFocusOrWithFollowInBraille() {
        XCTAssertTrue(changes(.playingTick, hasFocus: false, isPlaying: true))
        XCTAssertFalse(changes(.playingTick, hasFocus: true, isPlaying: true))
        XCTAssertTrue(changes(.playingTick, hasFocus: true, isPlaying: true, follows: true))
        XCTAssertFalse(changes(.playingTick, hasFocus: false, isPlaying: false))
    }

    /// Coming back from the background changes it, but not under a reader
    /// in the middle of it.
    func testComingBackChangesItUnlessFocused() {
        XCTAssertTrue(changes(.cameBack, hasFocus: false, isPlaying: true))
        XCTAssertFalse(changes(.cameBack, hasFocus: true, isPlaying: true))
    }

    // MARK: - The Passage

    /// The passage starts at the start of the sentence holding the place,
    /// and runs to the chapter's end when that's within the limit.
    func testThePassageStartsAtTheSentenceStart() {
        let text = "One two. Three four five. Six."
        // The place inside "Three four five." starts the passage at "Three".
        XCTAssertEqual(PhonePassagePolicy.passage(in: text, at: 15, maximumLength: 100), 9..<30)
        XCTAssertEqual(PhonePassagePolicy.passage(in: text, at: 9, maximumLength: 100), 9..<30)
        XCTAssertEqual(PhonePassagePolicy.passage(in: text, at: 0, maximumLength: 100), 0..<30)
    }

    /// A place out of the text's bounds is held to them.
    func testAPlaceOutOfBoundsIsHeldToTheText() {
        let text = "One two. Three."
        XCTAssertEqual(PhonePassagePolicy.passage(in: text, at: -5, maximumLength: 100), 0..<15)
        XCTAssertEqual(PhonePassagePolicy.passage(in: text, at: 999, maximumLength: 100).upperBound, 15)
        XCTAssertEqual(PhonePassagePolicy.passage(in: "", at: 0, maximumLength: 100), 0..<0)
    }

    /// A long passage stops within the limit, on a whole word.
    func testALongPassageEndsOnAWholeWord() {
        let text = "Start here. " + Array(repeating: "alpha", count: 50).joined(separator: " ")
        let range = PhonePassagePolicy.passage(in: text, at: 0, maximumLength: 100)
        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertLessThanOrEqual(range.count, 100)
        let end = text.index(atUTF16Offset: range.upperBound)
        XCTAssertTrue(end == text.endIndex || text[end].isWhitespace, "The passage ends inside a word")
        XCTAssertGreaterThan(range.count, 60, "The end moved back too far")
    }

    // MARK: - Listen from Here

    /// A moved selection wins; then the rotor's sentence; then the start.
    func testListenFromHereFindsVoiceOversCursorInOrder() {
        XCTAssertEqual(
            PhonePassagePolicy.listeningPlace(passageStart: 100, movedSelection: 12, rotorSentence: 40, passageLength: 80),
            112
        )
        XCTAssertEqual(
            PhonePassagePolicy.listeningPlace(passageStart: 100, movedSelection: nil, rotorSentence: 40, passageLength: 80),
            140
        )
        XCTAssertEqual(
            PhonePassagePolicy.listeningPlace(passageStart: 100, movedSelection: nil, rotorSentence: nil, passageLength: 80),
            100
        )
        // A place past the passage is held inside it.
        XCTAssertEqual(
            PhonePassagePolicy.listeningPlace(passageStart: 100, movedSelection: 500, rotorSentence: nil, passageLength: 80),
            179
        )
    }

    // MARK: - The Sentences Rotor

    /// The rotor steps sentence by sentence, each a range of the passage,
    /// and finds nothing past either end.
    func testTheRotorStepsBySentence() {
        let passage = "One two. Three four. Five."
        XCTAssertEqual(PhonePassagePolicy.sentence(in: passage, from: 0, forward: true), 9..<21)
        XCTAssertEqual(PhonePassagePolicy.sentence(in: passage, from: 9, forward: true), 21..<26)
        XCTAssertNil(PhonePassagePolicy.sentence(in: passage, from: 21, forward: true))
        XCTAssertEqual(PhonePassagePolicy.sentence(in: passage, from: 21, forward: false), 9..<21)
        XCTAssertEqual(PhonePassagePolicy.sentence(in: passage, from: 9, forward: false), 0..<9)
        XCTAssertNil(PhonePassagePolicy.sentence(in: passage, from: 0, forward: false))
        // From inside a sentence, back goes to its own start.
        XCTAssertEqual(PhonePassagePolicy.sentence(in: passage, from: 12, forward: false), 9..<21)
    }

    // MARK: - Helpers

    /// Whether `event` changes the passage in the state given.
    private func changes(
        _ event: PhonePassagePolicy.Event,
        hasFocus: Bool,
        isPlaying: Bool,
        follows: Bool = false
    ) -> Bool {
        PhonePassagePolicy.changesPassage(on: event, hasFocus: hasFocus, isPlaying: isPlaying, followsInBraille: follows)
    }
}
