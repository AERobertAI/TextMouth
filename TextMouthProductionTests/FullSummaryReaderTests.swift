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
/// heard. The test delivers the synthesizer's callbacks itself.
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
        XCTAssertTrue(
            waitUntil(timeout: ReaderViewModel.whereAmIEndSoundDelay + 5) { isPlaying(reader) },
            "the book did not resume after the full summary"
        )
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
        XCTAssertTrue(waitUntil(timeout: ReaderViewModel.whereAmIEndSoundDelay + 5) { isPlaying(reader) }, "the book did not resume")

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
        preserveSharedSleepTimer()
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
        preserveSharedSleepTimer()
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
        preserveSharedSleepTimer()
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

    // MARK: - Fixtures

    /// A reader playing a silent audiobook, with what it handed over.
    private struct PlayingBook {
        let reader: ReaderViewModel
        /// The sound effects the reader asked for.
        let sounds: RecordedSoundEffects
        /// The announcements the reader handed over in place of its
        /// Where Am I synthesizer.
        let announcements: HandedOverSummaries
    }

    /// The utterances a reader's Where Am I handed over, oldest first.
    private final class HandedOverSummaries {
        var utterances: [AVSpeechUtterance] = []
    }

    /// Opens a reader of a silent audiobook in a world of its own, named
    /// after `label`, joined to a Now Playing coordinator of its own, its
    /// sound effects and announcements recorded, and plays it. The play
    /// sound is forgotten, so the sounds recorded are the ones Where Am I
    /// asked for.
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
        return PlayingBook(reader: reader, sounds: sounds, announcements: announcements)
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

    /// Returns once the main queue has run every block queued on it so far,
    /// such as the delegate's report of how an announcement ended.
    private func handleQueuedCallbacks(file: StaticString = #filePath, line: UInt = #line) {
        var handled = false
        DispatchQueue.main.async { handled = true }
        XCTAssertTrue(waitUntil(timeout: 5) { handled }, "The main queue never ran", file: file, line: line)
    }
}
