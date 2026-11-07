import XCTest
@testable import TextMouth

/// `PhoneMoveFeedback`: what a move says while the book plays and while it's
/// paused, by the spec's "What a move says" and the engineering review's F2.
final class PhoneMoveFeedbackTests: XCTestCase {
    // MARK: - While the Book Plays

    /// A move by sentence, paragraph, or seconds, and a text book's heading
    /// or subheading, says nothing while the book plays.
    func testWhilePlayingATextMoveSaysNothing() {
        for unit in [SkipUnit.sentence, .paragraph, .seconds15, .heading, .subheading] {
            // A move by seconds says nothing on the Mac either.
            let said = unit.isTimeBased ? [] : [word(macWord(for: unit))]
            let feedback = PhoneMoveFeedback.deciding(move(unit, playing: true, said: said))
            XCTAssertNil(feedback.playValue, "\(unit)")
            XCTAssertEqual(feedback.announcements, [], "\(unit)")
        }
    }

    /// A page, a bookmark, and an audiobook's heading say the Mac's short
    /// word while the book plays, since the book's own words can't.
    func testWhilePlayingAPageBookmarkOrAudiobookHeadingSaysItsWord() {
        let page = PhoneMoveFeedback.deciding(move(.page, playing: true, said: [word("Page 113")]))
        XCTAssertEqual(page.announcements, [word("Page 113")])
        XCTAssertNil(page.playValue)

        let bookmark = PhoneMoveFeedback.deciding(move(.bookmark, playing: true, said: [word("Bookmark 3")]))
        XCTAssertEqual(bookmark.announcements, [word("Bookmark 3")])

        let heading = PhoneMoveFeedback.deciding(
            move(.heading, playing: true, audiobook: true, said: [word("Heading: Chapter 4")])
        )
        XCTAssertEqual(heading.announcements, [word("Heading: Chapter 4")])
    }

    // MARK: - While Paused

    /// While paused, a heading, page, or bookmark's word goes in Play's value,
    /// and adjusting Play announces nothing more: the value is its answer.
    func testWhilePausedAStructuralWordGoesInPlaysValue() {
        for (unit, said) in [(SkipUnit.heading, "Heading: The Battle"), (.page, "Page 112"), (.bookmark, "Bookmark 3")] {
            let feedback = PhoneMoveFeedback.deciding(move(unit, playing: false, said: [word(said)]))
            XCTAssertEqual(feedback.playValue, said)
            XCTAssertEqual(feedback.announcements, [])
        }
    }

    /// After a command (a skip button, a heading button, a rotor), nothing
    /// answers by itself, so the paused move's words are also announced.
    func testWhilePausedACommandAlsoAnnouncesItsWords() {
        let feedback = PhoneMoveFeedback.deciding(
            move(.heading, source: .command, playing: false, said: [word("Heading: The Battle")])
        )
        XCTAssertEqual(feedback.playValue, "Heading: The Battle")
        XCTAssertEqual(feedback.announcements, [word("Heading: The Battle")])
    }

    /// A paused move by sentence or paragraph says the sentence at the new
    /// place, not the Mac's "Next sentence".
    func testWhilePausedASentenceMoveSaysTheSentence() {
        let feedback = PhoneMoveFeedback.deciding(
            move(.sentence, playing: false, said: [word("Next sentence")], sentence: "Call me Ishmael.")
        )
        XCTAssertEqual(feedback.playValue, "Call me Ishmael.")
        XCTAssertEqual(feedback.announcements, [])
    }

    /// With no sentence at the new place, a sentence move's Mac word stands
    /// in, so a paused move is never silent.
    func testASentenceMoveWithNoSentenceKeepsTheMacsWord() {
        let feedback = PhoneMoveFeedback.deciding(move(.paragraph, playing: false, said: [word("Next section")]))
        XCTAssertEqual(feedback.playValue, "Next section")
    }

    /// A paused move by seconds in a text book says the sentence at the new
    /// place; in an audiobook, the Mac's "Moved to" with the time.
    func testWhilePausedASecondsMoveSaysTheSentenceOrTheTime() {
        let text = PhoneMoveFeedback.deciding(move(.seconds30, playing: false, sentence: "It was a dark night."))
        XCTAssertEqual(text.playValue, "It was a dark night.")

        let audio = PhoneMoveFeedback.deciding(move(.seconds30, playing: false, audiobook: true, time: 3_825))
        XCTAssertEqual(audio.playValue, "Moved to 1 hour, 3 minutes, 45 seconds.")
        XCTAssertEqual(audio.announcements, [])
    }

    // MARK: - Nothing That Way

    /// A move that went nowhere says so, with the unit in lower case, whether
    /// playing or paused.
    func testAMoveThatWentNowhereSaysSo() {
        let playing = PhoneMoveFeedback.deciding(move(.heading, moved: false, playing: true))
        XCTAssertEqual(playing.announcements, [word("No next heading.")])
        XCTAssertNil(playing.playValue)

        let paused = PhoneMoveFeedback.deciding(move(.bookmark, forward: false, moved: false, playing: false))
        XCTAssertEqual(paused.playValue, "No previous bookmark.")
        XCTAssertEqual(paused.announcements, [])

        let pausedCommand = PhoneMoveFeedback.deciding(move(.page, source: .command, moved: false, playing: false))
        XCTAssertEqual(pausedCommand.announcements, [word("No next page.")])
    }

    /// A move by seconds at either end says where the book ends.
    func testASecondsMoveAtAnEndSaysWhichEnd() {
        let back = PhoneMoveFeedback.deciding(move(.seconds10, forward: false, moved: false, playing: false))
        XCTAssertEqual(back.playValue, "Start of the book.")
        let forward = PhoneMoveFeedback.deciding(move(.seconds60, moved: false, playing: true))
        XCTAssertEqual(forward.announcements, [word("End of the book.")])
    }

    /// When the Mac had a word for a move that went nowhere, that's the
    /// answer: "This book has no pages."
    func testAMoveThatWentNowhereKeepsTheMacsOwnWord() {
        let feedback = PhoneMoveFeedback.deciding(
            move(.page, moved: false, playing: false, said: [word(ReaderPageWording.noPages)])
        )
        XCTAssertEqual(feedback.playValue, ReaderPageWording.noPages)
    }

    // MARK: - What Else Passes

    /// What the shared code said before a structural move's own word, such
    /// as a sleep timer ending at a heading's end, still passes, in order and
    /// at its priority, playing or paused.
    func testEarlierWordsOfAStructuralMovePass() {
        let timer = VoiceOverAnnouncement(message: "Sleep timer ended", priority: .medium)
        let playing = PhoneMoveFeedback.deciding(
            move(.heading, playing: true, said: [timer, word("Heading: Coda")])
        )
        XCTAssertEqual(playing.announcements, [timer])

        let paused = PhoneMoveFeedback.deciding(
            move(.heading, source: .command, playing: false, said: [timer, word("Heading: Coda")])
        )
        XCTAssertEqual(paused.announcements, [timer, word("Heading: Coda")])
    }

    /// A move by seconds has no words of its own, so all it said passes.
    func testEverythingASecondsMoveSaidPasses() {
        let ended = word("Finished: Dune")
        let feedback = PhoneMoveFeedback.deciding(move(.seconds15, playing: true, said: [ended]))
        XCTAssertEqual(feedback.announcements, [ended])
    }

    /// The paused words win over the state before the move: a backward skip
    /// that starts a finished book counts as playing, and says nothing.
    func testTheStateAfterTheMoveDecides() {
        let feedback = PhoneMoveFeedback.deciding(
            move(.sentence, forward: false, playing: true, said: [word("Previous sentence")], sentence: "The end.")
        )
        XCTAssertNil(feedback.playValue)
        XCTAssertEqual(feedback.announcements, [])
    }

    // MARK: - Helpers

    /// A move, by default forward, by adjusting Play, that went somewhere, in
    /// a text book.
    private func move(
        _ unit: SkipUnit,
        source: PhoneMoveFeedback.Source = .adjustingPlay,
        forward: Bool = true,
        moved: Bool = true,
        playing: Bool,
        audiobook: Bool = false,
        said: [VoiceOverAnnouncement] = [],
        sentence: String? = nil,
        time: TimeInterval? = nil
    ) -> PhoneMoveFeedback.Move {
        PhoneMoveFeedback.Move(
            unit: unit,
            forward: forward,
            source: source,
            moved: moved,
            isPlayingAfter: playing,
            isAudioBook: audiobook,
            collected: said,
            sentenceAtPlace: sentence,
            timeAtPlace: time
        )
    }

    /// A word as a move says it.
    private func word(_ message: String) -> VoiceOverAnnouncement {
        PhoneMoveFeedback.ownWords(message)
    }

    /// The Mac's word for a move by `unit`, as the shared code says it.
    private func macWord(for unit: SkipUnit) -> String {
        switch unit {
        case .sentence: return "Next sentence"
        case .paragraph: return "Next paragraph"
        default: return "Heading: The Battle"
        }
    }
}
