import XCTest
@testable import TextMouth

/// When direct speech counts as silent while the synthesizer says it speaks,
/// and that a voice that reports no words, or few, is never taken for silent.
final class PhoneAudioWordWatchdogTests: XCTestCase {
    /// The playback watchdog's tick, as `SpeechService.directWatchdogInterval`.
    private let interval: TimeInterval = 0.5

    /// A watchdog that has heard `voice` report word by word in this play.
    private func watchingWordByWord(voice: String? = "v") -> PhoneAudioWordWatchdog {
        var watchdog = PhoneAudioWordWatchdog(tickInterval: interval)
        watchdog.playStarted()
        for _ in 0...PhoneAudioWordWatchdog.wordByWordReportsNeeded {
            watchdog.wordReported(voiceIdentifier: voice)
        }
        return watchdog
    }

    /// Ticks the watchdog `count` times while speech should be heard, and
    /// says which ticks (1-based) asked for a recovery.
    private func tick(_ watchdog: inout PhoneAudioWordWatchdog, _ count: Int, voice: String? = "v", wpm: Double = 200) -> [Int] {
        (1...count).filter { _ in watchdog.tick(isExpectedToSpeak: true, voiceIdentifier: voice, wordsPerMinute: wpm) }
    }

    func testSilenceForTheLimitAsksForOneRecovery() {
        var watchdog = watchingWordByWord()
        let ticksToLimit = Int(PhoneAudioWordWatchdog.shortestSilenceLimit / interval)
        XCTAssertEqual(tick(&watchdog, ticksToLimit), [ticksToLimit])
        XCTAssertEqual(watchdog.silentTicks, 0, "the count starts again after a recovery")
    }

    func testAWordStartsTheSilenceAgain() {
        var watchdog = watchingWordByWord()
        let ticksToLimit = Int(PhoneAudioWordWatchdog.shortestSilenceLimit / interval)
        XCTAssertEqual(tick(&watchdog, ticksToLimit - 1), [])
        watchdog.wordReported(voiceIdentifier: "v")
        XCTAssertEqual(tick(&watchdog, ticksToLimit - 1), [])
    }

    /// F19: a voice that reports no words would otherwise look silent at
    /// every tick.
    func testNothingIsWatchedBeforeThisPlaysFirstWord() {
        var watchdog = watchingWordByWord()
        watchdog.playStarted()
        XCTAssertEqual(tick(&watchdog, 200), [], "no word yet in this play")
        watchdog.wordReported(voiceIdentifier: "v")
        XCTAssertEqual(tick(&watchdog, 16), [16])
    }

    func testAVoiceThatReportsNoWordsIsNeverWatched() {
        var watchdog = PhoneAudioWordWatchdog(tickInterval: interval)
        watchdog.playStarted()
        XCTAssertEqual(tick(&watchdog, 400), [])
    }

    func testAVoiceThatReportsASentenceAtATimeIsNeverWatched() {
        var watchdog = PhoneAudioWordWatchdog(tickInterval: interval)
        watchdog.playStarted()
        // A report every six seconds, as a sentence at a time comes.
        for _ in 0..<10 {
            XCTAssertEqual(tick(&watchdog, 12), [])
            watchdog.wordReported(voiceIdentifier: "v")
        }
        XCTAssertEqual(tick(&watchdog, 100), [])
    }

    func testAnotherVoiceMustShowItReportsWordByWord() {
        var watchdog = watchingWordByWord(voice: "first")
        watchdog.wordReported(voiceIdentifier: "second")
        XCTAssertEqual(tick(&watchdog, 100, voice: "second"), [], "one report of the new voice isn't enough")
    }

    func testTheSystemsDefaultVoiceIsAVoiceLikeAnyOther() {
        var watchdog = watchingWordByWord(voice: nil)
        XCTAssertEqual(tick(&watchdog, 16, voice: nil), [16])
    }

    func testAnythingButSpeechExpectedStartsTheCountAgain() {
        var watchdog = watchingWordByWord()
        XCTAssertEqual(tick(&watchdog, 15), [])
        XCTAssertFalse(watchdog.tick(isExpectedToSpeak: false, voiceIdentifier: "v", wordsPerMinute: 200))
        XCTAssertEqual(watchdog.silentTicks, 0)
        XCTAssertEqual(tick(&watchdog, 15), [], "paused, interrupted, or on rendered audio, nothing counts")
    }

    func testAnUtteranceStartingStartsTheSilenceAgain() {
        var watchdog = watchingWordByWord()
        XCTAssertEqual(tick(&watchdog, 15), [])
        watchdog.utteranceStarted()
        XCTAssertEqual(tick(&watchdog, 15), [])
    }

    func testSlowSpeechWaitsLonger() {
        XCTAssertEqual(PhoneAudioWordWatchdog.silenceLimit(wordsPerMinute: 200), PhoneAudioWordWatchdog.shortestSilenceLimit)
        XCTAssertEqual(PhoneAudioWordWatchdog.silenceLimit(wordsPerMinute: 50), 12, accuracy: 0.001)
        XCTAssertEqual(PhoneAudioWordWatchdog.silenceLimit(wordsPerMinute: 0), PhoneAudioWordWatchdog.shortestSilenceLimit)
        var watchdog = watchingWordByWord()
        XCTAssertEqual(tick(&watchdog, 24, wpm: 50), [24])
    }
}
