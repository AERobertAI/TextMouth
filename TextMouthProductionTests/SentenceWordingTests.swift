import XCTest
@testable import TextMouth

/// `SentenceWording.joined`: the one joiner of whole sentences (FR34), whose
/// separator is a localized pattern so Japanese and Chinese can join with no
/// space. English joins with one space, as the sentences were joined before.
final class SentenceWordingTests: XCTestCase {
    /// No sentences make no text, and one sentence is itself, with no
    /// stray separator before or after it.
    func testNothingAndOneSentenceAddNoSeparator() {
        XCTAssertEqual(SentenceWording.joined([]), "")
        XCTAssertEqual(SentenceWording.joined(["One."]), "One.")
    }

    /// Two or more sentences are joined by the pattern, one space in English,
    /// in order, folded pairwise.
    func testSentencesAreJoinedByTheLocalizedSeparator() {
        XCTAssertEqual(SentenceWording.joined(["One.", "Two."]), "One. Two.")
        XCTAssertEqual(SentenceWording.joined(["One.", "Two.", "Three.", "Four."]), "One. Two. Three. Four.")
    }

    /// Speak Info's sentences go through the shared joiner: the same words
    /// as before, a space apart, with empty parts left out.
    func testSpeakInfoJoinsItsSentencesWithTheSharedJoiner() {
        XCTAssertEqual(LibraryInfoWording.sentences(["A book", "", "by Someone."]), "A book. by Someone.")
        XCTAssertEqual(LibraryInfoWording.sentences([]), "")
        XCTAssertEqual(LibraryInfoWording.sentences(["Done!", "Why?", "Because…"]), "Done! Why? Because…")
    }
}
