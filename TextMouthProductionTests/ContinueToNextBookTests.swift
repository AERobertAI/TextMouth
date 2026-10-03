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
/// starting, since it could never pause that book.
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
    /// stays finished.
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
        XCTAssertTrue(world.requests.hasRequest(for: next.id))
        XCTAssertFalse(world.requests.hasRequest(for: finished.id))
        XCTAssertFalse(finishedReader.isCurrentlyPlaying)
        XCTAssertFalse(finishedReader.audioPlaybackService.isPlaying)
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
        XCTAssertTrue(nextReader.audioPlaybackService.isPlaying)
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

    // MARK: - Sleep timer

    /// The finished book's own sleep timer ends listening while it is in
    /// effect, whatever it waits for: a timer set for the end of the chapter
    /// is still in effect as the last chapter ends, since it ends there
    /// itself. A timer that has ended, or another book's, does not.
    func testOnlyTheFinishedBooksEffectiveSleepTimerEndsListening() {
        let cases: [(name: String, owned: Bool, active: Bool, ends: Bool)] = [
            ("counting down, or waiting for a heading's or a chapter's end", true, true, true),
            ("ended: run out, stopped at an earlier chapter's end, or cancelled", true, false, false),
            ("another book's, in effect", false, true, false),
            ("another book's, ended", false, false, false),
        ]
        for testCase in cases {
            XCTAssertEqual(
                ReaderViewModel.sleepTimerEndsListening(
                    timerBelongsToThisBook: testCase.owned,
                    timerIsActive: testCase.active
                ),
                testCase.ends,
                testCase.name
            )
        }
    }

    /// A sleep timer the finished book set could never pause the next book,
    /// so while it counts down the next book is not started: the finished
    /// book says why, and asks for nothing.
    func testFinishedBooksRunningSleepTimerKeepsTheNextBookFromStarting() throws {
        try assertSleepTimerKeepsTheNextBookFromStarting { finishedBookID in
            startSharedSleepTimer(.minutes(30), ownedBy: finishedBookID)
        }
    }

    /// A timer set for the end of the chapter stops playback where the
    /// book's last chapter ends, so the next book is not started, and the
    /// timer ends there.
    func testEndOfChapterTimerAtTheBooksEndKeepsTheNextBookFromStarting() throws {
        try assertSleepTimerKeepsTheNextBookFromStarting { finishedBookID in
            startSharedSleepTimer(.endOfChapter, ownedBy: finishedBookID)
        }
        XCTAssertFalse(SleepTimerService.shared.isActive, "The timer did not end with the book")
    }

    /// Another book's sleep timer pauses only that book, so it does not
    /// keep the finished book from continuing.
    func testAnotherBooksSleepTimerDoesNotStopContinuing() throws {
        let finished = try makeAudioBook(title: "First Volume", endOfBook: .continueNext)
        let next = try makeAudioBook(title: "Second Volume")
        let world = try makeWorld(books: [finished, next])
        let finishedReader = makeReader(for: finished, in: world)
        let nextReader = makeReader(for: next, in: world)
        waitUntilLoaded(finishedReader)
        waitUntilLoaded(nextReader)
        startSharedSleepTimer(.minutes(30), ownedBy: UUID())

        let recorder = recordingAnnouncements {
            finishedReader.handleEndOfBook()
            XCTAssertTrue(eventually { nextReader.isCurrentlyPlaying }, "The next book never started")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: Second Volume"])
        XCTAssertTrue(nextReader.audioPlaybackService.isPlaying)
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
    /// import indexes it, opening at `savedPosition`. The package is removed
    /// when the test ends.
    ///
    /// - Parameters:
    ///   - title: The book's title, which also orders it in its folder.
    ///   - endOfBook: The book's own end-of-book behavior.
    private func makeAudioBook(title: String, endOfBook: EndOfBookBehavior = .stop) throws -> Book {
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
        let book = Book(
            title: title,
            format: .audio,
            filePath: tracksFolder.path,
            md5Hash: UUID().uuidString,
            readingPosition: Self.savedPosition,
            tmbDirectoryName: packageName,
            localEndOfBookBehavior: endOfBook.rawValue
        )
        let analysis = try BookContentAnalysisService.load(book: book)
        try book.saveBookInfoThrowing(contentIndex: analysis.index)
        return book
    }

    /// A reader for `book` in `world`, which starts loading at once and is
    /// closed when the test ends.
    ///
    /// - Parameter requests: The request store, when not the world's own.
    private func makeReader(
        for book: Book,
        in world: World,
        requests: ReaderAutoplayRequests? = nil
    ) -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: world.settings,
            autoplayRequests: requests ?? world.requests,
            notificationCenter: world.notifications
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
    /// - Parameter setUpTimer: Arranges the shared sleep timer, given the
    ///   finished book's ID, just before the book ends.
    private func assertSleepTimerKeepsTheNextBookFromStarting(
        _ setUpTimer: (UUID) -> Void,
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
        setUpTimer(finished.id)

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

    /// Start the app's one sleep timer for `owner`, and put it back as it
    /// was when the test ends: stopped, with the user's last-used duration
    /// and its saved preference restored.
    @discardableResult
    private func startSharedSleepTimer(
        _ duration: SleepTimerDuration,
        ownedBy owner: UUID
    ) -> SleepTimerService {
        let timer = SleepTimerService.shared
        let preferenceKey = "sleepTimer.lastUsedDuration"
        let savedDuration = timer.lastUsedDuration
        let savedPreference = TextMouthRuntime.current.preferences.object(forKey: preferenceKey)
        addTeardownBlock {
            timer._resetForTesting()
            if let savedDuration {
                timer.start(duration: savedDuration, ownerID: UUID(), onExpire: {})
                timer.stop()
            }
            TextMouthRuntime.current.preferences.set(savedPreference, forKey: preferenceKey)
        }
        timer.start(duration: duration, ownerID: owner, onExpire: {})
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
}
