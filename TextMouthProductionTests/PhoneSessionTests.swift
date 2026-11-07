import Combine
import XCTest
@testable import TextMouth

/// `PhoneSession`, the iPhone's one owner of the open book's reader. It runs on
/// the Mac's test host, since nothing can run on iOS tonight, over real readers
/// of silent audiobooks in a private world: its own library, settings,
/// notification center, and requests. Nothing is heard: the sounds go to a
/// player that records them, and under test the media session installs nothing.
@MainActor
final class PhoneSessionTests: XCTestCase {
    /// Subscriptions a test keeps until it ends.
    private var subscriptions = Set<AnyCancellable>()

    // MARK: - Opening

    /// A book opens at once, with its reader held here, its sounds set before
    /// anything can play, the book marked opened, and its ID kept for the next
    /// launch. The reader is still loading, and nothing plays when it has.
    func testOpeningMakesAReaderAndWaitsAtItsPlace() throws {
        let world = try makeIntegrationWorld("PhoneOpen")
        let book = try world.makeSilentAudioBook(
            title: "Tide Tables",
            trackDurations: [5, 5],
            savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: 10, globalCharacterOffset: 60)
        )
        let sounds = makeSounds("PhoneOpen")
        let session = makeSession(in: world, sounds: sounds)
        XCTAssertNil(world.library.bookByID(book.id)?.lastOpened, "The fixture starts unopened")

        let reader = session.open(book)

        XCTAssertTrue(session.reader === reader)
        XCTAssertTrue(reader.soundEffectService === sounds, "A Play from the AirPods could come before any view")
        XCTAssertNotNil(world.library.bookByID(book.id)?.lastOpened, "Not marked opened")
        XCTAssertEqual(session.bookToReopenAtLaunch?.id, book.id)
        XCTAssertEqual(session.snapshot?.bookID, book.id)
        XCTAssertEqual(session.snapshot?.title, "Tide Tables")
        XCTAssertEqual(session.snapshot?.isLoading, true)
        XCTAssertEqual(session.snapshot?.isPlaying, false)

        waitForReaderToLoad(reader)
        XCTAssertTrue(eventually { session.snapshot?.isLoading == false }, "The snapshot never saw the load end")
        XCTAssertEqual(reader.currentChapterIndex, 1, "Not at its saved place")
        XCTAssertEqual(reader.currentCharacterOffset, 10, "Not at its saved place")
        XCTAssertFalse(reader.isPlaybackUnderWay, "A book waits at its place until Play")
    }

    /// Opening the book already open keeps its reader, playing or not.
    func testOpeningTheOpenBookKeepsItsReader() throws {
        let world = try makeIntegrationWorld("PhoneOpenAgain")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let session = makeSession(in: world)

        let first = session.open(book)
        waitForReaderToLoad(first)
        let second = session.open(book)

        XCTAssertTrue(first === second)
        XCTAssertFalse(first.hasClosed)
    }

    /// The reader starts from the library's own row, not from whatever row a
    /// view read a while ago, which could hold an older place.
    func testAStaleRowOpensAtTheLibrarysPlace() throws {
        let world = try makeIntegrationWorld("PhoneStaleRow")
        let stale = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let index = try XCTUnwrap(world.library.library.books.firstIndex { $0.id == stale.id })
        world.library.library.books[index].readingPosition = ReadingPosition(
            chapterIndex: 1, characterOffset: 20, globalCharacterOffset: 70
        )
        let session = makeSession(in: world)

        let reader = session.open(stale)
        waitForReaderToLoad(reader)

        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentCharacterOffset, 20)
    }

    // MARK: - Switching and Closing

    /// Opening another book saves and closes the first, leaves one reader open
    /// and playing nothing, and keeps the new book's ID for the next launch.
    func testSwitchingClosesAndSavesTheOldReader() throws {
        let world = try makeIntegrationWorld("PhoneSwitch")
        let oldBook = try world.makeSilentAudioBook(title: "Old Volume", trackDurations: [5, 5])
        let newBook = try world.makeSilentAudioBook(title: "New Volume", trackDurations: [5, 5])
        let session = makeSession(in: world)
        let old = session.open(oldBook)
        waitForReaderToLoad(old)
        old.currentCharacterOffset = 20

        let new = session.open(newBook)

        XCTAssertTrue(old.hasClosed, "The old reader is still open")
        XCTAssertFalse(new.hasClosed)
        XCTAssertTrue(session.reader === new)
        XCTAssertEqual(session.snapshot?.bookID, newBook.id)
        XCTAssertEqual(world.library.openBookIDs, [newBook.id], "One reader at a time")
        XCTAssertEqual(
            world.library.bookByID(oldBook.id)?.readingPosition?.characterOffset, 20,
            "The old book's place was not saved"
        )
        XCTAssertEqual(session.bookToReopenAtLaunch?.id, newBook.id)
        waitForReaderToLoad(new)
        XCTAssertFalse(new.isPlaybackUnderWay, "The new book waits at its place until Play")
    }

    /// Closing saves and closes the reader, and leaves nothing to open at the
    /// next launch. Closing again does nothing.
    func testClosingEndsTheReaderAndForgetsIt() throws {
        let world = try makeIntegrationWorld("PhoneClose")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let session = makeSession(in: world)
        let reader = session.open(book)
        waitForReaderToLoad(reader)
        reader.currentCharacterOffset = 20

        session.closeReader()

        XCTAssertTrue(reader.hasClosed)
        XCTAssertNil(session.reader)
        XCTAssertNil(session.snapshot)
        XCTAssertNil(session.bookToReopenAtLaunch)
        XCTAssertTrue(world.library.openBookIDs.isEmpty)
        XCTAssertEqual(world.library.bookByID(book.id)?.readingPosition?.characterOffset, 20)

        session.closeReader()
        XCTAssertNil(session.reader)
    }

    /// A closed reader's later changes never reach the session.
    func testAClosedReaderIsNoLongerFollowed() throws {
        let world = try makeIntegrationWorld("PhoneClosedFollow")
        let oldBook = try world.makeSilentAudioBook(title: "Old Volume", trackDurations: [5])
        let newBook = try world.makeSilentAudioBook(title: "New Volume", trackDurations: [5])
        let session = makeSession(in: world)
        let old = session.open(oldBook)
        waitForReaderToLoad(old)
        session.open(newBook)

        old.book.title = "Renamed After Closing"
        spinMainRunLoop(for: 0.1)

        XCTAssertEqual(session.snapshot?.title, "New Volume")
    }

    // MARK: - The Magic Tap

    /// With a reader open, the magic tap plays it, and again pauses it.
    func testTheMagicTapPlaysAndPausesTheOpenBook() throws {
        let world = try makeIntegrationWorld("PhoneTapOpen")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let session = makeSession(in: world)
        let reader = session.open(book)
        waitForReaderToLoad(reader)

        XCTAssertTrue(session.togglePlayPauseFromAnywhere())
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "Never played")

        XCTAssertTrue(session.togglePlayPauseFromAnywhere())
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == false }, "Never paused")
        XCTAssertTrue(session.reader === reader, "It opened another reader")
    }

    /// With no reader open, the magic tap opens the book last opened, and plays
    /// it once it has loaded.
    func testTheMagicTapOpensAndPlaysTheLastBook() throws {
        let world = try makeIntegrationWorld("PhoneTapLast")
        preserveLastOpenedBook()
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        ConfigService.shared.config.lastOpenedBookID = book.id.uuidString
        let session = makeSession(in: world)

        XCTAssertTrue(session.togglePlayPauseFromAnywhere())

        let reader = try XCTUnwrap(session.reader, "No reader opened")
        XCTAssertEqual(reader.book.id, book.id)
        XCTAssertTrue(reader.isLoading, "The load should still be under way")
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "Never played")
    }

    /// With no book ever opened, the magic tap answers false, so that the
    /// system's fallback runs, and opens nothing. So does a last book that has
    /// left the library.
    func testTheMagicTapAnswersFalseWithNoBookToPlay() throws {
        let world = try makeIntegrationWorld("PhoneTapNone")
        preserveLastOpenedBook()
        let session = makeSession(in: world)

        ConfigService.shared.config.lastOpenedBookID = ""
        XCTAssertFalse(session.togglePlayPauseFromAnywhere(), "No book was ever opened")
        XCTAssertNil(session.reader)

        ConfigService.shared.config.lastOpenedBookID = UUID().uuidString
        XCTAssertFalse(session.togglePlayPauseFromAnywhere(), "The last book left the library")
        XCTAssertNil(session.reader)
        XCTAssertNil(session.snapshot)
    }

    /// The magic tap on a finished last book does what Play does there: says
    /// "Finished: <title>", as the user decided on October 10, 2026, and leaves
    /// the book at its end. It is not a finished book's request to go on to the
    /// next, which would start the book over without a word.
    func testTheMagicTapOnAFinishedBookSaysWhatPlaySays() throws {
        let world = try makeIntegrationWorld("PhoneTapFinished")
        preserveLastOpenedBook()
        // A place past the last chapter's end opens at the book's end, finished.
        let book = try world.makeSilentAudioBook(
            title: "Harbour Soundings",
            trackDurations: [5],
            savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: 1_000)
        )
        ConfigService.shared.config.lastOpenedBookID = book.id.uuidString
        let session = makeSession(in: world)

        let recorder = recordingAnnouncements {
            XCTAssertTrue(session.togglePlayPauseFromAnywhere())
            XCTAssertTrue(eventually(within: 30) { session.snapshot?.isLoading == false }, "Never loaded")
            spinMainRunLoop(for: 0.1)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Finished: Harbour Soundings"])
        let reader = try XCTUnwrap(session.reader)
        XCTAssertTrue(reader.cursorRestsAtEnd, "The book moved from its end")
        XCTAssertFalse(reader.isPlaybackUnderWay, "The book played")
    }

    // MARK: - Play While Loading

    /// A press while the book loads waits for the load to end, since a reader
    /// ignores Play until then.
    func testAPressWhileLoadingPlaysOnceLoaded() throws {
        let world = try makeIntegrationWorld("PhonePressLoading")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let session = makeSession(in: world)
        let reader = session.open(book)
        XCTAssertTrue(reader.isLoading, "The load should still be under way")

        session.togglePlayPause()

        XCTAssertFalse(reader.isPlaybackUnderWay, "Nothing to play yet")
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "The press was lost")
    }

    /// A second press while the book loads takes the first back.
    func testASecondPressWhileLoadingTakesItBack() throws {
        let world = try makeIntegrationWorld("PhonePressTwice")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let session = makeSession(in: world)
        let reader = session.open(book)
        XCTAssertTrue(reader.isLoading, "The load should still be under way")

        session.togglePlayPause()
        session.togglePlayPause()
        waitForReaderToLoad(reader)
        spinMainRunLoop(for: 0.2)

        XCTAssertFalse(reader.isPlaybackUnderWay, "The press taken back still played")
    }

    /// A press while a book loads that a finished book asked for means stop:
    /// that book was about to play. A second press wants it played after all.
    func testAPressWhileLoadingStopsABookAboutToPlay() throws {
        let world = try makeIntegrationWorld("PhonePressRequest")
        let previous = try world.makeSilentAudioBook(title: "Previous Volume", trackDurations: [5])
        let book = try world.makeSilentAudioBook(title: "Next Volume", trackDurations: [5, 5])
        world.autoplayRequests.request(for: book.id, from: previous.id)
        let session = makeSession(in: world)
        let reader = session.open(book)
        XCTAssertTrue(reader.isLoading, "The load should still be under way")

        session.togglePlayPause()

        XCTAssertFalse(world.autoplayRequests.hasRequest(for: book.id), "The request still waits")
        waitForReaderToLoad(reader)
        spinMainRunLoop(for: 0.2)
        XCTAssertFalse(reader.isPlaybackUnderWay, "The book played though the press said stop")
    }

    /// A book that could not load has nothing to play: the press that waited
    /// for it does nothing, and no later change of the reader plays it.
    func testAPressWaitingForABookThatCannotLoadDoesNothing() throws {
        let world = try makeIntegrationWorld("PhonePressFailure")
        let book = Book(
            title: "Missing Volume",
            format: .txt,
            filePath: "/nonexistent/\(UUID().uuidString).txt",
            md5Hash: UUID().uuidString
        )
        world.library.library.addBook(book)
        let session = makeSession(in: world)
        let reader = session.open(book)

        session.togglePlayPause()
        waitForReaderToLoad(reader)
        spinMainRunLoop(for: 0.2)

        XCTAssertNotNil(reader.loadErrorMessage, "The book should have failed to load")
        XCTAssertFalse(reader.isPlaybackUnderWay)
        XCTAssertEqual(session.snapshot?.isPlaying, false)
    }

    // MARK: - Going On to the Next Book

    /// A book's end asks for the next one by notification, and the session opens
    /// it: the old reader closes, and the new one claims the request as it
    /// loads, so it plays. Nothing asks the navigation to change.
    func testTheNextBookOpensAndPlaysThroughTheNotification() throws {
        let folder = try makeFolderWorld("PhoneNext")
        let session = makeSession(in: folder.world)
        let shown = recordScreenRequests(of: session)
        let first = session.open(folder.first)
        waitForReaderToLoad(first)

        first.handleEndOfBook()

        XCTAssertTrue(
            eventually(within: 30) { session.reader?.book.id == folder.second.id },
            "Continue to Next Book said its book's name, and nothing started"
        )
        XCTAssertTrue(first.hasClosed, "The finished book's reader is still open")
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "The next book never played")
        XCTAssertEqual(session.snapshot?.bookID, folder.second.id)
        XCTAssertFalse(folder.world.autoplayRequests.hasRequest(for: folder.second.id), "The request was not claimed")
        XCTAssertEqual(session.bookToReopenAtLaunch?.id, folder.second.id)
        XCTAssertTrue(shown().isEmpty, "A listener in the Library stays there")
    }

    /// A running sleep timer goes on with the next book, though the session
    /// closes the old reader before it makes the new one.
    func testASleepTimerGoesOnWithTheNextBook() throws {
        preserveSharedSleepTimer()
        let folder = try makeFolderWorld("PhoneNextTimer")
        let session = makeSession(in: folder.world)
        let first = session.open(folder.first)
        waitForReaderToLoad(first)
        let timer = SleepTimerService.shared
        timer.start(duration: .minutes(30), ownerID: first.readerID, onExpire: {})

        first.handleEndOfBook()
        XCTAssertTrue(
            eventually(within: 30) { session.reader?.book.id == folder.second.id },
            "The next book never opened"
        )
        let second = try XCTUnwrap(session.reader)
        waitForReaderToLoad(second)

        XCTAssertTrue(first.hasClosed)
        XCTAssertTrue(timer.isActive, "Closing the old reader stopped the timer")
        XCTAssertEqual(timer.ownerID, second.readerID, "The new reader did not take the timer")
        XCTAssertEqual(timer.duration, .minutes(30))
    }

    /// A request for the book already open leaves its reader in place, which
    /// claims the request itself.
    func testARequestForTheOpenBookLeavesItsReaderToClaimIt() throws {
        let world = try makeIntegrationWorld("PhoneNextOpen")
        let previous = try world.makeSilentAudioBook(title: "Previous Volume", trackDurations: [5])
        let book = try world.makeSilentAudioBook(title: "Next Volume", trackDurations: [5, 5])
        let session = makeSession(in: world)
        let reader = session.open(book)
        waitForReaderToLoad(reader)

        let request = world.autoplayRequests.request(for: book.id, from: previous.id)
        world.notifications.post(name: .continueToNextBook, object: nil, userInfo: request.notificationUserInfo)

        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "The reader did not claim it")
        XCTAssertTrue(session.reader === reader)
        XCTAssertFalse(reader.hasClosed)
    }

    /// Next in Folder's request opens the book and does not play it.
    func testARequestToOpenABookOpensItWithoutPlaying() throws {
        let world = try makeIntegrationWorld("PhoneOpenRequest")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let session = makeSession(in: world)

        world.notifications.post(name: .openBookWindow, object: book.id)
        XCTAssertNil(session.reader, "Handled on a later turn of the main queue, never inside the post")

        XCTAssertTrue(eventually { session.reader?.book.id == book.id }, "The book never opened")
        let reader = try XCTUnwrap(session.reader)
        waitForReaderToLoad(reader)
        spinMainRunLoop(for: 0.2)
        XCTAssertFalse(reader.isPlaybackUnderWay, "Opening alone played the book")
    }

    /// A notification posted off the main thread reaches the session safely, on
    /// the main actor: a main-actor closure run on another thread stops the app.
    func testARequestPostedOffTheMainThreadIsHandledOnTheMainActor() throws {
        let world = try makeIntegrationWorld("PhoneOffMain")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let session = makeSession(in: world)
        let center = world.notifications
        let bookID = book.id

        DispatchQueue.global().async {
            center.post(name: .openBookWindow, object: bookID)
        }

        XCTAssertTrue(eventually { session.reader?.book.id == bookID }, "The book never opened")
    }

    /// A book that has left the library opens nothing, keeps the book open now,
    /// and leaves no request waiting.
    func testARequestForAMissingBookOpensNothing() throws {
        let world = try makeIntegrationWorld("PhoneMissing")
        let open = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let session = makeSession(in: world)
        let reader = session.open(open)
        waitForReaderToLoad(reader)
        let missing = UUID()

        let request = world.autoplayRequests.request(for: missing, from: open.id)
        world.notifications.post(name: .continueToNextBook, object: nil, userInfo: request.notificationUserInfo)

        XCTAssertTrue(
            eventually { !world.autoplayRequests.hasRequest(for: missing) },
            "The request still waits for a book that is gone"
        )
        XCTAssertTrue(session.reader === reader)
        XCTAssertFalse(reader.hasClosed)
    }

    /// An import that opens its book goes through `readerOpener`: the book opens
    /// and the navigation is told to show its screen.
    func testTheLibrarysOpenerOpensTheBookAndAsksForItsScreen() throws {
        let world = try makeIntegrationWorld("PhoneOpener")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let session = makeSession(in: world)
        let shown = recordScreenRequests(of: session)

        world.library.readerOpener(book.id)

        XCTAssertEqual(session.reader?.book.id, book.id)
        XCTAssertEqual(shown(), [book.id])

        world.library.readerOpener(UUID())
        XCTAssertEqual(session.reader?.book.id, book.id, "A book that is gone took the open book's place")
        XCTAssertEqual(shown(), [book.id], "A book that is gone has no screen to show")
    }

    // MARK: - The Snapshot

    /// The reader publishing, and its place moving, changes nothing a view of
    /// the session would hear. A check that the reader did publish keeps this
    /// from passing with nothing to do.
    func testThePlaceMovingPublishesNothing() throws {
        let world = try makeIntegrationWorld("PhoneSnapshotPlace")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let session = makeSession(in: world)
        let reader = session.open(book)
        waitForReaderToLoad(reader)
        XCTAssertTrue(eventually { session.snapshot?.isLoading == false })
        spinMainRunLoop(for: 0.1)

        var sessionPublishes = 0
        var readerPublishes = 0
        session.objectWillChange.sink { sessionPublishes += 1 }.store(in: &subscriptions)
        reader.objectWillChange.sink { readerPublishes += 1 }.store(in: &subscriptions)
        for offset in stride(from: 5, through: 45, by: 5) {
            reader.currentCharacterOffset = offset
            reader.objectWillChange.send()
            spinMainRunLoop(for: 0.02)
        }

        XCTAssertGreaterThan(readerPublishes, 0, "The reader never published, so this checked nothing")
        XCTAssertEqual(sessionPublishes, 0, "A view of the session would redraw as the book's place moves")
    }

    /// While a book plays, with its reader publishing as it goes, a snapshot is
    /// published only when it differs from the last: half a second of a reader
    /// at eight times a second would otherwise add four more.
    func testTheSnapshotChangesOnlyAsPlayStartsAndStops() throws {
        let world = try makeIntegrationWorld("PhoneSnapshotPlay")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [30])
        let session = makeSession(in: world)
        let reader = session.open(book)
        waitForReaderToLoad(reader)
        XCTAssertTrue(eventually { session.snapshot?.isLoading == false })
        spinMainRunLoop(for: 0.1)

        var published: [PhoneReaderSnapshot] = []
        session.$snapshot.dropFirst().compactMap { $0 }.sink { published.append($0) }.store(in: &subscriptions)

        session.togglePlayPause()
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == true }, "Never played")
        spinMainRunLoop(for: 0.5)
        session.togglePlayPause()
        XCTAssertTrue(eventually(within: 30) { session.snapshot?.isPlaying == false }, "Never paused")

        XCTAssertEqual(published.first?.isPlaying, true)
        XCTAssertEqual(published.last?.isPlaying, false)
        for (earlier, later) in zip(published, published.dropFirst()) {
            XCTAssertNotEqual(earlier, later, "A snapshot was published with nothing changed")
        }
    }

    /// The title follows a rename, as the reader's own book does.
    func testTheSnapshotFollowsARename() throws {
        let world = try makeIntegrationWorld("PhoneSnapshotRename")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let session = makeSession(in: world)
        let reader = session.open(book)
        waitForReaderToLoad(reader)

        reader.book.title = "Harbour Tide Tables"

        XCTAssertTrue(eventually { session.snapshot?.title == "Harbour Tide Tables" }, "The title never changed")
    }

    // MARK: - Coming Back

    /// A new launch, here a new session over the same preferences, finds the
    /// book that was open. It finds none once the book is closed, once it has
    /// left the library, or from a value that names no book.
    func testTheOpenBookIsFoundAgainAtTheNextLaunch() throws {
        let world = try makeIntegrationWorld("PhoneReopen")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let preferences = makeSandboxedPreferences("PhoneReopen")
        let session = makeSession(in: world, preferences: preferences)
        let nextLaunch = makeSession(in: world, preferences: preferences)
        XCTAssertNil(nextLaunch.bookToReopenAtLaunch, "A first launch has nothing to open")

        session.open(book)
        XCTAssertEqual(nextLaunch.bookToReopenAtLaunch?.id, book.id)

        session.closeReader()
        XCTAssertNil(nextLaunch.bookToReopenAtLaunch, "A closed book opens again")

        preferences.set(UUID().uuidString, forKey: PhoneSession.openBookPreferenceKey)
        XCTAssertNil(nextLaunch.bookToReopenAtLaunch, "A book no longer in the library")

        preferences.set("not an identifier", forKey: PhoneSession.openBookPreferenceKey)
        XCTAssertNil(nextLaunch.bookToReopenAtLaunch, "A damaged preference")
    }

    // MARK: - The Mac

    /// The Mac's app never makes a session or a model: only the iPhone's own
    /// folders do, and these tests. So the Mac does what it did.
    func testOnlyTheIPhonesOwnFoldersMakeASessionOrAModel() throws {
        let inTheIPhonesFolders: (AppSourceFile) -> Bool = {
            $0.path.hasPrefix("Phone/") || $0.path.hasPrefix("Platform/iOS/")
        }
        for file in try AppSourceFile.all() where !inTheIPhonesFolders(file) {
            XCTAssertFalse(file.text.contains("PhoneSession("), "\(file.path) makes a PhoneSession")
            XCTAssertFalse(file.text.contains("PhoneAppModel("), "\(file.path) makes a PhoneAppModel")
        }
    }

    // MARK: - Support

    /// A sound service whose sounds reach a player that records them and plays
    /// nothing aloud.
    private func makeSounds(_ label: String) -> SoundEffectService {
        SoundEffectService(
            preferences: makeSandboxedPreferences("\(label) Sounds"),
            player: HeldSoundEffectPlayer(holding: false)
        )
    }

    /// A session over `world`, whose reader is closed when the test ends, before
    /// the world is taken apart: tear-down blocks run last registered first.
    private func makeSession(
        in world: IntegrationWorld,
        sounds: SoundEffectService? = nil,
        preferences: UserDefaults? = nil
    ) -> PhoneSession {
        let session = PhoneSession(
            library: world.library,
            settings: world.settings,
            soundEffects: sounds ?? makeSounds("Session"),
            notificationCenter: world.notifications,
            autoplayRequests: world.autoplayRequests,
            preferences: preferences ?? makeSandboxedPreferences("Session")
        )
        addTeardownBlock { session.closeReader() }
        return session
    }

    /// Puts the app's last opened book back when the test ends: every reader
    /// made in a test also records itself there.
    private func preserveLastOpenedBook() {
        let config = ConfigService.shared
        let saved = config.config.lastOpenedBookID
        addTeardownBlock { config.config.lastOpenedBookID = saved }
    }

    /// Records each request to show the reader's screen, and returns them when
    /// called.
    private func recordScreenRequests(of session: PhoneSession) -> () -> [UUID] {
        var requested: [UUID] = []
        session.showReaderRequests.sink { requested.append($0) }.store(in: &subscriptions)
        return { requested }
    }

    /// Three books in one folder of a world that continues to the next book at
    /// each one's end.
    private struct FolderWorld {
        let world: IntegrationWorld
        let first: Book
        let second: Book
    }

    /// Makes a `FolderWorld`. The titles order the books in their folder, and
    /// the tracks are longer than any test runs.
    private func makeFolderWorld(_ label: String) throws -> FolderWorld {
        let world = try makeIntegrationWorld(label)
        let first = try world.makeSilentAudioBook(title: "A Volume", trackDurations: [5, 5], endOfBook: .continueNext)
        let second = try world.makeSilentAudioBook(title: "B Volume", trackDurations: [5, 5], endOfBook: .continueNext)
        world.library.library.folders = [BookFolder(name: world.folder.path)]
        world.settings.endOfBookBehavior = .continueNext
        return FolderWorld(world: world, first: first, second: second)
    }
}
