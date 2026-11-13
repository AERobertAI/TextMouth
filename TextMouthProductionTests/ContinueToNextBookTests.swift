import Combine
import XCTest
@testable import TextMouth

/// Continue to Next Book, from the finished book to the next book's reader.
///
/// The finished book says "Starting" once, then leaves the next book a
/// request and asks for its window. The next book's reader starts playing
/// for that request exactly once, through the normal Play path and without
/// announcing anything: when it finishes loading, or at once when it was
/// already open. Only that book's reader responds, a reader still loading
/// waits until it has loaded, and a book that cannot be loaded drops the
/// request. A sleep timer the finished book set keeps the next book from
/// starting, since it could never pause that book. Finished books after it
/// in its folder are passed over, at its end and on Play at its end (REV14).
///
/// Every book is a package of silent audio tracks, so a reader that starts
/// playing is never heard. Each test's readers listen on a private
/// notification center and share a private request store, so the running
/// app's own windows never see these requests, and announcements are
/// recorded instead of spoken.
@MainActor
final class ContinueToNextBookTests: XCTestCase {
    /// Seconds of silence in each track: longer than any test runs, so no
    /// chapter ends by itself.
    private static let trackDuration: TimeInterval = 5

    /// Where every fixture book was last read: the second chapter, half a
    /// second in (ten characters stand for one second of audio).
    private static let savedPosition = ReadingPosition(chapterIndex: 1, characterOffset: 5)

    /// Subscriptions a test keeps until it ends.
    private var subscriptions = Set<AnyCancellable>()

    /// Every reader here is in a window of its own, with a sleep timer of its
    /// own (`makeReader`), so no timer a test starts may outlive the test:
    /// every timer of the app's registry is stopped when it ends, and the
    /// duration last used is put back.
    override func setUp() async throws {
        try await super.setUp()
        preserveSleepTimers()
    }

    // MARK: - Starting the next book

    /// A reader opened for a waiting request starts playing once it has
    /// loaded, from the book's saved position, and not a moment before. It
    /// claims the request, starts a listening session and Now Playing as
    /// Play does, and announces nothing.
    func testReaderOpenedForARequestPlaysOnceLoadedAndNotBefore() throws {
        let book = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [book])
        world.requests.request(for: book.id, from: UUID())

        let recorder = recordingAnnouncements {
            let reader = makeReader(for: book, in: world)
            let starts = countPlaybackStarts(of: reader)

            XCTAssertTrue(reader.isLoading)
            XCTAssertFalse(reader.isCurrentlyPlaying, "Played before loading")
            XCTAssertTrue(world.requests.hasRequest(for: book.id), "Claimed before loading")

            waitUntilLoaded(reader)

            XCTAssertNil(reader.errorMessage, "The book did not load")
            XCTAssertEqual(starts(), 1)
            XCTAssertTrue(reader.isCurrentlyPlaying)
            XCTAssertFalse(reader.isCurrentlyPaused)
            XCTAssertTrue(reader.audioPlaybackService.isPlaying)
            XCTAssertFalse(world.requests.hasRequest(for: book.id), "Request left to claim again")
            // The saved position: the second track, half a second in.
            XCTAssertEqual(reader.currentChapterIndex, Self.savedPosition.chapterIndex)
            XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "02.wav")
            XCTAssertEqual(reader.audioPlaybackService.currentTime, 0.5, accuracy: 0.3)
            XCTAssertTrue(ReadingStatsService.shared.hasActiveSession)
            XCTAssertEqual(NowPlayingService.shared.playingOwnerID, reader.nowPlayingService.ownerID)
            XCTAssertNil(reader.lastAnnouncement)
        }
        XCTAssertEqual(recorder.announcements, [])
    }

    /// A request announced while the reader is still loading waits for the
    /// load to end, and then starts playback once.
    func testReaderStillLoadingWhenItsRequestArrivesPlaysOnceLoaded() throws {
        let book = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [book])
        let reader = makeReader(for: book, in: world)
        let starts = countPlaybackStarts(of: reader)

        continueTo(book.id, in: world)

        XCTAssertTrue(reader.isLoading)
        XCTAssertFalse(reader.isCurrentlyPlaying, "Played before loading")
        XCTAssertTrue(world.requests.hasRequest(for: book.id), "Claimed before loading")

        waitUntilLoaded(reader)

        XCTAssertEqual(starts(), 1)
        XCTAssertTrue(reader.audioPlaybackService.isPlaying)
        XCTAssertFalse(world.requests.hasRequest(for: book.id))
    }

    /// A reader already open and loaded starts playing as soon as its
    /// request is announced, exactly once, however often the notification
    /// arrives.
    func testOpenReaderPlaysOnceWhenItsRequestArrives() throws {
        let book = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [book])
        let reader = makeReader(for: book, in: world)
        waitUntilLoaded(reader)
        let starts = countPlaybackStarts(of: reader)

        let recorder = recordingAnnouncements {
            continueTo(book.id, in: world)
            // The same notification again, with its request already claimed.
            world.notifications.post(
                name: .continueToNextBook,
                object: nil,
                userInfo: [Notification.ContinueToNextBookKey.bookID: book.id]
            )
        }

        XCTAssertEqual(starts(), 1)
        XCTAssertTrue(reader.isCurrentlyPlaying)
        XCTAssertTrue(reader.audioPlaybackService.isPlaying)
        XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "02.wav")
        XCTAssertFalse(world.requests.hasRequest(for: book.id))
        XCTAssertEqual(recorder.announcements, [])
    }

    /// A reader for any other book ignores the request and leaves it
    /// waiting for the book it names.
    func testReaderForAnotherBookIgnoresTheRequest() throws {
        let book = try makeAudioBook(title: "Unrelated Volume")
        let world = try makeWorld(books: [book])
        let reader = makeReader(for: book, in: world)
        waitUntilLoaded(reader)
        let starts = countPlaybackStarts(of: reader)
        let nextBookID = UUID()

        continueTo(nextBookID, in: world)

        XCTAssertEqual(starts(), 0)
        XCTAssertFalse(reader.isCurrentlyPlaying)
        XCTAssertFalse(reader.audioPlaybackService.isPlaying)
        XCTAssertTrue(world.requests.hasRequest(for: nextBookID))
    }

    /// A book that cannot be loaded drops its request without playing; the
    /// load error is shown as before, and nothing is announced.
    func testReaderThatCannotLoadDropsTheRequestWithoutPlaying() throws {
        let missing = Book(
            title: "Missing Volume",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-missing-volume.txt",
            md5Hash: UUID().uuidString
        )
        let world = try makeWorld(books: [missing])
        world.requests.request(for: missing.id, from: UUID())

        let recorder = recordingAnnouncements {
            let reader = makeReader(for: missing, in: world)
            waitUntilLoaded(reader)

            XCTAssertNil(reader.content)
            XCTAssertNotNil(reader.loadErrorMessage, "The load error is not shown")
            XCTAssertFalse(reader.isCurrentlyPlaying)
            XCTAssertFalse(reader.speechService.isSpeaking)
            XCTAssertFalse(world.requests.hasRequest(for: missing.id), "Request left to claim later")
            XCTAssertFalse(ReadingStatsService.shared.hasActiveSession)
        }
        XCTAssertEqual(recorder.announcements, [])
    }

    /// A reader already playing its book keeps playing, untouched: the
    /// request is claimed, so it cannot start the book again later, but
    /// playback does not restart.
    func testPlayingReaderKeepsPlayingWithoutRestarting() throws {
        let book = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [book])
        let reader = makeReader(for: book, in: world)
        waitUntilLoaded(reader)
        reader.play()
        XCTAssertTrue(reader.audioPlaybackService.isPlaying)
        let starts = countPlaybackStarts(of: reader)

        continueTo(book.id, in: world)

        XCTAssertEqual(starts(), 0, "Playback restarted")
        XCTAssertTrue(reader.isCurrentlyPlaying)
        XCTAssertTrue(reader.audioPlaybackService.isPlaying)
        XCTAssertFalse(world.requests.hasRequest(for: book.id))
    }

    /// A paused reader resumes from where it was paused.
    func testPausedReaderResumesForItsRequest() throws {
        let book = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [book])
        let reader = makeReader(for: book, in: world)
        waitUntilLoaded(reader)
        reader.play()
        reader.pause()
        XCTAssertTrue(reader.isCurrentlyPaused)

        continueTo(book.id, in: world)

        XCTAssertTrue(reader.isCurrentlyPlaying)
        XCTAssertFalse(reader.isCurrentlyPaused)
        XCTAssertTrue(reader.audioPlaybackService.isPlaying)
        XCTAssertFalse(reader.audioPlaybackService.isPaused)
        XCTAssertEqual(reader.currentChapterIndex, Self.savedPosition.chapterIndex)
    }

    /// Playback cannot start while a Where Am I announcement speaks, so the
    /// announcement ends and the book starts.
    func testWhereAmIAnnouncementGivesWayToTheContinuedBook() throws {
        let book = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [book])
        let reader = makeReader(for: book, in: world)
        waitUntilLoaded(reader)
        reader.isWhereAmISpeaking = true

        continueTo(book.id, in: world)

        XCTAssertFalse(reader.isWhereAmISpeaking)
        XCTAssertTrue(reader.isCurrentlyPlaying)
        XCTAssertTrue(reader.audioPlaybackService.isPlaying)
    }

    /// A request older than its lifetime when the reader finishes loading
    /// starts nothing, and is thrown away.
    func testStaleRequestDoesNotStartTheReader() throws {
        let book = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [book])
        var now = Date()
        let requests = ReaderAutoplayRequests(now: { now })
        requests.request(for: book.id, from: UUID())
        now += ReaderAutoplayRequests.lifetime + 1

        let reader = makeReader(for: book, in: world, requests: requests)
        waitUntilLoaded(reader)

        XCTAssertNil(reader.errorMessage, "The book did not load")
        XCTAssertFalse(reader.isCurrentlyPlaying)
        XCTAssertFalse(reader.audioPlaybackService.isPlaying)
        now -= ReaderAutoplayRequests.lifetime + 1
        XCTAssertFalse(requests.hasRequest(for: book.id), "Stale request kept")
    }

    /// A closed reader claims nothing, so the request stays waiting.
    func testClosedReaderClaimsNothing() throws {
        let book = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [book])
        let reader = makeReader(for: book, in: world)
        waitUntilLoaded(reader)
        reader.close()

        continueTo(book.id, in: world)

        XCTAssertFalse(reader.isCurrentlyPlaying)
        XCTAssertFalse(reader.audioPlaybackService.isPlaying)
        XCTAssertTrue(world.requests.hasRequest(for: book.id))
    }

    // MARK: - Finishing a book

    /// A book that finishes with Continue to Next Book says "Starting" once,
    /// then, after a moment, leaves the next book a request and asks for its
    /// window exactly once, naming both books. The finished reader itself
    /// stays silent, counted finished, and rests at its end no longer: the
    /// next book takes the media controls.
    func testFinishedBookAnnouncesTheNextOnceThenAsksForIt() throws {
        let finished = try makeAudioBook(title: "First Volume", endOfBook: .continueNext)
        let next = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [finished, next])
        let finishedReader = makeReader(for: finished, in: world)
        waitUntilLoaded(finishedReader)
        let asked = recordContinueRequests(in: world)

        let recorder = recordingAnnouncements {
            finishedReader.handleEndOfBook()

            XCTAssertTrue(asked().isEmpty, "Asked before the announcement had a moment")
            XCTAssertFalse(world.requests.hasRequest(for: next.id), "Requested before asking")
            // The hand-over begins with the announcement, before the next
            // book is asked for.
            XCTAssertFalse(finishedReader.hasFinishedBook, "The book still rests finished as it says Starting")
            XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")
            // Long enough for any second request to arrive.
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Volume"])
        XCTAssertEqual(finishedReader.lastAnnouncement, "Starting: Second Volume")
        XCTAssertEqual(asked().count, 1)
        XCTAssertEqual(asked().first?.nextBookID, next.id)
        XCTAssertEqual(
            asked().first?.userInfo?[Notification.ContinueToNextBookKey.previousBookID] as? UUID,
            finished.id
        )
        // Waited for, as `asked()` was, so a busy Mac cannot read the
        // world's request queue too soon (as in the pass-over test below).
        XCTAssertTrue(eventually { world.requests.hasRequest(for: next.id) }, "The next book was never requested")
        XCTAssertFalse(world.requests.hasRequest(for: finished.id))
        XCTAssertFalse(finishedReader.isCurrentlyPlaying)
        XCTAssertFalse(finishedReader.audioPlaybackService.isPlaying)
        XCTAssertFalse(finishedReader.hasFinishedBook, "The book that continued still rests finished at its end")
        XCTAssertEqual(
            ReadingStatsService.shared.stats.finishedBooks.map(\.bookID),
            [finished.id.uuidString]
        )
    }

    /// Finishing a book starts the next one in the reader opened for it,
    /// once that reader has loaded; only the finished book says anything.
    func testFinishingABookStartsTheNextInTheReaderOpenedForIt() throws {
        let finished = try makeAudioBook(title: "First Volume", endOfBook: .continueNext)
        let next = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [finished, next])
        let finishedReader = makeReader(for: finished, in: world)
        waitUntilLoaded(finishedReader)
        let asked = recordContinueRequests(in: world)

        var nextReader: ReaderViewModel?
        var starts: () -> Int = { 0 }
        let recorder = recordingAnnouncements {
            finishedReader.handleEndOfBook()
            XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")
            // The window opened for the request creates the next book's reader.
            let reader = makeReader(for: next, in: world)
            starts = countPlaybackStarts(of: reader)
            nextReader = reader
            waitUntilLoaded(reader)
        }

        let reader = try XCTUnwrap(nextReader)
        XCTAssertEqual(starts(), 1)
        XCTAssertTrue(reader.isCurrentlyPlaying)
        XCTAssertTrue(reader.audioPlaybackService.isPlaying)
        XCTAssertNil(reader.lastAnnouncement)
        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Volume"])
        XCTAssertFalse(finishedReader.isCurrentlyPlaying)
        XCTAssertFalse(world.requests.hasRequest(for: next.id))
    }

    /// Finishing a book starts its next book in a reader already open and
    /// loaded, exactly once, and that reader announces nothing.
    func testFinishingABookStartsItsAlreadyOpenNextBookOnce() throws {
        let finished = try makeAudioBook(title: "First Volume", endOfBook: .continueNext)
        let next = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [finished, next])
        let finishedReader = makeReader(for: finished, in: world)
        let nextReader = makeReader(for: next, in: world)
        waitUntilLoaded(finishedReader)
        waitUntilLoaded(nextReader)
        let starts = countPlaybackStarts(of: nextReader)

        let recorder = recordingAnnouncements {
            finishedReader.handleEndOfBook()
            XCTAssertTrue(eventually { nextReader.isCurrentlyPlaying }, "The next book never started")
            // Long enough for any second start to happen.
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(starts(), 1)
        // Waited for, not read once the spin above ends: the spin is there
        // for a second start, which must not come, not for the first.
        XCTAssertTrue(eventually { nextReader.audioPlaybackService.isPlaying }, "The next book's audio never played")
        XCTAssertNil(nextReader.lastAnnouncement)
        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Volume"])
        XCTAssertFalse(finishedReader.isCurrentlyPlaying)
        XCTAssertFalse(finishedReader.audioPlaybackService.isPlaying)
        XCTAssertFalse(world.requests.hasRequest(for: next.id))
    }

    /// The last book in its folder says so and asks for nothing.
    func testLastBookInItsFolderAsksForNothing() throws {
        let finished = try makeAudioBook(title: "Only Volume", endOfBook: .continueNext)
        let world = try makeWorld(books: [finished])
        let finishedReader = makeReader(for: finished, in: world)
        waitUntilLoaded(finishedReader)
        let asked = recordContinueRequests(in: world)

        let recorder = recordingAnnouncements {
            finishedReader.handleEndOfBook()
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(
            recorder.announcements.map(\.message),
            ["Finished: Only Volume. No more books in folder."]
        )
        XCTAssertTrue(asked().isEmpty)
    }

    // MARK: - Passing over finished books (REV14)

    /// A book that finishes with Continue to Next Book passes over the
    /// finished books after it in its folder: it says "Starting" for the
    /// first one not finished and asks for that one alone. Each finished
    /// book once came next, its reader opened, and its Play at the end went
    /// straight on to the book after it, one window for each.
    func testFinishingABookPassesOverFinishedBooksToTheNextUnfinishedOne() throws {
        let finished = try makeAudioBook(title: "First Volume", endOfBook: .continueNext)
        let finishedBefore = try makeAudioBook(title: "Second Volume", restingAtItsEnd: true)
        let next = try makeAudioBook(title: "Third Volume")
        let world = try makeWorld(books: [finished, finishedBefore, next])
        let finishedReader = makeReader(for: finished, in: world)
        waitUntilLoaded(finishedReader)
        let asked = recordContinueRequests(in: world)

        let recorder = recordingAnnouncements {
            finishedReader.handleEndOfBook()
            XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")
            // Long enough for any second request to arrive.
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Third Volume"])
        XCTAssertEqual(asked().map(\.nextBookID), [next.id])
        // The request reaches the world's queue just after the ask is
        // recorded: wait for it, as `asked()` was waited for, so a busy Mac
        // cannot read it too soon.
        XCTAssertTrue(eventually { world.requests.hasRequest(for: next.id) }, "The next book was never requested")
        XCTAssertFalse(world.requests.hasRequest(for: finishedBefore.id), "The finished book was asked for")
    }

    /// A book that finishes with Continue to Next Book where only finished
    /// books follow it says so, rests finished, and asks for nothing.
    func testFinishingABookBeforeOnlyFinishedBooksSaysSo() throws {
        let finished = try makeAudioBook(title: "First Volume", endOfBook: .continueNext)
        let finishedBefore = try makeAudioBook(title: "Second Volume", restingAtItsEnd: true)
        let world = try makeWorld(books: [finished, finishedBefore])
        let finishedReader = makeReader(for: finished, in: world)
        waitUntilLoaded(finishedReader)
        let asked = recordContinueRequests(in: world)

        let recorder = recordingAnnouncements {
            finishedReader.handleEndOfBook()
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(
            recorder.announcements.map(\.message),
            ["Finished: First Volume. Every book after it in the folder is finished."]
        )
        XCTAssertEqual(EndOfBookWording.onlyFinishedBooksInFolderNote, "Every book after it in the folder is finished")
        XCTAssertTrue(asked().isEmpty)
        XCTAssertTrue(finishedReader.hasFinishedBook, "The book does not rest finished")
    }

    /// Play on a finished book whose end continues to the next book
    /// (`playFromTheEnd()`, TODO P07) passes over the finished books after
    /// it as its end does, plays nothing of its own, and asks for the first
    /// book not finished alone.
    func testPlayAtTheEndPassesOverFinishedBooks() throws {
        let finished = try makeAudioBook(title: "First Volume", endOfBook: .continueNext, restingAtItsEnd: true)
        let finishedBefore = try makeAudioBook(title: "Second Volume", restingAtItsEnd: true)
        let next = try makeAudioBook(title: "Third Volume")
        let world = try makeWorld(books: [finished, finishedBefore, next])
        let reader = makeReader(
            for: finished,
            in: world,
            nowPlaying: NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        )
        waitUntilLoaded(reader)
        XCTAssertTrue(reader.cursorRestsAtEnd, "The finished book did not open at its end")
        let asked = recordContinueRequests(in: world)

        let recorder = recordingAnnouncements {
            reader.play()
            XCTAssertTrue(eventually { !asked().isEmpty }, "Play at the end never asked for the next book")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Third Volume"])
        XCTAssertEqual(asked().map(\.nextBookID), [next.id])
        XCTAssertFalse(reader.audioPlaybackService.isPlaying, "Play at the end played the finished book")
    }

    // MARK: - Resting at the end

    /// Where a finished book rests follows its end-of-book behavior, and
    /// decides what a backward skip then does. A book that stops at its
    /// end, that continues when no book follows, or whose own sleep timer
    /// keeps the next book from starting rests finished at its end: it
    /// keeps its media session, and Skip Backward, from the keyboard or as
    /// the AirPods' rewind, plays it again from where the skip lands. A book
    /// that continues to the next book hands the media controls over to it
    /// as it says "Starting", so it is not finished: a skip moves its cursor
    /// and plays nothing (REV07, speech finding 5). A book that loops starts
    /// again, and one whose timer keeps it from restarting waits at its
    /// beginning, so neither is finished: a skip there starts nothing. The
    /// skip announces nothing in any case, and leaves no book finished.
    func testWhereAFinishedBookRestsFollowsItsEndOfBookBehavior() throws {
        let cases: [(
            name: String, behavior: EndOfBookBehavior, hasNext: Bool, timer: Bool,
            announcement: String, finished: Bool, chapter: Int, playsAfterSkipBackward: Bool
        )] = [
            ("stop", .stop, false, false, "Finished: First Volume", true, 1, true),
            ("stop with the timer", .stop, false, true, "Finished: First Volume. Sleep timer expired.", true, 1, true),
            // It stops at the end as Stop does; only Play at the end differs.
            ("stop, and Play starts over", .stopAndPlayStartsOver, false, false, "Finished: First Volume", true, 1, true),
            (
                "continue with no next book", .continueNext, false, false,
                "Finished: First Volume. No more books in folder.", true, 1, true
            ),
            (
                "continue with the timer", .continueNext, true, true,
                "Finished: First Volume. Next book not started because of the sleep timer.", true, 1, true
            ),
            ("continue to the next book", .continueNext, true, false, "Starting: Second Volume", false, 1, false),
            ("loop", .loop, false, false, "Restarting: First Volume", false, 0, true),
            (
                "loop with the timer", .loop, false, true,
                "Finished: First Volume. Not restarted because of the sleep timer.", false, 0, false
            ),
        ]
        for testCase in cases {
            let finished = try makeAudioBook(title: "First Volume", endOfBook: testCase.behavior)
            var books = [finished]
            if testCase.hasNext {
                books.append(try makeAudioBook(title: "Second Volume"))
            }
            let world = try makeWorld(books: books)
            // Fifteen seconds back from the end of the second track, where
            // the finished book rests, lands at the start of the first.
            world.settings.skipBackwardUnit = .seconds15
            // The reader joins a media session of its own, as its only
            // reader, so it is the active owner, as a finished book's reader
            // is while no other book plays: a finished book plays again on a
            // backward skip only then. Readers of other tests may still be
            // registered in the app's shared session.
            let reader = makeReader(
                for: finished,
                in: world,
                nowPlaying: NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
            )
            waitUntilLoaded(reader)
            if testCase.timer {
                startSleepTimer(.endOfBook, for: reader)
            }

            let ending = recordingAnnouncements {
                reader.handleEndOfBook()
                spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
            }
            XCTAssertEqual(ending.announcements.map(\.message), [testCase.announcement], testCase.name)
            XCTAssertEqual(reader.hasFinishedBook, testCase.finished, "\(testCase.name): finished")
            XCTAssertEqual(reader.currentChapterIndex, testCase.chapter, "\(testCase.name): chapter")
            // Every end but a loop's rests exactly at the book's end, saved
            // there, the book that continued included (TODO P07); a loop
            // starts again, or waits, at the beginning.
            let restsAtEnd = testCase.behavior != .loop
            XCTAssertEqual(reader.cursorRestsAtEnd, restsAtEnd, "\(testCase.name): at the end")
            if restsAtEnd {
                XCTAssertEqual(
                    reader.currentCharacterOffset,
                    reader.endOfBookPlace?.characterOffset,
                    "\(testCase.name): short of the end"
                )
                XCTAssertEqual(
                    world.library.bookByID(finished.id)?.readingPosition?.globalCharacterOffset,
                    reader.content?.totalCharacterCount,
                    "\(testCase.name): not saved at the end"
                )
            }
            // Only a loop that restarts plays after the end: its playing is
            // waited for, not read once the spin above ends, which is there
            // for what must not start.
            if testCase.behavior == .loop && !testCase.timer {
                XCTAssertTrue(
                    eventually { reader.audioPlaybackService.isPlaying },
                    "\(testCase.name): not playing after the end"
                )
            } else {
                XCTAssertFalse(reader.audioPlaybackService.isPlaying, "\(testCase.name): playing after the end")
            }

            let skipping = recordingAnnouncements {
                reader.skipBackward()
            }
            XCTAssertEqual(skipping.announcements, [], "\(testCase.name): the skip announced something")
            XCTAssertEqual(
                reader.audioPlaybackService.isPlaying,
                testCase.playsAfterSkipBackward,
                "\(testCase.name): playing after Skip Backward"
            )
            XCTAssertFalse(reader.hasFinishedBook, "\(testCase.name): still finished after Skip Backward")
        }
    }

    // MARK: - Sleep timer

    /// The finished book's own sleep timer ends listening while it is in
    /// effect and fades out or waits for a place: a timer set for the end of
    /// the heading or of the book is still in effect as the last chapter
    /// ends, since it ends there itself. A timer counting minutes goes on
    /// with the next book instead (0.2.5), a timer that has ended does not
    /// end anything, and another book's never does.
    func testOnlyTheFinishedBooksEffectiveSleepTimerEndsListening() {
        let cases: [(name: String, owned: Bool, active: Bool, fadesOrWaits: Bool, ends: Bool)] = [
            ("fading out, or waiting for a heading's or the book's end", true, true, true, true),
            ("counting minutes: it goes on with the next book", true, true, false, false),
            ("ended: run out, stopped at an earlier heading's end, or cancelled", true, false, false, false),
            ("another reader's, in effect", false, true, true, false),
            ("another reader's, ended", false, false, false, false),
        ]
        for testCase in cases {
            XCTAssertEqual(
                ReaderViewModel.sleepTimerEndsListening(
                    timerBelongsToThisReader: testCase.owned,
                    timerIsActive: testCase.active,
                    timerFadesOutOrWaitsForAPlace: testCase.fadesOrWaits
                ),
                testCase.ends,
                testCase.name
            )
        }
    }

    /// A sleep timer counting minutes goes on with the next book (0.2.5): the
    /// next book starts, "Starting: <title>", and the timer is the next
    /// reader's from then on, running, with its time left and its duration as
    /// they were, never restarted. The next reader is in a window of its own,
    /// so the timer changes windows: the next reader's window's timer has it,
    /// and the finished reader's window's timer has stopped.
    func testFinishedBooksRunningSleepTimerGoesOnWithTheNextBook() throws {
        let finished = try makeAudioBook(title: "First Volume", endOfBook: .continueNext)
        let next = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [finished, next])
        let finishedReader = makeReader(for: finished, in: world)
        let nextReader = makeReader(for: next, in: world)
        waitUntilLoaded(finishedReader)
        waitUntilLoaded(nextReader)
        startSleepTimer(.minutes(30), for: finishedReader)
        let before = finishedReader.sleepTimerService.remainingSeconds

        let recorder = recordingAnnouncements {
            finishedReader.handleEndOfBook()
            XCTAssertTrue(eventually { nextReader.isCurrentlyPlaying }, "The next book never started")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Volume"])
        // The next reader's window's timer: the timer changed windows.
        let timer = nextReader.sleepTimerService
        XCTAssertFalse(finishedReader.sleepTimerService.isActive, "The finished reader's window kept a timer")
        XCTAssertTrue(timer.isActive, "The timer ended with the book")
        XCTAssertEqual(timer.ownerID, nextReader.readerID, "The next reader does not own the timer")
        XCTAssertEqual(timer.duration, .minutes(30))
        XCTAssertLessThanOrEqual(timer.remainingSeconds, before)
        XCTAssertGreaterThan(timer.remainingSeconds, before - 60, "The countdown was reset or lost")
    }

    /// The finished book's close leaves a timer it handed over running: the
    /// reader that takes the next book, in a window of its own, takes it
    /// afterwards into its window's timer, once, and exactly one reader owns
    /// it throughout. The finished reader's window's timer has stopped by then.
    func testTheFinishedReadersCloseDoesNotStopAHandedOverTimer() throws {
        let finished = try makeAudioBook(title: "First Volume", endOfBook: .continueNext)
        let next = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [finished, next])
        let finishedReader = makeReader(for: finished, in: world)
        waitUntilLoaded(finishedReader)
        // The finished reader's window's timer, held for the next book.
        let finishedTimer = startSleepTimer(.minutes(30), for: finishedReader)

        // The ask: a request for the next book to take the timer, as a switch
        // makes it before the next reader exists.
        finishedReader.holdSleepTimer(forBook: next.id)
        finishedTimer.markAsked(forBook: next.id)
        finishedReader.close()
        XCTAssertTrue(finishedTimer.isActive, "Closing the reader stopped a timer it handed over")
        XCTAssertEqual(
            finishedTimer.ownerID, finishedReader.readerID, "Exactly one owner until the next reader takes it"
        )

        // The next book opens in a window of its own: its window's timer
        // takes the running timer, and the finished reader's window's stops.
        let nextReader = makeReader(for: next, in: world)
        waitUntilLoaded(nextReader)
        let timer = nextReader.sleepTimerService
        XCTAssertTrue(timer.isActive)
        XCTAssertEqual(timer.ownerID, nextReader.readerID)
        XCTAssertFalse(finishedTimer.isActive, "The finished reader's window kept a timer")
        XCTAssertFalse(
            SleepTimerRegistry.shared.isHeld(forBook: next.id), "The hold was left after the next reader took the timer"
        )
    }

    /// The timer runs out in the half second between "Starting" and the ask:
    /// it has ended listening, so the next book is not asked for or started,
    /// and the listener hears the timer's own expiry.
    func testATimerThatRunsOutBeforeTheNextBookIsAskedForEndsListening() throws {
        let finished = try makeAudioBook(title: "First Volume", endOfBook: .continueNext)
        let next = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [finished, next])
        let finishedReader = makeReader(for: finished, in: world)
        let nextReader = makeReader(for: next, in: world)
        waitUntilLoaded(finishedReader)
        waitUntilLoaded(nextReader)
        // Started by the reader, so its expiry is heard as the listener hears
        // it: the finished reader's window's timer.
        startSleepTimer(.minutes(30), for: finishedReader)
        finishedReader.startSleepTimer(duration: .minutes(30))
        let asked = recordContinueRequests(in: world)

        let recorder = recordingAnnouncements {
            finishedReader.handleEndOfBook()
            finishedReader.sleepTimerService._expireForTesting()
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(
            recorder.announcements.map(\.message),
            ["Starting: Second Volume", ReaderViewModel.sleepTimerExpiredAnnouncement]
        )
        XCTAssertTrue(asked().isEmpty, "Asked for the next book after the timer ran out")
        XCTAssertFalse(world.requests.hasRequest(for: next.id), "A request for the next book was left")
        XCTAssertFalse(nextReader.isCurrentlyPlaying, "The next book started after the timer ran out")
    }

    /// A timer that ran out before the next book took it ends listening: the
    /// reader that loads the next book finds it so, drops the request to
    /// start it, and does not play.
    func testATimerThatRanOutBeforeTheNextBookLoadedKeepsItFromStarting() throws {
        let finished = try makeAudioBook(title: "First Volume", endOfBook: .continueNext)
        let next = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [finished, next])
        let finishedReader = makeReader(for: finished, in: world)
        waitUntilLoaded(finishedReader)
        startSleepTimer(.minutes(30), for: finishedReader)
        finishedReader.holdSleepTimer(forBook: next.id)
        _ = world.requests.request(for: next.id, from: finished.id)
        finishedReader.sleepTimerService._expireForTesting()

        let nextReader = makeReader(for: next, in: world)
        waitUntilLoaded(nextReader)
        spinMainRunLoop(for: 0.5)

        XCTAssertFalse(nextReader.isCurrentlyPlaying, "The next book started after the timer ran out")
        XCTAssertFalse(world.requests.hasRequest(for: next.id), "The request to start it was left")
        // The timer ran out in the finished reader's window and went nowhere.
        XCTAssertFalse(finishedReader.sleepTimerService.isActive)
        XCTAssertFalse(nextReader.sleepTimerService.isActive, "The next reader's window took a timer that ran out")
    }

    /// A timer fading out is putting the listener to sleep: it ends
    /// listening at the book's end, and the next book is not started, as the
    /// end says today.
    func testATimerFadingOutKeepsTheNextBookFromStarting() throws {
        try assertSleepTimerKeepsTheNextBookFromStarting { finishedReader in
            // The finished reader's window's timer, started again with a
            // fade, and run out into it.
            let timer = startSleepTimer(.minutes(1), for: finishedReader)
            timer.start(
                duration: .minutes(1), ownerID: finishedReader.readerID, onExpire: {}, fadeOutDuration: 5
            )
            timer._expireForTesting()
            XCTAssertTrue(timer.isFadingOut)
        }
    }

    /// A timer set for the end of the heading stops playback where the
    /// book's last chapter ends, which ends the last heading, so the next
    /// book is not started, and the timer ends there.
    func testEndOfHeadingTimerAtTheBooksEndKeepsTheNextBookFromStarting() throws {
        var finishedTimer: SleepTimerService?
        try assertSleepTimerKeepsTheNextBookFromStarting { finishedReader in
            finishedTimer = startSleepTimer(.endOfHeading, for: finishedReader)
        }
        XCTAssertEqual(finishedTimer?.isActive, false, "The timer did not end with the book")
    }

    /// The timer belongs to the reader that set it: one set in another
    /// window of the finished book does not keep this window's book from
    /// continuing to the next. The two windows have a timer each, and the
    /// other window's goes on running, untouched by the hand-over.
    func testATimerSetByAnotherReaderOfTheSameBookDoesNotStopContinuing() throws {
        let finished = try makeAudioBook(title: "First Volume", endOfBook: .continueNext)
        let next = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [finished, next])
        let finishedReader = makeReader(for: finished, in: world)
        let secondWindowOfFinished = makeReader(for: finished, in: world)
        let nextReader = makeReader(for: next, in: world)
        waitUntilLoaded(finishedReader)
        waitUntilLoaded(secondWindowOfFinished)
        waitUntilLoaded(nextReader)
        // Set in the second window of the finished book, whose timer is its own.
        let otherWindowsTimer = startSleepTimer(.minutes(30), for: secondWindowOfFinished)

        let recorder = recordingAnnouncements {
            finishedReader.handleEndOfBook()
            XCTAssertTrue(eventually { nextReader.isCurrentlyPlaying }, "The next book never started")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Volume"])
        XCTAssertTrue(nextReader.audioPlaybackService.isPlaying)
        XCTAssertTrue(otherWindowsTimer.isActive, "The other window's timer ended")
        XCTAssertFalse(finishedReader.sleepTimerService.isActive, "The finished window has a timer it never set")
    }

    /// Another book's sleep timer pauses only that book, so it does not
    /// keep the finished book from continuing.
    func testAnotherBooksSleepTimerDoesNotStopContinuing() throws {
        let finished = try makeAudioBook(title: "First Volume", endOfBook: .continueNext)
        let next = try makeAudioBook(title: "Second Volume")
        let otherBook = try makeAudioBook(title: "Third Volume")
        let world = try makeWorld(books: [finished, next, otherBook])
        let finishedReader = makeReader(for: finished, in: world)
        let nextReader = makeReader(for: next, in: world)
        waitUntilLoaded(finishedReader)
        waitUntilLoaded(nextReader)
        // Another book's reader, in a window of its own with a timer of its own.
        let otherBooksReader = makeReader(for: otherBook, in: world)
        waitUntilLoaded(otherBooksReader)
        let otherBooksTimer = startSleepTimer(.minutes(30), for: otherBooksReader)

        let recorder = recordingAnnouncements {
            finishedReader.handleEndOfBook()
            XCTAssertTrue(eventually { nextReader.isCurrentlyPlaying }, "The next book never started")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Volume"])
        XCTAssertTrue(nextReader.audioPlaybackService.isPlaying)
        XCTAssertTrue(otherBooksTimer.isActive, "The other book's timer ended")
    }

    // MARK: - Counting starts

    /// The start counter the tests above rely on counts every Play, even
    /// one over a reader already playing, so a second start cannot pass
    /// unnoticed, and never a pause. A paused audio book stays "playing but
    /// paused" and claims the Playing state again as it pauses; an
    /// audio-route change that paused the next book mid-test once made the
    /// counter report two starts for one.
    func testStartCounterCountsEveryPlayButNoPause() throws {
        let book = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [book])
        let reader = makeReader(for: book, in: world)
        waitUntilLoaded(reader)
        let starts = countPlaybackStarts(of: reader)

        reader.play()
        XCTAssertEqual(starts(), 1)

        // An output-route change pauses the book, as CoreAudio can at any
        // moment of a hosted test; the book still claims to be playing.
        reader.pauseForAudioRouteChange()
        XCTAssertTrue(reader.isCurrentlyPlaying)
        XCTAssertTrue(reader.isCurrentlyPaused)
        XCTAssertEqual(starts(), 1, "A pause was counted as a start")

        // Play starts the audio again each time it is asked: once over the
        // paused book, and once more over the book now playing.
        reader.play()
        reader.play()
        XCTAssertEqual(starts(), 3, "A Play went uncounted")
    }

    // MARK: - Fixtures

    /// A test's private surroundings: the library holding its books,
    /// settings in a private preferences suite, and the notification center
    /// and request store its readers share.
    private struct World {
        let library: LibraryViewModel
        let settings: SettingsViewModel
        let notifications: NotificationCenter
        let requests: ReaderAutoplayRequests
    }

    /// A world whose library holds `books`. Listening statistics start
    /// empty with no open session; they and the preferences suite are put
    /// back when the test ends.
    private func makeWorld(books: [Book]) throws -> World {
        let defaults = makeSandboxedPreferences("continue-to-next-book")
        let notifications = NotificationCenter()
        let settings = SettingsViewModel(
            notificationCenter: notifications,
            initializeServices: false,
            userDefaults: defaults
        )
        let library = LibraryViewModel()
        library.library = Library(books: books)

        let statistics = ReadingStatsService.shared
        let savedStatistics = statistics.stats
        statistics.endSession()
        statistics.stats = ReadingStats()
        addTeardownBlock {
            statistics.endSession()
            statistics.stats = savedStatistics
            statistics.save()
        }

        return World(
            library: library,
            settings: settings,
            notifications: notifications,
            requests: ReaderAutoplayRequests()
        )
    }

    /// An audio book of two silent tracks in its own package, indexed as an
    /// import indexes it, opening at `savedPosition`, or finished. The
    /// package is removed when the test ends.
    ///
    /// - Parameters:
    ///   - title: The book's title, which also orders it in its folder.
    ///   - endOfBook: The book's own end-of-book behavior.
    ///   - restingAtItsEnd: Whether the book is finished: measured, and
    ///     saved exactly at its end (`Book.restsAtEnd`), as a book that
    ///     played to its end rests (TODO P07).
    private func makeAudioBook(
        title: String,
        endOfBook: EndOfBookBehavior = .stop,
        restingAtItsEnd: Bool = false
    ) throws -> Book {
        let packageName = "\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        let tracksFolder = package.appendingPathComponent("Tracks", isDirectory: true)
        for trackName in ["01.wav", "02.wav"] {
            try AudioTestFixtures.writeSilence(
                to: tracksFolder.appendingPathComponent(trackName),
                duration: Self.trackDuration
            )
        }
        var book = Book(
            title: title,
            format: .audio,
            filePath: tracksFolder.path,
            md5Hash: UUID().uuidString,
            readingPosition: Self.savedPosition,
            tmbDirectoryName: packageName,
            localEndOfBookBehavior: endOfBook.rawValue
        )
        let analysis = try BookContentAnalysisService.load(book: book)
        if restingAtItsEnd {
            // Its last chapter at its full length, the book's total.
            let index = analysis.index
            book.totalCharacterCount = index.totalCharacterCount
            book.readingPosition = ReadingPosition(
                chapterIndex: max(0, index.chapters.count - 1),
                characterOffset: index.chapters.last?.characterCount ?? 0,
                globalCharacterOffset: index.totalCharacterCount
            )
            XCTAssertTrue(book.restsAtEnd, "\(title) does not rest at its end")
        }
        try book.saveBookInfoThrowing(contentIndex: analysis.index)
        return book
    }

    /// A reader for `book` in `world`, which starts loading at once and is
    /// closed when the test ends.
    ///
    /// The reader is in a window of its own, as a book opened from the
    /// Library is, so it has a sleep timer of its own (`sleepTimerService`):
    /// a reader made with none would share the shared timer.
    ///
    /// - Parameters:
    ///   - requests: The request store, when not the world's own.
    ///   - nowPlaying: The Now Playing coordinator the reader joins, when
    ///     not the app's shared one.
    private func makeReader(
        for book: Book,
        in world: World,
        requests: ReaderAutoplayRequests? = nil,
        nowPlaying: NowPlayingService? = nil
    ) -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: world.settings,
            autoplayRequests: requests ?? world.requests,
            notificationCenter: world.notifications,
            nowPlaying: nowPlaying,
            sleepTimer: SleepTimerService()
        )
        addTeardownBlock { reader.close() }
        return reader
    }

    /// Ask for `bookID` the way a finished book does: leave a request in the
    /// world's store, then announce it on the world's notification center.
    private func continueTo(_ bookID: UUID, in world: World) {
        let request = world.requests.request(for: bookID, from: UUID())
        world.notifications.post(
            name: .continueToNextBook,
            object: nil,
            userInfo: request.notificationUserInfo
        )
    }

    /// Wait until `reader` has finished loading its book, successfully or
    /// not, including whatever it does as loading ends.
    private func waitUntilLoaded(_ reader: ReaderViewModel) {
        let loaded = expectation(description: "Loading ended")
        reader.$isLoading
            .filter { !$0 }
            .prefix(1)
            .sink { _ in loaded.fulfill() }
            .store(in: &subscriptions)
        wait(for: [loaded], timeout: 10)
    }

    /// Count every time `reader` starts playing from now on. Play claims the
    /// Playing state each time it starts audio, even over a reader already
    /// playing, so a second start is counted. Pausing claims it as well,
    /// since a paused audio book stays "playing but paused", but such a
    /// claim is not a start: an audio-route change can pause a book at any
    /// moment of a hosted test.
    ///
    /// A plain count of changes from not playing to playing would miss a
    /// second Play over a reader already playing, which is the double start
    /// these tests look for.
    ///
    /// - Returns: A function reading the count so far.
    private func countPlaybackStarts(of reader: ReaderViewModel) -> () -> Int {
        var starts = 0
        reader.$isCurrentlyPlaying
            .dropFirst()
            // Play starts the audio service and pause pauses it before
            // either claims the Playing state, so the service's own paused
            // flag tells a start from a pause as the claim is published.
            .filter { [weak reader] isPlaying in
                isPlaying && reader?.audioPlaybackService.isPaused == false
            }
            .sink { _ in starts += 1 }
            .store(in: &subscriptions)
        return { starts }
    }

    /// Check that the sleep timer `setUpTimer` arranges for the finished
    /// book keeps an open, loaded next book from starting: the finished book
    /// says it finished and why the next one did not start, leaves no
    /// request, and asks for no window.
    ///
    /// - Parameter setUpTimer: Arranges the finished book's reader's window's
    ///   sleep timer, given the finished book's reader, its owner, just
    ///   before the book ends.
    private func assertSleepTimerKeepsTheNextBookFromStarting(
        _ setUpTimer: (ReaderViewModel) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let finished = try makeAudioBook(title: "First Volume", endOfBook: .continueNext)
        let next = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [finished, next])
        let finishedReader = makeReader(for: finished, in: world)
        let nextReader = makeReader(for: next, in: world)
        waitUntilLoaded(finishedReader)
        waitUntilLoaded(nextReader)
        let asked = recordContinueRequests(in: world)
        setUpTimer(finishedReader)

        let recorder = recordingAnnouncements {
            finishedReader.handleEndOfBook()
            // Long enough for a request to have been made.
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(
            recorder.announcements.map(\.message),
            ["Finished: First Volume. Next book not started because of the sleep timer."],
            file: file,
            line: line
        )
        XCTAssertTrue(asked().isEmpty, "Asked for the next book", file: file, line: line)
        XCTAssertFalse(world.requests.hasRequest(for: next.id), "Requested the next book", file: file, line: line)
        XCTAssertFalse(nextReader.isCurrentlyPlaying, "The next book started", file: file, line: line)
        XCTAssertFalse(nextReader.audioPlaybackService.isPlaying, "The next book plays", file: file, line: line)
        XCTAssertEqual(
            ReadingStatsService.shared.stats.finishedBooks.map(\.bookID),
            [finished.id.uuidString],
            file: file,
            line: line
        )
    }

    /// Start the sleep timer of `reader`'s window for `reader`, which owns it.
    /// The class's `setUp` (`preserveSleepTimers()`) stops it when the test
    /// ends and puts back the user's last-used duration and its saved
    /// preference.
    ///
    /// - Returns: The reader's window's timer.
    @discardableResult
    private func startSleepTimer(
        _ duration: SleepTimerDuration,
        for reader: ReaderViewModel
    ) -> SleepTimerService {
        let timer = reader.sleepTimerService
        timer.start(duration: duration, ownerID: reader.readerID, onExpire: {})
        return timer
    }

    /// Record every `.continueToNextBook` posted on `world`'s notification
    /// center from now on.
    ///
    /// - Returns: A function reading the notifications posted so far.
    private func recordContinueRequests(in world: World) -> () -> [Notification] {
        var posted: [Notification] = []
        world.notifications.publisher(for: .continueToNextBook)
            .sink { posted.append($0) }
            .store(in: &subscriptions)
        return { posted }
    }

    // MARK: - A Plain Folder's Own Options (FR19)

    /// The three books of a plain folder with listening options of its own,
    /// in the order the folder lists them, in a world of their own.
    private struct FolderWorld {
        let world: World
        let first: Book
        let second: Book
        let third: Book
    }

    /// A world whose library holds the plain folder "Serials" with the books
    /// First, Second and Third Volume, whose folder has `options`
    /// (`LibraryViewModel.setListeningOptions(_:ofFolder:)`), with the global
    /// "When book ends" at `global`. No book has an end-of-book behavior of
    /// its own, unless `own` gives it one.
    ///
    /// - Parameters:
    ///   - options: The folder's listening options, or nil for none.
    ///   - global: The global "When book ends".
    ///   - finished: The titles of the books that rest at their ends.
    ///   - own: The books' own end-of-book behaviors, by title.
    private func makeFolderWorld(
        options: ListeningOptions?,
        global: EndOfBookBehavior = .stop,
        finished: Set<String> = [],
        own: [String: EndOfBookBehavior] = [:]
    ) throws -> FolderWorld {
        // Setting the folder's options saves the library, so the library
        // index is put back when the test ends.
        let index = try LibraryIndexSandbox.capture()
        addTeardownBlock { index.restore() }
        let folder = BookFolder(name: "Serials")
        // `makeAudioBook` makes each package at the top level, but a book
        // placed in the folder saves its record in the folder's own
        // directory, which no package's teardown covers: remove it too, or
        // the next test to open a library adopts what is left as orphaned
        // packages (the full suite saw FeedItemIndexMoveTests fail on them).
        let folderDirectory = TextMouthPaths.libraryDir.appendingPathComponent(folder.fullPath, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folderDirectory) }
        var books: [Book] = []
        for title in ["First Volume", "Second Volume", "Third Volume"] {
            var book = try makeAudioBook(title: title, restingAtItsEnd: finished.contains(title))
            book.folderPath = folder.fullPath
            book.localEndOfBookBehavior = own[title]?.rawValue
            books.append(book)
        }
        let world = try makeWorld(books: books)
        world.library.library.folders = [folder]
        world.library.setListeningOptions(options, ofFolder: folder.id)
        world.settings.endOfBookBehavior = global
        return FolderWorld(world: world, first: books[0], second: books[1], third: books[2])
    }

    /// Ends `book`'s reader as its last chapter's end does, and says what
    /// the reader announced and which books it asked for.
    ///
    /// - Parameters:
    ///   - book: The book whose reader ends.
    ///   - folder: The folder's world.
    ///   - expectingARequest: Whether the end is meant to ask for another
    ///     book, so the wait ends as soon as it does.
    private func endBook(
        _ book: Book,
        in folder: FolderWorld,
        expectingARequest: Bool
    ) -> (announced: [String], asked: [UUID]) {
        let reader = makeReader(for: book, in: folder.world)
        waitUntilLoaded(reader)
        let asked = recordContinueRequests(in: folder.world)
        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            if expectingARequest {
                XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")
            }
            // Long enough for any second request to arrive.
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        return (recorder.announcements.map(\.message), asked().compactMap(\.nextBookID))
    }

    /// "Play the book above" plays the book above when a book ends, saying
    /// "Starting" once; at the top of the folder the book says that no book
    /// follows and plays nothing. The global setting is Stop.
    func testAFolderThatPlaysTheBookAboveGoesUp() throws {
        let folder = try makeFolderWorld(options: ListeningOptions(continuation: .playBookAbove))

        let up = endBook(folder.second, in: folder, expectingARequest: true)
        XCTAssertEqual(up.announced, ["Starting: First Volume"])
        XCTAssertEqual(up.asked, [folder.first.id])

        let top = endBook(folder.first, in: folder, expectingARequest: false)
        XCTAssertEqual(top.announced, ["Finished: First Volume. No more books in folder."])
        XCTAssertEqual(top.asked, [])
    }

    /// "Play the book below" plays the book below, where the global setting
    /// is Stop.
    func testAFolderThatPlaysTheBookBelowGoesDown() throws {
        let folder = try makeFolderWorld(options: ListeningOptions(continuation: .playBookBelow))

        let down = endBook(folder.first, in: folder, expectingARequest: true)
        XCTAssertEqual(down.announced, ["Starting: Second Volume"])
        XCTAssertEqual(down.asked, [folder.second.id])
    }

    /// "Stop" stops where the global setting is Continue to Next Book.
    func testAFolderThatStopsStopsWhereTheGlobalSettingContinues() throws {
        let folder = try makeFolderWorld(options: ListeningOptions(continuation: .stop), global: .continueNext)

        let stopped = endBook(folder.first, in: folder, expectingARequest: false)
        XCTAssertEqual(stopped.announced, ["Finished: First Volume"])
        XCTAssertEqual(stopped.asked, [])
    }

    /// "Use the global setting" follows the global setting: with Continue to
    /// Next Book it plays the book below, as it always did. The options here
    /// are not the standard ones, so the folder keeps them.
    func testAFolderThatUsesTheGlobalSettingContinuesWhereItDoes() throws {
        let options = ListeningOptions(continuation: nil, predownloadsNext: false)
        XCTAssertFalse(options.isStandard)
        let folder = try makeFolderWorld(options: options, global: .continueNext)

        let down = endBook(folder.first, in: folder, expectingARequest: true)
        XCTAssertEqual(down.announced, ["Starting: Second Volume"])
        XCTAssertEqual(down.asked, [folder.second.id])
    }

    /// A folder with no options follows the global setting.
    func testAFolderWithNoOptionsFollowsTheGlobalSetting() throws {
        let folder = try makeFolderWorld(options: nil, global: .continueNext)

        let down = endBook(folder.first, in: folder, expectingARequest: true)
        XCTAssertEqual(down.announced, ["Starting: Second Volume"])
        XCTAssertEqual(down.asked, [folder.second.id])
    }

    /// "Skip finished" passes over a finished book below, and, switched off,
    /// plays it.
    func testSkipFinishedBooksPassesOverAFinishedBookBelowOrPlaysIt() throws {
        let skipping = try makeFolderWorld(
            options: ListeningOptions(continuation: .playBookBelow),
            finished: ["Second Volume"]
        )
        let passedOver = endBook(skipping.first, in: skipping, expectingARequest: true)
        XCTAssertEqual(passedOver.announced, ["Starting: Third Volume"])
        XCTAssertEqual(passedOver.asked, [skipping.third.id])

        let notSkipping = try makeFolderWorld(
            options: ListeningOptions(continuation: .playBookBelow, skipsFinished: false),
            finished: ["Second Volume"]
        )
        let played = endBook(notSkipping.first, in: notSkipping, expectingARequest: true)
        XCTAssertEqual(played.announced, ["Starting: Second Volume"])
        XCTAssertEqual(played.asked, [notSkipping.second.id])
    }

    /// Going up with only finished books above, the book says so in the
    /// words of the direction: "Every book before it in the folder is
    /// finished". Going up with "Skip finished" off, the finished book
    /// plays.
    func testGoingUpPastOnlyFinishedBooksSaysSo() throws {
        XCTAssertEqual(
            EndOfBookWording.onlyFinishedBooksInFolderNote(going: .down),
            EndOfBookWording.onlyFinishedBooksInFolderNote
        )
        XCTAssertEqual(
            EndOfBookWording.onlyFinishedBooksInFolderNote(going: .up),
            "Every book before it in the folder is finished"
        )

        let skipping = try makeFolderWorld(
            options: ListeningOptions(continuation: .playBookAbove),
            finished: ["First Volume"]
        )
        let nothing = endBook(skipping.second, in: skipping, expectingARequest: false)
        XCTAssertEqual(nothing.announced, ["Finished: Second Volume. Every book before it in the folder is finished."])
        XCTAssertEqual(nothing.asked, [])

        let notSkipping = try makeFolderWorld(
            options: ListeningOptions(continuation: .playBookAbove, skipsFinished: false),
            finished: ["First Volume"]
        )
        let played = endBook(notSkipping.second, in: notSkipping, expectingARequest: true)
        XCTAssertEqual(played.announced, ["Starting: First Volume"])
        XCTAssertEqual(played.asked, [notSkipping.first.id])
    }

    /// The book's own end behavior beats the folder's option: a book set to
    /// Stop stops though its folder plays the book above.
    func testABooksOwnEndBehaviorBeatsItsFolders() throws {
        let folder = try makeFolderWorld(
            options: ListeningOptions(continuation: .playBookAbove),
            own: ["Second Volume": .stop]
        )

        let stopped = endBook(folder.second, in: folder, expectingARequest: false)
        XCTAssertEqual(stopped.announced, ["Finished: Second Volume"])
        XCTAssertEqual(stopped.asked, [])
    }

    /// A book opened from the reading list beats both its own end behavior
    /// and its folder's option: the list's next book plays, not the folder's.
    func testAReadingListBeatsTheBooksOwnAndTheFoldersChoice() throws {
        let folder = try makeFolderWorld(
            options: ListeningOptions(continuation: .playBookAbove),
            own: ["Second Volume": .stop]
        )
        // The list holds the second and the third; it plays the one below.
        folder.world.library.library.readingList = ReadingList(bookIDs: [folder.second.id, folder.third.id])
        let requests = ReadingListOpenRequests()
        requests.request(for: folder.second.id)
        let reader = ReaderViewModel(
            book: folder.second,
            libraryViewModel: folder.world.library,
            settingsViewModel: folder.world.settings,
            autoplayRequests: folder.world.requests,
            readingListRequests: requests,
            notificationCenter: folder.world.notifications,
            sleepTimer: SleepTimerService()
        )
        addTeardownBlock { reader.close() }
        waitUntilLoaded(reader)
        XCTAssertTrue(reader.isOpenedFromReadingList, "The book is not read from the list")
        let asked = recordContinueRequests(in: folder.world)

        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the list's next book")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Third Volume"])
        XCTAssertEqual(asked().compactMap(\.nextBookID), [folder.third.id])
    }

    /// Play on a finished book follows the same rule as its end: with the
    /// folder playing the book above, it asks for the book above.
    func testPlayOnAFinishedBookFollowsTheFoldersChoice() throws {
        let folder = try makeFolderWorld(
            options: ListeningOptions(continuation: .playBookAbove),
            finished: ["Second Volume"]
        )
        let reader = makeReader(
            for: folder.second,
            in: folder.world,
            nowPlaying: NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        )
        waitUntilLoaded(reader)
        XCTAssertTrue(reader.cursorRestsAtEnd, "The finished book did not open at its end")
        let asked = recordContinueRequests(in: folder.world)

        let recorder = recordingAnnouncements {
            reader.play()
            XCTAssertTrue(eventually { !asked().isEmpty }, "Play at the end never asked for the book above")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: First Volume"])
        XCTAssertEqual(asked().compactMap(\.nextBookID), [folder.first.id])
        XCTAssertFalse(reader.audioPlaybackService.isPlaying, "Play at the end played the finished book")
    }

    /// The behavior in force that the reader's settings sheet shows follows
    /// the folder's option, and the book's own over it.
    func testTheBehaviorInForceShowsTheFoldersOptionAndTheBooksOwnOverIt() throws {
        let stopping = try makeFolderWorld(options: ListeningOptions(continuation: .stop), global: .continueNext)
        XCTAssertEqual(makeReader(for: stopping.first, in: stopping.world).effectiveEndOfBookBehavior, .stop)

        let continuing = try makeFolderWorld(options: ListeningOptions(continuation: .playBookAbove), global: .stop)
        XCTAssertEqual(makeReader(for: continuing.first, in: continuing.world).effectiveEndOfBookBehavior, .continueNext)

        let own = try makeFolderWorld(
            options: ListeningOptions(continuation: .playBookAbove),
            global: .stop,
            own: ["First Volume": .loop]
        )
        XCTAssertEqual(makeReader(for: own.first, in: own.world).effectiveEndOfBookBehavior, .loop)
    }

    // MARK: - A Hand-over to a Finished Book (REV18a, finding 5)

    /// The library's row for `book`, as the library holds it now.
    private func row(of book: Book, in world: World) -> Book? {
        world.library.library.books.first { $0.id == book.id }
    }

    /// Check that `reader`, claimed by a hand-over while it rested finished,
    /// plays its first track from its beginning, no longer finished, in the
    /// reader and in the library's row.
    ///
    /// - Parameters:
    ///   - reader: The reader of the finished book.
    ///   - world: The world whose library holds the book.
    private func assertPlaysFromItsBeginning(
        _ reader: ReaderViewModel,
        in world: World,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // A fresh test host's first audio takes about five seconds to start.
        XCTAssertTrue(
            eventually(within: 15) { reader.audioPlaybackService.isPlaying },
            "The finished book never played",
            file: file,
            line: line
        )
        XCTAssertEqual(reader.currentChapterIndex, 0, "It did not play from its first chapter", file: file, line: line)
        XCTAssertEqual(
            reader.audioPlaybackService.loadedURL?.lastPathComponent,
            "01.wav",
            "It did not play its first track",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            reader.audioPlaybackService.currentTime,
            1.5,
            "It did not play from its beginning",
            file: file,
            line: line
        )
        XCTAssertFalse(reader.hasFinishedBook, "It is still finished", file: file, line: line)
        XCTAssertFalse(reader.cursorRestsAtEnd, "It still rests at its end", file: file, line: line)
        XCTAssertEqual(
            row(of: reader.book, in: world)?.restsAtEnd,
            false,
            "The library still shows it finished",
            file: file,
            line: line
        )
    }

    /// With "Skip finished" off, a book that ends hands over to the finished
    /// book below, whose reader opens for the request: it plays from its
    /// beginning, announces nothing more, and does not run its own end rule,
    /// which would hand over to the Third Volume and play none of the
    /// Second.
    func testAHandOverToAFinishedBookPlaysItFromItsBeginning() throws {
        let folder = try makeFolderWorld(
            options: ListeningOptions(continuation: .playBookBelow, skipsFinished: false),
            finished: ["Second Volume"]
        )
        XCTAssertTrue(folder.second.restsAtEnd, "The Second Volume is not finished")

        let handOver = endBook(folder.first, in: folder, expectingARequest: true)
        XCTAssertEqual(handOver.announced, ["Starting: Second Volume"])
        XCTAssertEqual(handOver.asked, [folder.second.id])

        // The Second Volume's window opens for the request that waits.
        let asked = recordContinueRequests(in: folder.world)
        let recorder = recordingAnnouncements {
            let reader = makeReader(for: folder.second, in: folder.world)
            waitUntilLoaded(reader)
            assertPlaysFromItsBeginning(reader, in: folder.world)
            // Long enough for a second hand-over to be announced.
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        XCTAssertEqual(recorder.announcements, [], "The finished book announced something")
        XCTAssertTrue(asked().isEmpty, "The finished book handed over to another")
        XCTAssertFalse(folder.world.requests.hasRequest(for: folder.third.id))
    }

    /// The same where the finished book's reader was open, resting at its
    /// end, when the request reached it.
    func testAHandOverToAnOpenFinishedBookPlaysItFromItsBeginning() throws {
        let folder = try makeFolderWorld(
            options: ListeningOptions(continuation: .playBookBelow, skipsFinished: false),
            finished: ["Second Volume"]
        )
        let reader = makeReader(for: folder.second, in: folder.world)
        waitUntilLoaded(reader)
        XCTAssertTrue(reader.cursorRestsAtEnd, "The finished book did not open at its end")
        XCTAssertFalse(reader.audioPlaybackService.isPlaying)

        // The announcement of the First Volume's hand-over is all the
        // listener hears: the Second Volume says nothing of its own.
        let handOver = endBook(folder.first, in: folder, expectingARequest: true)
        XCTAssertEqual(handOver.announced, ["Starting: Second Volume"])
        XCTAssertEqual(handOver.asked, [folder.second.id])

        assertPlaysFromItsBeginning(reader, in: folder.world)
        XCTAssertFalse(folder.world.requests.hasRequest(for: folder.second.id), "The request was left to claim again")
    }

    /// A finished audiobook whose player the book's own end stopped, or left
    /// paused, at its end, plays from its beginning when a hand-over reaches
    /// it: its player is not resumed where it ended.
    func testAHandOverToAnAudiobookItsPlayerEndedPlaysItFromItsBeginning() throws {
        let endings: [(name: String, settle: (ReaderViewModel) -> Void)] = [
            ("stopped", { $0.audioPlaybackService.stop() }),
            ("paused", { $0.pause(playingPauseSound: false) })
        ]
        for (name, settle) in endings {
            let folder = try makeFolderWorld(
                options: ListeningOptions(continuation: .playBookBelow, skipsFinished: false),
                own: ["Second Volume": .stop]
            )
            // The Second Volume plays, then ends by its own rule (Stop), its
            // player left as `settle` leaves it.
            let reader = makeReader(for: folder.second, in: folder.world)
            waitUntilLoaded(reader)
            reader.play()
            XCTAssertTrue(eventually(within: 15) { reader.audioPlaybackService.isPlaying }, "\(name): it never played")
            settle(reader)
            reader.handleEndOfBook()
            XCTAssertTrue(reader.hasFinishedBook, "\(name): the book did not finish")
            XCTAssertTrue(reader.cursorRestsAtEnd, "\(name): the book did not rest at its end")

            // Another book hands over to it.
            continueTo(folder.second.id, in: folder.world)

            assertPlaysFromItsBeginning(reader, in: folder.world)
            XCTAssertFalse(reader.audioPlaybackService.isPaused, "\(name): the player was resumed, not started")
            reader.stop()
        }
    }

    /// A finished text book claimed by a hand-over speaks from its
    /// beginning, and does not reply with its end rule (here, a hand-over of
    /// its own to the next book). Its speech is silenced before the run loop
    /// turns, so nothing is heard.
    func testAHandOverToAFinishedTextBookSpeaksItFromItsBeginning() throws {
        try withSpeechReader("Hand-over To A Finished Text Book", endOfBook: .continueNext) { speech in
            let reader = speech.reader
            reader.restAtEnd()
            reader.hasFinishedBook = true
            XCTAssertTrue(reader.cursorRestsAtEnd, "The text book does not rest at its end")
            let asked = recordContinueRequests(in: speech.world)
            speech.world.autoplayRequests.request(for: speech.book.id, from: UUID())

            let recorder = recordingAnnouncements {
                reader.claimAutoplayRequest()
                // Silenced before anything is heard.
                reader.speechService.stop()
                spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
            }

            XCTAssertEqual(reader.currentChapterIndex, 0, "It did not start from its first chapter")
            XCTAssertFalse(reader.hasFinishedBook)
            XCTAssertFalse(reader.cursorRestsAtEnd)
            XCTAssertEqual(recorder.announcements, [], "The finished book announced something")
            XCTAssertTrue(asked().isEmpty, "The finished book handed over to another")
        }
    }
}
