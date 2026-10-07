import AVFoundation
import XCTest
@testable import TextMouth

/// A synthesizer that records what it is told and plays nothing, standing
/// in for the app's in every test of Speak Info.
final class InfoSynthesizerRecorder: LibraryInfoSynthesizing {
    var delegate: (any AVSpeechSynthesizerDelegate)?
    /// Every utterance it was told to speak, in order.
    private(set) var utterances: [AVSpeechUtterance] = []
    /// How many times it was told to stop.
    private(set) var stops = 0

    func speak(_ utterance: AVSpeechUtterance) {
        utterances.append(utterance)
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stops += 1
        return true
    }

    /// The texts it was told to speak, in order.
    var spoken: [String] {
        utterances.map(\.speechString)
    }
}

/// Speak Info's speaker (October 7, 2026): the brief summary on the first
/// press, the full one on a quick second press, a stop on a press while it
/// speaks, with the app's own voice and speed, through a recorder, so no
/// test plays sound.
@MainActor
final class LibraryInfoSpeakerTests: XCTestCase {

    // MARK: - Fixtures

    /// A moment presses are timed from.
    private let start = Date(timeIntervalSince1970: 1_791_000_000)

    /// A folder's facts, whose summaries differ between brief and full.
    private let classics = LibraryInfoSubject.folder(
        FolderInfoFacts(name: "Classics", bookCount: 2, unopenedCount: 1, feedCount: 0, subfolderCount: 1, timeRemaining: 120)
    )

    /// A speaker speaking through a recorder.
    private func makeSpeaker() -> (speaker: LibraryInfoSpeaker, recorder: InfoSynthesizerRecorder) {
        let recorder = InfoSynthesizerRecorder()
        return (LibraryInfoSpeaker(synthesizer: recorder), recorder)
    }

    // MARK: - Pressing

    /// The first press speaks the brief summary with the chosen voice at the
    /// chosen speed, never VoiceOver's, and the speaker knows it speaks.
    func testTheFirstPressSpeaksTheBriefSummaryWithTheChosenVoiceAndSpeed() throws {
        let (speaker, recorder) = makeSpeaker()
        let voice = AVSpeechSynthesisVoice.speechVoices().first
        var asked: [Bool] = []

        let text = speaker.press(voice: voice, wordsPerMinute: 250, now: start) { full in
            asked.append(full)
            return classics
        }

        XCTAssertEqual(text, LibraryInfoWording.brief(classics))
        XCTAssertEqual(text, "Classics. Folder. 2 books, 1 unopened.")
        XCTAssertEqual(recorder.spoken, [text])
        XCTAssertEqual(asked, [false])
        XCTAssertTrue(speaker.isSpeaking)
        XCTAssertEqual(speaker.lastSpokenText, text)
        let utterance = try XCTUnwrap(recorder.utterances.first)
        XCTAssertEqual(utterance.rate, SpeechService.rateForWPM(250))
        XCTAssertFalse(utterance.prefersAssistiveTechnologySettings)
        XCTAssertEqual(utterance.voice?.identifier, voice?.identifier)
        XCTAssertNotNil(recorder.delegate, "nothing tells the speaker when the announcement ends")
    }

    /// A second press within three seconds of the first speaks the full
    /// summary, and a press three seconds or more after the last one that
    /// started an announcement is brief again, at the boundary Where Am I
    /// keeps.
    func testASecondPressWithinThreeSecondsSpeaksTheFullSummary() {
        let (speaker, recorder) = makeSpeaker()
        var asked: [Bool] = []
        func press(after seconds: TimeInterval) -> String? {
            speaker.press(voice: nil, wordsPerMinute: 200, now: start.addingTimeInterval(seconds)) { full in
                asked.append(full)
                return classics
            }
        }

        XCTAssertEqual(press(after: 0), LibraryInfoWording.brief(classics))
        speaker.announcementFinished()
        XCTAssertFalse(speaker.isSpeaking)
        let full = press(after: 2)
        XCTAssertEqual(full, LibraryInfoWording.full(classics, now: start.addingTimeInterval(2)))
        XCTAssertEqual(full, "Classics. Folder. 2 books, 1 unopened. 1 subfolder. 2 minutes remaining in total.")
        speaker.announcementFinished()
        // Three seconds after the press that started the full summary.
        XCTAssertEqual(press(after: 5), LibraryInfoWording.brief(classics))
        XCTAssertEqual(asked, [false, true, false])
        XCTAssertEqual(recorder.spoken.count, 3)
    }

    /// A press while an announcement speaks stops it, speaks nothing, and
    /// asks for no subject; a stop while nothing speaks does nothing.
    func testAPressWhileSpeakingStopsTheAnnouncement() {
        let (speaker, recorder) = makeSpeaker()
        speaker.stop()
        XCTAssertEqual(recorder.stops, 0)

        speaker.press(voice: nil, wordsPerMinute: 200, now: start) { _ in classics }
        let stopsBefore = recorder.stops
        var asked = 0
        let text = speaker.press(voice: nil, wordsPerMinute: 200, now: start.addingTimeInterval(1)) { _ in
            asked += 1
            return classics
        }

        XCTAssertNil(text)
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(speaker.isSpeaking)
        XCTAssertEqual(recorder.stops, stopsBefore + 1)
        XCTAssertEqual(recorder.spoken.count, 1)
    }

    /// The escalation window counts from the press that started the brief
    /// summary, as Where Am I's does: a quick third press after a stop
    /// speaks the full summary, and a later one the brief.
    func testAQuickThirdPressAfterAStopSpeaksTheFullSummary() {
        let (speaker, _) = makeSpeaker()
        func press(after seconds: TimeInterval) -> String? {
            speaker.press(voice: nil, wordsPerMinute: 200, now: start.addingTimeInterval(seconds)) { _ in classics }
        }

        XCTAssertEqual(press(after: 0), LibraryInfoWording.brief(classics))
        XCTAssertNil(press(after: 1), "the second press should have stopped the announcement")
        XCTAssertEqual(press(after: 2), LibraryInfoWording.full(classics, now: start.addingTimeInterval(2)))
        XCTAssertNil(press(after: 2.5))
        XCTAssertEqual(press(after: 6), LibraryInfoWording.brief(classics))
    }

    /// With nothing selected, every press says so, the quick second one
    /// included.
    func testNothingSelectedIsSaidOnEveryPress() {
        let (speaker, recorder) = makeSpeaker()

        XCTAssertEqual(speaker.press(voice: nil, wordsPerMinute: 200, now: start) { _ in nil }, "Nothing is selected.")
        speaker.announcementFinished()
        XCTAssertEqual(speaker.press(voice: nil, wordsPerMinute: 200, now: start.addingTimeInterval(1)) { _ in nil }, "Nothing is selected.")
        XCTAssertEqual(recorder.spoken, ["Nothing is selected.", "Nothing is selected."])
    }

    /// The synthesizer's delegate ends the announcement on the main queue,
    /// so the next press speaks instead of stopping.
    func testTheSynthesizersDelegateEndsTheAnnouncement() throws {
        let (speaker, recorder) = makeSpeaker()
        speaker.press(voice: nil, wordsPerMinute: 200, now: start) { _ in classics }
        let utterance = try XCTUnwrap(recorder.utterances.first)
        let delegate = try XCTUnwrap(recorder.delegate)

        // The app's delegate helper is told as the synthesizer tells it, by
        // a synthesizer that speaks nothing here.
        delegate.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)
        let ended = waitUntil(timeout: 2) { !speaker.isSpeaking }

        XCTAssertTrue(ended, "the announcement never ended")
        XCTAssertEqual(speaker.press(voice: nil, wordsPerMinute: 200, now: start.addingTimeInterval(10)) { _ in classics }, LibraryInfoWording.brief(classics))
    }

    // MARK: - Shared With Where Am I

    /// The escalation interval is Where Am I's, and the text of a press is
    /// the wording's.
    func testTheEscalationIntervalAndTextAreSharedWithWhereAmI() {
        XCTAssertEqual(LibraryInfoSpeaker.escalationInterval, ReaderViewModel.whereAmIEscalationInterval)
        XCTAssertEqual(LibraryInfoSpeaker.escalationInterval, 3)
        XCTAssertEqual(LibraryInfoSpeaker.text(for: nil, full: true, now: start), LibraryInfoWording.nothingSelected)
        XCTAssertEqual(LibraryInfoSpeaker.text(for: classics, full: false, now: start), LibraryInfoWording.brief(classics))
        XCTAssertEqual(LibraryInfoSpeaker.text(for: classics, full: true, now: start), LibraryInfoWording.full(classics, now: start))
    }

    /// The app's own synthesizer is what a speaker made without one speaks
    /// through; made here, it speaks nothing.
    func testTheAppsSynthesizerIsTheDefault() {
        let synthesizer = LibraryInfoSpeaker.makeSynthesizer()
        XCTAssertTrue(synthesizer is AVSpeechSynthesizer)
        XCTAssertNil(synthesizer.delegate)
    }
}
