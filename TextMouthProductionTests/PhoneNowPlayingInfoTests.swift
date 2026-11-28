import MediaPlayer
import XCTest
@testable import TextMouth

/// The words and numbers the lock screen shows for a book.
final class PhoneNowPlayingInfoTests: XCTestCase {
    private func audiobook(speed: Double, elapsed: TimeInterval, duration: TimeInterval) -> PhoneNowPlayingDetails {
        PhoneNowPlayingDetails(
            speed: speed,
            chapterTime: PhoneNowPlayingDetails.ChapterTime(elapsed: elapsed, duration: duration)
        )
    }

    func testSpeechShowsTitleAuthorAndNoTime() {
        let info = PhoneNowPlayingInfo(title: "Dune", author: "Frank Herbert", isPlaying: true, details: .none)
        XCTAssertEqual(info.title, "Dune")
        XCTAssertEqual(info.artist, "Frank Herbert")
        XCTAssertEqual(info.rate, 1)
        XCTAssertEqual(info.defaultRate, 1)
        XCTAssertNil(info.elapsedTime, "any figure for speech would be an estimate")
        XCTAssertNil(info.duration)
    }

    func testAPausedBookHasRateZeroAndKeepsItsDefaultRate() {
        let info = PhoneNowPlayingInfo(
            title: "Dune", author: "Frank Herbert", isPlaying: false,
            details: audiobook(speed: 1.5, elapsed: 30, duration: 600)
        )
        XCTAssertEqual(info.rate, 0)
        XCTAssertEqual(info.defaultRate, 1.5)
    }

    func testAPlayingAudiobookShowsItsSpeedAndItsChaptersClock() {
        let info = PhoneNowPlayingInfo(
            title: "Dune", author: "Frank Herbert", isPlaying: true,
            details: audiobook(speed: 1.5, elapsed: 30, duration: 600)
        )
        XCTAssertEqual(info.rate, 1.5)
        XCTAssertEqual(info.defaultRate, 1.5)
        XCTAssertEqual(info.elapsedTime, 30)
        XCTAssertEqual(info.duration, 600)
    }

    func testTheElapsedTimeStaysWithinTheChapter() {
        let past = PhoneNowPlayingInfo(title: "T", author: "A", isPlaying: true, details: audiobook(speed: 1, elapsed: 700, duration: 600))
        XCTAssertEqual(past.elapsedTime, 600)
        let before = PhoneNowPlayingInfo(title: "T", author: "A", isPlaying: true, details: audiobook(speed: 1, elapsed: -4, duration: 600))
        XCTAssertEqual(before.elapsedTime, 0)
        let notANumber = PhoneNowPlayingInfo(title: "T", author: "A", isPlaying: true, details: audiobook(speed: 1, elapsed: .nan, duration: 600))
        XCTAssertEqual(notANumber.elapsedTime, 0)
    }

    func testAChapterWithNoLengthShowsNoClock() {
        for duration in [0, -1, TimeInterval.infinity, .nan] {
            let info = PhoneNowPlayingInfo(title: "T", author: "A", isPlaying: true, details: audiobook(speed: 1, elapsed: 3, duration: duration))
            XCTAssertNil(info.duration, "\(duration)")
            XCTAssertNil(info.elapsedTime, "\(duration)")
        }
    }

    func testASpeedThatIsNoPositiveNumberIsShownAsNormal() {
        for speed in [0, -1, Double.nan, .infinity] {
            let details = PhoneNowPlayingDetails(speed: speed, chapterTime: nil)
            let info = PhoneNowPlayingInfo(title: "T", author: "A", isPlaying: true, details: details)
            XCTAssertEqual(info.rate, 1, "\(speed): a playing book is never shown paused")
            XCTAssertEqual(info.defaultRate, 1, "\(speed)")
        }
    }

    func testAnEmptyAuthorSaysNothing() {
        let info = PhoneNowPlayingInfo(title: "Dune", author: "", isPlaying: true, details: .none)
        XCTAssertNil(info.artist)
        XCTAssertNil(info.systemDictionary[MPMediaItemPropertyArtist])
    }

    func testTheSystemsDictionaryUsesMediaPlayersKeys() {
        let info = PhoneNowPlayingInfo(
            title: "Dune", author: "Frank Herbert", isPlaying: true,
            details: audiobook(speed: 1.25, elapsed: 12, duration: 300)
        )
        let dictionary = info.systemDictionary
        XCTAssertEqual(dictionary[MPMediaItemPropertyTitle] as? String, "Dune")
        XCTAssertEqual(dictionary[MPMediaItemPropertyArtist] as? String, "Frank Herbert")
        XCTAssertEqual(dictionary[MPNowPlayingInfoPropertyMediaType] as? UInt, MPNowPlayingInfoMediaType.audio.rawValue)
        XCTAssertEqual(dictionary[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.25)
        XCTAssertEqual(dictionary[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1.25)
        XCTAssertEqual(dictionary[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 12)
        XCTAssertEqual(dictionary[MPMediaItemPropertyPlaybackDuration] as? Double, 300)
        XCTAssertNil(dictionary[MPMediaItemPropertyAlbumTitle], "the heading waits for a later version (F31)")
    }

    func testSpeechsDictionaryHasNoClock() {
        let dictionary = PhoneNowPlayingInfo(title: "Dune", author: "Frank Herbert", isPlaying: false, details: .none).systemDictionary
        XCTAssertNil(dictionary[MPNowPlayingInfoPropertyElapsedPlaybackTime])
        XCTAssertNil(dictionary[MPMediaItemPropertyPlaybackDuration])
        XCTAssertEqual(dictionary[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(dictionary[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1)
    }
}
