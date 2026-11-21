import XCTest
@testable import TextMouth

/// The measured pace of speech the first run logs.
final class PhoneAudioPaceTests: XCTestCase {
    func testWordsAreRunsOfLettersAndDigits() {
        XCTAssertEqual(PhoneAudioPace.wordCount(in: "The ferry left at 9, late."), 6)
        XCTAssertEqual(PhoneAudioPace.wordCount(in: "  —  "), 0)
        XCTAssertEqual(PhoneAudioPace.wordCount(in: ""), 0)
        XCTAssertEqual(PhoneAudioPace.wordCount(in: "Café crème"), 2)
    }

    func testThePaceIsWordsPerMinute() {
        XCTAssertEqual(PhoneAudioPace.wordsPerMinute(words: 100, seconds: 30), 200)
    }

    func testTooLittleTimedSaysNothing() {
        XCTAssertNil(PhoneAudioPace.wordsPerMinute(words: 3, seconds: 0.5))
        XCTAssertNil(PhoneAudioPace.wordsPerMinute(words: 0, seconds: 30))
        XCTAssertNil(PhoneAudioPace.wordsPerMinute(words: 10, seconds: .infinity))
    }

    func testTheLogsWords() {
        XCTAssertEqual(
            PhoneAudioPace.description(words: 100, seconds: 30, expectedWordsPerMinute: 216.4),
            "words=100 seconds=30.0 wpm=200 expected=216"
        )
        XCTAssertEqual(
            PhoneAudioPace.description(words: 2, seconds: 0.4, expectedWordsPerMinute: 200),
            "words=2 seconds=0.4 wpm=unmeasured"
        )
    }
}
