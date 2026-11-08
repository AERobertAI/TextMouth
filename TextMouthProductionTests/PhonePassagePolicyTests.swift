import XCTest
@testable import TextMouth

/// `PhonePassagePolicy`: when Book content changes, the passage it holds,
/// Listen from Here's place, and the Sentences rotor's steps, by the spec's
/// "Book content".
final class PhonePassagePolicyTests: XCTestCase {
    // MARK: - When It Changes

    /// Loading, focus leaving, and the listener's own request always change
    /// the passage.
    func testTheseEventsAlwaysChangeThePassage() {
        for event in [PhonePassagePolicy.Event.loaded, .focusLeft, .followAsked] {
            for hasFocus in [false, true] {
                XCTAssertTrue(changes(event, hasFocus: hasFocus, isPlaying: true), "\(event)")
            }
        }
    }

    /// A move changes the passage, except while the book plays and Book
    /// content has focus, when only Follow in Braille lets it (the spec, "when
    /// it has focus and the book plays, never, unless the Follow in Braille
    /// switch").
    func testAMoveDoesNotReplaceTheTextUnderAFocusedReaderWhileItPlays() {
        XCTAssertTrue(changes(.movedWhilePaused, hasFocus: false, isPlaying: true))
        XCTAssertTrue(changes(.movedWhilePaused, hasFocus: false, isPlaying: false))
        XCTAssertTrue(changes(.movedWhilePaused, hasFocus: true, isPlaying: false))
        XCTAssertFalse(changes(.movedWhilePaused, hasFocus: true, isPlaying: true))
        XCTAssertTrue(changes(.movedWhilePaused, hasFocus: true, isPlaying: true, follows: true))
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

    // MARK: - Paging

    /// Paging forward goes on where the passage ends, then to the next
    /// chapter with words in it, passing over a chapter of spaces; nothing
    /// after the last.
    func testPagingForwardCrossesChapters() {
        let chapters = ["0123456789", "   ", "Next words."]
        XCTAssertEqual(target(chapters, chapter: 0, shown: 0..<4, forward: true)?.chapter, 0)
        XCTAssertEqual(target(chapters, chapter: 0, shown: 0..<4, forward: true)?.offset, 4)
        XCTAssertEqual(target(chapters, chapter: 0, shown: 4..<10, forward: true)?.chapter, 2)
        XCTAssertEqual(target(chapters, chapter: 0, shown: 4..<10, forward: true)?.offset, 0)
        XCTAssertNil(target(chapters, chapter: 2, shown: 0..<11, forward: true))
    }

    /// Paging back goes a passage's length before the start, then to the
    /// last passage of the chapter with words before; nothing before the
    /// first.
    func testPagingBackCrossesChapters() {
        let chapters = ["0123456789", "   ", "Next words."]
        XCTAssertEqual(target(chapters, chapter: 0, shown: 8..<10, forward: false)?.offset, 4)
        XCTAssertEqual(target(chapters, chapter: 0, shown: 2..<10, forward: false)?.offset, 0)
        let back = target(chapters, chapter: 2, shown: 0..<11, forward: false)
        XCTAssertEqual(back?.chapter, 0)
        XCTAssertEqual(back?.offset, 6)
        XCTAssertNil(target(chapters, chapter: 0, shown: 0..<10, forward: false))
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

    // MARK: - The Place to Show

    /// Whether each of `chapters` has words, by playback's own rule.
    private func place(_ chapters: [String], chapter: Int, offset: Int) -> (chapter: Int, offset: Int)? {
        PhonePassagePolicy.placeToShow(
            chapter: chapter,
            offset: offset,
            chapterCount: chapters.count,
            hasWords: { ReaderViewModel.hasSpeakableText(chapters[$0]) }
        )
    }

    /// A place in a chapter with words stays where it is.
    func testAPlaceInAChapterWithWordsStays() {
        let shown = place(["", "One. Two."], chapter: 1, offset: 5)
        XCTAssertEqual(shown?.chapter, 1)
        XCTAssertEqual(shown?.offset, 5)
    }

    /// A new Project Gutenberg EPUB: the place is the start of a "Cover"
    /// chapter that holds only an image, so Book content shows the first
    /// passage of the next chapter with words, the one Play would read.
    func testAPlaceInAChapterWithNoTextMovesToTheNextWithWords() {
        let shown = place(["", " \n ", "Chapter I. It began.", "More."], chapter: 0, offset: 0)
        XCTAssertEqual(shown?.chapter, 2)
        XCTAssertEqual(shown?.offset, 0)
    }

    /// When no later chapter has words, there's nothing to show, and the
    /// search never goes back or wraps around.
    func testNothingToShowWhenNoLaterChapterHasWords() {
        XCTAssertNil(place(["Words.", "", " "], chapter: 1, offset: 0))
    }

    /// A chapter outside the book gives nothing, however the place got there.
    func testAChapterOutsideTheBookGivesNothing() {
        XCTAssertNil(place(["Words."], chapter: 3, offset: 0))
        XCTAssertNil(place(["Words."], chapter: -1, offset: 0))
        XCTAssertNil(place([], chapter: 0, offset: 0))
    }

    // MARK: - Read All's page turns

    /// Paused, a turn moves the place as well as the text, so stopping Read All
    /// leaves the place at the last page reached.
    func testTurnWhilePausedMovesThePlaceAndTheText() {
        XCTAssertEqual(PhonePassagePolicy.turnEffect(isPlaying: false), .movesPlaceAndText)
    }

    /// Playing, a turn moves only the text; the book plays on.
    func testTurnWhilePlayingMovesOnlyTheText() {
        XCTAssertEqual(PhonePassagePolicy.turnEffect(isPlaying: true), .movesTextOnly)
    }

    /// Read All's chain of `.next` turns walks the whole book, across the
    /// chapter boundary and past a silent chapter, and then ends with nil,
    /// which the view answers with false so VoiceOver stops.
    func testRepeatedForwardTurnsWalkTheBookAndThenEnd() {
        let chapters = ["abcdefghij", "   ", "klmn"]
        var chapter = 0
        var shown = 0..<4
        var places: [[Int]] = []
        // Bounded, so a mistake can't loop forever.
        for _ in 0..<10 {
            guard let next = target(chapters, chapter: chapter, shown: shown, forward: true) else { break }
            places.append([next.chapter, next.offset])
            chapter = next.chapter
            shown = next.offset..<min(next.offset + 4, chapters[next.chapter].utf16Length)
        }
        XCTAssertEqual(places, [[0, 4], [0, 8], [2, 0]])
    }

    // MARK: - Helpers

    /// Where a page from `shown` of chapter `chapter` goes, with passages of
    /// at most four characters.
    private func target(
        _ chapters: [String],
        chapter: Int,
        shown: Range<Int>,
        forward: Bool
    ) -> (chapter: Int, offset: Int)? {
        PhonePassagePolicy.pageTarget(chapters: chapters, chapter: chapter, shown: shown, forward: forward, maximumLength: 4)
    }

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
