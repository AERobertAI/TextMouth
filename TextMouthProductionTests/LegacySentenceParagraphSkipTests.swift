import XCTest
@testable import TextMouth

/// Production-backed ports of every legacy sentence/paragraph skip scenario.
final class LegacySentenceParagraphSkipTests: XCTestCase {
    private let sentences = "First sentence. Second sentence. Third sentence."
    private let paragraphs = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."

    func testNextSentenceFromStart() {
        XCTAssertEqual(ReaderViewModel.nextSentenceStart(in: sentences, after: 0), 16)
    }

    func testNextSentenceFromMiddleOfFirst() {
        XCTAssertEqual(ReaderViewModel.nextSentenceStart(in: sentences, after: 5), 16)
    }

    func testNextSentenceFromSecond() {
        XCTAssertEqual(ReaderViewModel.nextSentenceStart(in: sentences, after: 16), 33)
    }

    func testNextSentenceReturnsNilWhenNoSentenceRemains() {
        XCTAssertNil(ReaderViewModel.nextSentenceStart(in: "Only sentence.", after: 0))
    }

    func testNextSentenceRecognizesExclamationMark() {
        XCTAssertEqual(ReaderViewModel.nextSentenceStart(in: "Wow! That was great.", after: 0), 5)
    }

    func testNextSentenceRecognizesQuestionMark() {
        XCTAssertEqual(ReaderViewModel.nextSentenceStart(in: "Really? Yes indeed.", after: 0), 8)
    }

    func testPreviousSentenceFromMiddleOfSecond() {
        XCTAssertEqual(ReaderViewModel.sentenceStart(in: sentences, before: 25), 16)
    }

    func testPreviousSentenceWithoutEarlierBoundaryReturnsStart() {
        XCTAssertEqual(ReaderViewModel.sentenceStart(in: "First sentence. Second sentence.", before: 5), 0)
    }

    func testPreviousSentenceAtThirdSentenceReturnsThirdStart() {
        XCTAssertEqual(ReaderViewModel.sentenceStart(in: "First. Second. Third.", before: 15), 15)
    }

    func testSentenceNavigationReturnsUTF16OffsetsForEmojiText() {
        let text = "😀 Hi. Next."

        XCTAssertEqual(ReaderViewModel.nextSentenceStart(in: text, after: 0), 7)
        XCTAssertEqual(ReaderViewModel.sentenceStart(in: text, before: text.utf16.count), 7)
    }

    func testNextParagraphFromStart() {
        XCTAssertEqual(ReaderViewModel.nextParagraphStart(in: paragraphs, after: 0), 18)
    }

    func testNextParagraphFromSecond() {
        XCTAssertEqual(ReaderViewModel.nextParagraphStart(in: paragraphs, after: 18), 37)
    }

    func testNextParagraphReturnsNilWhenNoParagraphRemains() {
        XCTAssertNil(ReaderViewModel.nextParagraphStart(in: "Only one paragraph here.", after: 0))
    }

    func testPreviousParagraphFromMiddleOfSecond() {
        XCTAssertEqual(ReaderViewModel.paragraphStart(in: paragraphs, before: 25), 18)
    }

    func testPreviousParagraphWithoutEarlierBoundaryReturnsStart() {
        XCTAssertEqual(ReaderViewModel.paragraphStart(in: "First paragraph.\n\nSecond paragraph.", before: 5), 0)
    }

    func testNextParagraphTreatsTripleNewlineAsOneBreak() {
        XCTAssertEqual(ReaderViewModel.nextParagraphStart(in: "First.\n\n\nSecond.", after: 0), 9)
    }

    func testParagraphNavigationReturnsUTF16OffsetsForEmojiText() {
        let text = "😀 first.\n\nNext."

        XCTAssertEqual(ReaderViewModel.nextParagraphStart(in: text, after: 0), 11)
        XCTAssertEqual(ReaderViewModel.paragraphStart(in: text, before: text.utf16.count), 11)
    }

    func testSentenceSkipUnitIsStructural() {
        XCTAssertFalse(SkipUnit.sentence.isTimeBased)
        XCTAssertNil(SkipUnit.sentence.wordCount(wpm: 200))
        XCTAssertNil(SkipUnit.sentence.seconds)
    }

    func testParagraphSkipUnitIsStructural() {
        XCTAssertFalse(SkipUnit.paragraph.isTimeBased)
        XCTAssertNil(SkipUnit.paragraph.wordCount(wpm: 200))
        XCTAssertNil(SkipUnit.paragraph.seconds)
    }

    func testSentenceAndParagraphSkipUnitRawValues() {
        XCTAssertEqual(SkipUnit.sentence.rawValue, "Sentence")
        XCTAssertEqual(SkipUnit.paragraph.rawValue, "Paragraph")
    }
}
