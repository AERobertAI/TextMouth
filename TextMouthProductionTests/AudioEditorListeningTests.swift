import AppKit
import XCTest
@testable import TextMouth

/// Listening and moving in the audio editor (FR04), on generated audio
/// through the real edit session, with a player that makes no sound:
/// play, pause, and stop; steps of a second, ten, and a tenth, which stop
/// at either end; the half second played after a move, as the setting
/// says; Go to Time, and what it says of a time it can't go to; chapter
/// markers; the pauses the level search finds, each a phrase apart; Where
/// Am I; and the shortcuts reaching the right window's editor.
@MainActor
final class AudioEditorListeningTests: XCTestCase {

    // MARK: - Playing

    /// Play starts at the cursor and the cursor follows the audio; Pause
    /// keeps the place and says it; Stop goes back to where playing began.
    func testPlayPauseAndStop() async throws {
        let harness = try await openRamp(seconds: 10, playsAfterMoves: true)
        let model = harness.model
        model.move(to: 2)

        model.togglePlay()
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(harness.player.plays.last, .init(from: 2, until: nil))
        harness.player.tick(to: 3.5)
        XCTAssertEqual(model.cursor, 3.5)
        XCTAssertEqual(model.statusSentence, "Playing; 3.5 seconds of 10 seconds")

        model.togglePlay()
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.cursor, 3.5)
        XCTAssertEqual(harness.announcements.sentences.last, "Paused at 3.5 seconds.")

        model.togglePlay()
        harness.player.tick(to: 6)
        model.stop()
        XCTAssertEqual(model.cursor, 3.5)
        XCTAssertEqual(harness.announcements.sentences.last, "Stopped. Back at 3.5 seconds.")
        XCTAssertFalse(model.canPerform(.editorStop))
        model.stop()
        XCTAssertEqual(harness.announcements.sentences.last, "Nothing is playing.")
    }

    /// Playing to the end says so and leaves the cursor there; Play at the
    /// end starts again from the start.
    func testPlayingToTheEndAndPlayingAgain() async throws {
        let harness = try await openRamp(seconds: 4, playsAfterMoves: true)
        let model = harness.model
        model.togglePlay()
        harness.player.finishPlaying(at: 4)

        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.cursor, 4)
        XCTAssertEqual(harness.announcements.sentences.last, "End of the audio.")

        model.togglePlay()
        XCTAssertEqual(harness.player.plays.last, .init(from: 0, until: nil))
        XCTAssertEqual(model.cursor, 0)
        XCTAssertEqual(harness.announcements.sentences.last, "Playing from the start.")
    }

    // MARK: - Moving

    /// The steps move a second, ten, and a tenth, either way, and stop at
    /// the start and the end, saying so; Go to Start and Go to End say
    /// where they landed.
    func testStepsMoveAndStopAtEitherEnd() async throws {
        let harness = try await openRamp(seconds: 12)
        let model = harness.model

        model.perform(.editorSkipForwardLong)
        XCTAssertEqual(model.cursor, 10)
        model.perform(.editorSkipForward)
        XCTAssertEqual(model.cursor, 11)
        model.perform(.editorSkipForwardShort)
        XCTAssertEqual(model.cursor, 11.1, accuracy: 0.000_1)
        model.perform(.editorSkipForwardLong)
        XCTAssertEqual(model.cursor, 12)
        model.perform(.editorSkipForward)
        XCTAssertEqual(harness.announcements.sentences.last, "Already at the end.")
        model.perform(.editorSkipBackShort)
        XCTAssertEqual(model.cursor, 11.9, accuracy: 0.000_1)
        model.perform(.editorSkipBack)
        model.perform(.editorSkipBackLong)
        XCTAssertEqual(model.cursor, 0.9, accuracy: 0.000_1)
        model.perform(.editorSkipBackLong)
        XCTAssertEqual(model.cursor, 0)
        model.perform(.editorSkipBack)
        XCTAssertEqual(harness.announcements.sentences.last, "Already at the start.")

        model.perform(.editorGoToEnd)
        XCTAssertEqual(model.cursor, 12)
        XCTAssertEqual(harness.announcements.sentences.last, "End of the audio, at 12 seconds.")
        model.perform(.editorGoToStart)
        XCTAssertEqual(model.cursor, 0)
        XCTAssertEqual(harness.announcements.sentences.last, "Start of the audio.")
        XCTAssertTrue(harness.player.plays.isEmpty, "a move played with the setting off")
    }

    /// With the setting on, every move plays half a second at the cursor,
    /// which stays put; none plays at the very end. While listening, a
    /// move carries the audio on from the new place.
    func testAMovePlaysHalfASecondThereAsTheSettingSays() async throws {
        let harness = try await openRamp(seconds: 6, playsAfterMoves: true)
        let model = harness.model
        XCTAssertTrue(model.scrubsAfterMoves, "the setting is on until turned off")

        model.perform(.editorSkipForward)
        XCTAssertEqual(harness.player.plays.last, .init(from: 1, until: 1.5))
        harness.player.tick(to: 1.4)
        XCTAssertEqual(model.cursor, 1, "a scrub moved the cursor")
        harness.player.finishPlaying(at: 1.5)
        XCTAssertEqual(model.cursor, 1)
        XCTAssertFalse(model.isPlaying)

        model.perform(.editorGoToEnd)
        XCTAssertEqual(harness.player.plays.count, 1, "a scrub played at the very end")

        model.perform(.editorGoToStart)
        model.togglePlay()
        harness.player.tick(to: 2)
        model.perform(.editorSkipForward)
        XCTAssertEqual(harness.player.plays.last, .init(from: 3, until: nil))
        XCTAssertTrue(model.isPlaying)
    }

    /// Go to Time takes a time as people write it and says where it went;
    /// anything else keeps the sheet open with what's wrong, which
    /// VoiceOver hears too.
    func testGoToTimeTakesATimeOrSaysWhatsWrong() async throws {
        let harness = try await openRamp(seconds: 90)
        let model = harness.model
        model.perform(.editorGoToTime)
        XCTAssertEqual(model.prompt, .goToTime)
        XCTAssertEqual(model.initialText(for: .goToTime), "0:00")

        XCTAssertEqual(model.answer(.goToTime, with: "1:31"), "That's after the end of the audio, at 1 minute, 30 seconds.")
        XCTAssertEqual(harness.announcements.sentences.last, "That's after the end of the audio, at 1 minute, 30 seconds.")
        XCTAssertEqual(model.prompt, .goToTime)
        XCTAssertEqual(model.answer(.goToTime, with: "soon"), TimeEntry.howToType)

        XCTAssertNil(model.answer(.goToTime, with: "1:04.5"))
        XCTAssertNil(model.prompt)
        XCTAssertEqual(model.cursor, 64.5)
        XCTAssertEqual(harness.announcements.sentences.last, "1 minute, 4.5 seconds")
    }

    // How a typed time is read is `TimeEntry`'s, shared with the reader's
    // Go to Time, and tested in TimeEntryTests.

    // MARK: - Chapters

    /// The chapter commands move from marker to marker and say which; the
    /// previous one goes to the start of the chapter the cursor is in
    /// first; past the last and before the first they say so.
    func testChapterMarkersAreVisitedInTurn() async throws {
        let harness = try await openRamp(seconds: 30)
        let model = harness.model
        model.perform(.editorNextChapter)
        XCTAssertEqual(harness.announcements.sentences.last, "This audio has no chapter markers.")

        try await model.session.perform(.setChapter(at: 0, title: "Quay"))
        try await model.session.perform(.setChapter(at: 10, title: "Locks"))
        try await model.session.perform(.setChapter(at: 20, title: "Weir"))

        model.perform(.editorNextChapter)
        XCTAssertEqual(model.cursor, 10)
        XCTAssertEqual(harness.announcements.sentences.last, "Chapter 2: Locks, at 10 seconds.")
        model.perform(.editorNextChapter)
        model.perform(.editorNextChapter)
        XCTAssertEqual(harness.announcements.sentences.last, "No chapter marker after the cursor.")
        XCTAssertEqual(model.statusSentence, "20 seconds of 30 seconds; in chapter 3: Weir")

        model.move(to: 14)
        model.perform(.editorPreviousChapter)
        XCTAssertEqual(model.cursor, 10)
        model.perform(.editorPreviousChapter)
        XCTAssertEqual(model.cursor, 0)
        model.perform(.editorPreviousChapter)
        XCTAssertEqual(harness.announcements.sentences.last, "No chapter marker before the cursor.")
    }

    // MARK: - Pauses

    /// The level search finds the pauses in generated speech-like sound,
    /// each where it is, to the hundredth; Next and Previous Pause move to
    /// where the sound after each begins, saying how long it lasted.
    func testPausesAreFoundAndVisitedPhraseByPhrase() async throws {
        let fixture = try AudioEditorTestBook.make(named: "Phrases.wav", for: self) { url in
            try AudioTestFixtures.writeTones([
                .init(seconds: 1, frequency: 440, amplitude: 0.3),
                .silence(0.8),
                .init(seconds: 1, frequency: 330, amplitude: 0.3),
                .silence(0.25),
                .init(seconds: 1, frequency: 550, amplitude: 0.3),
                .silence(0.6),
                .init(seconds: 0.5, frequency: 440, amplitude: 0.3),
            ], to: url, sampleRate: AudioEditorTestBook.rate)
        }
        let harness = try await EditorHarness.open(fixture, for: self)
        AudioEditorPreferences.playAfterMoves.write(false, to: harness.store)
        let model = harness.model
        defer { model.windowClosed() }
        model.perform(.editorNextPause)
        XCTAssertEqual(harness.announcements.sentences.last, AudioEditorWording.findingPauses)

        await model.loadPreview()
        let found = await eventually(timeout: 10) { model.pauseSearch == .found }
        XCTAssertTrue(found, "the pauses were never found: \(model.pauseSearch)")

        // The quarter-second gap is a breath, not a pause.
        XCTAssertEqual(model.pauses.count, 2)
        XCTAssertEqual(model.pauses.first?.start ?? -1, 1, accuracy: 0.011)
        XCTAssertEqual(model.pauses.first?.end ?? -1, 1.8, accuracy: 0.011)
        XCTAssertEqual(model.pauses.last?.start ?? -1, 4.05, accuracy: 0.011)
        XCTAssertEqual(model.pauses.last?.end ?? -1, 4.65, accuracy: 0.011)

        model.perform(.editorNextPause)
        XCTAssertEqual(model.cursor, 1.8, accuracy: 0.011)
        XCTAssertEqual(harness.announcements.sentences.last, "After a pause of 0.8 seconds, at 1.8 seconds.")
        model.perform(.editorNextPause)
        XCTAssertEqual(model.cursor, 4.65, accuracy: 0.011)
        model.perform(.editorNextPause)
        XCTAssertEqual(harness.announcements.sentences.last, "No pause after the cursor.")
        model.perform(.editorPreviousPause)
        XCTAssertEqual(model.cursor, 1.8, accuracy: 0.011)
        model.perform(.editorPreviousPause)
        XCTAssertEqual(harness.announcements.sentences.last, "No pause before the cursor.")
    }

    /// The pause threshold follows the recording's own background: 15 dB
    /// above its quietest tenth, kept between -60 and -30 dBFS.
    func testThePauseThresholdFollowsTheBackground() {
        let quietRoom = AudioEditorLevels(decibels: Array(repeating: -70, count: 20) + Array(repeating: -12, count: 80), duration: 1)
        XCTAssertEqual(quietRoom.pauseThreshold, -55)
        let digitalSilence = AudioEditorLevels(decibels: Array(repeating: AudioEditorLevels.silence, count: 20) + Array(repeating: -12, count: 80), duration: 1)
        XCTAssertEqual(digitalSilence.pauseThreshold, -60)
        let noisyRoom = AudioEditorLevels(decibels: Array(repeating: -40, count: 20) + Array(repeating: -10, count: 80), duration: 1)
        XCTAssertEqual(noisyRoom.pauseThreshold, -30)
        XCTAssertEqual(AudioEditorLevels(decibels: [], duration: 0).pauses(), [])
        XCTAssertEqual(noisyRoom.envelope(5), [-40, -10, -10, -10, -10])
        XCTAssertEqual(noisyRoom.envelope(0), [])
    }

    // MARK: - Where Am I and Shortcuts

    /// Where Am I says the status line.
    func testWhereAmISaysTheStatusLine() async throws {
        let harness = try await openRamp(seconds: 8)
        harness.model.move(to: 2.5)
        harness.model.perform(.editorWhereAmI)
        XCTAssertEqual(harness.announcements.sentences.last, "2.5 seconds of 8 seconds")
    }

    /// A shortcut pressed in an editor's window reaches that editor alone.
    func testAShortcutReachesTheEditorOfItsWindowAlone() async throws {
        let first = try await openRamp(seconds: 5)
        let second = try await openRamp(seconds: 5)
        let firstWindow = makeWindow()
        first.model.hostWindow = firstWindow
        second.model.hostWindow = makeWindow()

        NotificationCenter.default.post(name: .audioEditorShortcut, object: nil, userInfo: [
            "action": ShortcutAction.editorGoToEnd.rawValue,
            "sourceWindow": firstWindow,
        ])

        let moved = await eventually { first.model.cursor == 5 }
        XCTAssertTrue(moved, "the shortcut never reached its window's editor")
        XCTAssertEqual(second.model.cursor, 0)
    }

    // MARK: - Helpers

    /// A window that is never shown, standing for an editor's.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
}
