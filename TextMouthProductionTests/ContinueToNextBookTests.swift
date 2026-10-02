import Combine
import XCTest
@testable import TextMouth

/// Continue to Next Book, from the finished book to the next book's reader.
///
/// The next book's reader starts playing for a finished book's request
/// exactly once, through the normal Play path and without announcing
/// anything: when it finishes loading, or at once when it was already open.
/// Only that book's reader responds, a reader still loading waits until it
/// has loaded, and a book that cannot be loaded drops the request.
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
        let suiteName = "com.textmouth.tests.continue-to-next-book.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
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

    /// Count every time `reader` claims the Playing state from now on. Play
    /// claims it each time it starts audio, even over a reader already
    /// playing, so a second start would be counted.
    ///
    /// - Returns: A function reading the count so far.
    private func countPlaybackStarts(of reader: ReaderViewModel) -> () -> Int {
        var starts = 0
        reader.$isCurrentlyPlaying
            .dropFirst()
            .filter { $0 }
            .sink { _ in starts += 1 }
            .store(in: &subscriptions)
        return { starts }
    }
}
