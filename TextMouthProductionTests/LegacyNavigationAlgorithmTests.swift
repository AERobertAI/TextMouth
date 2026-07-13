import XCTest
@testable import TextMouth

/// Production-backed navigation cases mined from the legacy simulator suite.
final class LegacyNavigationAlgorithmTests: XCTestCase {
    /// Shared ordered heading fixture for current/next/previous selection tests.
    private var headings: [Heading] {
        [
            Heading(level: 1, text: "H1", chapterIndex: 0, characterOffset: 0),
            Heading(level: 2, text: "H2", chapterIndex: 0, characterOffset: 500),
            Heading(level: 1, text: "H3", chapterIndex: 1, characterOffset: 0),
        ]
    }

    /// Only the closest heading at or before the cursor should be current.
    func testCurrentHeadingSelectsClosestPrecedingHeading() {
        let selected = ReaderViewModel.currentHeading(
            in: headings,
            chapterIndex: 0,
            characterOffset: 550
        )
        XCTAssertEqual(selected?.text, "H2")
    }

    /// Next-heading selection should cross chapter boundaries in document order.
    func testNextHeadingNavigation() {
        XCTAssertEqual(ReaderViewModel.nextHeading(in: headings, chapterIndex: 0, characterOffset: 100)?.text, "H2")
        XCTAssertEqual(ReaderViewModel.nextHeading(in: headings, chapterIndex: 0, characterOffset: 600)?.text, "H3")
        XCTAssertNil(ReaderViewModel.nextHeading(in: headings, chapterIndex: 1, characterOffset: 1))
    }

    /// Previous-heading selection should honor the reader's ten-character grace zone.
    func testPreviousHeadingNavigationUsesGraceZone() {
        XCTAssertEqual(ReaderViewModel.previousHeading(in: headings, chapterIndex: 0, characterOffset: 505)?.text, "H1")
        XCTAssertEqual(ReaderViewModel.previousHeading(in: headings, chapterIndex: 1, characterOffset: 100)?.text, "H3")
    }

    /// A target inside a word should snap to that word's UTF-16 start.
    func testSnapToWordBoundaryFindsWordStart() {
        XCTAssertEqual(ReaderViewModel.snappedWordStart(in: "Hello world this is a test", at: 7), 6)
    }

    /// Snapping the beginning of text should remain at zero.
    func testSnapAtTextStartRemainsZero() {
        XCTAssertEqual(ReaderViewModel.snappedWordStart(in: "Hello world", at: 0), 0)
    }

    /// A cursor already on a word boundary should not move.
    func testSnapAtExactWordBoundaryRemainsInPlace() {
        XCTAssertEqual(ReaderViewModel.snappedWordStart(in: "Hello world", at: 6), 6)
    }

    /// One forward word skip should land at the next word's start.
    func testSkipForwardOneWordFromStart() {
        XCTAssertEqual(ReaderViewModel.offsetAfterSkippingWords(in: "Hello world test", from: 0, wordCount: 1), 6)
    }

    /// Multiple forward skips should count word starts rather than characters.
    func testSkipForwardThreeWordsFromStart() {
        XCTAssertEqual(ReaderViewModel.offsetAfterSkippingWords(in: "one two three four five", from: 0, wordCount: 3), 14)
    }

    /// A forward skip beyond available words should clamp to the UTF-16 end.
    func testSkipForwardPastTextEndClamps() {
        let text = "Hello world"
        XCTAssertEqual(ReaderViewModel.offsetAfterSkippingWords(in: text, from: 0, wordCount: 10), text.utf16.count)
    }

    /// One backward word skip from the end should find the final word's start.
    func testSkipBackwardOneWord() {
        XCTAssertEqual(ReaderViewModel.offsetAfterSkippingWords(in: "Hello world test", from: 16, wordCount: -1), 12)
    }

    /// Multiple backward skips should traverse exact word starts.
    func testSkipBackwardTwoWordsFromMiddle() {
        XCTAssertEqual(ReaderViewModel.offsetAfterSkippingWords(in: "one two three four five", from: 18, wordCount: -2), 8)
    }

    /// A backward skip beyond available words should clamp to zero.
    func testSkipBackwardPastTextStartClamps() {
        XCTAssertEqual(ReaderViewModel.offsetAfterSkippingWords(in: "Hello world", from: 6, wordCount: -10), 0)
    }

    /// Starting inside a word should first consume the rest of that word.
    func testSkipForwardFromMiddleOfWord() {
        XCTAssertEqual(ReaderViewModel.offsetAfterSkippingWords(in: "Hello world test", from: 3, wordCount: 1), 6)
    }

    /// Empty text should always yield the only valid offset.
    func testSkipInEmptyTextReturnsZero() {
        XCTAssertEqual(ReaderViewModel.offsetAfterSkippingWords(in: "", from: 0, wordCount: 5), 0)
    }

    /// Word counting should include each word start in a complete range.
    func testCountWordsBetweenCompleteRange() {
        XCTAssertEqual(ReaderViewModel.countWordsBetween(in: "one two three four", from: 0, to: 18), 4)
    }

    /// Word counting should respect a partial UTF-16 range.
    func testCountWordsBetweenPartialRange() {
        XCTAssertEqual(ReaderViewModel.countWordsBetween(in: "one two three four", from: 4, to: 14), 2)
    }

    /// Forward scanning should consume runs of whitespace as one separator.
    func testSkipForwardAcrossMultipleSpaces() {
        XCTAssertEqual(ReaderViewModel.offsetAfterSkippingWords(in: "Hello   world   test", from: 0, wordCount: 1), 8)
    }

    /// The production time formula should change displayed remaining time by 15 seconds.
    func testFifteenSecondSkipMatchesRemainingTimeDisplay() {
        let content = uniformContent(characterCount: 10_000, wordCount: 2_000)
        let totalTime = content.estimatedReadingTime(wpm: 200)
        let delta = ReaderViewModel.timeSkipCharacterDelta(seconds: 15, totalCharacterCount: content.totalCharacterCount, totalTime: totalTime)
        XCTAssertNotNil(delta)

        let before = content.estimatedTimeRemaining(fromGlobalOffset: 5_000, wpm: 200)
        let after = content.estimatedTimeRemaining(fromGlobalOffset: 5_000 - (delta ?? 0), wpm: 200)
        XCTAssertEqual(after - before, 15, accuracy: 0.01)
    }

    /// The same time skip should have the same displayed effect throughout a book.
    func testThirtySecondSkipIsPositionIndependent() {
        let content = uniformContent(characterCount: 50_000, wordCount: 10_000)
        let totalTime = content.estimatedReadingTime(wpm: 250)
        let delta = ReaderViewModel.timeSkipCharacterDelta(seconds: 30, totalCharacterCount: content.totalCharacterCount, totalTime: totalTime) ?? 0

        for offset in stride(from: 5_000, through: 40_000, by: 5_000) {
            let before = content.estimatedTimeRemaining(fromGlobalOffset: offset, wpm: 250)
            let after = content.estimatedTimeRemaining(fromGlobalOffset: offset - delta, wpm: 250)
            XCTAssertEqual(after - before, 30, accuracy: 0.01)
        }
    }

    /// Equal forward and backward time skips should produce opposite character deltas.
    func testTimeSkipDirectionsAreSymmetric() {
        let content = uniformContent(characterCount: 20_000, wordCount: 4_000)
        let totalTime = content.estimatedReadingTime(wpm: 200)
        let forward = ReaderViewModel.timeSkipCharacterDelta(seconds: 15, totalCharacterCount: content.totalCharacterCount, totalTime: totalTime)
        let backward = ReaderViewModel.timeSkipCharacterDelta(seconds: -15, totalCharacterCount: content.totalCharacterCount, totalTime: totalTime)
        XCTAssertEqual(forward, -(backward ?? 0))
    }

    /// Faster speech should cover more characters during the same time interval.
    func testTimeSkipDeltaScalesWithWPM() {
        let content = uniformContent(characterCount: 10_000, wordCount: 2_000)
        let delta200 = ReaderViewModel.timeSkipCharacterDelta(
            seconds: 15,
            totalCharacterCount: content.totalCharacterCount,
            totalTime: content.estimatedReadingTime(wpm: 200)
        ) ?? 0
        let delta400 = ReaderViewModel.timeSkipCharacterDelta(
            seconds: 15,
            totalCharacterCount: content.totalCharacterCount,
            totalTime: content.estimatedReadingTime(wpm: 400)
        ) ?? 0
        XCTAssertGreaterThan(delta400, delta200)
    }

    /// Build content whose whitespace-separated word count and UTF-16 length are exact.
    private func uniformContent(characterCount: Int, wordCount: Int) -> DocumentContent {
        let separators = wordCount - 1
        let letters = characterCount - separators
        let baseLettersPerWord = letters / wordCount
        let extraLetters = letters % wordCount
        let words = (0..<wordCount).map { index in
            String(repeating: "a", count: baseLettersPerWord + (index < extraLetters ? 1 : 0))
        }
        return DocumentContent(title: "Time", author: "Test", chapters: [Chapter(text: words.joined(separator: " "))])
    }
}
