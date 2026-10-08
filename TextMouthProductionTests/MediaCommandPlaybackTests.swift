import AVFoundation
import Combine
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

    /// A book that finishes with Continue to Next Book hands the AirPods
    /// over to the next book as it says "Starting: <title>" (REV07, speech
    /// finding 5): it rests finished no longer. The AirPods' rewind in the
    /// moment before the next book is asked for moves its cursor back and
    /// plays nothing; once the next book plays, the finished book's window
    /// offers no Release Media Controls, and its keyboard Skip Backward
    /// moves its cursor only, leaving the next book playing and holding the
    /// controls. Before the repair the rewind played the finished book's
    /// end until the next book's start paused it, and the keyboard's skip
    /// played the finished book again and paused the next.
    func testABookThatContinuedToTheNextLeavesTheAirPodsToIt() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Continue Hand-over")
        world.settings.skipBackwardUnit = .seconds15
        // Forty seconds into a minute: each 15-second skip back lands
        // exactly, well inside the track.
        let finishedBook = try world.makeSilentAudioBook(
            title: "First Crossing",
            trackDurations: [60],
            savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: 400),
            endOfBook: .continueNext
        )
        let nextBook = try world.makeSilentAudioBook(title: "Second Crossing", trackDurations: [30])
        let finished = world.openReader(for: finishedBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(finished)
        let audio = finished.audioPlaybackService

        // The first book plays, and ends with the hand-over. The main run
        // loop has not turned since, so the next book is not asked for yet.
        finished.play()
        XCTAssertTrue(audio.isPlaying, "The first book did not play")
        audio.stop()
        let ending = recordingAnnouncements {
            finished.handleEndOfBook()
        }
        XCTAssertEqual(ending.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertFalse(finished.hasFinishedBook, "The book that continued still rests finished at its end")
        XCTAssertFalse(world.autoplayRequests.hasRequest(for: nextBook.id), "The next book was asked for at once")

        // The AirPods' rewind in that moment only moves the cursor back.
        let atTheRewind = finished.currentCharacterOffset
        let rewinding = recordingAnnouncements {
            XCTAssertEqual(system.press(.previousTrack), .success)
        }
        XCTAssertFalse(audio.isPlaying, "The rewind played the book that continued")
        XCTAssertFalse(finished.isCurrentlyPlaying, "The book that continued shows Playing after the rewind")
        XCTAssertEqual(
            finished.currentCharacterOffset,
            atTheRewind - Self.fifteenSecondsOfAudio,
            "The rewind did not move the cursor back by the skip unit"
        )
        XCTAssertEqual(rewinding.announcements, [], "The rewind announced something")

        // The next book's window opens for the request and starts it.
        XCTAssertTrue(
            eventually { world.autoplayRequests.hasRequest(for: nextBook.id) },
            "The next book was never asked for"
        )
        let next = world.openReader(for: nextBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(next)
        let nextAudio = next.audioPlaybackService
        XCTAssertTrue(nextAudio.isPlaying && !nextAudio.isPaused, "Continue to Next Book did not start the next book")
        assertToldSystem(system, that: next, plays: true, "The next book's start")

        // Back in the finished book's window, which becomes key.
        finished.windowBecameKey()
        XCTAssertFalse(finished.canReleaseMediaControls, "Release Media Controls is offered for the book that continued")
        let atTheKeyboardSkip = finished.currentCharacterOffset
        finished.lastSkipTime = .distantPast
        let skipping = recordingAnnouncements {
            finished.skipBackward()
        }
        XCTAssertFalse(audio.isPlaying, "The keyboard's Skip Backward played the book that continued")
        XCTAssertEqual(
            finished.currentCharacterOffset,
            atTheKeyboardSkip - Self.fifteenSecondsOfAudio,
            "The keyboard's Skip Backward did not move the cursor back by the skip unit"
        )
        XCTAssertTrue(nextAudio.isPlaying && !nextAudio.isPaused, "The keyboard's Skip Backward paused the next book")
        assertToldSystem(system, that: next, plays: true, "The keyboard's Skip Backward in the finished book's window")
        XCTAssertEqual(skipping.announcements, [], "The keyboard's Skip Backward announced something")
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

    // MARK: - After the Speech Engine Refuses the Text

    /// The Mac's speech engine refuses the text where speech goes on, on
    /// the fresh synthesizer too, and speech stops there (#1308). The reader
    /// makes the stop its own, as a pause: the book's listening session
    /// ends, so no time away is credited as listening; the system is told
    /// the book is paused, never stopped, so the AirPods stay with TextMouth
    /// and their next press is Play; and the place where speech stopped and
    /// the stop itself are saved. Play then speaks on from that place.
    func testARefusedTextStopsAsAPauseAndPlaySpeaksOnFromThere() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Refusal")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let reader = quay.reader
        let statistics = ReadingStatsService.shared

        reader.play()
        XCTAssertTrue(statistics.hasActiveSession, "Play opened no listening session")
        assertToldSystem(system, that: reader, plays: true, "Play")
        var refusedAt = 0
        let recorder = recordingAnnouncements {
            refusedAt = refuseTheChunkAfterTheFirst(of: quay)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [SpeechService.engineRefusedAnnouncement])
        XCTAssertFalse(reader.speechService.isSpeaking, "Speech did not stop")
        XCTAssertEqual(reader.currentCharacterOffset, refusedAt, "The cursor is not where speech stopped")
        XCTAssertFalse(statistics.hasActiveSession, "The listening session stayed open")
        assertToldSystem(system, that: reader, plays: false, "The refusal")
        let row = try XCTUnwrap(world.library.bookByID(reader.book.id))
        XCTAssertEqual(row.readingPosition?.characterOffset, refusedAt, "The place where speech stopped was not saved")
        XCTAssertNotNil(row.lastPlaybackStopped, "The stop was not recorded")

        XCTAssertEqual(system.press(.play), .success)
        handleQueuedCallbacks()
        assertSpeaks(quay, from: refusedAt, "Play after the refusal")
        assertToldSystem(system, that: reader, plays: true, "Play after the refusal")
        XCTAssertTrue(statistics.hasActiveSession, "Play after the refusal opened no listening session")
    }

    /// A 15-minute sleep timer's countdown halts where the speech engine's
    /// refusal stopped speech, as it halts at a pause, so it cannot run out
    /// while nothing plays; Play resumes it.
    func testARefusedTextHaltsTheSleepTimersCountdownUntilPlay() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Refusal Timer")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)

        quay.reader.play()
        quay.reader.startSleepTimer(duration: .minutes(15))
        let atTheRefusal = logLines(in: .sleepTimer) {
            _ = recordingAnnouncements {
                _ = refuseTheChunkAfterTheFirst(of: quay)
            }
        }

        XCTAssertTrue(timer.isActive, "The refusal ended the timer")
        XCTAssertTrue(atTheRefusal.contains { $0.contains("COUNTDOWN_PAUSED") }, "\(atTheRefusal)")
        let atPlay = logLines(in: .sleepTimer) {
            XCTAssertEqual(system.press(.play), .success)
        }
        XCTAssertTrue(atPlay.contains { $0.contains("COUNTDOWN_RESUMED") }, "\(atPlay)")
        XCTAssertTrue(quay.reader.speechService.isSpeaking, "Play did not speak")
    }

    /// Where the speech engine's refusal stopped speech, the book is shown
    /// paused and holds the media controls, so Release Media Controls is
    /// offered, as it is for a paused book, and hands them back: the system
    /// is told once that playback stopped, and VoiceOver hears so. Before,
    /// it was not offered until Play, though the book held the controls.
    func testReleaseMediaControlsIsOfferedWhereARefusalStoppedSpeech() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Refusal Release")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let reader = quay.reader

        reader.play()
        recordingAnnouncements {
            refuseTheChunkAfterTheFirst(of: quay)
        }
        XCTAssertFalse(reader.speechService.isSpeaking, "Speech did not stop")
        assertToldSystem(system, that: reader, plays: false, "The refusal")
        XCTAssertTrue(reader.canReleaseMediaControls, "Release Media Controls is not offered where the refusal stopped speech")

        let releasing = recordingAnnouncements {
            reader.releaseMediaControls()
        }
        XCTAssertEqual(releasing.announcements.map(\.message), ["Media controls released"])
        XCTAssertEqual(system.told.last, .some(nil), "Releasing media controls did not clear Now Playing")
        XCTAssertEqual(system.told.filter { $0 == nil }.count, 1, "Now Playing was cleared more than once")
        XCTAssertNil(system.coordinator.playingOwnerID)
        XCTAssertFalse(reader.canReleaseMediaControls, "Release Media Controls is offered again")
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

    /// After an audiobook has finished, Next Track at the end stays at the
    /// end, plays nothing, and announces nothing more, and Pause changes
    /// nothing either; the keyboard's Skip Backward then moves the cursor
    /// back by the skip unit from the end and plays, as the AirPods' rewind
    /// does. The keyboard's shortcut, the playback bar's button, and the
    /// AirPods all reach `skipBackward()`.
    func testNextTrackAndPauseAtTheEndChangeNothingAndTheKeyboardsSkipBackwardPlays() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Keyboard Audio")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let reader = ferry.reader
        let audio = reader.audioPlaybackService
        let chapterEnd = try XCTUnwrap(reader.content?.chapters.last?.text.utf16Length)

        let recorder = recordingAnnouncements {
            XCTAssertEqual(system.press(.nextTrack), .success)
            XCTAssertFalse(audio.isPlaying, "Next Track at the end played")
            XCTAssertEqual(reader.currentChapterIndex, 1, "Next Track at the end left the last chapter")
            XCTAssertEqual(reader.currentCharacterOffset, chapterEnd - 1, "Next Track at the end did not stay at the end")
            assertToldSystem(system, that: reader, plays: false, "Next Track at the end")

            XCTAssertEqual(system.press(.pause), .success)
            XCTAssertFalse(audio.isPlaying, "Pause at the end played")
            assertToldSystem(system, that: reader, plays: false, "Pause at the end")

            reader.lastSkipTime = .distantPast
            reader.skipBackward()
        }
        assertPlaysAudio(reader, from: chapterEnd - 1 - Self.fifteenSecondsOfAudio, "Skip Backward after the end")
        assertToldSystem(system, that: reader, plays: true, "Skip Backward after the end")
        XCTAssertEqual(recorder.announcements, [], "A skip or Pause at the end announced something")
    }

    /// The same for a text book: the keyboard's Skip Forward at the end
    /// stays at the end and speaks nothing, as a stopped reader's skip
    /// never speaks on its own, and Skip Backward then speaks from the skip
    /// unit before the end at full volume, the system told the book plays.
    func testTheKeyboardsSkipForwardAtTheEndStaysSilentAndSkipBackwardThenSpeaks() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Keyboard Text")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let reader = quay.reader
        let end = finishSpeech(of: quay, in: system)
        let handedOverBefore = quay.handedOver.utterances.count

        let recorder = recordingAnnouncements {
            reader.skipForward()
            XCTAssertFalse(reader.speechService.isSpeaking, "Skip Forward at the end spoke")
            XCTAssertEqual(quay.handedOver.utterances.count, handedOverBefore, "Skip Forward at the end handed speech over")
            XCTAssertGreaterThanOrEqual(reader.currentCharacterOffset, end, "Skip Forward at the end moved back")
            assertToldSystem(system, that: reader, plays: false, "Skip Forward at the end")

            reader.lastSkipTime = .distantPast
            reader.skipBackward()
        }
        let movedTo = reader.currentCharacterOffset
        XCTAssertLessThan(movedTo, end, "Skip Backward did not move back")
        XCTAssertGreaterThan(movedTo, end - 2_000, "Skip Backward moved too far")
        assertSpeaks(quay, from: movedTo, "Skip Backward after the end")
        assertToldSystem(system, that: reader, plays: true, "Skip Backward after the end")
        XCTAssertEqual(recorder.announcements, [], "A skip at the end announced something")
    }

    /// A jump away from the end, here to the first chapter, leaves the
    /// finished book a stopped reader like any other: a Skip Backward then
    /// moves the cursor without playing, the system still shows the book
    /// paused, and Play starts it from there.
    func testAJumpAwayFromTheEndLeavesASkipMovingTheCursorOnly() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Jump")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let reader = ferry.reader

        reader.navigateTo(chapterIndex: 0, characterOffset: 5)
        XCTAssertFalse(reader.hasFinishedBook, "The book is still finished after the jump")
        reader.lastSkipTime = .distantPast
        reader.skipBackward()
        XCTAssertFalse(reader.audioPlaybackService.isPlaying, "A skip after the jump played")
        XCTAssertEqual(reader.currentChapterIndex, 0, "The skip left the first chapter")
        XCTAssertEqual(reader.currentCharacterOffset, 0, "The skip did not move to the start")
        assertToldSystem(system, that: reader, plays: false, "The skip after the jump")

        XCTAssertEqual(system.press(.play), .success)
        assertPlaysAudio(reader, inChapter: 0, from: 0, "Play after the jump")
        assertToldSystem(system, that: reader, plays: true, "Play after the jump")
    }

    /// A finished book still owns the media controls, so Release Media
    /// Controls is offered, and hands them back: the system is told
    /// playback stopped, and the book is finished no longer, so a Skip
    /// Backward then moves the cursor without playing or reclaiming the
    /// controls, as a stopped reader's does.
    func testReleasingMediaControlsAfterTheBookFinishesHandsThemBack() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Release")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let reader = ferry.reader
        XCTAssertTrue(reader.canReleaseMediaControls, "Release Media Controls is not offered after the end")

        let recorder = recordingAnnouncements {
            reader.releaseMediaControls()
        }
        XCTAssertEqual(recorder.announcements.map(\.message), ["Media controls released"])
        XCTAssertEqual(system.told.last, .some(nil), "Releasing media controls did not clear Now Playing")
        XCTAssertFalse(reader.hasFinishedBook, "The released book is still finished")
        XCTAssertFalse(reader.canReleaseMediaControls, "Release Media Controls is offered again")

        reader.lastSkipTime = .distantPast
        reader.skipBackward()
        XCTAssertFalse(reader.audioPlaybackService.isPlaying, "A skip after releasing played")
        XCTAssertLessThan(reader.currentCharacterOffset, ferry.endOffset, "The skip did not move the cursor")
        XCTAssertEqual(system.told.last, .some(nil), "The skip reclaimed Now Playing")
    }

    /// A finished book offers Release Media Controls only while it holds
    /// them, its book the one the system shows (REV07, speech finding 5).
    /// Once another book plays, the finished book's window, which asks
    /// again as it becomes key, offers nothing, and Release Media Controls
    /// chosen anyway, as a key can choose it, releases nothing and says
    /// nothing: the playing book plays on with the controls, and the system
    /// is never told that TextMouth stopped. Before, the finished book
    /// stopped and said "Media controls released" while the other book kept
    /// them. Nor is it offered while the system shows that book paused;
    /// that book's own window releases them.
    func testAFinishedBookOffersReleaseMediaControlsOnlyWhileItHoldsThem() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Release Owner")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let finished = ferry.reader
        XCTAssertTrue(finished.canReleaseMediaControls, "Release Media Controls is not offered while the finished book holds the controls")

        // Another book's window opens, becomes key, and plays its book.
        let otherBook = try world.makeSilentAudioBook(title: "Harbour Timetable", trackDurations: [30])
        let other = world.openReader(for: otherBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(other)
        other.windowBecameKey()
        other.play()
        let otherAudio = other.audioPlaybackService
        XCTAssertTrue(otherAudio.isPlaying && !otherAudio.isPaused, "The other book did not play")
        assertToldSystem(system, that: other, plays: true, "The other book's start")

        // The finished book's window becomes key again and asks afresh.
        var republished = 0
        let watching = finished.objectWillChange.sink { _ in republished += 1 }
        finished.windowBecameKey()
        watching.cancel()
        XCTAssertGreaterThan(republished, 0, "The finished book's window did not ask afresh as it became key")
        XCTAssertEqual(system.coordinator.focusedOwnerID, finished.nowPlayingService.ownerID, "The finished book's reader is not focused")
        XCTAssertFalse(finished.canReleaseMediaControls, "Release Media Controls is offered while another book plays")
        let refused = recordingAnnouncements {
            finished.releaseMediaControls()
        }
        XCTAssertEqual(refused.announcements, [], "Release Media Controls announced releasing what another book holds")
        XCTAssertTrue(otherAudio.isPlaying && !otherAudio.isPaused, "Release Media Controls paused the book playing")
        assertToldSystem(system, that: other, plays: true, "Release Media Controls in the finished book's window")

        // The other book pauses, and the system shows it paused.
        other.windowBecameKey()
        other.pause()
        finished.windowBecameKey()
        XCTAssertEqual(
            system.told.last,
            .some(NowPlayingItem(title: other.book.title, author: other.book.author, isPlaying: false)),
            "The system does not show the other book paused"
        )
        XCTAssertFalse(finished.canReleaseMediaControls, "Release Media Controls is offered while the system shows another book")

        // That book's own window releases them.
        other.windowBecameKey()
        XCTAssertTrue(other.canReleaseMediaControls, "The paused book's window does not offer Release Media Controls")
        let released = recordingAnnouncements {
            other.releaseMediaControls()
        }
        XCTAssertEqual(released.announcements.map(\.message), ["Media controls released"])
        XCTAssertEqual(system.told.last, .some(nil), "Releasing media controls did not clear Now Playing")
        XCTAssertEqual(system.told.filter { $0 == nil }.count, 1, "Now Playing was cleared more than once")
    }

    /// While another book plays, the keyboard's Skip Backward in a finished
    /// book's window moves its cursor back by the skip unit and plays
    /// nothing (REV07, speech finding 5): the book being listened to plays
    /// on and keeps the controls, and the finished book rests at its end no
    /// longer. Before, the skip played the finished book again and paused
    /// the other.
    func testAFinishedBooksSkipBackwardWhileAnotherBookPlaysMovesItsCursorOnly() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Skip Owner")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let finished = ferry.reader

        // Another book's window opens, becomes key, and plays its book.
        let otherBook = try world.makeSilentAudioBook(title: "Harbour Timetable", trackDurations: [30])
        let other = world.openReader(for: otherBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(other)
        other.windowBecameKey()
        other.play()
        let otherAudio = other.audioPlaybackService
        XCTAssertTrue(otherAudio.isPlaying && !otherAudio.isPaused, "The other book did not play")

        // Back in the finished book's window, Skip Backward.
        finished.windowBecameKey()
        finished.lastSkipTime = .distantPast
        let skipping = recordingAnnouncements {
            finished.skipBackward()
        }
        XCTAssertFalse(finished.audioPlaybackService.isPlaying, "Skip Backward played the finished book while another played")
        XCTAssertEqual(
            finished.currentCharacterOffset,
            ferry.endOffset - Self.fifteenSecondsOfAudio,
            "Skip Backward did not move the cursor back by the skip unit"
        )
        XCTAssertFalse(finished.hasFinishedBook, "The finished book still rests at its end after its cursor moved")
        XCTAssertTrue(otherAudio.isPlaying && !otherAudio.isPaused, "Skip Backward in the finished book's window paused the book playing")
        assertToldSystem(system, that: other, plays: true, "Skip Backward in the finished book's window")
        XCTAssertEqual(skipping.announcements, [], "Skip Backward announced something")
    }

    /// While nothing plays, a finished book's Skip Backward plays it again,
    /// though another book was played since and is shown paused: the
    /// finished book's reader, its window key, is the active owner, and the
    /// rewind exists to hear the end again while nothing else plays. The
    /// paused book stays paused.
    func testAFinishedBooksSkipBackwardWhileNothingPlaysPlaysItAgain() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Skip Paused Other")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let finished = ferry.reader

        // Another book's window opens, becomes key, and plays its book, then
        // pauses it.
        let otherBook = try world.makeSilentAudioBook(title: "Harbour Timetable", trackDurations: [30])
        let other = world.openReader(for: otherBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(other)
        other.windowBecameKey()
        other.play()
        other.pause()
        let otherAudio = other.audioPlaybackService
        XCTAssertTrue(otherAudio.isPaused, "The other book did not pause")

        // Back in the finished book's window, Skip Backward.
        finished.windowBecameKey()
        finished.lastSkipTime = .distantPast
        finished.skipBackward()
        assertPlaysAudio(finished, from: ferry.endOffset - Self.fifteenSecondsOfAudio, "Skip Backward while nothing plays")
        assertToldSystem(system, that: finished, plays: true, "Skip Backward while nothing plays")
        XCTAssertTrue(otherAudio.isPaused, "The paused book did not stay paused")
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

    /// Has the Mac's speech engine refuse the text where `book`'s speech
    /// goes on after its first chunk, as the synthesizer reports it: the
    /// first chunk starts, which queues the next, and finishes, which makes
    /// the next the one speaking; the engine cancels that one before it
    /// says a word, and then the fresh synthesizer's retry of it, and the
    /// main queue handles each report. Speech then stops where the second
    /// chunk begins, a place nothing saved before the refusal.
    ///
    /// - Returns: Where speech stopped: the second chunk's start.
    @discardableResult
    private func refuseTheChunkAfterTheFirst(
        of book: TextBookReader,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        let speech = book.reader.speechService
        let synthesizer = AVSpeechSynthesizer()
        guard let first = book.handedOver.utterances.last else {
            XCTFail("Nothing was handed to the synthesizer", file: file, line: line)
            return 0
        }
        speech.speechSynthesizer(synthesizer, didStart: first)
        handleQueuedCallbacks(file: file, line: line)
        guard let second = book.handedOver.utterances.last, second !== first else {
            XCTFail("The second chunk was not queued", file: file, line: line)
            return 0
        }
        speech.speechSynthesizer(synthesizer, didFinish: first)
        handleQueuedCallbacks(file: file, line: line)
        speech.speechSynthesizer(synthesizer, didCancel: second)
        handleQueuedCallbacks(file: file, line: line)
        guard let retry = book.handedOver.utterances.last, retry !== second else {
            XCTFail("The refused chunk was not spoken again", file: file, line: line)
            return 0
        }
        speech.speechSynthesizer(synthesizer, didCancel: retry)
        handleQueuedCallbacks(file: file, line: line)
        let firstChunk = DirectSpeechChunk.starting(
            at: Self.openingOffset,
            in: book.text,
            maximumLength: SpeechService.directModeFirstChunkSize
        )
        return DirectSpeechChunk.starting(at: firstChunk.end, in: book.text, maximumLength: SpeechService.directModeChunkSize).start
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

    /// Check that `reader`'s audio plays from `offset` of chapter
    /// `chapterIndex`, the last by default: the player playing, not paused,
    /// the reader showing Playing, and the cursor and the player within a
    /// second of the place.
    private func assertPlaysAudio(
        _ reader: ReaderViewModel,
        inChapter chapterIndex: Int = 1,
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
        XCTAssertEqual(reader.currentChapterIndex, chapterIndex, "\(context): the cursor is in another chapter", file: file, line: line)
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
