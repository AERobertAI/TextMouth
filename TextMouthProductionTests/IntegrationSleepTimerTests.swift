import AppKit
import Combine
import SwiftUI
import XCTest
@testable import TextMouth

/// Sleep timer expiry at the real boundary (TODO Q04; repair F17): the
/// shared timer counts down on its own clock, fades the owning reader's
/// real audio out, and pauses it, while another book's reader window
/// closes, as windows do when a listener settles down for the night.
///
/// A timer set for a place in the book stops playback where the book gets
/// there, for text and audio alike (TODO P01, finding #676): at the end of
/// the chapter playing, before the next one starts, or at the end of the
/// book, before the book starts again or the next book does; and it belongs
/// to the reader that set it, not to its book. Audiobooks play real,
/// silent tracks; a text book's speech is stopped before the main run loop
/// turns, and its look-ahead renders are held; so nothing is ever heard.
@MainActor
final class IntegrationSleepTimerTests: XCTestCase {
    /// Subscriptions the test keeps until it ends.
    private var subscriptions = Set<AnyCancellable>()

    /// A one-minute sleep timer with one second left, set in a reader
    /// playing silent audio with a one-second fade, pauses that reader once,
    /// when the fade has finished, and says so once ("Sleep timer expired.
    /// Playback paused."), even though another book's reader closes while
    /// the audio fades out. The volume is back to full for the next Play,
    /// and the timer has ended.
    ///
    /// The single shared timer belongs to the book that set it, so only that
    /// book's reader may cancel its fade. Before the repair, any reader that
    /// stopped during a fade cancelled it. With that decision restored in
    /// `ReaderViewModel.stop()` (commit 709c3b2 no longer reverts cleanly),
    /// this test fails with "XCTAssertTrue failed - The timer never paused
    /// Night Reading": the fade is cancelled, the book plays on at full
    /// volume, and nothing is announced.
    func testExpiringTimerPausesItsOwnBookOnceWhileAnotherBooksWindowCloses() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("Integration Sleep Timer")
        world.settings.sleepFadeOutDuration = 1
        let owner = try world.makeSilentAudioBook(title: "Night Reading", trackDurations: [30])
        let other = try world.makeSilentAudioBook(title: "Morning Reading", trackDurations: [30])
        let ownerReader = world.openReader(for: owner)
        let otherReader = world.openReader(for: other)
        waitForReaderToLoad(ownerReader)
        waitForReaderToLoad(otherReader)
        let pauses = countPauses(of: ownerReader)

        let recorder = recordingAnnouncements {
            ownerReader.play()
            XCTAssertTrue(
                waitUntil(timeout: 5) { ownerReader.audioPlaybackService.isPlaying },
                "Night Reading never started playing"
            )
            ownerReader.startSleepTimer(duration: .minutes(1))
            // One second left on the clock: the next tick expires it.
            timer.remainingSeconds = 1
            XCTAssertTrue(waitUntil(timeout: 3) { timer.isFadingOut }, "The timer never began to fade out")

            otherReader.close()

            XCTAssertTrue(
                waitUntil(timeout: 4) { ownerReader.isCurrentlyPaused },
                "The timer never paused Night Reading"
            )
            // Another pause or announcement would follow within a countdown
            // tick; none may.
            XCTAssertFalse(
                waitUntil(timeout: 1.2) { pauses() > 1 || timer.isActive },
                "The timer paused again or started again"
            )
        }

        XCTAssertEqual(pauses(), 1, "Night Reading was not paused exactly once")
        XCTAssertEqual(recorder.announcements.map(\.message), ["Sleep timer expired. Playback paused."])
        XCTAssertTrue(ownerReader.audioPlaybackService.isPaused, "The audio is not paused")
        XCTAssertEqual(ownerReader.audioPlaybackService.outputVolume, 1, "The volume was not restored for the next Play")
        XCTAssertFalse(timer.isActive)
        XCTAssertFalse(timer.isFadingOut)
    }

    // MARK: - Stopping Where a Chapter Ends (TODO P01, finding #676)

    /// Finding #676: a timer set for the end of the chapter, with the
    /// default fade of no seconds, stops an audiobook where the chapter
    /// playing ends, before the next one starts. The listener hears once
    /// that the timer stopped playback, the timer has ended, the next
    /// chapter's file is never played, and the cursor waits, saved, at the
    /// beginning of the next chapter, where Play then starts it.
    ///
    /// Before the repair the timer announced a pause that paused nothing,
    /// since the chapter's audio had already finished, and the next chapter
    /// played on.
    func testEndOfChapterTimerStopsAnAudiobookBeforeTheNextChapter() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("Sleep Timer Chapter End")
        world.settings.sleepFadeOutDuration = 0
        let book = try world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [0.6, 5])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let service = reader.audioPlaybackService
        let secondChapterFile = try XCTUnwrap(reader.audioChapterFiles.last.map(resolvedPath))
        defer { reader.stop() }

        let recorder = recordingAnnouncements {
            reader.startSleepTimer(duration: .endOfChapter)
            reader.play()
            XCTAssertTrue(service.isPlaying, "The first chapter did not play")
            XCTAssertTrue(eventually(within: 10) { reader.currentChapterIndex == 1 }, "The first chapter never ended")
            XCTAssertFalse(service.isPlaying, "The next chapter played")
            XCTAssertFalse(reader.isCurrentlyPlaying, "The reader shows the next chapter playing")
            // Nothing may start a moment later either.
            XCTAssertFalse(
                eventually(within: 1) { service.isPlaying || reader.isCurrentlyPlaying },
                "Playback started again after the chapter's end"
            )
        }

        XCTAssertEqual(
            recorder.announcements.map(\.message),
            ["Sleep timer expired at the end of the chapter. Playback paused."]
        )
        XCTAssertFalse(timer.isActive, "The timer is still in effect")
        XCTAssertEqual(reader.currentCharacterOffset, 0)
        XCTAssertNotEqual(
            service.loadedURL.map { resolvedPath($0.path) },
            secondChapterFile,
            "The next chapter's file was loaded"
        )
        try assertSavedPlace(of: book, in: world, chapter: 1, offset: 0)

        reader.togglePlayPause()
        XCTAssertTrue(service.isPlaying, "Play did not start the next chapter")
        XCTAssertEqual(service.loadedURL.map { resolvedPath($0.path) }, secondChapterFile)
        XCTAssertEqual(reader.currentChapterIndex, 1)
    }

    /// The same for a text book: a timer set for the end of the chapter
    /// stops speech where the chapter ends, with no fade even when one is
    /// set, since speech is not faded there. The next chapter is not
    /// spoken, the chapter rendered ahead is let go without playing, the
    /// timer has ended, and the cursor waits, saved, at the beginning of
    /// the next chapter. Before the repair the next chapter was spoken at
    /// once.
    func testEndOfChapterTimerStopsSpeechBeforeTheNextChapter() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
        for fadeSeconds: TimeInterval in [0, 5] {
            try withSpeechReader("Sleep Timer Speech Fade \(Int(fadeSeconds))", fadeSeconds: fadeSeconds) { speech in
                let reader = speech.reader
                reader.startSleepTimer(duration: .endOfChapter)
                let endOfFirstChapter = try startSpeakingSilently(reader)
                XCTAssertNotNil(reader.lookAhead, "The next chapter was not looked ahead to")

                var spokeOn = false
                let recorder = recordingAnnouncements {
                    spokeOn = endSpeechSilently(endOfFirstChapter, of: reader)
                }

                let fade = "with a fade of \(fadeSeconds) seconds"
                XCTAssertFalse(spokeOn, "The next chapter was spoken \(fade)")
                XCTAssertEqual(
                    recorder.announcements.map(\.message),
                    ["Sleep timer expired at the end of the chapter. Playback paused."],
                    fade
                )
                XCTAssertFalse(timer.isActive, "The timer is still in effect \(fade)")
                XCTAssertFalse(timer.isFadingOut, "Speech faded out \(fade)")
                XCTAssertNil(reader.lookAhead, "The chapter rendered ahead was kept \(fade)")
                XCTAssertEqual(reader.currentChapterIndex, 1, fade)
                XCTAssertEqual(reader.currentCharacterOffset, 0, fade)
                try assertSavedPlace(of: speech.book, in: speech.world, chapter: 1, offset: 0)
            }
        }
    }

    /// A timer set for the end of the chapter that is the book's last
    /// stops playback where the book ends, whatever the book does at its
    /// end: it neither starts again nor continues to the next book. The
    /// listener hears once that the book finished and why nothing follows,
    /// and the timer has ended.
    func testEndOfChapterTimerAtTheLastChapterEndsListeningWithTheBook() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
        let outcomes: [(behavior: EndOfBookBehavior, announcement: String, chapterAfter: Int)] = [
            (.stop, "Finished: Quay Notes. Sleep timer expired.", 2),
            (.loop, "Finished: Quay Notes. Not restarted because of the sleep timer.", 0),
            (.continueNext, "Finished: Quay Notes. Next book not started because of the sleep timer.", 2),
        ]
        for outcome in outcomes {
            let label = "Sleep Timer Book End \(outcome.behavior.rawValue)"
            try withSpeechReader(label, endOfBook: outcome.behavior) { speech in
                let reader = speech.reader
                let continued = recordContinueRequests(in: speech.world)
                reader.navigateTo(chapterIndex: 2, characterOffset: 0)
                reader.startSleepTimer(duration: .endOfChapter)
                let endOfLastChapter = try startSpeakingSilently(reader)

                var spokeOn = false
                var askedForTheNextBook = false
                let recorder = recordingAnnouncements {
                    spokeOn = endSpeechSilently(endOfLastChapter, of: reader)
                    askedForTheNextBook = nextBookIsAskedFor(continued)
                }

                let behavior = outcome.behavior.rawValue
                XCTAssertFalse(spokeOn, "\(behavior): the book was spoken again")
                XCTAssertEqual(recorder.announcements.map(\.message), [outcome.announcement], behavior)
                XCTAssertFalse(timer.isActive, "\(behavior): the timer is still in effect")
                XCTAssertFalse(askedForTheNextBook, "\(behavior): the next book was asked for")
                XCTAssertFalse(speech.world.autoplayRequests.hasRequest(for: speech.nextBook.id), behavior)
                XCTAssertEqual(reader.currentChapterIndex, outcome.chapterAfter, behavior)
            }
        }
    }

    // MARK: - Fading Out Before the Stop (TODO P01)

    /// With a fade-out time set, an audiobook stays at full volume until
    /// that much of the chapter is left where an End of chapter timer stops
    /// it, then fades evenly with the time left, so the stop at the chapter's
    /// end comes in silence. The volume is back to full for the next chapter.
    func testEndOfChapterTimerFadesAnAudiobookOutOverTheLastSecondsOfTheChapter() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("Sleep Timer Chapter Fade")
        let fadeSeconds: TimeInterval = 1
        world.settings.sleepFadeOutDuration = fadeSeconds
        let book = try world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2, 5])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let service = reader.audioPlaybackService
        let samples = try recordVolumes(of: reader)
        defer { reader.stop() }

        let recorder = recordingAnnouncements {
            reader.startSleepTimer(duration: .endOfChapter)
            reader.play()
            XCTAssertTrue(eventually(within: 10) { reader.currentChapterIndex == 1 }, "The first chapter never ended")
        }

        let beforeTheFade = samples().filter { $0.secondsLeft > fadeSeconds + 0.05 }
        let duringTheFade = samples().filter { $0.secondsLeft < fadeSeconds }
        XCTAssertFalse(beforeTheFade.isEmpty, "No position was reported before the fade")
        XCTAssertTrue(beforeTheFade.allSatisfy { $0.volume == 1 }, "The audio faded too soon: \(beforeTheFade)")
        XCTAssertGreaterThanOrEqual(duringTheFade.count, 2, "Too few positions were reported during the fade: \(samples())")
        for sample in duringTheFade {
            XCTAssertEqual(sample.volume, Float(sample.secondsLeft / fadeSeconds), accuracy: 0.001, "\(sample)")
        }
        XCTAssertLessThan(duringTheFade.map(\.volume).min() ?? 1, 0.5, "The audio never faded below half volume")
        XCTAssertEqual(
            recorder.announcements.map(\.message),
            ["Sleep timer expired at the end of the chapter. Playback paused."]
        )
        XCTAssertFalse(timer.isActive)
        XCTAssertFalse(service.isPlaying, "The next chapter played")
        XCTAssertEqual(service.intendedVolume, 1, "The volume was not put back for the next chapter")
    }

    /// Cancelling an End of chapter timer while it fades an audiobook out
    /// puts the volume back to full at once, and the next chapter plays on.
    func testCancellingTheTimerDuringItsFadeRestoresTheVolumeAndPlaysOn() throws {
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("Sleep Timer Chapter Fade Cancel")
        world.settings.sleepFadeOutDuration = 2
        let book = try world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2.5, 5])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let service = reader.audioPlaybackService
        defer { reader.stop() }

        reader.startSleepTimer(duration: .endOfChapter)
        reader.play()
        XCTAssertTrue(eventually(within: 10) { service.intendedVolume < 1 }, "The audio never began to fade")
        XCTAssertEqual(reader.currentChapterIndex, 0)

        reader.cancelSleepTimer()

        XCTAssertEqual(service.intendedVolume, 1, "Cancelling the timer left the audio faded")
        XCTAssertEqual(service.outputVolume, 1)
        XCTAssertTrue(eventually(within: 10) { reader.currentChapterIndex == 1 }, "The first chapter never ended")
        XCTAssertTrue(service.isPlaying, "The next chapter did not play on")
        XCTAssertEqual(service.intendedVolume, 1)
    }

    /// Pausing while an End of chapter timer fades the audio out keeps the
    /// timer, which waits for a place rather than counting time: playing
    /// again goes on fading from where the fade was, and stops at the
    /// chapter's end.
    func testPausingDuringTheFadeKeepsTheTimerAndPlayingAgainStopsAtTheEnd() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("Sleep Timer Chapter Fade Pause")
        world.settings.sleepFadeOutDuration = 2
        let book = try world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [2.5, 5])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let service = reader.audioPlaybackService
        defer { reader.stop() }

        let recorder = recordingAnnouncements {
            reader.startSleepTimer(duration: .endOfChapter)
            reader.play()
            XCTAssertTrue(eventually(within: 10) { service.intendedVolume < 1 }, "The audio never began to fade")
            reader.pause()
            let volumeWhenPaused = service.intendedVolume
            XCTAssertTrue(timer.isActive, "Pausing during the fade ended the timer")
            XCTAssertLessThan(volumeWhenPaused, 1, "Pausing put the volume back")

            reader.togglePlayPause()
            XCTAssertEqual(service.intendedVolume, volumeWhenPaused, accuracy: 0.001, "Playing again did not go on fading")
            XCTAssertTrue(eventually(within: 10) { reader.currentChapterIndex == 1 }, "The first chapter never ended")
        }

        XCTAssertEqual(
            recorder.announcements.map(\.message),
            ["Sleep timer expired at the end of the chapter. Playback paused."]
        )
        XCTAssertFalse(timer.isActive)
        XCTAssertFalse(service.isPlaying, "The next chapter played")
        XCTAssertEqual(service.intendedVolume, 1)
    }

    // MARK: - Stopping Where the Book Ends (TODO P01)

    /// A timer set for the end of the book lets an audiobook play on from
    /// chapter to chapter, rolling straight on into the next chapter's file,
    /// and stops it where the last chapter ends. With Continue to Next Book
    /// on, the next book is not started; with it off, the book would have
    /// stopped there anyway. The listener hears once that the book finished
    /// and that the timer stopped it, and the timer has ended.
    func testEndOfBookTimerPlaysAnAudiobookToItsEndAndStartsNothingAfter() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let outcomes: [(behavior: EndOfBookBehavior, announcement: String)] = [
            (.continueNext, "Finished: Ferry Timetable. Next book not started because of the sleep timer."),
            (.stop, "Finished: Ferry Timetable. Sleep timer expired."),
        ]
        for outcome in outcomes {
            let behavior = outcome.behavior.rawValue
            let world = try makeIntegrationWorld("Sleep Timer Audio Book End \(behavior)")
            world.settings.sleepFadeOutDuration = 0
            let book = try world.makeSilentAudioBook(
                title: "Ferry Timetable",
                trackDurations: [0.5, 0.5],
                endOfBook: outcome.behavior
            )
            let nextBook = try world.makeSilentAudioBook(title: "Harbour Almanac", trackDurations: [5])
            let reader = world.openReader(for: book)
            waitForReaderToLoad(reader)
            let service = reader.audioPlaybackService
            let files = reader.audioChapterFiles.map(resolvedPath)
            let continued = recordContinueRequests(in: world)
            defer { reader.stop() }

            var askedForTheNextBook = false
            let recorder = recordingAnnouncements {
                reader.startSleepTimer(duration: .endOfBook)
                reader.play()
                XCTAssertEqual(service.queuedFilePaths, files, "\(behavior): the last chapter's file was not named to follow")
                XCTAssertTrue(eventually(within: 10) { reader.currentChapterIndex == 1 }, "\(behavior): the first chapter never ended")
                XCTAssertTrue(service.isPlaying, "\(behavior): the timer stopped playback before the last chapter")
                XCTAssertTrue(
                    eventually(within: 10) { !reader.isCurrentlyPlaying && !service.isPlaying },
                    "\(behavior): the book never ended"
                )
                askedForTheNextBook = nextBookIsAskedFor(continued)
            }

            XCTAssertEqual(recorder.announcements.map(\.message), [outcome.announcement], behavior)
            XCTAssertFalse(timer.isActive, "\(behavior): the timer is still in effect")
            XCTAssertFalse(askedForTheNextBook, "\(behavior): the next book was asked for")
            XCTAssertFalse(world.autoplayRequests.hasRequest(for: nextBook.id), behavior)
        }
    }

    /// The same for a text book: a timer set for the end of the book lets
    /// speech go on from chapter to chapter and stops it where the last
    /// chapter ends, whatever the book does at its end: it neither starts
    /// again nor continues to the next book. The listener hears once that
    /// the book finished and why nothing follows.
    func testEndOfBookTimerSpeaksATextBookToItsEndAndStartsNothingAfter() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
        let outcomes: [(behavior: EndOfBookBehavior, announcement: String, chapterAfter: Int)] = [
            (.stop, "Finished: Quay Notes. Sleep timer expired.", 2),
            (.loop, "Finished: Quay Notes. Not restarted because of the sleep timer.", 0),
            (.continueNext, "Finished: Quay Notes. Next book not started because of the sleep timer.", 2),
        ]
        for outcome in outcomes {
            let behavior = outcome.behavior.rawValue
            try withSpeechReader("Sleep Timer Speech Book End \(behavior)", endOfBook: outcome.behavior) { speech in
                let reader = speech.reader
                let continued = recordContinueRequests(in: speech.world)
                reader.navigateTo(chapterIndex: 1, characterOffset: 0)
                reader.startSleepTimer(duration: .endOfBook)
                let endOfSecondChapter = try startSpeakingSilently(reader)

                var spokeTheLastChapter = false
                var spokeAfterTheBook = false
                var askedForTheNextBook = false
                let recorder = recordingAnnouncements {
                    spokeTheLastChapter = endSpeechSilently(endOfSecondChapter, of: reader)
                    XCTAssertEqual(reader.currentChapterIndex, 2, "\(behavior): the last chapter did not start")
                    if let endOfLastChapter = reader.speechService.onUtteranceFinished {
                        spokeAfterTheBook = endSpeechSilently(endOfLastChapter, of: reader)
                    }
                    askedForTheNextBook = nextBookIsAskedFor(continued)
                }

                XCTAssertTrue(spokeTheLastChapter, "\(behavior): the timer stopped speech before the last chapter")
                XCTAssertFalse(spokeAfterTheBook, "\(behavior): the book was spoken again")
                XCTAssertEqual(recorder.announcements.map(\.message), [outcome.announcement], behavior)
                XCTAssertFalse(timer.isActive, "\(behavior): the timer is still in effect")
                XCTAssertFalse(askedForTheNextBook, "\(behavior): the next book was asked for")
                XCTAssertFalse(speech.world.autoplayRequests.hasRequest(for: speech.nextBook.id), behavior)
                XCTAssertEqual(reader.currentChapterIndex, outcome.chapterAfter, behavior)
            }
        }
    }

    // MARK: - Stopping Where a Heading Ends (finding #787)

    /// Finding #787: speech crossing from one heading into the next within a
    /// chapter stops there, once, as the reader's view of the cursor learns
    /// which heading the cursor is in. Speech has run a moment past the next
    /// heading's start by then, so the cursor goes back to it, saved, for
    /// Play to begin that heading from its first word. Before the repair
    /// playback crossing a heading told the timer nothing, so it never
    /// stopped a book playing on its own.
    func testEndOfHeadingTimerStopsSpeechWhereTheHeadingEndsWithinAChapter() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
        let harbour = harbourChapter()
        try withSpeechReader("Sleep Timer Heading End Speech", chapters: [harbour.chapter]) { speech in
            let reader = speech.reader
            reader.startSleepTimer(duration: .endOfHeading)
            // The first word of the Tides section after its heading.
            let wordAfterTheHeading = harbour.tidesOffset + "Tides\n\n".utf16.count

            var spokeOn = true
            let recorder = recordingAnnouncements {
                reader.play()
                // The speech service reports that word about to be spoken, in
                // the speech's own offsets, and the reader's next refresh of
                // its view of the cursor comes; a later one finds nothing to do.
                let spokenOffset = reader.currentOffsetMap?.toModified(wordAfterTheHeading) ?? wordAfterTheHeading
                reader.speechService.onWordSpoken?(NSRange(location: spokenOffset, length: 3), "The")
                reader.stopForSleepTimerIfPlaybackReachedHeadingEnd()
                spokeOn = reader.speechService.isSpeaking
                reader.speechService.stop()
                reader.stopForSleepTimerIfPlaybackReachedHeadingEnd()
            }

            XCTAssertFalse(spokeOn, "Speech went on into the next heading")
            XCTAssertEqual(
                recorder.announcements,
                [VoiceOverAnnouncement(message: "Sleep timer expired at the end of the heading. Playback paused.", priority: .high)]
            )
            XCTAssertFalse(timer.isActive, "The timer is still in effect")
            XCTAssertEqual(timer.lastUsedDuration, .endOfHeading)
            XCTAssertEqual(reader.currentChapterIndex, 0)
            XCTAssertEqual(reader.currentCharacterOffset, harbour.tidesOffset, "The cursor is not at the next heading")
            try assertSavedPlace(of: speech.book, in: speech.world, chapter: 0, offset: harbour.tidesOffset)
        }
    }

    /// Finding #787: a jump that stays within the heading the timer waits for
    /// ends nothing: back to that heading's own start, or on to its next
    /// sentence. A jump out of it, to the next heading, ends the timer at
    /// once, the first time; the listener hears the next heading's name, then
    /// that the timer ended, after it rather than over it. Before the repair
    /// a jump to the next heading only armed the timer, and a second ended it.
    func testAJumpWithinTheHeadingKeepsTheTimerAndAJumpOutEndsItOnce() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
        let harbour = harbourChapter()
        try withSpeechReader("Sleep Timer Heading Jumps", chapters: [harbour.chapter]) { speech in
            let reader = speech.reader
            // Well inside the Moorings section, past the grace a jump back to
            // a heading allows.
            let insideMoorings = harbour.tidesOffset - "checked.\n\n".utf16.count
            reader.navigateTo(chapterIndex: 0, characterOffset: insideMoorings)
            reader.startSleepTimer(duration: .endOfHeading)

            var keptWithinTheHeading = false
            let recorder = recordingAnnouncements {
                reader.previousHeading()
                XCTAssertEqual(reader.currentCharacterOffset, 0, "The jump back did not reach the heading's start")
                reader.nextSentence()
                keptWithinTheHeading = timer.isActive

                reader.nextHeading()
                XCTAssertFalse(timer.isActive, "The jump out of the heading did not end the timer")
                // The timer's end is said on the main queue's next turn.
                XCTAssertTrue(
                    waitUntil(timeout: 2) { reader.lastAnnouncement != "Heading: Tides" },
                    "The timer's end was not said"
                )
                // No later heading to jump to: nothing more is said.
                reader.nextHeading()
            }

            XCTAssertTrue(keptWithinTheHeading, "A jump within the heading ended the timer")
            XCTAssertEqual(
                recorder.announcements,
                [
                    VoiceOverAnnouncement(message: "Heading: Moorings", priority: .high),
                    VoiceOverAnnouncement(message: "Next sentence", priority: .high),
                    VoiceOverAnnouncement(message: "Heading: Tides", priority: .high),
                    VoiceOverAnnouncement(
                        message: "Sleep timer expired at the end of the heading. Playback paused.",
                        priority: .medium
                    ),
                ]
            )
            XCTAssertEqual(reader.currentCharacterOffset, harbour.tidesOffset, "The cursor is not where the jump went")
        }
    }

    /// Finding #787, while an audiobook plays: a jump back to the start of
    /// the heading the timer waits for plays on, the timer in effect; a jump
    /// out of it, to the next heading, stops playback where the jump went,
    /// once, and the cursor waits there, saved.
    func testAJumpOutOfTheHeadingStopsAnAudiobookWhereTheJumpWent() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("Sleep Timer Heading Jump Audio")
        world.settings.sleepFadeOutDuration = 0
        let book = try world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [5, 5])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let service = reader.audioPlaybackService
        defer { reader.stop() }

        let recorder = recordingAnnouncements {
            reader.startSleepTimer(duration: .endOfHeading)
            reader.play()
            // Past the grace a jump back to a heading allows: a second and a
            // half of the chapter, at ten characters a second.
            XCTAssertTrue(eventually(within: 5) { reader.currentCharacterOffset > 15 }, "The first chapter did not play on")
            reader.previousHeading()
            XCTAssertTrue(service.isPlaying, "The jump back to the heading's start stopped playback")
            XCTAssertTrue(timer.isActive, "The jump back to the heading's start ended the timer")

            reader.nextHeading()
            XCTAssertFalse(service.isPlaying, "The next heading played")
            XCTAssertFalse(timer.isActive, "The jump out of the heading did not end the timer")
            // The timer's end is said on the main queue's next turn.
            spinMainRunLoop(for: 0.2)
        }

        XCTAssertEqual(recorder.announcements.count, 3, "\(recorder.announcements)")
        XCTAssertEqual(
            recorder.announcements.last,
            VoiceOverAnnouncement(message: "Sleep timer expired at the end of the heading. Playback paused.", priority: .medium)
        )
        XCTAssertFalse(reader.isCurrentlyPlaying, "The reader shows the next heading playing")
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentCharacterOffset, 0)
        try assertSavedPlace(of: book, in: world, chapter: 1, offset: 0)
    }

    /// Finding #787: an audiobook's chapters are its headings, so a timer
    /// set for the end of the heading stops the audiobook where its chapter
    /// ends, before the next chapter starts, once, as the Stop At section's
    /// End of chapter does; the next chapter's file is never named to follow.
    /// The cursor waits, saved, at the beginning of the next chapter, where
    /// Play starts it.
    func testEndOfHeadingTimerStopsAnAudiobookWhereItsChapterEnds() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("Sleep Timer Heading End Audio")
        world.settings.sleepFadeOutDuration = 0
        let book = try world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [0.6, 5])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let service = reader.audioPlaybackService
        let firstChapterFile = reader.audioChapterFiles.prefix(1).map(resolvedPath)
        defer { reader.stop() }

        let recorder = recordingAnnouncements {
            reader.startSleepTimer(duration: .endOfHeading)
            reader.play()
            XCTAssertTrue(service.isPlaying, "The first chapter did not play")
            XCTAssertEqual(service.queuedFilePaths, firstChapterFile, "The next chapter's file was named to follow")
            XCTAssertTrue(eventually(within: 10) { reader.currentChapterIndex == 1 }, "The first heading never ended")
            XCTAssertFalse(service.isPlaying, "The next heading played")
            XCTAssertFalse(
                eventually(within: 1) { service.isPlaying || reader.isCurrentlyPlaying },
                "Playback started again after the heading's end"
            )
        }

        XCTAssertEqual(
            recorder.announcements.map(\.message),
            ["Sleep timer expired at the end of the heading. Playback paused."]
        )
        XCTAssertFalse(timer.isActive, "The timer is still in effect")
        XCTAssertEqual(reader.currentCharacterOffset, 0)
        try assertSavedPlace(of: book, in: world, chapter: 1, offset: 0)
    }

    /// Finding #787, for a text book whose chapters begin with their
    /// headings: speech stops where the chapter ends when the next chapter
    /// begins the next heading, white space before it or not, and goes on
    /// when the next chapter has no heading of its own, so the heading goes
    /// on through it.
    func testEndOfHeadingTimerStopsSpeechWhereTheChapterEndsOnlyWhenTheHeadingDoes() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
        let opening = Chapter(
            title: "Bollard",
            text: "Bollard\n\nThe bollard is noted here.",
            headings: [Heading(level: 1, text: "Bollard")]
        )
        let cases: [(name: String, next: Chapter, stops: Bool)] = [
            ("a chapter opening with its heading", Chapter(
                title: "Capstan",
                text: "Capstan\n\nThe capstan is noted here.",
                headings: [Heading(level: 1, text: "Capstan")]
            ), true),
            ("a chapter whose heading follows a blank line", Chapter(
                title: "Davit",
                text: "\n\nDavit\n\nThe davit is noted here.",
                headings: [Heading(level: 1, text: "Davit", characterOffset: 2)]
            ), true),
            ("a chapter with no heading of its own", Chapter(title: "", text: "The cleat is noted here."), false),
        ]
        for (number, nextChapter) in cases.enumerated() {
            try withSpeechReader("Sleep Timer Heading Chapter End \(number)", chapters: [opening, nextChapter.next]) { speech in
                let reader = speech.reader
                reader.startSleepTimer(duration: .endOfHeading)
                let endOfFirstChapter = try startSpeakingSilently(reader)

                var spokeOn = false
                let recorder = recordingAnnouncements {
                    spokeOn = endSpeechSilently(endOfFirstChapter, of: reader)
                }

                XCTAssertEqual(spokeOn, !nextChapter.stops, nextChapter.name)
                XCTAssertEqual(timer.isActive, !nextChapter.stops, nextChapter.name)
                XCTAssertEqual(
                    recorder.announcements.map(\.message),
                    nextChapter.stops ? ["Sleep timer expired at the end of the heading. Playback paused."] : [],
                    nextChapter.name
                )
                XCTAssertEqual(reader.currentChapterIndex, 1, nextChapter.name)
                XCTAssertEqual(reader.currentCharacterOffset, 0, nextChapter.name)
            }
        }
    }

    /// Finding #787: the last heading ends with the book, so a timer set for
    /// the end of the heading in the last one stops playback where the book
    /// ends, and the book does not start again, as one set for the end of
    /// the book would not let it.
    func testEndOfHeadingTimerInTheLastHeadingStopsWhereTheBookEnds() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
        let harbour = harbourChapter()
        try withSpeechReader("Sleep Timer Heading Book End", endOfBook: .loop, chapters: [harbour.chapter]) { speech in
            let reader = speech.reader
            reader.navigateTo(chapterIndex: 0, characterOffset: harbour.tidesOffset)
            reader.startSleepTimer(duration: .endOfHeading)
            let endOfTheBook = try startSpeakingSilently(reader)

            var spokeOn = false
            let recorder = recordingAnnouncements {
                spokeOn = endSpeechSilently(endOfTheBook, of: reader)
            }

            XCTAssertFalse(spokeOn, "The book started again")
            XCTAssertEqual(
                recorder.announcements.map(\.message),
                ["Finished: Quay Notes. Not restarted because of the sleep timer."]
            )
            XCTAssertFalse(timer.isActive, "The timer is still in effect")
        }
    }

    /// Finding #787: a timer for the end of the heading set while the book
    /// still loads, before its headings are known, waits once they are for
    /// the end of the heading the cursor is in, rather than for the end of
    /// the book.
    func testAHeadingTimerSetWhileTheBookLoadsWaitsForItsHeadingOnceLoaded() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
        let harbour = harbourChapter()
        try withSpeechReader("Sleep Timer Heading While Loading", chapters: [harbour.chapter]) { speech in
            let reader = speech.reader
            let book = try XCTUnwrap(reader.content)
            reader.content = nil
            reader.startSleepTimer(duration: .endOfHeading)

            reader.showLoadedContent(
                ReaderViewModel.LoadedContent(
                    content: book,
                    index: book.contentIndex,
                    audioFiles: nil,
                    audioSegments: nil,
                    audioTags: nil,
                    shouldPersistContentIndex: false,
                    cacheFormatVersion: nil
                ),
                readFrom: speech.book.filePath
            )
            reader.navigateTo(chapterIndex: 0, characterOffset: harbour.tidesOffset)

            XCTAssertFalse(timer.isActive, "The heading's end did not end the timer")
        }
    }

    /// Whether a heading has begun by the time a chapter says anything: it
    /// begins in an earlier chapter, or in this one with nothing but white
    /// space before it; not when it begins in a later chapter, or after
    /// words of this one.
    func testAHeadingHasBegunWhereNothingIsSaidBeforeIt() {
        let text = "\n \nTides\n\nThe tides are noted here."
        let cases: [(name: String, heading: Heading, begun: Bool)] = [
            ("in an earlier chapter", Heading(level: 1, text: "Moorings", chapterIndex: 2, characterOffset: 40), true),
            ("at the chapter's start", Heading(level: 1, text: "Tides", chapterIndex: 3, characterOffset: 0), true),
            ("after white space alone", Heading(level: 1, text: "Tides", chapterIndex: 3, characterOffset: 3), true),
            ("after words", Heading(level: 2, text: "Tide Tables", chapterIndex: 3, characterOffset: 12), false),
            ("in a later chapter", Heading(level: 1, text: "Quays", chapterIndex: 4, characterOffset: 0), false),
        ]
        for heading in cases {
            XCTAssertEqual(
                ReaderViewModel.headingHasBegun(heading.heading, atStartOfChapter: 3, text: text),
                heading.begun,
                heading.name
            )
        }
    }

    // MARK: - Two Readers of One Book

    /// The timer belongs to the reader that set it, not to its book (TODO
    /// P01). The owner of the timer plays until the other window of its
    /// book takes over, which pauses the owner, since only one reader plays
    /// at a time. The end of a chapter in the other window then neither
    /// stops that window nor ends the timer, and the owner, played again,
    /// stops where its own chapter ends. Before the repair the timer was the
    /// book's, so the other window's chapter end ended it and stopped the
    /// wrong window.
    func testTheTimerBelongsToTheReaderThatSetItNotToItsBook() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("Sleep Timer Two Readers")
        world.settings.sleepFadeOutDuration = 0
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [0.5, 2.5, 5])
        let owner = world.openReader(for: book)
        let other = world.openReader(for: book)
        waitForReaderToLoad(owner)
        waitForReaderToLoad(other)
        defer {
            owner.stop()
            other.stop()
        }
        owner.navigateTo(chapterIndex: 1, characterOffset: 0)

        let recorder = recordingAnnouncements {
            owner.startSleepTimer(duration: .endOfChapter)
            owner.play()
            other.play()
            XCTAssertTrue(owner.isCurrentlyPaused, "Playing the other window did not pause the owner")
            XCTAssertTrue(
                eventually(within: 10) { other.currentChapterIndex == 1 },
                "The other window's first chapter never ended"
            )
            XCTAssertTrue(other.audioPlaybackService.isPlaying, "The other window stopped at its own chapter's end")
            XCTAssertFalse(other.isCurrentlyPaused, "The other window paused at its own chapter's end")
            XCTAssertTrue(timer.isActive, "The other window's chapter end ended the timer")
            XCTAssertEqual(owner.currentChapterIndex, 1, "The other window's chapter end moved the owner")

            owner.togglePlayPause()
            XCTAssertTrue(owner.audioPlaybackService.isPlaying, "The owner did not play again")
            XCTAssertTrue(eventually(within: 10) { owner.currentChapterIndex == 2 }, "The owner's chapter never ended")
            XCTAssertFalse(owner.audioPlaybackService.isPlaying, "The owner played on past its chapter's end")
            XCTAssertFalse(owner.isCurrentlyPlaying)
        }

        XCTAssertEqual(
            recorder.announcements.map(\.message),
            ["Sleep timer expired at the end of the chapter. Playback paused."]
        )
        XCTAssertFalse(timer.isActive)
        XCTAssertEqual(other.currentChapterIndex, 1, "The owner's chapter end moved the other window")
    }

    /// Restart Sleep Timer from a media gesture, which belongs to no window,
    /// goes to the reader that set the last timer, not to every reader of
    /// its book. Once that reader closes, which stops its timer, the gesture
    /// goes to the reader left, which starts a timer of the last duration.
    func testRestartFromAMediaGestureGoesToTheReaderThatSetTheTimer() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("Sleep Timer Restart Route")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [30])
        let owner = world.openReader(for: book)
        let other = world.openReader(for: book)
        waitForReaderToLoad(owner)
        waitForReaderToLoad(other)
        defer { other.stop() }
        owner.startSleepTimer(duration: .minutes(30))

        let restart = recordingAnnouncements {
            world.notifications.post(name: .restartSleepTimer, object: nil)
        }
        XCTAssertEqual(restart.announcements.map(\.message), ["Timer reset."], "Not just the owner restarted the timer")
        XCTAssertEqual(timer.ownerID, owner.readerID)

        owner.close()
        XCTAssertFalse(timer.isActive, "Closing the owner's window left its timer running")
        let restartAfterClosing = recordingAnnouncements {
            world.notifications.post(name: .restartSleepTimer, object: nil)
        }
        XCTAssertEqual(restartAfterClosing.announcements.map(\.message), ["Timer restarted: 30 minutes."])
        XCTAssertEqual(timer.ownerID, other.readerID)
        XCTAssertEqual(timer.duration, .minutes(30))
    }

    // MARK: - Helpers

    /// Counts each time `reader` goes from not paused to paused from now on.
    /// - Returns: A function reading the count so far.
    private func countPauses(of reader: ReaderViewModel) -> () -> Int {
        var count = 0
        reader.$isCurrentlyPaused
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { _ in count += 1 }
            .store(in: &subscriptions)
        return { count }
    }

    /// Check that the library holds `book`'s position as `chapter` and
    /// `offset`, as the reader last saved it.
    private func assertSavedPlace(
        of book: Book,
        in world: IntegrationWorld,
        chapter: Int,
        offset: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let saved = try XCTUnwrap(
            world.library.bookByID(book.id)?.readingPosition,
            "No position was saved",
            file: file,
            line: line
        )
        XCTAssertEqual(saved.chapterIndex, chapter, "The saved chapter", file: file, line: line)
        XCTAssertEqual(saved.characterOffset, offset, "The saved offset", file: file, line: line)
    }

    /// What an audiobook's reader left its audio service playing at one
    /// reported position.
    private struct VolumeSample {
        /// Seconds of listening left before what the service plays ends.
        let secondsLeft: TimeInterval
        /// The volume it plays at.
        let volume: Float
    }

    /// Record, from now on, the time left and the volume each time `reader`'s
    /// audio service reports a position, once the reader has handled it.
    ///
    /// - Returns: A function reading the samples so far, oldest first.
    private func recordVolumes(of reader: ReaderViewModel) throws -> () -> [VolumeSample] {
        let service = reader.audioPlaybackService
        let readerHandles = try XCTUnwrap(service.onPositionUpdate, "The reader takes no position reports")
        var samples: [VolumeSample] = []
        service.onPositionUpdate = { [weak service] time in
            readerHandles(time)
            guard let service, let left = service.timeLeftToPlay, service.playbackSpeed > 0 else { return }
            samples.append(VolumeSample(secondsLeft: left / service.playbackSpeed, volume: service.intendedVolume))
        }
        return { samples }
    }

    /// Whether the next book is asked for, as `continued` records the
    /// requests, within twice the time a finished book takes to ask for it:
    /// a wait that ends as soon as one is asked for, and otherwise shows that
    /// none was.
    private func nextBookIsAskedFor(_ continued: () -> [Notification]) -> Bool {
        eventually(within: ReaderViewModel.continueToNextBookDelay * 2) { !continued().isEmpty }
    }

    /// Record every `.continueToNextBook` posted in `world` from now on.
    ///
    /// - Returns: A function reading the notifications posted so far.
    private func recordContinueRequests(in world: IntegrationWorld) -> () -> [Notification] {
        var posted: [Notification] = []
        world.notifications.publisher(for: .continueToNextBook)
            .sink { posted.append($0) }
            .store(in: &subscriptions)
        return { posted }
    }

    // MARK: - A Text Book's Reader

    /// The surroundings of a test of a text book's reader.
    private struct SpeechWorld {
        /// The world the reader belongs to.
        let world: IntegrationWorld
        /// The reader, loaded with the test's chapters.
        let reader: ReaderViewModel
        /// The book the reader reads.
        let book: Book
        /// The book after it in its folder, where Continue to Next Book goes.
        let nextBook: Book
    }

    /// Run `body` with a reader of a text book of `chapters`, three short
    /// ones with no headings unless the test gives its own, in a world of
    /// its own whose folder holds another book after it.
    ///
    /// The reader's content is given to it directly: the book names a file
    /// that is not there, so the reader's own load fails before the content
    /// is given, and nothing is read from disk. Its look-ahead renders are
    /// held, never rendered, and a test silences its speech before the main
    /// run loop turns (`startSpeakingSilently`, `endSpeechSilently`), so
    /// nothing is ever heard.
    ///
    /// - Parameters:
    ///   - label: Names the world's folder, config, and preferences.
    ///   - endOfBook: What the book does when its last chapter ends.
    ///   - fadeSeconds: The sleep timer's fade-out setting.
    ///   - chapters: The book's chapters.
    private func withSpeechReader(
        _ label: String,
        endOfBook: EndOfBookBehavior = .stop,
        fadeSeconds: TimeInterval = 0,
        chapters: [Chapter] = ["Bollard", "Capstan", "Davit"].map {
            Chapter(title: $0, text: "The \($0.lowercased()) is noted here.")
        },
        _ body: (SpeechWorld) throws -> Void
    ) throws {
        let world = try makeIntegrationWorld(label)
        world.settings.sleepFadeOutDuration = fadeSeconds
        let book = listTextBook(titled: "Quay Notes", in: world, endOfBook: endOfBook)
        let nextBook = listTextBook(titled: "Slipway Notes", in: world, endOfBook: .stop)
        let reader = world.openReader(for: book, renderScheduler: HeldRenderQueue())
        waitForReaderToLoad(reader)
        reader.errorMessage = nil
        reader.content = DocumentContent(title: book.title, author: "Test Author", chapters: chapters)
        try body(SpeechWorld(world: world, reader: reader, book: book, nextBook: nextBook))
    }

    /// A chapter with two headings, Moorings at its start and Tides further
    /// on, and where Tides begins.
    private func harbourChapter() -> (chapter: Chapter, tidesOffset: Int) {
        let text = "Moorings\n\nThe moorings are noted here. Each one is checked.\n\nTides\n\nThe tides are noted here."
        let tidesOffset = (text as NSString).range(of: "Tides").location
        let chapter = Chapter(
            title: "Harbour",
            text: text,
            headings: [
                Heading(level: 1, text: "Moorings"),
                Heading(level: 1, text: "Tides", characterOffset: tidesOffset),
            ]
        )
        return (chapter, tidesOffset)
    }

    /// A text book titled `title`, listed in `world`'s folder, whose file is
    /// not there.
    private func listTextBook(titled title: String, in world: IntegrationWorld, endOfBook: EndOfBookBehavior) -> Book {
        let book = Book(
            title: title,
            format: .txt,
            filePath: world.folder.path + "/\(UUID().uuidString) missing.txt",
            md5Hash: UUID().uuidString,
            folderPath: world.folder.path,
            localEndOfBookBehavior: endOfBook.rawValue
        )
        world.library.library.addBook(book)
        return book
    }

    /// Start `reader` speaking from its cursor, then stop its speech before
    /// the main run loop turns, so nothing is heard. The chapter play stays
    /// under way, with its look-ahead.
    ///
    /// - Returns: The end of that chapter's speech, to report as the speech
    ///   service reports it once the chapter has been spoken.
    private func startSpeakingSilently(_ reader: ReaderViewModel) throws -> () -> Void {
        reader.play()
        let endOfChapter = try XCTUnwrap(reader.speechService.onUtteranceFinished, "Speech did not start")
        reader.speechService.stop()
        return endOfChapter
    }

    /// Report the end of a chapter's speech through `endOfChapter`, then stop
    /// anything `reader` began speaking in reply before the main run loop
    /// turns, so nothing is heard.
    ///
    /// - Returns: Whether the reader went on speaking.
    private func endSpeechSilently(_ endOfChapter: () -> Void, of reader: ReaderViewModel) -> Bool {
        endOfChapter()
        let spokeOn = reader.speechService.isSpeaking
        reader.speechService.stop()
        return spokeOn
    }
}

// MARK: - The Sleep Timer Sheet's Stop At Section

/// The sleep timer sheet's Stop At section as VoiceOver meets it (TODO
/// P01): an End of chapter and an End of book button, each labelled with
/// what it does and given a hint, the End of book hint saying what the timer
/// adds to what the book does at its end on its own; pressing one sets that
/// timer for the reader, starts playback, and announces where it stops; and
/// the sheet's status line then reads where the timer stops playback.
/// SwiftUI builds the accessibility elements of its buttons only for a
/// connected assistive app, so the test that presses them skips, rather
/// than fails, when it exposes none; the wording tests cover every label
/// either way. The book is silent audio, so starting playback is not heard.
@MainActor
final class SleepTimerSheetTests: XCTestCase {

    // MARK: - Wording

    /// Each Stop At button names what it does, and its hint says when it
    /// pauses playback; the End of book hint follows the book's end-of-book
    /// behavior, and says so when the book stops at its end on its own.
    func testStopAtButtonsSayWhatTheyDo() {
        XCTAssertEqual(SleepTimerView.stopAtHeading, "Stop At")
        XCTAssertEqual(SleepTimerView.endOfChapterTitle, "End of chapter")
        XCTAssertEqual(SleepTimerView.endOfChapterLabel, "Stop at the end of this chapter and start playing")
        XCTAssertEqual(
            SleepTimerView.endOfChapterHint,
            "Pauses playback when the chapter playing now ends, before the next chapter starts."
        )
        XCTAssertEqual(SleepTimerView.endOfBookTitle, "End of book")
        XCTAssertEqual(SleepTimerView.endOfBookLabel, "Stop at the end of the book and start playing")
        XCTAssertEqual(
            SleepTimerView.endOfBookHint(for: .continueNext),
            "Pauses playback when this book ends, before Continue to Next Book starts the next book."
        )
        XCTAssertEqual(
            SleepTimerView.endOfBookHint(for: .loop),
            "Pauses playback when this book ends, before Loop to Start plays it again."
        )
        XCTAssertEqual(
            SleepTimerView.endOfBookHint(for: .stop),
            "This book already stops playing at its end, since Continue to Next Book is off; the timer stops it there too."
        )
    }

    /// Setting a timer for a place in the book announces where it stops
    /// playback; a timer counting minutes announces its minutes, as before.
    /// Reset Timer announces the restarted timer's status.
    func testSettingATimerAnnouncesWhatWasSet() {
        XCTAssertEqual(
            SleepTimerView.announcement(forSetting: .endOfChapter),
            "Sleep timer: stops at the end of this chapter."
        )
        XCTAssertEqual(SleepTimerView.announcement(forSetting: .endOfBook), "Sleep timer: stops at the end of the book.")
        XCTAssertEqual(
            SleepTimerView.announcement(forSetting: .endOfHeading),
            "Sleep timer: set for the end of the heading."
        )
        XCTAssertEqual(SleepTimerView.announcement(forSetting: .minutes(15)), "Timer set for 15 minutes.")
        XCTAssertEqual(SleepTimerView.resetAnnouncement(status: "15:00 remaining"), "Timer reset: 15:00 remaining.")
        XCTAssertEqual(
            SleepTimerView.resetAnnouncement(status: "stops at the end of the book"),
            "Timer reset: stops at the end of the book."
        )
    }

    // MARK: - The Rendered Sheet

    /// In the sheet, after the minute presets, End of chapter and End of
    /// book come with their labels and hints, the End of book hint for a
    /// book that continues to the next. Pressing End of chapter through
    /// accessibility sets that timer for this reader and announces it once;
    /// the status line then reads where the timer stops; pressing End of
    /// book replaces it.
    func testStopAtButtonsAreLabelledAndSetTheirTimers() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("Sleep Timer Sheet")
        world.settings.sleepFadeOutDuration = 0
        let book = try world.makeSilentAudioBook(
            title: "Ferry Timetable",
            trackDurations: [30],
            endOfBook: .continueNext
        )
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        defer { reader.stop() }
        let sheet = SleepTimerView(
            viewModel: reader,
            sleepTimerService: timer,
            onStartPlayback: {},
            onClose: {},
            autoClose: false
        )

        try skipUnlessHostedWindowsExposeAccessibility()
        try withHostedView(sheet, until: { self.stopAtButtons(in: $0) != nil }) { hostingView in
            guard let buttons = stopAtButtons(in: hostingView) else {
                throw XCTSkip("SwiftUI exposed no buttons to accessibility in this run")
            }
            XCTAssertEqual(buttons.endOfChapter.hint, SleepTimerView.endOfChapterHint)
            XCTAssertEqual(buttons.endOfBook.hint, SleepTimerView.endOfBookHint(for: .continueNext))
            let labels = accessibleControls(in: hostingView).map(\.label)
            let lastPreset = try XCTUnwrap(labels.lastIndex(of: "Set timer for 60 minutes and start playing"))
            let chapterIndex = try XCTUnwrap(labels.firstIndex(of: SleepTimerView.endOfChapterLabel))
            let bookIndex = try XCTUnwrap(labels.firstIndex(of: SleepTimerView.endOfBookLabel))
            XCTAssertLessThan(lastPreset, chapterIndex, "Stop At does not follow the minute presets: \(labels)")
            XCTAssertLessThan(chapterIndex, bookIndex, "End of book comes before End of chapter: \(labels)")

            let setChapter = recordingAnnouncements {
                XCTAssertTrue(buttons.endOfChapter.element.accessibilityPerformPress())
                XCTAssertTrue(waitUntil { timer.duration == .endOfChapter }, "Pressing End of chapter set no timer")
            }
            XCTAssertEqual(setChapter.announcements.map(\.message), ["Sleep timer: stops at the end of this chapter."])
            XCTAssertEqual(timer.ownerID, reader.readerID, "The timer is not this reader's")
            XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Pressing End of chapter did not start playback")

            let status = "Sleep timer: stops at the end of this chapter"
            XCTAssertTrue(
                waitUntil { !self.accessibilityElements(labelled: status, in: hostingView).isEmpty },
                "The status line does not say where the timer stops"
            )

            // The sheet drew its Current Timer section, so its buttons are
            // found again rather than pressed through elements it replaced.
            guard let redrawn = stopAtButtons(in: hostingView) else {
                XCTFail("The Stop At buttons went missing once a timer was set")
                return
            }
            let setBook = recordingAnnouncements {
                XCTAssertTrue(redrawn.endOfBook.element.accessibilityPerformPress())
                XCTAssertTrue(waitUntil { timer.duration == .endOfBook }, "Pressing End of book set no timer")
            }
            XCTAssertEqual(setBook.announcements.map(\.message), ["Sleep timer: stops at the end of the book."])
        }
    }

    // MARK: - Helpers

    /// The End of chapter and End of book buttons among the controls
    /// VoiceOver finds below `root`, or nil while either is missing.
    private func stopAtButtons(in root: NSView) -> (endOfChapter: AccessibleControl, endOfBook: AccessibleControl)? {
        let buttons = accessibleControls(in: root).filter { $0.role == .button }
        guard let endOfChapter = buttons.first(where: { $0.label == SleepTimerView.endOfChapterLabel }),
              let endOfBook = buttons.first(where: { $0.label == SleepTimerView.endOfBookLabel }) else { return nil }
        return (endOfChapter, endOfBook)
    }
}
