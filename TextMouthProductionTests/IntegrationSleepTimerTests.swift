import Combine
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
                let recorder = recordingAnnouncements {
                    spokeOn = endSpeechSilently(endOfLastChapter, of: reader)
                    // Long enough for the next book to have been asked for.
                    spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
                }

                let behavior = outcome.behavior.rawValue
                XCTAssertFalse(spokeOn, "\(behavior): the book was spoken again")
                XCTAssertEqual(recorder.announcements.map(\.message), [outcome.announcement], behavior)
                XCTAssertFalse(timer.isActive, "\(behavior): the timer is still in effect")
                XCTAssertTrue(continued().isEmpty, "\(behavior): the next book was asked for")
                XCTAssertFalse(speech.world.autoplayRequests.hasRequest(for: speech.nextBook.id), behavior)
                XCTAssertEqual(reader.currentChapterIndex, outcome.chapterAfter, behavior)
            }
        }
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
                // Long enough for the next book to have been asked for.
                spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
            }

            XCTAssertEqual(recorder.announcements.map(\.message), [outcome.announcement], behavior)
            XCTAssertFalse(timer.isActive, "\(behavior): the timer is still in effect")
            XCTAssertTrue(continued().isEmpty, "\(behavior): the next book was asked for")
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
                let recorder = recordingAnnouncements {
                    spokeTheLastChapter = endSpeechSilently(endOfSecondChapter, of: reader)
                    XCTAssertEqual(reader.currentChapterIndex, 2, "\(behavior): the last chapter did not start")
                    if let endOfLastChapter = reader.speechService.onUtteranceFinished {
                        spokeAfterTheBook = endSpeechSilently(endOfLastChapter, of: reader)
                    }
                    // Long enough for the next book to have been asked for.
                    spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
                }

                XCTAssertTrue(spokeTheLastChapter, "\(behavior): the timer stopped speech before the last chapter")
                XCTAssertFalse(spokeAfterTheBook, "\(behavior): the book was spoken again")
                XCTAssertEqual(recorder.announcements.map(\.message), [outcome.announcement], behavior)
                XCTAssertFalse(timer.isActive, "\(behavior): the timer is still in effect")
                XCTAssertTrue(continued().isEmpty, "\(behavior): the next book was asked for")
                XCTAssertFalse(speech.world.autoplayRequests.hasRequest(for: speech.nextBook.id), behavior)
                XCTAssertEqual(reader.currentChapterIndex, outcome.chapterAfter, behavior)
            }
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
        /// The reader, loaded with three short chapters.
        let reader: ReaderViewModel
        /// The book the reader reads.
        let book: Book
        /// The book after it in its folder, where Continue to Next Book goes.
        let nextBook: Book
    }

    /// Run `body` with a reader of a text book of three short chapters, in a
    /// world of its own whose folder holds another book after it.
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
    private func withSpeechReader(
        _ label: String,
        endOfBook: EndOfBookBehavior = .stop,
        fadeSeconds: TimeInterval = 0,
        _ body: (SpeechWorld) throws -> Void
    ) throws {
        let world = try makeIntegrationWorld(label)
        world.settings.sleepFadeOutDuration = fadeSeconds
        let book = listTextBook(titled: "Quay Notes", in: world, endOfBook: endOfBook)
        let nextBook = listTextBook(titled: "Slipway Notes", in: world, endOfBook: .stop)
        let reader = world.openReader(for: book, renderScheduler: HeldRenderQueue())
        waitForReaderToLoad(reader)
        reader.errorMessage = nil
        reader.content = DocumentContent(
            title: book.title,
            author: "Test Author",
            chapters: ["Bollard", "Capstan", "Davit"].map {
                Chapter(title: $0, text: "The \($0.lowercased()) is noted here.")
            }
        )
        try body(SpeechWorld(world: world, reader: reader, book: book, nextBook: nextBook))
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
