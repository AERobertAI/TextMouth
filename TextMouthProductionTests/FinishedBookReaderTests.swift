import Combine
import XCTest
@testable import TextMouth

/// A book that plays to its end, in a real reader (TODO P07): where it
/// rests, what Play and a rewind do there, and how often it is counted.
///
/// The user decided on October 10, 2026 that a book that plays to its end
/// is saved exactly at its end and stays finished after TextMouth quits
/// (question 11). Every audiobook here is silent WAV or AAC audio, so a
/// reader that plays it is never heard, and announcements are recorded
/// instead of spoken.
@MainActor
final class FinishedBookReaderTests: XCTestCase {

    // MARK: - Resting at the End

    /// The ways an audiobook's chapters can lie in its files, each with its
    /// own way of reporting the end (`ReaderViewModel.AudioLayout`).
    private enum Layout: String, CaseIterable {
        /// A file per chapter: the last file's natural end.
        case filePerChapter
        /// One file, one chapter: the file's natural end.
        case oneFile
        /// One file with chapter marks, an m4b: the file's natural end, since
        /// the last chapter, unlike the others, has no clip end
        /// (`testAChapteredBookEndsAtItsFilesEndNotBefore`).
        case chapterMarks
        /// A DAISY audiobook's clips: the last clip of the last chapter's
        /// chain.
        case clips

        /// The layout the reader finds the book in.
        var audioLayout: ReaderViewModel.AudioLayout {
            switch self {
            case .filePerChapter: return .multiFile
            case .oneFile: return .singleFile
            case .chapterMarks: return .chaptersInOneFile
            case .clips: return .segmented
            }
        }
    }

    /// Every audiobook layout, played to its end with the Stop behavior,
    /// rests exactly at its end: the last chapter at its full length, the
    /// cursor's global offset the book's total, saved to the library's row.
    /// The player's clock, which ticks once more as it stops at the end,
    /// moves it no more, and closing the window keeps it there (TODO P07).
    /// It once rested at the last quarter-second tick the player reported,
    /// or a moment past the end, wherever the late tick put it.
    func testEveryAudiobookLayoutRestsExactlyAtItsEnd() throws {
        for layout in Layout.allCases {
            let world = try makeIntegrationWorld("Finished End \(layout.rawValue)")
            let book = try makeAudioBook(layout, titled: "Harbour Soundings", in: world)
            let reader = world.openReader(for: book, nowPlaying: privateMediaSession())
            waitForReaderToLoad(reader)
            XCTAssertNil(reader.errorMessage, "\(layout): the book did not open")
            XCTAssertEqual(reader.audioLayout, layout.audioLayout, "\(layout): the book opened in another layout")
            let end = try XCTUnwrap(reader.endOfBookPlace, "\(layout): no end")

            let recorder = recordingAnnouncements {
                reader.play()
                XCTAssertTrue(reader.audioPlaybackService.isPlaying, "\(layout): the book did not play")
                XCTAssertTrue(
                    eventually(within: 10) { reader.lastAnnouncement != nil },
                    "\(layout): the book never finished"
                )
                // Long enough for the player's last tick, as it stops at the
                // end, to have been handled.
                spinMainRunLoop(for: 0.5)
            }
            XCTAssertEqual(recorder.announcements.map(\.message), ["Finished: Harbour Soundings"], "\(layout)")
            assertRestsAtItsEnd(reader, end: end, in: world, "\(layout): after the end")

            // Closing lets go of the book's content, so its total is taken
            // first.
            let total = reader.content?.totalCharacterCount
            reader.close()
            assertSavedAtItsEnd(book, end: end, total: total, in: world, "\(layout): closed")
        }
    }

    /// A one-file audiobook with chapter marks plays its last chapter to the
    /// file's own end, which ends the book, however far the chapters'
    /// summed lengths fall short of the file
    /// (`ReaderViewModel.AudioLayout.clipEnd(ofChapter:chapterUTF16Lengths:)`).
    /// A chapter's length is its duration in whole tenths of a second, so
    /// the ten chapters of 1.09 seconds here add up to 10 seconds in a file
    /// of 10.9. The last chapter once stopped at that sum, a clip end 0.9
    /// seconds before the file's end, and the book was told finished, and
    /// counted, with its last seconds unplayed.
    func testAChapteredBookEndsAtItsFilesEndNotBefore() throws {
        let world = try makeIntegrationWorld("Finished End Chapter Drift")
        let chapterSeconds = 1.09
        let markers = (0..<10).map { index in
            AudioTestFixtures.ChapterMarker(
                title: "Reach \(index + 1)",
                start: Double(index) * chapterSeconds,
                duration: chapterSeconds
            )
        }
        let fileSeconds = Double(markers.count) * chapterSeconds
        let book = try makeChapteredAudioBook(
            title: "Dredging Survey",
            in: world,
            duration: fileSeconds,
            markers: markers,
            savedPosition: ReadingPosition(chapterIndex: markers.count - 1, characterOffset: 0)
        )
        let reader = world.openReader(for: book, nowPlaying: privateMediaSession())
        waitForReaderToLoad(reader)
        XCTAssertEqual(reader.audioLayout, .chaptersInOneFile, "The book opened in another layout")
        // Where the chapters' summed lengths end: 10 seconds, well short of
        // the file's end, which the test needs.
        let summedEnd = Double(try XCTUnwrap(reader.content?.totalCharacterCount)) / ReaderViewModel.audioCharsPerSecond
        XCTAssertLessThanOrEqual(summedEnd, fileSeconds - 0.8, "The chapters' lengths do not fall short of the file")

        let service = reader.audioPlaybackService
        let reports = PlayerReportLog(observing: service)
        // The log's hook holds the log unowned, so the hook goes first.
        defer { service._reportHandledForTesting = nil }
        let recorder = recordingAnnouncements {
            reader.play()
            XCTAssertTrue(service.isPlaying, "The book did not play")
            XCTAssertTrue(eventually(within: 10) { reader.lastAnnouncement != nil }, "The book never finished")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Finished: Dredging Survey"])
        XCTAssertTrue(reader.hasFinishedBook, "The book does not rest finished")
        XCTAssertFalse(reports.finishedAClipOnATick, "The last chapter stopped at a clip end, short of the file's end")
        XCTAssertEqual(reports.endOfFileOutcomes, [.endedPlay], "The file's own end did not end the book")
        XCTAssertTrue(reports.handledTick(atOrAfter: summedEnd + 0.5), "The file's last seconds did not play")
    }

    // MARK: - What a Finished Book Says

    /// In a real reader, Where Am I? says "Finished" for the book resting at
    /// its end, in place of its percent and time left (TODO P07, question
    /// 12), while the reader's own status row keeps its percent and time,
    /// as the user asked: "yes except the reader, those controls with the
    /// info should still be there".
    func testWhereAmISaysFinishedWhileTheStatusRowKeepsItsPercentAndTime() throws {
        let world = try makeIntegrationWorld("Finished Where Am I")
        let book = try makeAudioBook(.filePerChapter, titled: "Harbour Soundings", in: world, savedAt: Self.lastChapterEnd)
        let reader = world.openReader(for: book, nowPlaying: privateMediaSession())
        waitForReaderToLoad(reader)
        XCTAssertTrue(reader.cursorRestsAtEnd, "The book did not open at its end")

        XCTAssertTrue(reader.buildBriefWhereAmI().hasSuffix(". Finished."), reader.buildBriefWhereAmI())
        let content = try XCTUnwrap(reader.content)
        let full = reader.buildFullWhereAmI(content: content)
        XCTAssertTrue(full.contains(". Finished. Total book time: "), full)
        XCTAssertFalse(full.contains("remaining"), full)

        XCTAssertTrue(
            eventually { reader.displayFormattedPercentComplete == "100.0%" },
            "The status row's percent is \(reader.displayFormattedPercentComplete)"
        )
        XCTAssertEqual(reader.displayFormattedTimeRemaining, TimeFormatting.format(0), "The status row's time left changed")
    }

    // MARK: - Opening a Finished Book

    /// A finished book opened again, as after a relaunch, rests finished,
    /// as it did before TextMouth quit (TODO P07, question 11): saved
    /// exactly at its end, it opens there, finished, and the keyboard's Skip
    /// Backward, once its window is the focused one, plays its end again
    /// from where the skip lands, as a rewind did after the end (B02). A book
    /// saved short of its end opens unfinished, and its Skip Backward moves
    /// the cursor and plays nothing, as any stopped reader's does.
    func testAFinishedBookOpenedAgainRestsFinished() throws {
        let world = try makeIntegrationWorld("Finished Opened Again")
        world.settings.skipBackwardUnit = .seconds15
        let finished = try makeAudioBook(.filePerChapter, titled: "Harbour Soundings", in: world, savedAt: Self.lastChapterEnd)
        let reader = world.openReader(for: finished, nowPlaying: privateMediaSession())
        waitForReaderToLoad(reader)
        XCTAssertTrue(reader.cursorRestsAtEnd, "The finished book did not open at its end")
        XCTAssertTrue(reader.hasFinishedBook, "The finished book opened unfinished")

        reader.windowBecameKey()
        let rewinding = recordingAnnouncements {
            reader.skipBackward()
        }
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Skip Backward did not play the finished book's end again")
        XCTAssertFalse(reader.cursorRestsAtEnd, "Skip Backward did not move back from the end")
        XCTAssertEqual(rewinding.announcements, [], "Skip Backward announced something")
        reader.stop()

        let unfinished = try makeAudioBook(.filePerChapter, titled: "Ferry Timetable", in: world)
        let other = world.openReader(for: unfinished, nowPlaying: privateMediaSession())
        waitForReaderToLoad(other)
        XCTAssertFalse(other.hasFinishedBook, "A book saved short of its end opened finished")
        other.windowBecameKey()
        other.skipBackward()
        XCTAssertFalse(other.audioPlaybackService.isPlaying, "Skip Backward played a book that was not finished")
        XCTAssertLessThan(other.currentCharacterOffset, Self.lastHalfSecond, "Skip Backward did not move the cursor")
    }

    // MARK: - Play at the End

    /// By default, Play on a finished book says "Finished: <title>" and
    /// does nothing else (TODO P07; the user, October 10, 2026, question
    /// 13: "it should just say "fished" if there not enabled to move to the
    /// next book or start over"): it plays nothing, neither the end again
    /// nor anything else; the book stays at its end, finished; no listening
    /// session opens; and nothing is told or counted as finished. Each way
    /// Play reaches a stopped reader does the same: Play, Play/Pause, and the
    /// AirPods' Play (`playOrResume()`). Play once played the last moment
    /// again, which ended the book again and counted it again.
    func testPlayOnAFinishedBookSaysFinishedAndDoesNothingElse() throws {
        let world = try makeIntegrationWorld("Finished Play Stop")
        let book = try makeAudioBook(.filePerChapter, titled: "Harbour Soundings", in: world)
        let reader = world.openReader(for: book, nowPlaying: privateMediaSession())
        waitForReaderToLoad(reader)
        reader.play()
        waitForTheEnd(of: reader, "The end")
        let told = recordFinishesTold()

        let presses: [(name: String, press: (ReaderViewModel) -> Void)] = [
            ("Play", { $0.play() }),
            ("Play/Pause", { $0.togglePlayPause() }),
            ("the AirPods' Play", { $0.playOrResume() }),
        ]
        for (name, press) in presses {
            let recorder = recordingAnnouncements {
                press(reader)
            }
            XCTAssertEqual(recorder.announcements.map(\.message), ["Finished: Harbour Soundings"], name)
            XCTAssertFalse(reader.audioPlaybackService.isPlaying, "\(name) played the book")
            XCTAssertFalse(reader.isCurrentlyPlaying, "\(name): the reader shows Playing")
            XCTAssertTrue(reader.cursorRestsAtEnd, "\(name) moved the book from its end")
            XCTAssertTrue(reader.hasFinishedBook, "\(name) left the book unfinished")
            XCTAssertFalse(ReadingStatsService.shared.hasActiveSession, "\(name) opened a listening session")
        }
        XCTAssertEqual(told(), [], "Play at the end was told as a finish")
        XCTAssertEqual(ReadingStatsService.shared.stats.finishedBooks.map(\.bookID), [book.id.uuidString])
    }

    /// Play on a finished book whose end goes on does what its end did,
    /// without playing the end again or telling a finish (question 13):
    /// with Continue to Next Book, the next book in the folder takes
    /// listening over, "Starting: <title>", as at the end; with Loop to
    /// Start, the book plays again from its beginning, "Restarting: <title>".
    func testPlayOnAFinishedBookThatContinuesOrLoopsDoesWhatItsEndDoes() throws {
        let world = try makeIntegrationWorld("Finished Play Continue")
        let first = try makeAudioBook(
            .filePerChapter, titled: "First Crossing", in: world, savedAt: Self.lastChapterEnd, endOfBook: .continueNext
        )
        let second = try makeAudioBook(.filePerChapter, titled: "Second Crossing", in: world)
        let reader = world.openReader(for: first, nowPlaying: privateMediaSession())
        waitForReaderToLoad(reader)
        let told = recordFinishesTold()

        let continuing = recordingAnnouncements {
            reader.play()
            XCTAssertTrue(
                eventually { world.autoplayRequests.hasRequest(for: second.id) },
                "Play at the end never asked for the next book"
            )
        }
        XCTAssertEqual(continuing.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertFalse(reader.audioPlaybackService.isPlaying, "Play at the end played the finished book")
        XCTAssertTrue(reader.cursorRestsAtEnd, "Play at the end moved the finished book from its end")

        let looping = try makeAudioBook(
            .filePerChapter, titled: "Third Crossing", in: world, savedAt: Self.lastChapterEnd, endOfBook: .loop
        )
        let loopReader = world.openReader(for: looping, nowPlaying: privateMediaSession())
        waitForReaderToLoad(loopReader)
        let restarting = recordingAnnouncements {
            loopReader.play()
        }
        XCTAssertEqual(restarting.announcements.map(\.message), ["Restarting: Third Crossing"])
        XCTAssertTrue(loopReader.audioPlaybackService.isPlaying, "Play at the end did not play the looping book again")
        XCTAssertEqual(loopReader.currentChapterIndex, 0, "The looping book did not start again from its beginning")
        loopReader.stop()
        XCTAssertEqual(told(), [], "Play at the end was told as a finish")
    }

    /// With the end-of-book choice "Stop, and Play Starts Over" (TODO P07,
    /// question 13), a book stops at its end as with Stop, "Finished:
    /// <title>", resting there, counted once; Play then starts it over from
    /// its beginning, "Starting again: <title>", which tells and counts no
    /// finish.
    func testWithStopAndPlayStartsOverPlayStartsAFinishedBookOver() throws {
        let world = try makeIntegrationWorld("Finished Play Starts Over")
        let book = try makeAudioBook(.filePerChapter, titled: "Harbour Soundings", in: world, endOfBook: .stopAndPlayStartsOver)
        let reader = world.openReader(for: book, nowPlaying: privateMediaSession())
        waitForReaderToLoad(reader)
        let told = recordFinishesTold()

        let ending = recordingAnnouncements {
            reader.play()
            waitForTheEnd(of: reader, "The end")
        }
        XCTAssertEqual(ending.announcements.map(\.message), ["Finished: Harbour Soundings"])
        XCTAssertTrue(reader.cursorRestsAtEnd, "The book did not rest at its end")
        XCTAssertEqual(told(), [book.id], "The end was not told once")

        let startingOver = recordingAnnouncements {
            reader.play()
        }
        XCTAssertEqual(startingOver.announcements.map(\.message), ["Starting again: Harbour Soundings"])
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "Play did not start the finished book over")
        XCTAssertEqual(reader.currentChapterIndex, 0, "Play did not start the book over from its beginning")
        XCTAssertFalse(reader.hasFinishedBook, "The book started over is still finished")
        reader.stop()
        XCTAssertEqual(told(), [book.id], "Starting over was told as a finish")
        XCTAssertEqual(ReadingStatsService.shared.stats.finishedBooks.map(\.bookID), [book.id.uuidString])
    }

    // MARK: - Counting

    /// A rewind after a book's end replays the end, which is no new finish
    /// (TODO P07; the user, October 10, 2026, question 14: yes): played on
    /// to the end again, the book is neither counted again in Books
    /// Finished nor told as finished (`.bookDidFinish`), which would mark a
    /// feed item played anew and restart its delete-after-played clock; it
    /// rests at its end, finished, as the first end left it. A jump, then a
    /// play to the end, is a new end: it is told, while Books Finished,
    /// which counts each book once, still counts the book once.
    func testARewindsReplayOfTheEndIsNoNewFinish() throws {
        let world = try makeIntegrationWorld("Finished Replay")
        world.settings.skipBackwardUnit = .seconds15
        world.settings.skipForwardUnit = .seconds30
        let book = try makeAudioBook(.filePerChapter, titled: "Harbour Soundings", in: world)
        let reader = world.openReader(for: book, nowPlaying: privateMediaSession())
        waitForReaderToLoad(reader)
        let told = recordFinishesTold()
        let statistics = ReadingStatsService.shared

        reader.play()
        waitForTheEnd(of: reader, "The first end")
        XCTAssertEqual(told(), [book.id], "The first end was not told")
        XCTAssertEqual(statistics.stats.finishedBooks.map(\.bookID), [book.id.uuidString])

        // The rewind replays the end, which Next Track brings near.
        reader.skipBackward()
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "The rewind did not play the end again")
        XCTAssertTrue(reader.replaysFinishedEnd, "The rewind's play is not a replay")
        reader.lastSkipTime = .distantPast
        reader.skipForward()
        XCTAssertTrue(reader.replaysFinishedEnd, "A skip during the replay ended it")
        waitForTheEnd(of: reader, "The replay's end")
        XCTAssertEqual(told(), [book.id], "The replay's end was told as a finish")
        XCTAssertEqual(statistics.stats.finishedBooks.map(\.bookID), [book.id.uuidString], "The replay was counted")
        XCTAssertFalse(reader.replaysFinishedEnd, "The replay outlived its end")
        XCTAssertTrue(reader.cursorRestsAtEnd, "The replay's end did not rest at the end")

        // A jump, then a play to the end, is a new end.
        reader.navigateTo(chapterIndex: 1, characterOffset: Self.lastHalfSecond)
        reader.play()
        waitForTheEnd(of: reader, "The end after a jump")
        XCTAssertEqual(told(), [book.id, book.id], "The end after a jump was not told")
        XCTAssertEqual(statistics.stats.finishedBooks.map(\.bookID), [book.id.uuidString], "The book was counted twice")
    }

    // MARK: - Fixtures

    /// How many seconds of silence the last chapter of every audiobook
    /// holds: long enough for a skip of either unit to land inside it.
    private static let lastChapterSeconds: TimeInterval = 2

    /// Where every audiobook was last read: half a second before the end of
    /// its last chapter, ten characters standing for a second of audio.
    private static let lastHalfSecond = Int((lastChapterSeconds - 0.5) * ReaderViewModel.audioCharsPerSecond)

    /// Where a finished book rests: the end of its last chapter.
    private static let lastChapterEnd = Int(lastChapterSeconds * ReaderViewModel.audioCharsPerSecond)

    /// An audiobook titled `title` in `layout`, in `world`, whose last
    /// chapter lasts `lastChapterSeconds`, saved `offset` into that chapter
    /// (half a second before its end unless given), ending with the Stop
    /// behavior unless `endOfBook` says otherwise.
    private func makeAudioBook(
        _ layout: Layout,
        titled title: String,
        in world: IntegrationWorld,
        savedAt offset: Int = lastHalfSecond,
        endOfBook: EndOfBookBehavior = .stop
    ) throws -> Book {
        switch layout {
        case .filePerChapter:
            return try world.makeSilentAudioBook(
                title: title,
                trackDurations: [1, Self.lastChapterSeconds],
                savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: offset),
                endOfBook: endOfBook
            )
        case .oneFile:
            return try world.makeSilentAudioFileBook(
                title: title,
                duration: Self.lastChapterSeconds,
                savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: offset),
                endOfBook: endOfBook
            )
        case .chapterMarks:
            return try makeChapteredAudioBook(
                title: title,
                in: world,
                duration: 1 + Self.lastChapterSeconds,
                markers: [
                    AudioTestFixtures.ChapterMarker(title: "Approach", start: 0, duration: 1),
                    AudioTestFixtures.ChapterMarker(title: "Breakwater", start: 1, duration: Self.lastChapterSeconds),
                ],
                savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: offset),
                endOfBook: endOfBook
            )
        case .clips:
            // The last chapter plays two clips, the first sharing its file
            // with the chapter before.
            return try world.makeSegmentedAudioBook(
                title: title,
                files: ["a.wav": 1.5, "b.wav": 1.5],
                sections: [
                    AudioSegment(title: "Approach", file: "a.wav", startTime: 0, endTime: 1),
                    try XCTUnwrap(AudioSegment(title: "Breakwater", clips: [
                        AudioClip(file: "a.wav", startTime: 1, endTime: 1.5),
                        AudioClip(file: "b.wav", startTime: 0, endTime: 1.5),
                    ])),
                ],
                savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: offset),
                endOfBook: endOfBook
            )
        }
    }

    /// A media session of the test's own, as a reader's only member, so the
    /// reader is the active owner, as a finished book's reader is while no
    /// other book plays: readers of other tests may still be registered in
    /// the app's shared session.
    private func privateMediaSession() -> NowPlayingService {
        NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
    }

    /// Subscriptions a test keeps until it ends.
    private var subscriptions: [AnyCancellable] = []

    /// Records the books the shared statistics service tells as finished
    /// from now on (`.bookDidFinish`), as the feed engine hears them.
    ///
    /// - Returns: The books told, oldest first.
    private func recordFinishesTold() -> () -> [UUID] {
        final class Told {
            var books: [UUID] = []
        }
        let told = Told()
        NotificationCenter.default.publisher(for: .bookDidFinish, object: ReadingStatsService.shared)
            .sink { notification in
                if let bookID = notification.userInfo?[ReadingStatsService.finishedBookIDKey] as? UUID {
                    told.books.append(bookID)
                }
            }
            .store(in: &subscriptions)
        return { told.books }
    }

    /// Waits until `reader`'s book has played to its end and rests
    /// finished, nothing playing.
    private func waitForTheEnd(
        of reader: ReaderViewModel,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            eventually(within: 10) { reader.hasFinishedBook && !reader.audioPlaybackService.isPlaying },
            "\(context): the book never reached its end",
            file: file,
            line: line
        )
    }

    // MARK: - Checks

    /// Check that `reader`'s book rests exactly at its end, `end`: the cursor
    /// there, which the reader reads as the end, and the book saved there.
    private func assertRestsAtItsEnd(
        _ reader: ReaderViewModel,
        end: (chapterIndex: Int, characterOffset: Int),
        in world: IntegrationWorld,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(reader.currentChapterIndex, end.chapterIndex, "\(context): the cursor is in another chapter", file: file, line: line)
        XCTAssertEqual(reader.currentCharacterOffset, end.characterOffset, "\(context): the cursor is not at the end", file: file, line: line)
        XCTAssertTrue(reader.cursorRestsAtEnd, "\(context): the reader does not read its cursor as the end", file: file, line: line)
        assertSavedAtItsEnd(reader.book, end: end, total: reader.content?.totalCharacterCount, in: world, context, file: file, line: line)
    }

    /// Check that the library's row of `book` is saved exactly at its end,
    /// `end`, whose global offset is the book's `total`, and so reads as
    /// finished once measured, as the library measures every book.
    private func assertSavedAtItsEnd(
        _ book: Book,
        end: (chapterIndex: Int, characterOffset: Int),
        total: Int?,
        in world: IntegrationWorld,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var row = world.library.bookByID(book.id)
        let saved = row?.readingPosition
        XCTAssertEqual(saved?.chapterIndex, end.chapterIndex, "\(context): saved in another chapter", file: file, line: line)
        XCTAssertEqual(saved?.characterOffset, end.characterOffset, "\(context): saved short of the end", file: file, line: line)
        XCTAssertEqual(saved?.globalCharacterOffset, total, "\(context): the saved place is not the book's end", file: file, line: line)
        row?.totalCharacterCount = total
        XCTAssertEqual(row?.restsAtEnd, true, "\(context): the measured row is not finished", file: file, line: line)
    }
}
