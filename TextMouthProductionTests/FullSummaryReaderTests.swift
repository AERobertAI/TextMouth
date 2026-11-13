import AVFoundation
import XCTest
@testable import TextMouth

/// Where Am I? and Where Am I? Full Summary in a reader (FR12's branch C,
/// section 3 of the design): each press with nothing announced, with the
/// brief summary speaking, and with the full one; the book paused for
/// either summary and resumed when it ends, W twice switching to the full
/// summary with the book still paused; the three-second rule retired
/// (question 4); and an announcement that ends with the book left paused,
/// by Play/Pause or by a cancel nobody asked for, settling the pause as a
/// pause does: the listening session ended, a minutes sleep timer's
/// countdown held, and an audiobook shown paused.
///
/// Each reader plays a silent audiobook, joins a Now Playing coordinator of
/// its own, and hands its announcements to a list in place of the
/// synthesizer; its sound effects are recorded, not played. Nothing is
/// heard. The test delivers the synthesizer's callbacks itself, and lets an
/// end sound's moment pass itself (`WhereAmIEndSoundClock`), never waiting.
@MainActor
final class FullSummaryReaderTests: XCTestCase {

    // MARK: - W and W Twice

    /// W twice: the first W pauses the book and speaks the brief summary
    /// after the start sound; the second switches to the full summary, with
    /// the book still paused and no second start sound; the brief summary's
    /// end, which the switch asked for, changes nothing; and the full
    /// summary's end plays the end sound and resumes the book.
    func testWTwiceSwitchesToTheFullSummaryWithTheBookStillPaused() throws {
        let book = try openPlayingAudiobook("Full Summary Switch")
        let reader = book.reader
        let content = try XCTUnwrap(reader.content)

        reader.whereAmI(.brief)
        let brief = try XCTUnwrap(book.announcements.utterances.last)
        XCTAssertEqual(brief.speechString, reader.buildBriefWhereAmI())
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "Where Am I did not pause the book")
        reader.whereAmI(.full)

        let full = try XCTUnwrap(book.announcements.utterances.last)
        XCTAssertEqual(book.announcements.utterances.count, 2)
        XCTAssertEqual(full.speechString, reader.buildFullWhereAmI(content: content))
        XCTAssertNotEqual(full.speechString, brief.speechString)
        XCTAssertTrue(reader.isWhereAmISpeaking)
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "the switch resumed the book")
        XCTAssertEqual(book.sounds.played, [.whereAmIStart], "the switch played a second start sound")

        deliver(cancelOf: brief, to: reader)
        deliver(finishOf: brief, to: reader)
        XCTAssertTrue(reader.isWhereAmISpeaking, "the brief summary's end ended the full one")
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "the brief summary's end resumed the book")

        deliver(finishOf: full, to: reader)
        XCTAssertFalse(reader.isWhereAmISpeaking)
        XCTAssertEqual(book.sounds.played, [.whereAmIStart, .whereAmIEnd])
        XCTAssertFalse(isPlaying(reader), "the book resumed before the end sound had played")
        book.endSound.passEndSound()
        XCTAssertTrue(isPlaying(reader), "the book did not resume after the full summary")
    }

    /// Where Am I? Full Summary with nothing announced pauses the book and
    /// speaks the full summary at once, after the start sound; pressed again
    /// while it speaks, it stops it and resumes the book.
    func testAFullPressWithNothingAnnouncedSpeaksTheFullSummary() throws {
        let book = try openPlayingAudiobook("Full Summary Alone")
        let reader = book.reader
        let content = try XCTUnwrap(reader.content)

        reader.whereAmI(.full)

        XCTAssertEqual(book.announcements.utterances.map(\.speechString), [reader.buildFullWhereAmI(content: content)])
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "Where Am I? Full Summary did not pause the book")
        XCTAssertEqual(book.sounds.played, [.whereAmIStart])

        reader.whereAmI(.full)

        XCTAssertFalse(reader.isWhereAmISpeaking, "a second full press did not stop the full summary")
        XCTAssertTrue(isPlaying(reader), "the stop did not resume the book")
        XCTAssertEqual(book.announcements.utterances.count, 1)
    }

    /// W while either summary speaks stops it and resumes the book at once,
    /// so a single press after the double-press time still silences a
    /// summary (question 3).
    func testWWhileEitherSummarySpeaksStopsItAndResumesTheBook() throws {
        let book = try openPlayingAudiobook("Full Summary Stopped")
        let reader = book.reader

        for first in [SummaryDetail.brief, .full] {
            reader.whereAmI(first)
            XCTAssertTrue(reader.isWhereAmISpeaking)

            reader.whereAmI(.brief)

            XCTAssertFalse(reader.isWhereAmISpeaking, "W did not stop the \(first) summary")
            XCTAssertTrue(isPlaying(reader), "W did not resume the book after the \(first) summary")
        }
        XCTAssertEqual(book.announcements.utterances.count, 2)
    }

    /// The three-second rule is retired (question 4): W just after an
    /// announcement ended speaks the brief summary again, never the full
    /// one unasked.
    func testWJustAfterAnAnnouncementSpeaksTheBriefSummaryAgain() throws {
        let book = try openPlayingAudiobook("Full Summary Rule Retired")
        let reader = book.reader
        reader.whereAmI()
        deliver(finishOf: try XCTUnwrap(book.announcements.utterances.last), to: reader)
        book.endSound.passEndSound()
        XCTAssertTrue(isPlaying(reader), "the book did not resume")

        reader.whereAmI()

        XCTAssertEqual(book.announcements.utterances.count, 2)
        let second = try XCTUnwrap(book.announcements.utterances.last?.speechString)
        XCTAssertEqual(second, reader.buildBriefWhereAmI())
        XCTAssertFalse(second.contains("Total book time"), second)
    }

    // MARK: - An Announcement That Ends With the Book Left Paused

    /// Play/Pause during an announcement ends it and leaves the book paused,
    /// as before, and now settles that pause as a pause does: the listening
    /// session ends, a minutes sleep timer's countdown waits for Play, the
    /// stop is recorded for rewind-on-resume, and the audiobook shows
    /// paused, so its Play/Pause button says Play. Play/Pause then resumes
    /// the book, its session, and the countdown.
    func testPlayPauseDuringAnAnnouncementSettlesThePause() throws {
        preserveSleepTimers()
        let book = try openPlayingAudiobook("Full Summary Play Pause")
        let reader = book.reader
        reader.startSleepTimer(duration: .minutes(10))
        reader.whereAmI(.full)
        XCTAssertTrue(reader.readingStatsService.hasActiveSession, "the announcement ended the session itself")
        assertCountdownRuns(reader.sleepTimerService, "the announcement held the countdown itself")
        let pressed = Date()

        reader.togglePlayPause()

        XCTAssertFalse(reader.isWhereAmISpeaking)
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "Play/Pause resumed the book")
        assertPauseIsSettled(in: reader, since: pressed)

        reader.togglePlayPause()

        XCTAssertTrue(isPlaying(reader), "Play/Pause did not resume the book")
        XCTAssertTrue(reader.isCurrentlyPlaying)
        XCTAssertFalse(reader.isCurrentlyPaused)
        XCTAssertTrue(reader.readingStatsService.hasActiveSession, "Play opened no listening session")
        assertCountdownRuns(reader.sleepTimerService, "Play did not restart the countdown")
    }

    /// A cancel nobody asked for, as when the speech engine refuses the
    /// announcement, settles the pause it leaves the same way.
    func testACancelNobodyAskedForSettlesThePauseToo() throws {
        preserveSleepTimers()
        let book = try openPlayingAudiobook("Full Summary Cancelled")
        let reader = book.reader
        reader.startSleepTimer(duration: .minutes(10))
        reader.whereAmI()
        let announcement = try XCTUnwrap(book.announcements.utterances.last)
        let cancelled = Date()

        deliver(cancelOf: announcement, to: reader)

        XCTAssertFalse(reader.isWhereAmISpeaking)
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "the book resumed after a cancel")
        assertPauseIsSettled(in: reader, since: cancelled)
    }

    /// An announcement that resumes the book, as W while it speaks does,
    /// leaves the session open, the countdown counting, and the audiobook
    /// shown playing, as before: only a pause left standing is settled.
    func testAnAnnouncementThatResumesTheBookLeavesItPlaying() throws {
        preserveSleepTimers()
        let book = try openPlayingAudiobook("Full Summary Resumed")
        let reader = book.reader
        reader.startSleepTimer(duration: .minutes(10))

        reader.whereAmI()
        reader.whereAmI()

        XCTAssertTrue(isPlaying(reader))
        XCTAssertTrue(reader.readingStatsService.hasActiveSession)
        assertCountdownRuns(reader.sleepTimerService, "a resumed book's countdown is held")
        XCTAssertTrue(reader.isCurrentlyPlaying)
        XCTAssertFalse(reader.isCurrentlyPaused)
    }

    // MARK: - The Toolbar's Where Am I? Button

    /// The toolbar's Where Am I? button names its VoiceOver action as the
    /// Playback menu names the command, "Where Am I? Full Summary", and the
    /// action asks for the full summary, since quick clicks no longer reach
    /// it (board #1593); VoiceOver calls the button by what a press does.
    func testTheToolbarButtonsFullSummaryActionAsksForTheFullSummary() {
        XCTAssertEqual(ReaderWhereAmIToolbarButton.fullSummaryActionName, "Where Am I? Full Summary")
        XCTAssertEqual(ReaderWhereAmIToolbarButton.title, "Where Am I?")
        XCTAssertEqual(ReaderWhereAmIToolbarButton.spokenLabel, "Where Am I? Announces current position in the book")
        XCTAssertEqual(ReaderWhereAmIToolbarButton.stopLabel, "Stop Where Am I announcement")
        var asked: [SummaryDetail] = []
        let button = ReaderWhereAmIToolbarButton(isSpeaking: false) { asked.append($0) }

        button.speakFullSummary()

        XCTAssertEqual(asked, [.full], "the action did not ask for the full summary")
    }

    /// Hosted, the button offers VoiceOver that action, and performing it
    /// asks for the full summary. SwiftUI builds the button's elements only
    /// for an assistive app, so without one this is skipped; the test above
    /// holds either way.
    func testTheToolbarButtonOffersTheFullSummaryToVoiceOver() throws {
        try skipUnlessSwiftUIExposesItsOwnElements()
        var asked: [SummaryDetail] = []
        let button = ReaderWhereAmIToolbarButton(isSpeaking: false) { asked.append($0) }
        let label = ReaderWhereAmIToolbarButton.spokenLabel
        try withHostedView(button, until: { !self.accessibilityElements(labelled: label, in: $0).isEmpty }) { hosting in
            guard let element = accessibilityElements(labelled: label, in: hosting).first else {
                throw XCTSkip("SwiftUI exposed no accessibility elements without an assistive app")
            }
            let actions = element.accessibilityCustomActions() ?? []
            XCTAssertEqual(actions.map(\.name), [ReaderWhereAmIToolbarButton.fullSummaryActionName])
            guard let action = actions.first else { return }
            // Performed as VoiceOver performs it: by its handler, or by its
            // target and selector.
            if let handler = action.handler {
                _ = handler()
            } else if let target = action.target, let selector = action.selector {
                _ = target.perform(selector, with: action)
            }
            XCTAssertEqual(asked, [.full], "the VoiceOver action did not ask for the full summary")
        }
    }

    // MARK: - Fixtures

    /// A reader playing a silent audiobook, with what it handed over.
    private struct PlayingBook {
        let reader: ReaderViewModel
        /// The sound effects the reader asked for.
        let sounds: RecordedSoundEffects
        /// The announcements the reader handed over in place of its
        /// Where Am I synthesizer.
        let announcements: HandedOverSummaries
        /// Holds what an announcement that ended by itself leaves for once
        /// its end sound has played, until the test lets the sound pass.
        let endSound: WhereAmIEndSoundClock
    }

    /// The utterances a reader's Where Am I handed over, oldest first.
    private final class HandedOverSummaries {
        var utterances: [AVSpeechUtterance] = []
    }

    /// Opens a reader of a silent audiobook in a world of its own, named
    /// after `label`, joined to a Now Playing coordinator of its own, its
    /// sound effects and announcements recorded and its announcements' end
    /// sound passed by the test, and plays it. The play sound is forgotten,
    /// so the sounds recorded are the ones Where Am I asked for.
    private func openPlayingAudiobook(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PlayingBook {
        let world = try makeIntegrationWorld(label)
        let book = try world.makeSilentAudioBook(title: "Harbour Soundings", trackDurations: [30])
        let reader = world.openReader(for: book, nowPlaying: NowPlayingService(installsSystemIntegrations: false))
        waitForReaderToLoad(reader, file: file, line: line)
        XCTAssertNil(reader.errorMessage, "The book did not open", file: file, line: line)
        let sounds = RecordedSoundEffects(preferences: makeSandboxedPreferences(label))
        reader.soundEffectService = sounds
        let announcements = HandedOverSummaries()
        reader._whereAmIUtteranceRecorderForTesting = { announcements.utterances.append($0) }

        reader.play()

        XCTAssertTrue(waitUntil(timeout: 5) { isPlaying(reader) }, "The book did not play", file: file, line: line)
        sounds.played.removeAll()
        return PlayingBook(
            reader: reader,
            sounds: sounds,
            announcements: announcements,
            endSound: WhereAmIEndSoundClock(holdingFor: reader)
        )
    }

    /// Asserts that `reader`'s pause, left by an announcement that ended
    /// at or after `moment`, is settled as a pause: no listening session
    /// open, the countdown held, the stop recorded, and the audiobook
    /// shown paused.
    private func assertPauseIsSettled(in reader: ReaderViewModel, since moment: Date, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(reader.readingStatsService.hasActiveSession, "the listening session stayed open", file: file, line: line)
        assertCountdownHolds(reader.sleepTimerService, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            reader.book.lastPlaybackStopped ?? .distantPast,
            moment,
            "the stop was not recorded for rewind-on-resume",
            file: file,
            line: line
        )
        XCTAssertTrue(reader.isCurrentlyPlaying, "the audiobook shows nothing loaded", file: file, line: line)
        XCTAssertTrue(reader.isCurrentlyPaused, "the audiobook still shows Playing", file: file, line: line)
    }

    /// Asserts that `timer`'s countdown is held: a tick takes nothing off.
    private func assertCountdownHolds(_ timer: SleepTimerService, file: StaticString = #filePath, line: UInt = #line) {
        let remaining = timer.remainingSeconds
        timer._advanceCountdownForTesting()
        XCTAssertEqual(timer.remainingSeconds, remaining, "the sleep timer's countdown kept counting", file: file, line: line)
    }

    /// Asserts that `timer`'s countdown counts: a tick takes a second off.
    private func assertCountdownRuns(_ timer: SleepTimerService, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let remaining = timer.remainingSeconds
        timer._advanceCountdownForTesting()
        XCTAssertEqual(timer.remainingSeconds, remaining - 1, message, file: file, line: line)
    }

    /// Tells `reader`'s Where Am I delegate, as the synthesizer does, that
    /// `utterance` was cancelled, and lets the main queue handle it.
    private func deliver(cancelOf utterance: AVSpeechUtterance, to reader: ReaderViewModel, file: StaticString = #filePath, line: UInt = #line) {
        guard let delegate = reader.whereAmIDelegate else {
            return XCTFail("Nothing hears the Where Am I synthesizer", file: file, line: line)
        }
        delegate.speechSynthesizer(AVSpeechSynthesizer(), didCancel: utterance)
        handleQueuedCallbacks(file: file, line: line)
    }

    /// Tells `reader`'s Where Am I delegate, as the synthesizer does, that
    /// `utterance` finished, and lets the main queue handle it.
    private func deliver(finishOf utterance: AVSpeechUtterance, to reader: ReaderViewModel, file: StaticString = #filePath, line: UInt = #line) {
        guard let delegate = reader.whereAmIDelegate else {
            return XCTFail("Nothing hears the Where Am I synthesizer", file: file, line: line)
        }
        delegate.speechSynthesizer(AVSpeechSynthesizer(), didFinish: utterance)
        handleQueuedCallbacks(file: file, line: line)
    }

    /// Whether `reader`'s audiobook plays: playing, not paused.
    private func isPlaying(_ reader: ReaderViewModel) -> Bool {
        reader.audioPlaybackService.isPlaying && !reader.audioPlaybackService.isPaused
    }
}
