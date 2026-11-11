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
/// there, for text and audio alike (TODO P01, findings #676 and #787): at
/// the end of the heading playing, where the next heading begins or the
/// book ends, or at the end of the book, before the book starts again or
/// the next book does; and it belongs to the reader that set it, not to its
/// book. The heading is one concept for every kind of document (October 6,
/// 2026, when End of chapter folded into End of heading): a text book's
/// headings of any level, and an audiobook's chapters, each of which begins
/// with its heading, so an audiobook's heading ends where its chapter does.
/// Audiobooks play real, silent tracks; a text book's speech is stopped
/// before the main run loop turns, and its look-ahead renders are held; so
/// nothing is ever heard.
@MainActor
final class IntegrationSleepTimerTests: XCTestCase {
    /// Subscriptions the test keeps until it ends.
    private var subscriptions = Set<AnyCancellable>()

    /// What the listener hears when the timer stops playback where the
    /// heading ends, wherever that end comes, in the tests' own words.
    private static let headingEndAnnouncement = "Sleep timer expired at the end of the heading. Playback paused."

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

        // The positive waits below allow a busy Mac thirty seconds, and end
        // as soon as their conditions hold.
        let recorder = recordingAnnouncements {
            ownerReader.play()
            XCTAssertTrue(
                waitUntil(timeout: 30) { ownerReader.audioPlaybackService.isPlaying },
                "Night Reading never started playing"
            )
            ownerReader.startSleepTimer(duration: .minutes(1))
            // One second left on the clock: the next tick expires it.
            timer.remainingSeconds = 1
            XCTAssertTrue(waitUntil(timeout: 30) { timer.isFadingOut }, "The timer never began to fade out")

            otherReader.close()

            XCTAssertTrue(
                waitUntil(timeout: 30) { ownerReader.isCurrentlyPaused },
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

    // MARK: - Stopping Where a Heading Ends With Its Chapter (TODO P01, findings #676 and #787)

    /// An audiobook's chapters are its headings, so a timer set for the end
    /// of the heading, with the default fade of no seconds, stops the
    /// audiobook where the chapter playing ends, before the next one starts,
    /// once. The listener hears once that the timer stopped playback at the
    /// heading's end, the timer has ended, the next chapter's file is never
    /// named to follow nor played, and the cursor waits, saved, at the
    /// beginning of the next chapter, where Play then starts it.
    ///
    /// Before the repair of finding #676 the timer announced a pause that
    /// paused nothing, since the chapter's audio had already finished, and
    /// the next chapter played on.
    func testEndOfHeadingTimerStopsAnAudiobookWhereItsChapterEnds() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("Sleep Timer Heading End Audio")
        world.settings.sleepFadeOutDuration = 0
        let book = try world.makeSilentAudioBook(title: "Ferry Timetable", trackDurations: [0.6, 5])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let service = reader.audioPlaybackService
        let firstChapterFile = Array(reader.audioChapterFiles.prefix(1).map(resolvedPath))
        let secondChapterFile = try XCTUnwrap(reader.audioChapterFiles.last.map(resolvedPath))
        defer { reader.stop() }

        let recorder = recordingAnnouncements {
            reader.startSleepTimer(duration: .endOfHeading)
            reader.play()
            XCTAssertTrue(service.isPlaying, "The first chapter did not play")
            XCTAssertEqual(service.queuedFilePaths, firstChapterFile, "The next chapter's file was named to follow")
            XCTAssertTrue(eventually(within: 10) { reader.currentChapterIndex == 1 }, "The first heading never ended")
            XCTAssertFalse(service.isPlaying, "The next heading played")
            XCTAssertFalse(reader.isCurrentlyPlaying, "The reader shows the next heading playing")
            // Nothing may start a moment later either.
            XCTAssertFalse(
                eventually(within: 1) { service.isPlaying || reader.isCurrentlyPlaying },
                "Playback started again after the heading's end"
            )
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [Self.headingEndAnnouncement])
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

    /// The same for a text book whose chapters begin with their headings, as
    /// most EPUB chapters do: a timer set for the end of the heading stops
    /// speech where the chapter ends, since the next chapter opens with the
    /// next heading, with no fade even when one is set, since speech is not
    /// faded there. The next chapter is not spoken, the chapter rendered
    /// ahead is let go without playing, the timer has ended, and the cursor
    /// waits, saved, at the beginning of the next chapter. Before the repair
    /// the next chapter was spoken at once.
    func testEndOfHeadingTimerStopsSpeechWhereTheChapterEndsTheHeadingWithoutAFade() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
        for fadeSeconds: TimeInterval in [0, 5] {
            try withSpeechReader(
                "Sleep Timer Speech Fade \(Int(fadeSeconds))",
                fadeSeconds: fadeSeconds,
                chapters: headedChapters()
            ) { speech in
                let reader = speech.reader
                reader.startSleepTimer(duration: .endOfHeading)
                let endOfFirstChapter = try startSpeakingSilentlyUntilItsEnd(reader)
                XCTAssertNotNil(reader.lookAhead, "The next chapter was not looked ahead to")

                var spokeOn = false
                let recorder = recordingAnnouncements {
                    spokeOn = endSpeechSilently(endOfFirstChapter, of: reader)
                }

                let fade = "with a fade of \(fadeSeconds) seconds"
                XCTAssertFalse(spokeOn, "The next heading was spoken \(fade)")
                XCTAssertEqual(recorder.announcements.map(\.message), [Self.headingEndAnnouncement], fade)
                XCTAssertFalse(timer.isActive, "The timer is still in effect \(fade)")
                XCTAssertFalse(timer.isFadingOut, "Speech faded out \(fade)")
                XCTAssertNil(reader.lookAhead, "The chapter rendered ahead was kept \(fade)")
                XCTAssertEqual(reader.currentChapterIndex, 1, fade)
                XCTAssertEqual(reader.currentCharacterOffset, 0, fade)
                try assertSavedPlace(of: speech.book, in: speech.world, chapter: 1, offset: 0)
            }
        }
    }

    /// A timer set for the end of the heading in the book's last heading,
    /// which begins its last chapter, stops playback where the book ends,
    /// which ends that heading, whatever the book does at its end: it
    /// neither starts again nor continues to the next book. The listener
    /// hears once that the book finished and why nothing follows, and the
    /// timer has ended.
    func testEndOfHeadingTimerInTheLastChapterEndsListeningWithTheBook() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
        let outcomes: [(behavior: EndOfBookBehavior, announcement: String, chapterAfter: Int)] = [
            (.stop, "Finished: Quay Notes. Sleep timer expired.", 2),
            (.loop, "Finished: Quay Notes. Not restarted because of the sleep timer.", 0),
            (.continueNext, "Finished: Quay Notes. Next book not started because of the sleep timer.", 2),
        ]
        for outcome in outcomes {
            let label = "Sleep Timer Book End \(outcome.behavior.rawValue)"
            try withSpeechReader(label, endOfBook: outcome.behavior, chapters: headedChapters()) { speech in
                let reader = speech.reader
                let continued = recordContinueRequests(in: speech.world)
                reader.navigateTo(chapterIndex: 2, characterOffset: 0)
                reader.startSleepTimer(duration: .endOfHeading)
                let endOfLastChapter = try startSpeakingSilentlyUntilItsEnd(reader)

                var spokeOn = false
                var askedForTheNextBook = false
                let recorder = recordingAnnouncements {
                    spokeOn = endSpeechSilently(endOfLastChapter, of: reader)
                    askedForTheNextBook = nextBookAskedSoFar(continued)
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
    /// that much of the chapter is left where an End of heading timer stops
    /// it, at the chapter's end, then fades evenly with the time left, so the
    /// stop comes in silence. The volume is back to full for the next
    /// chapter.
    func testEndOfHeadingTimerFadesAnAudiobookOutOverTheLastSecondsOfItsChapter() throws {
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
            reader.startSleepTimer(duration: .endOfHeading)
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
        XCTAssertEqual(recorder.announcements.map(\.message), [Self.headingEndAnnouncement])
        XCTAssertFalse(timer.isActive)
        XCTAssertFalse(service.isPlaying, "The next chapter played")
        XCTAssertEqual(service.intendedVolume, 1, "The volume was not put back for the next chapter")
    }

    /// Cancelling an End of heading timer while it fades an audiobook out
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

        reader.startSleepTimer(duration: .endOfHeading)
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

    /// Pausing while an End of heading timer fades the audio out keeps the
    /// timer, which waits for a place rather than counting time: playing
    /// again goes on fading from where the fade was, and stops at the
    /// chapter's end, where the heading ends.
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
            reader.startSleepTimer(duration: .endOfHeading)
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

        XCTAssertEqual(recorder.announcements.map(\.message), [Self.headingEndAnnouncement])
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
                askedForTheNextBook = nextBookAskedSoFar(continued)
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
                let endOfSecondChapter = try startSpeakingSilentlyUntilItsEnd(reader)

                var spokeTheLastChapter = false
                var spokeAfterTheBook = false
                var askedForTheNextBook = false
                let recorder = recordingAnnouncements {
                    spokeTheLastChapter = endSpeechSilently(endOfSecondChapter, of: reader)
                    XCTAssertEqual(reader.currentChapterIndex, 2, "\(behavior): the last chapter did not start")
                    if let endOfLastChapter = reader.speechService.onUtteranceFinished {
                        spokeAfterTheBook = endSpeechSilently(endOfLastChapter, of: reader)
                    }
                    askedForTheNextBook = nextBookAskedSoFar(continued)
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
    /// which heading the cursor is in, and not at the chapter's end, which
    /// is where End of chapter stopped before it folded into End of heading
    /// (October 6, 2026). Speech has run a moment past the next heading's
    /// start by then, so the cursor goes back to it, saved, for Play to
    /// begin that heading from its first word. Before the repair playback
    /// crossing a heading told the timer nothing, so it never stopped a book
    /// playing on its own.
    func testEndOfHeadingTimerStopsSpeechWhereTheHeadingEndsWithinAChapter() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
        let harbour = harbourChapter()
        let quays = Chapter(title: "Quays", text: "Quays\n\nThe quays are noted here.", headings: [Heading(level: 1, text: "Quays")])
        try withSpeechReader("Sleep Timer Heading End Speech", chapters: [harbour.chapter, quays]) { speech in
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
                [VoiceOverAnnouncement(message: Self.headingEndAnnouncement, priority: .high)]
            )
            XCTAssertFalse(timer.isActive, "The timer is still in effect")
            XCTAssertEqual(timer.lastUsedDuration, .endOfHeading)
            XCTAssertEqual(reader.currentChapterIndex, 0, "The cursor left the chapter: the timer waited for its end")
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
                // The timer's end is said on the main queue's next turn,
                // which a busy Mac can put off: the wait allows thirty
                // seconds, and ends as soon as it is said.
                XCTAssertTrue(
                    waitUntil(timeout: 30) { reader.lastAnnouncement != "Heading: Tides" },
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
            // half of the chapter, at ten characters a second. The wait
            // allows a busy Mac thirty seconds, and ends once it is past.
            XCTAssertTrue(eventually(within: 30) { reader.currentCharacterOffset > 15 }, "The first chapter did not play on")
            reader.previousHeading()
            XCTAssertTrue(service.isPlaying, "The jump back to the heading's start stopped playback")
            XCTAssertTrue(timer.isActive, "The jump back to the heading's start ended the timer")

            reader.nextHeading()
            XCTAssertFalse(service.isPlaying, "The next heading played")
            XCTAssertFalse(timer.isActive, "The jump out of the heading did not end the timer")
            // The timer's end is said on the main queue's next turn: once
            // the main queue has run what was queued so far, it is said.
            handleQueuedCallbacks()
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

    /// Where End of chapter and End of heading differed, the one timer keeps
    /// the heading's meaning (October 6, 2026): a next chapter that has text
    /// before its first heading goes on under the heading playing, so speech
    /// goes on into it at the chapter's end, the timer still in effect and
    /// nothing said, and stops where that chapter's heading begins, once,
    /// the cursor waiting there, saved.
    func testEndOfHeadingTimerGoesOnIntoAChapterWithTextBeforeItsFirstHeading() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
        let opening = Chapter(
            title: "Bollard",
            text: "Bollard\n\nThe bollard is noted here.",
            headings: [Heading(level: 1, text: "Bollard")]
        )
        let continuation = "The bollard's rope is noted here too.\n\nCapstan\n\nThe capstan is noted here."
        let capstanOffset = (continuation as NSString).range(of: "Capstan").location
        let next = Chapter(
            title: "Capstan",
            text: continuation,
            headings: [Heading(level: 1, text: "Capstan", characterOffset: capstanOffset)]
        )
        try withSpeechReader("Sleep Timer Heading Into Next Chapter", chapters: [opening, next]) { speech in
            let reader = speech.reader
            reader.startSleepTimer(duration: .endOfHeading)
            let endOfFirstChapter = try startSpeakingSilentlyUntilItsEnd(reader)

            var spokeOn = false
            let atTheChapterEnd = recordingAnnouncements {
                endOfFirstChapter()
                spokeOn = reader.speechService.isSpeaking
            }
            XCTAssertTrue(spokeOn, "Speech stopped at the chapter's end, under the same heading")
            XCTAssertTrue(timer.isActive, "The chapter's end ended the timer")
            XCTAssertEqual(atTheChapterEnd.announcements, [])
            XCTAssertEqual(reader.currentChapterIndex, 1)

            // The first word after the Capstan heading is about to be spoken,
            // and the reader's next refresh of its view of the cursor comes.
            let wordAfterTheHeading = capstanOffset + "Capstan\n\n".utf16.count
            var spokeIntoTheHeading = true
            let atTheHeading = recordingAnnouncements {
                let spokenOffset = reader.currentOffsetMap?.toModified(wordAfterTheHeading) ?? wordAfterTheHeading
                reader.speechService.onWordSpoken?(NSRange(location: spokenOffset, length: 3), "The")
                reader.stopForSleepTimerIfPlaybackReachedHeadingEnd()
                spokeIntoTheHeading = reader.speechService.isSpeaking
                reader.speechService.stop()
            }
            XCTAssertFalse(spokeIntoTheHeading, "Speech went on into the next heading")
            XCTAssertEqual(atTheHeading.announcements.map(\.message), [Self.headingEndAnnouncement])
            XCTAssertFalse(timer.isActive, "The timer is still in effect")
            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertEqual(reader.currentCharacterOffset, capstanOffset, "The cursor is not at the next heading")
            try assertSavedPlace(of: speech.book, in: speech.world, chapter: 1, offset: capstanOffset)
        }
    }

    /// The concept reaches beyond EPUB: a Markdown file's headings, as the
    /// Markdown parser reads them, are where its headings end, whatever
    /// their level. A timer for the end of the heading set under a level-1
    /// heading stops speech where the level-2 heading after it begins, once,
    /// and the cursor waits there, at the offset the parser gave the heading.
    func testEndOfHeadingTimerStopsAMarkdownBookWhereTheNextHeadingOfAnyLevelBegins() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
        let markdown = """
        # Moorings

        The moorings are noted here. Each one is checked.

        ## Tide Tables

        The tides are noted here.
        """
        let chapter = try MarkdownDocParser.parseChapter(markdown: markdown, title: "Harbour")
        let tideTables = try XCTUnwrap(
            chapter.headings.first { $0.text == "Tide Tables" },
            "The Markdown parser found no Tide Tables heading: \(chapter.headings)"
        )
        XCTAssertEqual(tideTables.level, 2)
        XCTAssertEqual(tideTables.characterOffset, (chapter.text as NSString).range(of: "Tide Tables").location)
        let wordAfterTheHeading = (chapter.text as NSString).range(of: "The tides").location
        try withSpeechReader("Sleep Timer Heading Markdown", chapters: [chapter]) { speech in
            let reader = speech.reader
            reader.startSleepTimer(duration: .endOfHeading)

            var spokeOn = true
            let recorder = recordingAnnouncements {
                reader.play()
                let spokenOffset = reader.currentOffsetMap?.toModified(wordAfterTheHeading) ?? wordAfterTheHeading
                reader.speechService.onWordSpoken?(NSRange(location: spokenOffset, length: 3), "The")
                reader.stopForSleepTimerIfPlaybackReachedHeadingEnd()
                spokeOn = reader.speechService.isSpeaking
                reader.speechService.stop()
            }

            XCTAssertFalse(spokeOn, "Speech went on into the next heading")
            XCTAssertEqual(recorder.announcements.map(\.message), [Self.headingEndAnnouncement])
            XCTAssertFalse(timer.isActive, "The timer is still in effect")
            XCTAssertEqual(reader.currentChapterIndex, 0)
            XCTAssertEqual(reader.currentCharacterOffset, tideTables.characterOffset, "The cursor is not at the next heading")
            try assertSavedPlace(of: speech.book, in: speech.world, chapter: 0, offset: tideTables.characterOffset)
        }
    }

    /// An audiobook whose chapters share one file, an m4b with chapter
    /// markers, has one heading per marker (`AudioBookParser`), so a timer
    /// for the end of the heading stops it at the next marker, once, as the
    /// reader's view of the cursor learns that playback crossed it: the file
    /// reports no end at a marker, so the stop comes a moment past it, and
    /// the cursor goes back to the marker, saved, where Play starts the next
    /// chapter. The listener hears the heading's end, not the book's.
    func testEndOfHeadingTimerStopsAnM4BAtItsNextChapterMarker() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("Sleep Timer Heading M4B")
        world.settings.sleepFadeOutDuration = 0
        let book = try makeChapteredAudioBook(
            title: "Harbour Lectures",
            in: world,
            duration: 6,
            markers: [
                AudioTestFixtures.ChapterMarker(title: "Harbour Approach", start: 0, duration: 1),
                AudioTestFixtures.ChapterMarker(title: "Breakwater Survey", start: 1, duration: 5),
            ]
        )
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let service = reader.audioPlaybackService
        defer { reader.stop() }
        XCTAssertEqual(reader.audioLayout, .chaptersInOneFile)
        XCTAssertEqual(reader.headings.map(\.chapterIndex), [0, 1], "The markers are not the book's headings")

        // The waits for playback to start allow a busy Mac thirty seconds,
        // and end as soon as it plays.
        let recorder = recordingAnnouncements {
            reader.startSleepTimer(duration: .endOfHeading)
            reader.play()
            XCTAssertTrue(waitUntil(timeout: 30) { service.isPlaying }, "The book did not play")
            XCTAssertTrue(eventually(within: 10) { !service.isPlaying && !reader.isCurrentlyPlaying }, "Playback never stopped")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [Self.headingEndAnnouncement])
        XCTAssertFalse(timer.isActive, "The timer is still in effect")
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentCharacterOffset, 0)
        try assertSavedPlace(of: book, in: world, chapter: 1, offset: 0)

        reader.togglePlayPause()
        XCTAssertTrue(waitUntil(timeout: 30) { service.isPlaying }, "Play did not start the next chapter")
        XCTAssertEqual(reader.currentChapterIndex, 1)
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
                let endOfFirstChapter = try startSpeakingSilentlyUntilItsEnd(reader)

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
            let endOfTheBook = try startSpeakingSilentlyUntilItsEnd(reader)

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

    /// A book with no headings at all, such as a plain-text file without
    /// structure, is one heading's worth of text: a timer for the end of
    /// the heading set in it lets speech go on from chapter to chapter and
    /// stops it where the book ends, as one set for the end of the book
    /// does, and the listener hears once that the book finished and why.
    func testEndOfHeadingTimerInABookWithNoHeadingsStopsWhereTheBookEnds() throws {
        preserveSharedSleepTimer()
        let timer = SleepTimerService.shared
        try withSpeechReader("Sleep Timer Heading No Headings") { speech in
            let reader = speech.reader
            XCTAssertTrue(reader.headings.isEmpty, "The book has headings: \(reader.headings)")
            reader.startSleepTimer(duration: .endOfHeading)
            let endOfFirstChapter = try startSpeakingSilentlyUntilItsEnd(reader)

            var spokeOn: [Bool] = []
            let recorder = try recordingAnnouncements {
                spokeOn.append(endSpeechSilently(endOfFirstChapter, of: reader))
                let endOfSecondChapter = try XCTUnwrap(reader.speechService.onUtteranceFinished, "The second chapter did not start")
                spokeOn.append(endSpeechSilently(endOfSecondChapter, of: reader))
                let endOfTheBook = try XCTUnwrap(reader.speechService.onUtteranceFinished, "The last chapter did not start")
                spokeOn.append(endSpeechSilently(endOfTheBook, of: reader))
            }

            XCTAssertEqual(spokeOn, [true, true, false], "Speech did not go on to the last chapter and stop with the book")
            XCTAssertEqual(recorder.announcements.map(\.message), ["Finished: Quay Notes. Sleep timer expired."])
            XCTAssertFalse(timer.isActive, "The timer is still in effect")
            XCTAssertEqual(reader.currentChapterIndex, 2)
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

    // MARK: - Where Nothing Is Read at the Start (November 11, 2026)

    /// A chapter of `text` whose headings (level 1) are the words `headings`,
    /// each found in the text after the one before, so a test names a
    /// heading once and its offset follows from the text.
    private func chapter(titled title: String, text: String, headings: [String]) -> Chapter {
        var searchFrom = 0
        let found = headings.map { heading -> Heading in
            let length = text.utf16.count - searchFrom
            let range = (text as NSString).range(of: heading, range: NSRange(location: searchFrom, length: length))
            searchFrom = range.location + range.length
            return Heading(level: 1, text: heading, characterOffset: range.location)
        }
        return Chapter(title: title, text: text, headings: found)
    }

    /// Set the End of heading timer in `reader`, start playing as Play does,
    /// and check what the listener meets:
    /// - the first refresh of the cursor, with Play's first words about to be
    ///   said, leaves the timer in effect and the speech going (before the
    ///   repair it stopped the book there, in silence, announcing "Sleep
    ///   timer expired at the end of the heading");
    /// - the speech then stops once, where `heading` begins, with the cursor
    ///   waiting at its start.
    ///
    /// - Parameters:
    ///   - heading: The heading the timer must stop at: the first after the
    ///     place where Play starts reading.
    ///   - reader: The reader, its cursor where the timer is set.
    ///   - name: Names the case in each failure.
    private func assertEndOfHeadingTimerSurvivesPlayStartAndStops(
        at heading: Heading,
        in reader: ReaderViewModel,
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let timer = SleepTimerService.shared
        reader.startSleepTimer(duration: .endOfHeading)

        var timerInEffectAtStart = false
        var spokeAtStart = false
        var spokeIntoTheHeading = true
        let recorder = recordingAnnouncements {
            reader.play()
            // The reader's first refresh of its view of the cursor, as Play's
            // first words are about to be said.
            reader.stopForSleepTimerIfPlaybackReachedHeadingEnd()
            timerInEffectAtStart = timer.isActive
            spokeAtStart = reader.speechService.isSpeaking
            // Then the first word of the heading the timer waits for.
            let spokenOffset = reader.currentOffsetMap?.toModified(heading.characterOffset) ?? heading.characterOffset
            reader.speechService.onWordSpoken?(NSRange(location: spokenOffset, length: 1), "x")
            reader.stopForSleepTimerIfPlaybackReachedHeadingEnd()
            spokeIntoTheHeading = reader.speechService.isSpeaking
            reader.speechService.stop()
        }

        XCTAssertTrue(timerInEffectAtStart, "\(name): the timer ended as Play started, in silence", file: file, line: line)
        XCTAssertTrue(spokeAtStart, "\(name): playback was stopped as it started", file: file, line: line)
        XCTAssertFalse(spokeIntoTheHeading, "\(name): speech went on into the heading \"\(heading.text)\"", file: file, line: line)
        XCTAssertEqual(
            recorder.announcements.map(\.message),
            [Self.headingEndAnnouncement],
            "\(name): the listener must hear the timer end once, at the heading",
            file: file,
            line: line
        )
        XCTAssertFalse(timer.isActive, "\(name): the timer is still in effect", file: file, line: line)
        XCTAssertEqual(reader.currentChapterIndex, heading.chapterIndex, "\(name): the cursor's chapter", file: file, line: line)
        XCTAssertEqual(
            reader.currentCharacterOffset,
            heading.characterOffset,
            "\(name): the cursor is not at \"\(heading.text)\"",
            file: file,
            line: line
        )
    }

    /// The heading named `text` in `reader`, or a failure naming the headings
    /// it has.
    private func heading(
        named text: String,
        in reader: ReaderViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Heading {
        try XCTUnwrap(
            reader.headings.first { $0.text == text },
            "No heading \"\(text)\" among \(reader.headings.map(\.text))",
            file: file,
            line: line
        )
    }

    /// The bug the iPhone's interface tests found, on a real EPUB as the
    /// parser reads it: a Project Gutenberg book opens at its cover, a chapter
    /// of one image and no words. A timer for the end of the heading, set
    /// there with "and start playing", saved the first heading after the cover,
    /// which is the heading Play begins in once it has passed the cover over.
    /// The first refresh of the cursor found that heading begun and stopped
    /// the book at once, in silence. The timer now waits for the heading
    /// after the one Play starts in.
    func testEndOfHeadingTimerSetAtAnImageOnlyCoverWaitsForTheHeadingPlayStartsIn() throws {
        preserveSharedSleepTimer()
        let epub = try TextPipelineFixtures.writeEPUB(Self.coverEPUBEntries(), named: "cover.epub", for: self)
        let content = try EPUBParser.parse(url: epub)
        XCTAssertEqual(content.chapters.count, 2, "The fixture's chapters: \(content.chapters.map(\.text))")
        try withSpeechReader("Sleep Timer Heading Cover", chapters: content.chapters) { speech in
            let reader = speech.reader
            XCTAssertFalse(
                ReaderViewModel.hasSpeakableText(reader.content?.chapters.first?.text ?? ""),
                "The cover says something: \(String(describing: reader.content?.chapters.first?.text))"
            )
            XCTAssertEqual([reader.currentChapterIndex, reader.currentCharacterOffset], [0, 0], "The book does not open at its cover")
            let partTwo = try heading(named: "Part Two", in: reader)
            XCTAssertEqual(reader.headingAfterPlaybackStart, partTwo, "The timer would wait for the wrong heading")

            assertEndOfHeadingTimerSurvivesPlayStartAndStops(at: partTwo, in: reader, "an image-only cover")
        }
    }

    /// A cover followed by one heading only: the heading Play starts in is the
    /// book's last, so the timer waits for the book's end, as it does for any
    /// last heading (no heading is kept).
    func testEndOfHeadingTimerSetAtACoverBeforeTheLastHeadingWaitsForTheBooksEnd() throws {
        preserveSharedSleepTimer()
        let only = chapter(titled: "Only", text: "Only\n\nThe only chapter is noted here.", headings: ["Only"])
        try withSpeechReader("Sleep Timer Heading Cover Last", chapters: [Chapter(title: "Cover", text: ""), only]) { speech in
            let reader = speech.reader
            XCTAssertNil(reader.headingAfterPlaybackStart, "A heading is kept: \(String(describing: reader.headingAfterPlaybackStart))")
            reader.startSleepTimer(duration: .endOfHeading)
            XCTAssertNil(reader.sleepTimerNextHeading, "A heading is kept: \(String(describing: reader.sleepTimerNextHeading))")
            XCTAssertTrue(SleepTimerService.shared.isActive, "The timer is not in effect")
        }
    }

    /// A timer set where a chapter has said its last words, in the blank
    /// lines that end it, waits for the end of the heading Play starts in, in
    /// the next chapter, and not for that chapter's first heading, which Play
    /// begins at.
    func testEndOfHeadingTimerSetAfterAChaptersLastWordsWaitsForTheHeadingPlayStartsIn() throws {
        preserveSharedSleepTimer()
        let opening = chapter(titled: "Moorings", text: "Moorings\n\nThe moorings are noted here.\n\n\n", headings: ["Moorings"])
        let next = chapter(
            titled: "Tides",
            text: "Tides\n\nThe tides are noted here.\n\nQuays\n\nThe quays are noted here.",
            headings: ["Tides", "Quays"]
        )
        try withSpeechReader("Sleep Timer Heading Chapter Tail", chapters: [opening, next]) { speech in
            let reader = speech.reader
            reader.currentChapterIndex = 0
            reader.currentCharacterOffset = opening.text.utf16.count - 2
            let quays = try heading(named: "Quays", in: reader)

            assertEndOfHeadingTimerSurvivesPlayStartAndStops(at: quays, in: reader, "the blank lines that end a chapter")
        }
    }

    /// A section the reader leaves out at the book's start: Play begins at
    /// the first words that remain, under the heading after the skipped one,
    /// so the timer waits for the heading after that.
    func testEndOfHeadingTimerSetBeforeASkippedSectionWaitsForTheHeadingPlayStartsIn() throws {
        preserveSharedSleepTimer()
        let text = "Copyright\n\nAll rights are reserved.\n\nChapter One\n\nIt began.\n\nChapter Two\n\nIt went on."
        let book = chapter(titled: "Book", text: text, headings: ["Copyright", "Chapter One", "Chapter Two"])
        try withSpeechReader("Sleep Timer Heading Skipped Start", chapters: [book]) { speech in
            let reader = speech.reader
            let copyright = try heading(named: "Copyright", in: reader)
            _ = recordingAnnouncements { reader.toggleHeadingSkip(copyright) }
            XCTAssertTrue(reader.isHeadingSkipped(copyright), "The section is not skipped")
            let chapterTwo = try heading(named: "Chapter Two", in: reader)

            assertEndOfHeadingTimerSurvivesPlayStartAndStops(at: chapterTwo, in: reader, "a skipped section at the start")
        }
    }

    /// The cursor in a skipped section that ends its chapter: Play passes on
    /// to the next chapter, so the timer waits for the heading after that
    /// chapter's first.
    func testEndOfHeadingTimerSetInASkippedSectionAtAChaptersEndWaitsForTheHeadingPlayStartsIn() throws {
        preserveSharedSleepTimer()
        let story = chapter(
            titled: "Story",
            text: "Story\n\nThe story is noted here.\n\nAppendix\n\nThe notes are noted here.",
            headings: ["Story", "Appendix"]
        )
        let next = chapter(
            titled: "Epilogue",
            text: "Epilogue\n\nThe epilogue is noted here.\n\nAfter\n\nThe after is noted here.",
            headings: ["Epilogue", "After"]
        )
        try withSpeechReader("Sleep Timer Heading Skipped End", chapters: [story, next]) { speech in
            let reader = speech.reader
            let appendix = try heading(named: "Appendix", in: reader)
            _ = recordingAnnouncements { reader.toggleHeadingSkip(appendix) }
            XCTAssertTrue(reader.isHeadingSkipped(appendix), "The section is not skipped")
            reader.currentChapterIndex = 0
            reader.currentCharacterOffset = appendix.characterOffset + "Appendix\n\n".utf16.count
            let after = try heading(named: "After", in: reader)

            assertEndOfHeadingTimerSurvivesPlayStartAndStops(at: after, in: reader, "a skipped section that ends its chapter")
        }
    }

    /// A book whose first chapters are empty: Play passes over every one of
    /// them, and the timer waits for the heading after the first one that
    /// says anything.
    func testEndOfHeadingTimerSetBeforeSeveralEmptyChaptersWaitsForTheHeadingPlayStartsIn() throws {
        preserveSharedSleepTimer()
        let cover = chapter(titled: "Cover", text: "", headings: [])
        let blank = Chapter(title: "Blank", text: "\n \n", headings: [Heading(level: 1, text: "Blank")])
        let body = chapter(
            titled: "Intro",
            text: "Intro\n\nThe intro is noted here.\n\nNext\n\nThe next is noted here.",
            headings: ["Intro", "Next"]
        )
        try withSpeechReader("Sleep Timer Heading Empty Chapters", chapters: [cover, blank, body]) { speech in
            let reader = speech.reader
            let next = try heading(named: "Next", in: reader)

            assertEndOfHeadingTimerSurvivesPlayStartAndStops(at: next, in: reader, "empty chapters at the start")
        }
    }

    /// White space before a chapter's first heading is not read: Play begins
    /// at the heading, which is then the heading playing, so the timer waits
    /// for the heading after it, not for the one Play is about to say.
    func testEndOfHeadingTimerSetBeforeWhiteSpaceAndAHeadingWaitsForTheHeadingAfterIt() throws {
        preserveSharedSleepTimer()
        let book = chapter(
            titled: "Davit",
            text: "\n\nDavit\n\nThe davit is noted here.\n\nEnd\n\nThe end is noted here.",
            headings: ["Davit", "End"]
        )
        try withSpeechReader("Sleep Timer Heading Leading Space", chapters: [book]) { speech in
            let reader = speech.reader
            let end = try heading(named: "End", in: reader)

            assertEndOfHeadingTimerSurvivesPlayStartAndStops(at: end, in: reader, "white space before the first heading")
        }
    }

    /// Every refresh of the timer's heading follows the place Play reads
    /// from, not the cursor: a timer handed to a reader, a book that starts
    /// over, an edited text, and a book loaded all refresh it, here with the
    /// cursor at a cover.
    func testRefreshingTheTimersHeadingAtACoverFollowsThePlaceWherePlayReads() throws {
        preserveSharedSleepTimer()
        let cover = chapter(titled: "Cover", text: "", headings: ["Cover"])
        let body = chapter(
            titled: "Intro",
            text: "Intro\n\nThe intro is noted here.\n\nNext\n\nThe next is noted here.",
            headings: ["Intro", "Next"]
        )
        try withSpeechReader("Sleep Timer Heading Refresh Cover", chapters: [cover, body]) { speech in
            let reader = speech.reader
            reader.startSleepTimer(duration: .endOfHeading)
            reader.sleepTimerNextHeading = nil

            reader.refreshSleepTimerHeading()

            XCTAssertEqual(
                reader.sleepTimerNextHeading?.text,
                "Next",
                "The refresh waits for \(String(describing: reader.sleepTimerNextHeading))"
            )
        }
    }

    /// While the book plays, the heading playing is the cursor's: a timer set
    /// then waits for the first heading after the cursor, as before.
    func testEndOfHeadingTimerSetWhilePlayingWaitsForTheHeadingAfterTheCursor() throws {
        preserveSharedSleepTimer()
        let harbour = harbourChapter()
        try withSpeechReader("Sleep Timer Heading While Playing", chapters: [harbour.chapter]) { speech in
            let reader = speech.reader
            reader.play()
            XCTAssertTrue(reader.isPlaybackUnderWay, "The book is not playing")

            reader.startSleepTimer(duration: .endOfHeading)
            reader.speechService.stop()

            XCTAssertEqual(reader.sleepTimerNextHeading?.text, "Tides")
        }
    }

    /// Where speech first says anything, in spoken text, from where it starts.
    func testTheFirstSpeakableOffsetPassesOverWhiteSpaceFromWhereSpeechStarts() {
        let cases: [(name: String, text: String, from: Int, expected: Int?)] = [
            ("words at the start", "Tides here", 0, 0),
            ("white space then words", "\n \nTides", 0, 3),
            ("starting inside white space", "a\n\n\nb", 2, 4),
            ("starting at a word", "a b", 2, 2),
            ("only white space", " \n ", 0, nil),
            ("past the end", "abc", 3, nil),
            ("empty", "", 0, nil),
        ]
        for testCase in cases {
            XCTAssertEqual(
                ReaderViewModel.firstSpeakableOffset(in: testCase.text, fromSpokenOffset: testCase.from),
                testCase.expected,
                testCase.name
            )
        }
    }

    /// The entries of an EPUB whose first document is only an image, a
    /// cover, and whose second has two headings, in words of no book.
    private static func coverEPUBEntries() -> [TestZIPEntry] {
        func file(_ path: String, _ text: String) -> TestZIPEntry {
            TestZIPEntry(path, Data(text.utf8))
        }
        func page(_ body: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body>\(body)</body></html>
            """
        }
        return [
            file("mimetype", "application/epub+zip"),
            file("META-INF/container.xml", """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """),
            file("OEBPS/package.opf", """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:2c6e1d3a-7f40-4b9e-8a15-0d9b3e5f7a21</dc:identifier>
            <dc:title>Cover Fixture</dc:title>
            </metadata>
            <manifest>
            <item id="c0" href="cover.xhtml" media-type="application/xhtml+xml"/>
            <item id="c1" href="main.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine><itemref idref="c0"/><itemref idref="c1"/></spine>
            </package>
            """),
            file("OEBPS/cover.xhtml", page("<img src=\"cover.jpg\" alt=\"\"/>")),
            file("OEBPS/main.xhtml", page("<h1>Main</h1><p>The first words are noted here.</p><h2>Part Two</h2><p>More words follow.</p>")),
        ]
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
            owner.startSleepTimer(duration: .endOfHeading)
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

        XCTAssertEqual(recorder.announcements.map(\.message), [Self.headingEndAnnouncement])
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

    /// Whether the next book has been asked for so far, as `continued`
    /// records the requests, read at once after the book's end has been
    /// handled, as `EndBehaviorMatrixTests` reads it for a cell that is not
    /// to hand over (`nextBookAsked(for:title:next:_:)`). That is as strong
    /// as waiting twice `ReaderViewModel.continueToNextBookDelay` for an ask
    /// (`nextBookIsAskedFor`), and takes no second: the next book is asked
    /// for only by a hand-over (`ReaderViewModel.handOverToNextBook`), which
    /// says "Starting: <title>" the moment it begins, as the end is handled.
    /// Every caller records the announcements from before the end until
    /// after this read and asserts them exactly, so a hand-over that began
    /// fails its test whether or not its ask is then waited for.
    private func nextBookAskedSoFar(_ continued: () -> [Notification]) -> Bool {
        !continued().isEmpty
    }

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
}

// MARK: - The Sleep Timer Sheet's Stop At Section

/// The sleep timer sheet's Stop At section as VoiceOver meets it (TODO
/// P01): an End of heading and an End of book button, each labelled with
/// what it does and given a hint, the End of heading hint saying where a
/// heading ends in any document, the End of book hint what the timer adds
/// to what the book does at its end on its own; pressing one sets that
/// timer for the reader, starts playback, and announces where it stops; and
/// the sheet's status line then reads where the timer stops playback. End
/// of heading is the one place-based timer besides End of book since
/// October 6, 2026, when End of chapter folded into it.
/// SwiftUI builds the accessibility elements of its buttons only for a
/// connected assistive app, so the test that presses them skips, rather
/// than fails, when it exposes none; the wording tests cover every label
/// either way. The book is silent audio, so starting playback is not heard.
@MainActor
final class SleepTimerSheetTests: XCTestCase {

    // MARK: - Wording

    /// Each Stop At button names what it does, and its hint says when it
    /// pauses playback: the End of heading hint where a heading ends, for
    /// any document; the End of book hint follows the book's end-of-book
    /// behavior, and says so when the book stops at its end on its own.
    func testStopAtButtonsSayWhatTheyDo() {
        XCTAssertEqual(SleepTimerView.stopAtHeading, "Stop At")
        XCTAssertEqual(SleepTimerView.endOfHeadingTitle, "End of heading")
        XCTAssertEqual(SleepTimerView.endOfHeadingLabel, "Stop at the end of this heading and start playing")
        XCTAssertEqual(
            SleepTimerView.endOfHeadingHint,
            "Pauses playback where the heading playing now ends: where the next heading begins, or the book ends."
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
        XCTAssertEqual(SleepTimerView.announcement(forSetting: .endOfBook), "Sleep timer: stops at the end of the book.")
        XCTAssertEqual(
            SleepTimerView.announcement(forSetting: .endOfHeading),
            "Sleep timer: stops at the end of this heading."
        )
        XCTAssertEqual(SleepTimerView.announcement(forSetting: .minutes(15)), "Timer set for 15 minutes.")
        XCTAssertEqual(SleepTimerView.resetAnnouncement(status: "15:00 remaining"), "Timer reset: 15:00 remaining.")
        XCTAssertEqual(
            SleepTimerView.resetAnnouncement(status: "stops at the end of the book"),
            "Timer reset: stops at the end of the book."
        )
    }

    // MARK: - The Rendered Sheet

    /// In the sheet, after the minute presets, End of heading and End of
    /// book come with their labels and hints, the End of book hint for a
    /// book that continues to the next, and no control offers a chapter
    /// timer: End of chapter folded into End of heading on October 6, 2026.
    /// Pressing End of heading through accessibility sets that timer for
    /// this reader and announces it once; the status line then reads where
    /// the timer stops; pressing End of book replaces it.
    func testStopAtButtonsAreLabelledAndSetTheirTimers() throws {
        try skipUnlessSwiftUIExposesItsOwnElements()
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
            XCTAssertEqual(buttons.endOfHeading.hint, SleepTimerView.endOfHeadingHint)
            XCTAssertEqual(buttons.endOfBook.hint, SleepTimerView.endOfBookHint(for: .continueNext))
            let labels = accessibleControls(in: hostingView).map(\.label)
            XCTAssertFalse(
                labels.contains { $0.localizedCaseInsensitiveContains("chapter") },
                "The sheet offers a chapter timer again: \(labels)"
            )
            let lastPreset = try XCTUnwrap(labels.lastIndex(of: "Set timer for 60 minutes and start playing"))
            let headingIndex = try XCTUnwrap(labels.firstIndex(of: SleepTimerView.endOfHeadingLabel))
            let bookIndex = try XCTUnwrap(labels.firstIndex(of: SleepTimerView.endOfBookLabel))
            XCTAssertLessThan(lastPreset, headingIndex, "Stop At does not follow the minute presets: \(labels)")
            XCTAssertLessThan(headingIndex, bookIndex, "End of book comes before End of heading: \(labels)")

            let setHeading = recordingAnnouncements {
                XCTAssertTrue(buttons.endOfHeading.element.accessibilityPerformPress())
                XCTAssertTrue(waitUntil { timer.duration == .endOfHeading }, "Pressing End of heading set no timer")
            }
            XCTAssertEqual(setHeading.announcements.map(\.message), ["Sleep timer: stops at the end of this heading."])
            XCTAssertEqual(timer.ownerID, reader.readerID, "The timer is not this reader's")
            XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Pressing End of heading did not start playback")

            let status = "Sleep timer: stops at the end of this heading"
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

    /// The End of heading and End of book buttons among the controls
    /// VoiceOver finds below `root`, or nil while either is missing.
    private func stopAtButtons(in root: NSView) -> (endOfHeading: AccessibleControl, endOfBook: AccessibleControl)? {
        let buttons = accessibleControls(in: root).filter { $0.role == .button }
        guard let endOfHeading = buttons.first(where: { $0.label == SleepTimerView.endOfHeadingLabel }),
              let endOfBook = buttons.first(where: { $0.label == SleepTimerView.endOfBookLabel }) else { return nil }
        return (endOfHeading, endOfBook)
    }
}
