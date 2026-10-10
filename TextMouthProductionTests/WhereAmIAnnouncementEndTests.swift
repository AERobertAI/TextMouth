import AVFoundation
import XCTest
@testable import TextMouth

/// How a reader's Where Am I announcement ends, as its synthesizer reports
/// it (finding #1296).
///
/// An announcement that finishes plays the end sound and resumes the book
/// it paused. One the reader stops, by a press while it speaks, is handled
/// where it was stopped, once, whatever the synthesizer reports afterwards.
/// One the system cancels on its own, as the speech engine does with a text
/// it refuses, ends without the end sound or the resume, leaving the book
/// paused for Play/Pause, and its synthesizer, which would never speak
/// again, is replaced.
///
/// Each reader plays a silent audiobook, joins a Now Playing coordinator of
/// its own, and hands its announcements to a recorder in place of the
/// synthesizer; its sound effects are recorded, not played. Nothing is ever
/// heard. The test delivers the synthesizer's callbacks itself, and lets an
/// end sound's moment pass itself (`WhereAmIEndSoundClock`), never waiting.
@MainActor
final class WhereAmIAnnouncementEndTests: XCTestCase {

    // MARK: - A Cancel Nobody Asked For

    /// An announcement the system cancels ends at once: Where Am I no
    /// longer speaks, its synthesizer is a fresh one, no end sound plays,
    /// and the book stays paused even after the end sound's moment. Play/Pause
    /// then resumes the book, and the next Where Am I speaks through the
    /// fresh synthesizer, which hears how it ends.
    func testAnAnnouncementTheSystemCancelsEndsWithoutTheEndSoundOrTheResume() throws {
        let harbour = try openPlayingAudiobook("Where Am I Cancelled")
        let reader = harbour.reader
        let announcement = try pressWhereAmI(in: harbour)
        let cancelledSynthesizer = reader.whereAmISynth

        deliver(cancelOf: announcement, to: reader)

        XCTAssertFalse(reader.isWhereAmISpeaking, "Where Am I still speaks")
        XCTAssertFalse(reader.whereAmISynth === cancelledSynthesizer, "The cancelled synthesizer is still in use")
        XCTAssertFalse(harbour.endSound.hasWorkWaiting, "A resume waits for an end sound")
        XCTAssertEqual(harbour.sounds.played, [.whereAmIStart], "An end sound played")
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "The book resumed after a cancel")

        reader.togglePlayPause()

        XCTAssertTrue(isPlaying(reader), "Play/Pause did not resume the book")
        _ = try pressWhereAmI(in: harbour)
        XCTAssertTrue(reader.whereAmISynth.delegate === reader.whereAmIDelegate, "Nothing hears the fresh synthesizer")
    }

    // MARK: - A Cancel the Reader Asked For

    /// A press of Where Am I while it speaks stops it and resumes the book
    /// at once, as before. The cancel its synthesizer then reports for the
    /// stopped announcement changes nothing more: the synthesizer stays, and
    /// the book plays on.
    func testAnAnnouncementStoppedByAPressIsHandledOnce() throws {
        let harbour = try openPlayingAudiobook("Where Am I Stopped")
        let reader = harbour.reader
        let announcement = try pressWhereAmI(in: harbour)
        let synthesizer = reader.whereAmISynth

        reader.whereAmI()

        XCTAssertFalse(reader.isWhereAmISpeaking, "The press did not stop the announcement")
        XCTAssertTrue(isPlaying(reader), "The press did not resume the book")

        deliver(cancelOf: announcement, to: reader)

        XCTAssertTrue(reader.whereAmISynth === synthesizer, "A cancel the reader asked for replaced the synthesizer")
        XCTAssertTrue(isPlaying(reader), "A cancel the reader asked for paused the book")
        XCTAssertEqual(harbour.sounds.played, [.whereAmIStart])
    }

    // MARK: - A Finish

    /// An announcement that finishes plays the end sound and then resumes
    /// the book it paused. The finish of an announcement stopped before it
    /// is ignored, so it can neither end the one speaking after it nor play
    /// a second end sound.
    func testAFinishEndsOnlyTheAnnouncementSpeaking() throws {
        let harbour = try openPlayingAudiobook("Where Am I Finished")
        let reader = harbour.reader
        let stopped = try pressWhereAmI(in: harbour)
        reader.whereAmI()
        let speaking = try pressWhereAmI(in: harbour)

        deliver(finishOf: stopped, to: reader)

        XCTAssertTrue(reader.isWhereAmISpeaking, "The stopped announcement's finish ended the one speaking")
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "The stopped announcement's finish resumed the book")

        deliver(finishOf: speaking, to: reader)

        XCTAssertFalse(reader.isWhereAmISpeaking)
        XCTAssertEqual(harbour.sounds.played, [.whereAmIStart, .whereAmIStart, .whereAmIEnd])
        XCTAssertFalse(isPlaying(reader), "The book resumed before the end sound had played")
        harbour.endSound.passEndSound()
        XCTAssertTrue(isPlaying(reader), "The book did not resume after the announcement")
    }

    // MARK: - The Full Summary in the Brief One's Place

    /// W twice, the full summary taking the place of the brief one still
    /// speaking, speaks it on a fresh synthesizer, the one saying the brief
    /// summary silenced and let go with its delegate, so nothing it reports
    /// reaches the reader: the full summary cannot be cancelled with the
    /// brief one and taken for a cancel nobody asked for, which would end it
    /// at once with the book left paused. Its own end resumes the book, with
    /// one start sound and one end sound.
    func testTheFullSummarySpeaksOnAFreshSynthesizer() throws {
        let harbour = try openPlayingAudiobook("Where Am I Full Summary Synthesizer")
        let reader = harbour.reader
        _ = try pressWhereAmI(in: harbour)
        let briefSynthesizer = reader.whereAmISynth

        reader.whereAmI(.full)

        XCTAssertTrue(reader.isWhereAmISpeaking, "the full summary does not speak")
        XCTAssertEqual(reader.whereAmIDetail, .full)
        XCTAssertFalse(reader.whereAmISynth === briefSynthesizer, "the full summary spoke on the brief one's synthesizer")
        XCTAssertNil(briefSynthesizer.delegate, "the brief summary's synthesizer still reports to the reader")
        XCTAssertTrue(reader.whereAmISynth.delegate === reader.whereAmIDelegate, "nothing hears the fresh synthesizer")
        let full = try XCTUnwrap(harbour.announcements.utterances.last)

        deliver(finishOf: full, to: reader)
        harbour.endSound.passEndSound()

        XCTAssertTrue(isPlaying(reader), "the book did not resume after the full summary")
        XCTAssertEqual(harbour.sounds.played, [.whereAmIStart, .whereAmIEnd])
    }

    // MARK: - Fixtures

    /// A reader playing a silent audiobook, with what it handed over.
    private struct PlayingBook {
        let reader: ReaderViewModel
        /// The sound effects the reader asked for.
        let sounds: RecordedSoundEffects
        /// The announcements the reader handed over in place of its
        /// Where Am I synthesizer.
        let announcements: HandedOverAnnouncements
        /// Holds what an announcement that ended by itself leaves for once
        /// its end sound has played, until the test lets the sound pass.
        let endSound: WhereAmIEndSoundClock
    }

    /// The utterances a reader's Where Am I handed over, oldest first.
    private final class HandedOverAnnouncements {
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
        let announcements = HandedOverAnnouncements()
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

    /// Presses Where Am I in `book`'s reader while nothing is announced,
    /// which pauses the book and hands the announcement over, and returns
    /// the announcement.
    private func pressWhereAmI(
        in book: PlayingBook,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AVSpeechUtterance {
        let before = book.announcements.utterances.count
        book.reader.whereAmI()
        XCTAssertTrue(book.reader.isWhereAmISpeaking, "Where Am I does not speak", file: file, line: line)
        XCTAssertTrue(book.reader.audioPlaybackService.isPaused, "Where Am I did not pause the book", file: file, line: line)
        let handedOver = book.announcements.utterances
        return try XCTUnwrap(
            handedOver.count > before ? handedOver.last : nil,
            "No announcement was handed over",
            file: file,
            line: line
        )
    }

    /// Tells `reader`'s Where Am I delegate, as the synthesizer does, that
    /// `utterance` was cancelled, and lets the main queue handle it.
    private func deliver(
        cancelOf utterance: AVSpeechUtterance,
        to reader: ReaderViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let delegate = reader.whereAmIDelegate else {
            XCTFail("Nothing hears the Where Am I synthesizer", file: file, line: line)
            return
        }
        delegate.speechSynthesizer(AVSpeechSynthesizer(), didCancel: utterance)
        handleQueuedCallbacks(file: file, line: line)
    }

    /// Tells `reader`'s Where Am I delegate, as the synthesizer does, that
    /// `utterance` finished, and lets the main queue handle it.
    private func deliver(
        finishOf utterance: AVSpeechUtterance,
        to reader: ReaderViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let delegate = reader.whereAmIDelegate else {
            XCTFail("Nothing hears the Where Am I synthesizer", file: file, line: line)
            return
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
