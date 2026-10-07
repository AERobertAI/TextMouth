import AVFoundation
import CoreAudio
import XCTest
@testable import TextMouth

/// The system's media commands, from the AirPods, the media keys, or
/// Control Center, end to end through a real reader (report of 2026-10-04:
/// "My AirPods aren't controlling playback of the book").
///
/// Each test joins real readers to a real `NowPlayingService`, made as the
/// app makes its own but without system integrations, and delivers commands
/// exactly as MediaPlayer does: the coordinator accepts each one and
/// MediaPlayer hears the result at once (`acceptRemoteCommand(_:)`), then the
/// main queue runs the command's action, which the test runs in its place.
/// Each test checks what the listener hears (speech resumed where it paused,
/// at full volume; paused; moved back or forward) and what the app tells the
/// system: its Now Playing item, playing or paused but never stopped, which
/// decides where macOS sends the next press, and which reader owns media
/// controls.
///
/// Nothing is ever heard. A text book's chapter is longer than speech ever
/// renders (`SpeechRenderCoordinator.maximumTextLength`), so its speech is
/// always direct, and every direct utterance goes to a recorder in place of
/// the synthesizer; look-ahead renders are held. Audiobooks play silent
/// tracks. Announcements are recorded, not spoken.
@MainActor
final class MediaCommandPlaybackTests: XCTestCase {

    // MARK: - Pause and Play

    /// The AirPods pause speech and play it again from where it paused. The
    /// system is told the book is paused, not stopped, so macOS sends the
    /// next press to TextMouth as Play, and then that it plays again.
    func testPauseThenPlayResumesSpeechWhereItPaused() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Pause")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let speech = quay.reader.speechService

        quay.reader.play()
        reportWordSpoken(by: quay)
        assertSpeaks(quay, from: Self.openingOffset, "Play")
        assertToldSystem(system, that: quay.reader, plays: true, "Play")

        XCTAssertEqual(system.press(.pause), .success)
        handleQueuedCallbacks()
        XCTAssertTrue(speech.isPaused, "Pause did not pause speech")
        XCTAssertTrue(quay.reader.isCurrentlyPaused, "The reader does not show Paused")
        assertToldSystem(system, that: quay.reader, plays: false, "Pause")

        XCTAssertEqual(system.press(.play), .success)
        handleQueuedCallbacks()
        assertSpeaks(quay, from: Self.openingOffset, "Play after Pause")
        XCTAssertFalse(quay.reader.isCurrentlyPaused, "The reader still shows Paused")
        assertToldSystem(system, that: quay.reader, plays: true, "Play after Pause")
    }

    // MARK: - After the Sleep Timer

    /// A 15-minute sleep timer with a two-second fade runs out and pauses
    /// speech; Play from the AirPods then resumes it where the fade began,
    /// at full volume, and the system is told it plays again.
    func testPlayAfterTheSleepTimerFadesOutResumesAtFullVolume() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Sleep Timer")
        world.settings.sleepFadeOutDuration = 2
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        let recorder = recordingAnnouncements {
            expireFifteenMinuteTimerWithItsFade(in: quay, timer: timer)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [ReaderViewModel.sleepTimerExpiredAnnouncement])
        XCTAssertEqual(quay.reader.speechService.currentWordRange?.location, Self.openingOffset, "The fade lost the place")
        assertToldSystem(system, that: quay.reader, plays: false, "The timer's pause")

        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(quay, from: Self.openingOffset, "Play after the timer")
        assertToldSystem(system, that: quay.reader, plays: true, "Play after the timer")
    }

    /// After the sleep timer has paused speech, Previous Track from the
    /// AirPods moves the place back while speech stays paused, and Play then
    /// speaks from there at full volume.
    func testPreviousTrackAfterTheSleepTimerMovesBackAndPlayStartsThere() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Timer Skip")
        world.settings.sleepFadeOutDuration = 2
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let speech = quay.reader.speechService

        quay.reader.play()
        reportWordSpoken(by: quay)
        recordingAnnouncements {
            expireFifteenMinuteTimerWithItsFade(in: quay, timer: timer)
        }
        let handedOverBefore = quay.handedOver.utterances.count

        XCTAssertEqual(system.press(.previousTrack), .success)
        let movedTo = quay.reader.currentCharacterOffset
        XCTAssertLessThan(movedTo, Self.openingOffset, "Previous Track did not move back")
        XCTAssertGreaterThan(movedTo, Self.openingOffset - 2_000, "Previous Track moved too far")
        XCTAssertTrue(speech.isSpeaking && speech.isPaused, "Previous Track did not leave speech paused")
        XCTAssertEqual(quay.handedOver.utterances.count, handedOverBefore, "Previous Track spoke while paused")
        assertToldSystem(system, that: quay.reader, plays: false, "Previous Track while paused")

        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(quay, from: movedTo, "Play after Previous Track")
        assertToldSystem(system, that: quay.reader, plays: true, "Play after Previous Track")
    }

    // MARK: - Next and Previous Track While Playing

    /// Next Track and Previous Track from the AirPods skip speech forward
    /// and back while it plays, and the book plays on.
    func testTrackCommandsSkipSpeechForwardAndBackWhilePlaying() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Skips")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        assertTrackCommandsSkipForwardAndBack(quay, system: system)
    }

    /// The same with an End of heading sleep timer set: skips that stay in
    /// the heading move speech and keep the timer, also once the reader has
    /// checked, at its usual pace, whether playback left the heading.
    func testTrackCommandsSkipWithinTheHeadingOfAnEndOfHeadingTimer() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Heading Timer")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        quay.reader.startSleepTimer(duration: .endOfHeading)
        // Several of the reader's playback refreshes, each of which asks
        // whether playback has left the timer's heading.
        spinMainRunLoop(for: ReaderViewModel.playbackUIRefreshInterval * 4)
        XCTAssertTrue(quay.reader.speechService.isSpeaking, "The heading timer stopped speech inside its heading")

        assertTrackCommandsSkipForwardAndBack(quay, system: system)
        spinMainRunLoop(for: ReaderViewModel.playbackUIRefreshInterval * 4)
        XCTAssertTrue(timer.isActive, "A skip within the heading ended the timer")
        XCTAssertEqual(timer.duration, .endOfHeading)
        XCTAssertFalse(quay.reader.speechService.isPaused, "The heading timer paused speech inside its heading")
    }

    // MARK: - Play Waiting for the Chapter's Speech

    /// Play from the AirPods while the opened chapter's speech is still
    /// being prepared in the background waits for it, showing Playing; Pause
    /// then stops the wait, so the speech, once ready, is not spoken; and
    /// Play speaks it from the cursor.
    func testPauseAndPlayWhilePlayWaitsForTheChaptersSpeech() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Waiting Play")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let inputs = try XCTUnwrap(quay.reader.speechInputs(forChapterAt: 0))

        quay.reader.prepareOpenedChapterSpeech()
        XCTAssertEqual(system.press(.play), .success)
        XCTAssertTrue(quay.reader.isWaitingForChapterSpeech, "Play did not wait for the chapter's speech")
        XCTAssertTrue(quay.handedOver.utterances.isEmpty, "Play spoke before the speech was ready")
        assertToldSystem(system, that: quay.reader, plays: true, "Play while waiting")

        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertFalse(quay.reader.isWaitingForChapterSpeech, "Pause did not stop the wait")
        assertToldSystem(system, that: quay.reader, plays: false, "Pause while waiting")

        XCTAssertTrue(
            waitUntil(timeout: 10) { !quay.reader.chapterSpeechCache.isPreparingInBackground(inputs) },
            "The chapter's speech was never prepared"
        )
        handleQueuedCallbacks()
        XCTAssertTrue(quay.handedOver.utterances.isEmpty, "The paused play spoke once the speech was ready")
        XCTAssertFalse(quay.reader.speechService.isSpeaking, "The paused play started once the speech was ready")

        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(quay, from: Self.openingOffset, "Play once the speech was ready")
        assertToldSystem(system, that: quay.reader, plays: true, "Play once the speech was ready")
    }

    // MARK: - Continue to Next Book

    /// The book Continue to Next Book started takes the AirPods: Pause
    /// pauses it, and Play plays it again, while the finished book's reader
    /// stays open and silent.
    func testPauseAndPlayReachTheBookContinueToNextBookStarted() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Continue")
        let finishedBook = try world.makeSilentAudioBook(
            title: "First Crossing", trackDurations: [30], endOfBook: .continueNext
        )
        let nextBook = try world.makeSilentAudioBook(title: "Second Crossing", trackDurations: [30])
        let finished = world.openReader(for: finishedBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(finished)

        // The first book plays to its end and continues to the next one,
        // whose reader then opens, as its window does, and starts it.
        finished.play()
        XCTAssertTrue(finished.audioPlaybackService.isPlaying, "The first book did not play")
        finished.audioPlaybackService.stop()
        _ = recordingAnnouncements {
            finished.handleEndOfBook()
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        XCTAssertTrue(world.autoplayRequests.hasRequest(for: nextBook.id), "The next book was not asked for")
        let next = world.openReader(for: nextBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(next)
        let audio = next.audioPlaybackService
        XCTAssertTrue(audio.isPlaying && !audio.isPaused, "Continue to Next Book did not start the next book")
        assertToldSystem(system, that: next, plays: true, "The next book's start")

        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertTrue(audio.isPaused, "Pause did not pause the next book")
        assertToldSystem(system, that: next, plays: false, "Pause")

        XCTAssertEqual(system.press(.play), .success)
        XCTAssertTrue(audio.isPlaying && !audio.isPaused, "Play did not play the next book again")
        assertToldSystem(system, that: next, plays: true, "Play")
        XCTAssertFalse(finished.audioPlaybackService.isPlaying, "The finished book played again")
    }

    // MARK: - Two Windows, One Closed

    /// The listener opens another book's window and closes it again, while
    /// the first book plays. SwiftUI keeps the closed window's reader alive.
    /// The AirPods go on pausing and playing the first book.
    func testClosingAnotherWindowLeavesTheCommandsWithTheBookPlaying() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Other Window")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let slipway = openTextBook(titled: "Slipway Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        slipway.reader.nowPlayingService.focus()
        slipway.reader.close()

        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertTrue(quay.reader.speechService.isPaused, "Pause did not reach the playing book")
        assertToldSystem(system, that: quay.reader, plays: false, "Pause")

        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(quay, from: Self.openingOffset, "Play")
        assertToldSystem(system, that: quay.reader, plays: true, "Play")
        XCTAssertTrue(slipway.handedOver.utterances.isEmpty, "The closed window's book spoke")
    }

    /// The listener starts a second book in its own window, which pauses the
    /// first, and closes the first book's window. The AirPods pause and play
    /// the second book, and the closed window's book stays silent.
    func testClosingTheFormerBooksWindowLeavesTheCommandsWithTheBookNowPlaying() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Former Window")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let slipway = openTextBook(titled: "Slipway Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        slipway.reader.nowPlayingService.focus()
        slipway.reader.play()
        reportWordSpoken(by: slipway)
        XCTAssertTrue(quay.reader.speechService.isPaused, "Starting the second book did not pause the first")
        quay.reader.close()
        let quaySpoke = quay.handedOver.utterances.count

        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertTrue(slipway.reader.speechService.isPaused, "Pause did not reach the playing book")
        assertToldSystem(system, that: slipway.reader, plays: false, "Pause")

        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(slipway, from: Self.openingOffset, "Play")
        assertToldSystem(system, that: slipway.reader, plays: true, "Play")
        XCTAssertEqual(quay.handedOver.utterances.count, quaySpoke, "The closed window's book spoke")
    }

    /// The listener's book is paused, as a sleep timer leaves it, when
    /// another book's window, which never played, opens and closes again.
    /// The system goes on showing the paused book, never told that playback
    /// stopped, and Play from the AirPods resumes it.
    func testClosingAWindowThatNeverPlayedKeepsThePausedBookShown() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Idle Window")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let slipway = openTextBook(titled: "Slipway Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        quay.reader.pause()
        slipway.reader.nowPlayingService.focus()
        slipway.reader.close()
        assertToldSystem(system, that: quay.reader, plays: false, "Closing the idle window")

        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(quay, from: Self.openingOffset, "Play")
        assertToldSystem(system, that: quay.reader, plays: true, "Play")
    }

    // MARK: - Bluetooth

    /// The AirPods go back in their case while speech plays: CoreAudio
    /// reports the default output leaving the AirPods, which pauses speech
    /// and opens the window in which macOS's spurious Play is ignored. Play
    /// inside that window changes nothing; Play after it starts speech again
    /// from the place, on the current output.
    func testPlayInsideTheBluetoothWindowIsIgnoredAndAfterItResumes() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Bluetooth")
        world.settings.bluetoothMonitoringEnabled = true
        world.settings.bluetoothDisconnectDelay = 2
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        system.coordinator.refreshPreviousDeviceInfo()
        XCTAssertTrue(system.coordinator.previousDeviceWasBluetooth, "The AirPods are not the output")

        quay.reader.play()
        reportWordSpoken(by: quay)
        system.takeAirPodsOut()
        XCTAssertTrue(quay.reader.speechService.isPaused, "Taking the AirPods out did not pause speech")
        assertToldSystem(system, that: quay.reader, plays: false, "The AirPods out")
        let handedOverBefore = quay.handedOver.utterances.count

        system.advanceClock(by: 1)
        XCTAssertEqual(system.press(.play), .success)
        XCTAssertTrue(quay.reader.speechService.isPaused, "Play inside the window started speech")
        XCTAssertEqual(quay.handedOver.utterances.count, handedOverBefore, "Play inside the window spoke")
        assertToldSystem(system, that: quay.reader, plays: false, "Play inside the window")

        system.advanceClock(by: 2)
        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(quay, from: Self.openingOffset, "Play after the window")
        assertToldSystem(system, that: quay.reader, plays: true, "Play after the window")
    }

    // MARK: - Releasing Media Controls

    /// Only Release Media Controls tells the system that TextMouth stopped,
    /// handing the AirPods back to other apps; pausing never does.
    func testOnlyReleasingMediaControlsTellsTheSystemPlaybackStopped() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Release")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        system.press(.pause)
        system.press(.play)
        system.press(.pause)
        assertToldSystem(system, that: quay.reader, plays: false, "Pausing")

        _ = recordingAnnouncements {
            quay.reader.releaseMediaControls()
        }
        XCTAssertEqual(system.told.last, .some(nil), "Releasing media controls did not clear Now Playing")
        XCTAssertEqual(system.told.filter { $0 == nil }.count, 1, "Now Playing was cleared more than once")
        XCTAssertNil(system.coordinator.playingOwnerID)
    }

    // MARK: - After the Book Has Finished

    /// Report of 2026-10-07: "after a book 'finished' trying to use the
    /// rewind track on my AirPods didn't seem to work to hear the last
    /// little bit." An audiobook plays its last half second and finishes
    /// with the Stop behavior. Nothing is lost on the way to the reader: it
    /// keeps its media session, shown paused at the end rather than
    /// stopped, so macOS goes on sending the AirPods here; it is still the
    /// owner, and Previous Track is accepted and not dropped. The skip
    /// itself was what was lost: it moved the cursor back and left the
    /// stopped player silent, since a skip only played on when something
    /// was playing. Now Previous Track moves the cursor back by the skip
    /// unit from the end and plays from there, as a skip during playback
    /// plays on, and the system is told the book plays; the listener heard
    /// once that the book finished.
    func testPreviousTrackAfterAnAudiobookFinishesMovesBackFromTheEndAndPlays() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Audio")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let reader = ferry.reader
        assertToldSystem(system, that: reader, plays: false, "The book's end")

        let recorder = recordingAnnouncements {
            XCTAssertEqual(system.press(.previousTrack), .success)
        }
        assertPlaysAudio(reader, from: ferry.endOffset - Self.fifteenSecondsOfAudio, "Previous Track after the end")
        assertToldSystem(system, that: reader, plays: true, "Previous Track after the end")
        XCTAssertEqual(recorder.announcements, [], "Previous Track after the end announced something")
    }

    /// The same for a text book, through the Skip Backward command, which
    /// the media keys send and an AirPods gesture can be set to: the book's
    /// last words are spoken and speech finishes with the Stop behavior,
    /// and the reader keeps its media session, shown paused at the end.
    /// Skip Backward then moves the cursor back by the skip unit and
    /// speaks from there at full volume, as it does while playing, and the
    /// system is told the book plays. Before the repair the skip seeked the
    /// finished speech, which started direct speech again on its own,
    /// outside Play: the system went on showing the book paused, nothing
    /// counted the listening, and the reader showed Playing by accident.
    func testSkipBackwardAfterATextBookFinishesMovesBackFromTheEndAndSpeaks() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Text")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let end = finishSpeech(of: quay, in: system)

        let recorder = recordingAnnouncements {
            XCTAssertEqual(system.press(.skipBackward), .success)
        }
        let movedTo = quay.reader.currentCharacterOffset
        XCTAssertLessThan(movedTo, end, "Skip Backward did not move back")
        XCTAssertGreaterThan(movedTo, end - 2_000, "Skip Backward moved too far")
        assertSpeaks(quay, from: movedTo, "Skip Backward after the end")
        handleQueuedCallbacks()
        XCTAssertTrue(quay.reader.isCurrentlyPlaying, "The reader does not show Playing")
        assertToldSystem(system, that: quay.reader, plays: true, "Skip Backward after the end")
        XCTAssertEqual(recorder.announcements, [], "Skip Backward after the end announced something")
    }

    // MARK: - The System's Side

    /// The system's side of the media session as a test plays it: the
    /// coordinator the readers join, made as the app makes its own but
    /// without system integrations; the commands MediaPlayer delivered, whose
    /// actions wait for the main queue; everything the app told the system's
    /// Now Playing center; the clock commands are received by; and the
    /// audio outputs CoreAudio reports.
    @MainActor
    private final class MediaSystem {
        /// The AirPods, a Bluetooth output, and the Mac's own speakers.
        nonisolated static let airPods: AudioDeviceID = 41
        nonisolated static let speakers: AudioDeviceID = 73

        /// What the coordinator reaches through the providers it was made
        /// with; kept apart so they can be made before the coordinator.
        @MainActor
        private final class State {
            var now = Date(timeIntervalSince1970: 1_000)
            var defaultOutput: AudioDeviceID? = MediaSystem.airPods
            var outputs: [AudioDeviceID] = [MediaSystem.airPods, MediaSystem.speakers]
            var waitingActions: [@MainActor @Sendable () -> Void] = []
            var told: [NowPlayingItem?] = []
            var routeLog: [String] = []
        }

        private let state: State
        /// The coordinator the test's readers join.
        let coordinator: NowPlayingService

        init() {
            let state = State()
            self.state = state
            coordinator = NowPlayingService(
                installsSystemIntegrations: false,
                diagnosticSink: { state.routeLog.append($0) },
                now: { state.now },
                defaultOutputDevice: { state.defaultOutput },
                audioDeviceIDs: { state.outputs },
                isBluetoothDevice: { $0 == MediaSystem.airPods },
                scheduleRemoteCommandAction: { state.waitingActions.append($0) },
                systemNowPlaying: { state.told.append($0) }
            )
        }

        /// Everything the app told the system's Now Playing center, oldest
        /// first: an item shown, or nil where it cleared the center.
        var told: [NowPlayingItem?] { state.told }

        /// The routing diagnostics of commands accepted but then dropped.
        var droppedCommands: [String] {
            state.routeLog.filter { $0.contains("result=commandFailed") }
        }

        /// Deliver `request` as MediaPlayer does when the AirPods are
        /// pressed: the coordinator accepts it and MediaPlayer hears the
        /// result at once, then the main queue runs the command's action.
        ///
        /// - Returns: What MediaPlayer heard.
        @discardableResult
        func press(_ request: RemoteMediaCommandRequest) -> RemoteCommandDispatchResult {
            let heard = coordinator.acceptRemoteCommand(request)
            while !state.waitingActions.isEmpty {
                state.waitingActions.removeFirst()()
            }
            return heard
        }

        /// Move the clock commands are received by.
        func advanceClock(by seconds: TimeInterval) {
            state.now = state.now.addingTimeInterval(seconds)
        }

        /// The AirPods go back in their case: CoreAudio removes them and
        /// reports the default output changed to the Mac's speakers.
        func takeAirPodsOut() {
            state.defaultOutput = MediaSystem.speakers
            state.outputs = [MediaSystem.speakers]
            coordinator.handleDefaultOutputChange()
        }
    }

    // MARK: - A Text Book That Is Never Heard

    /// The utterances a reader's speech handed over in place of the
    /// synthesizer, oldest first.
    private final class HandedOverUtterances {
        var utterances: [AVSpeechUtterance] = []
    }

    /// A text book's reader, joined to a test's media system.
    private struct TextBookReader {
        let reader: ReaderViewModel
        /// The book's one chapter, which is also exactly what is spoken: no
        /// pauses, substitutions, or skipped sections change it.
        let text: String
        let handedOver: HandedOverUtterances
    }

    /// Where every text book opens: the start of the 200th mooring, well
    /// inside the Moorings heading and far from either end of the chapter.
    private static let openingOffset = ledgerText.utf16OffsetOfFirst("Mooring 200 ")

    /// The one chapter of every text book: the Moorings heading at its
    /// start and the Tides heading past its middle, in all longer than
    /// speech ever renders, so speech stays direct and never reaches the
    /// audio engine.
    private static let ledgerText: String = {
        var text = "Moorings\n\n"
        for entry in 1...1_400 {
            text += "Mooring \(entry) of the harbour ledger is checked. "
        }
        text += "\n\nTides\n\n"
        for entry in 1...1_200 {
            text += "Tide \(entry) of the harbour ledger is noted. "
        }
        return text
    }()

    /// The chapter of `ledgerText`, with its two headings.
    private static func ledgerChapter() -> Chapter {
        Chapter(
            title: "Harbour Ledger",
            text: ledgerText,
            headings: [
                Heading(level: 1, text: "Moorings"),
                Heading(level: 1, text: "Tides", characterOffset: ledgerText.utf16OffsetOfFirst("Tides\n")),
            ]
        )
    }

    /// Opens a reader of a text book titled `title` in `world`, joined to
    /// `system`, at `openingOffset` of its one chapter (`ledgerChapter()`).
    ///
    /// The reader's direct utterances go to a recorder before it can speak,
    /// and its look-ahead renders are held. The book names a file that is not
    /// there, so its own load fails before the chapter is given to it, and
    /// nothing is read from disk. Punctuation pauses are off, so the spoken
    /// text is the chapter's own.
    private func openTextBook(
        titled title: String,
        in world: IntegrationWorld,
        joining system: MediaSystem
    ) -> TextBookReader {
        XCTAssertGreaterThan(
            Self.ledgerText.utf16Length,
            SpeechRenderCoordinator.maximumTextLength,
            "The chapter is short enough to render, so speech could be heard"
        )
        world.settings.punctuationPauseLevel = 0
        let book = Book(
            title: title,
            author: "Harbour Office",
            format: .txt,
            filePath: world.folder.path + "/\(UUID().uuidString) missing.txt",
            md5Hash: UUID().uuidString,
            folderPath: world.folder.path,
            readingPosition: ReadingPosition(chapterIndex: 0, characterOffset: Self.openingOffset)
        )
        world.library.library.addBook(book)
        let reader = world.openReader(for: book, renderScheduler: HeldRenderQueue(), nowPlaying: system.coordinator)
        let handedOver = HandedOverUtterances()
        reader.speechService._directUtteranceRecorderForTesting = { handedOver.utterances.append($0) }
        waitForReaderToLoad(reader)
        reader.errorMessage = nil
        reader.content = DocumentContent(title: title, author: book.author, chapters: [Self.ledgerChapter()])
        return TextBookReader(reader: reader, text: Self.ledgerText, handedOver: handedOver)
    }

    /// Tell `book`'s speech, as the synthesizer does once it begins, that it
    /// speaks the first word of the utterance handed over last, and let the
    /// main queue handle it, so the place is where speech really is.
    private func reportWordSpoken(
        by book: TextBookReader,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let spoken = book.handedOver.utterances.last else {
            XCTFail("Nothing was handed to the synthesizer", file: file, line: line)
            return
        }
        let firstWord = (spoken.speechString as NSString).range(of: " ")
        book.reader.speechService.speechSynthesizer(
            AVSpeechSynthesizer(),
            willSpeakRangeOfSpeechString: NSRange(location: 0, length: max(1, firstWord.location)),
            utterance: spoken
        )
        handleQueuedCallbacks(file: file, line: line)
    }

    /// Set a 15-minute sleep timer in `book`'s reader and run it out on its
    /// own clock: one second left, then the next tick, then its fade, which
    /// the main run loop plays out in steps, as in the app.
    private func expireFifteenMinuteTimerWithItsFade(
        in book: TextBookReader,
        timer: SleepTimerService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        book.reader.startSleepTimer(duration: .minutes(15))
        XCTAssertEqual(timer.remainingSeconds, 15 * 60, file: file, line: line)
        timer.remainingSeconds = 1
        timer._advanceCountdownForTesting()
        XCTAssertTrue(timer.isFadingOut, "The timer did not begin its fade", file: file, line: line)
        let speech = book.reader.speechService
        XCTAssertTrue(
            waitUntil(timeout: 6) { !timer.isActive && speech.isPaused },
            "The timer never paused speech",
            file: file,
            line: line
        )
        handleQueuedCallbacks(file: file, line: line)
        XCTAssertTrue(book.handedOver.utterances.contains { $0.volume < 1 }, "Speech did not fade", file: file, line: line)
        XCTAssertTrue(speech.isSpeaking, "The timer stopped speech instead of pausing it", file: file, line: line)
    }

    /// Next Track then Previous Track from the AirPods while `book` plays:
    /// each moves speech, which goes on playing from the new place, and the
    /// system is told it plays. The presses come more than the skip
    /// debounce apart, as a listener's do.
    private func assertTrackCommandsSkipForwardAndBack(
        _ book: TextBookReader,
        system: MediaSystem,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reader = book.reader
        let before = reader.currentCharacterOffset

        reader.lastSkipTime = .distantPast
        XCTAssertEqual(system.press(.nextTrack), .success, file: file, line: line)
        let forward = reader.currentCharacterOffset
        XCTAssertGreaterThan(forward, before, "Next Track did not move forward", file: file, line: line)
        assertSpeaks(book, from: forward, "Next Track", file: file, line: line)
        assertToldSystem(system, that: reader, plays: true, "Next Track", file: file, line: line)

        reader.lastSkipTime = .distantPast
        XCTAssertEqual(system.press(.previousTrack), .success, file: file, line: line)
        let back = reader.currentCharacterOffset
        XCTAssertLessThan(back, forward, "Previous Track did not move back", file: file, line: line)
        assertSpeaks(book, from: back, "Previous Track", file: file, line: line)
        assertToldSystem(system, that: reader, plays: true, "Previous Track", file: file, line: line)
    }

    // MARK: - A Book That Has Finished

    /// Seconds of silence in the last track of every finished audiobook:
    /// long enough for a skip of either unit to land inside it.
    private static let lastTrackSeconds: TimeInterval = 30

    /// How far the 15-second skip moves an audiobook's cursor: ten
    /// characters stand for one second of audio.
    private static let fifteenSecondsOfAudio = Int(15 * ReaderViewModel.audioCharsPerSecond)

    /// An audiobook's reader, joined to a test's media system, whose book
    /// has just finished.
    private struct FinishedAudioBook {
        let reader: ReaderViewModel
        /// Where the cursor rests at the end: the last position the player
        /// reported, within the last second of the last track.
        let endOffset: Int
    }

    /// Opens a reader of a silent audiobook titled `title` in `world`,
    /// joined to `system`, half a second before the end of its last track,
    /// and plays it to its end, where it finishes with the Stop behavior:
    /// the listener hears once that the book finished, the reader shows
    /// nothing playing, and the system is told the book is paused, not
    /// stopped. The skip units are set to 15 seconds back and 30 forward,
    /// as the app's defaults are, so that a skip's landing is known.
    private func finishSilentAudioBook(
        titled title: String,
        in world: IntegrationWorld,
        joining system: MediaSystem,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> FinishedAudioBook {
        world.settings.skipBackwardUnit = .seconds15
        world.settings.skipForwardUnit = .seconds30
        let lastHalfSecond = Int((Self.lastTrackSeconds - 0.5) * ReaderViewModel.audioCharsPerSecond)
        let book = try world.makeSilentAudioBook(
            title: title,
            trackDurations: [1, Self.lastTrackSeconds],
            savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: lastHalfSecond),
            endOfBook: .stop
        )
        let reader = world.openReader(for: book, nowPlaying: system.coordinator)
        waitForReaderToLoad(reader, file: file, line: line)
        let audio = reader.audioPlaybackService
        let recorder = recordingAnnouncements {
            reader.play()
            XCTAssertTrue(audio.isPlaying, "\(title) did not play", file: file, line: line)
            XCTAssertTrue(
                eventually(within: 10) { !reader.isCurrentlyPlaying && !audio.isPlaying },
                "\(title) never finished",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(recorder.announcements.map(\.message), ["Finished: \(title)"], file: file, line: line)
        XCTAssertEqual(reader.currentChapterIndex, 1, "The cursor left the last chapter", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            reader.currentCharacterOffset, lastHalfSecond, "The cursor is not at the end", file: file, line: line
        )
        return FinishedAudioBook(reader: reader, endOffset: reader.currentCharacterOffset)
    }

    /// Where the text book's last words begin: inside the last chunk direct
    /// speech speaks, which ends where the chapter does.
    private static let lastWordsOffset = ledgerText.utf16Length - 400

    /// Speaks `book`'s last words and finishes its speech, as the
    /// synthesizer reports the end of the utterance handed over, so that
    /// the book finishes with the Stop behavior: the listener hears once
    /// that it finished, the reader shows nothing playing, and the system
    /// is told the book is paused, not stopped.
    ///
    /// - Returns: Where the cursor rests at the end: the last word speech
    ///   reported.
    private func finishSpeech(
        of book: TextBookReader,
        in system: MediaSystem,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        let reader = book.reader
        reader.navigateTo(chapterIndex: 0, characterOffset: Self.lastWordsOffset)
        let recorder = recordingAnnouncements {
            reader.play()
            reportWordSpoken(by: book, file: file, line: line)
            guard let spoken = book.handedOver.utterances.last else {
                XCTFail("Nothing was handed to the synthesizer", file: file, line: line)
                return
            }
            reader.speechService.speechSynthesizer(AVSpeechSynthesizer(), didFinish: spoken)
            handleQueuedCallbacks(file: file, line: line)
        }
        XCTAssertEqual(
            recorder.announcements.map(\.message), ["Finished: \(reader.book.title)"], file: file, line: line
        )
        XCTAssertFalse(reader.speechService.isSpeaking, "Speech did not finish", file: file, line: line)
        XCTAssertTrue(
            waitUntil(timeout: 2) { !reader.isCurrentlyPlaying },
            "The reader still shows Playing",
            file: file,
            line: line
        )
        assertToldSystem(system, that: reader, plays: false, "The book's end", file: file, line: line)
        return reader.currentCharacterOffset
    }

    // MARK: - Checks

    /// Check that `book`'s speech plays from `offset` of its chapter at full
    /// volume: speaking, not paused, and the utterance handed over last is
    /// the first chunk direct speech speaks from there.
    private func assertSpeaks(
        _ book: TextBookReader,
        from offset: Int,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let speech = book.reader.speechService
        XCTAssertTrue(speech.isSpeaking, "\(context): speech is not playing", file: file, line: line)
        XCTAssertFalse(speech.isPaused, "\(context): speech is paused", file: file, line: line)
        let expected = DirectSpeechChunk.starting(
            at: offset,
            in: book.text,
            maximumLength: SpeechService.directModeFirstChunkSize
        ).words(of: book.text)
        let spoken = book.handedOver.utterances.last
        XCTAssertEqual(
            spoken?.speechString.prefix(60),
            expected.prefix(60),
            "\(context): speech does not start at the place",
            file: file,
            line: line
        )
        XCTAssertEqual(spoken?.volume, 1, "\(context): speech is not at full volume", file: file, line: line)
    }

    /// Check that `reader`'s audio plays from `offset` of its last chapter:
    /// the player playing, not paused, the reader showing Playing, and the
    /// cursor and the player within a second of the place.
    private func assertPlaysAudio(
        _ reader: ReaderViewModel,
        from offset: Int,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let audio = reader.audioPlaybackService
        XCTAssertTrue(audio.isPlaying && !audio.isPaused, "\(context): the audio is not playing", file: file, line: line)
        XCTAssertTrue(
            reader.isCurrentlyPlaying && !reader.isCurrentlyPaused,
            "\(context): the reader does not show Playing",
            file: file,
            line: line
        )
        XCTAssertEqual(reader.currentChapterIndex, 1, "\(context): the cursor left the last chapter", file: file, line: line)
        XCTAssertLessThanOrEqual(
            abs(reader.currentCharacterOffset - offset),
            Int(ReaderViewModel.audioCharsPerSecond),
            "\(context): the cursor is not at the place",
            file: file,
            line: line
        )
        let seconds = Double(offset) / ReaderViewModel.audioCharsPerSecond
        XCTAssertTrue(
            eventually(within: 2) { abs(audio.currentTime - seconds) <= 1.5 },
            "\(context): the audio does not play from the place",
            file: file,
            line: line
        )
    }

    /// Check what the system was last told: `reader`'s book, playing or
    /// paused as `playing` says, never that playback stopped; that
    /// `reader` owns media controls, as the playing reader when it plays;
    /// and that no command was dropped after it was accepted.
    private func assertToldSystem(
        _ system: MediaSystem,
        that reader: ReaderViewModel,
        plays playing: Bool,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let shown = NowPlayingItem(title: reader.book.title, author: reader.book.author, isPlaying: playing)
        XCTAssertEqual(system.told.last, .some(shown), "\(context): the system was told otherwise", file: file, line: line)
        XCTAssertFalse(system.told.contains(nil), "\(context): the system was told playback stopped", file: file, line: line)
        let owner = reader.nowPlayingService.ownerID
        XCTAssertEqual(system.coordinator.activeOwnerID, owner, "\(context): another reader owns media controls", file: file, line: line)
        XCTAssertEqual(
            system.coordinator.playingOwnerID,
            playing ? owner : nil,
            "\(context): the playing owner is wrong",
            file: file,
            line: line
        )
        XCTAssertEqual(system.droppedCommands, [], "\(context): a command was dropped", file: file, line: line)
    }

    /// Returns once the main queue has run every block queued on it so far,
    /// such as the reader's mirrors of the speech service's state and the
    /// synthesizer's callbacks.
    private func handleQueuedCallbacks(file: StaticString = #filePath, line: UInt = #line) {
        var handled = false
        DispatchQueue.main.async { handled = true }
        XCTAssertTrue(waitUntil(timeout: 5) { handled }, "The main queue never ran", file: file, line: line)
    }
}

private extension String {
    /// The UTF-16 offset where `fragment` first occurs; 0 when it does not.
    func utf16OffsetOfFirst(_ fragment: String) -> Int {
        let found = (self as NSString).range(of: fragment)
        return found.location == NSNotFound ? 0 : found.location
    }
}
