import XCTest
@testable import TextMouth

/// Reopening at launch (`PhoneLifeCycle+Reopening`): what the next launch does
/// with the book open when the app last ended, over a model of private parts,
/// whose readers are real readers of silent audiobooks in a private world.
@MainActor
final class PhoneLifeCycleReopeningTests: XCTestCase {
    /// A book whose reader's screen was showing opens again, paused at its
    /// place, with its screen pushed over the Library; the screen says the title, not the launch.
    func testAReaderOnScreenIsOpenedAgainWithItsScreen() throws {
        let parts = try makeParts("PhoneReopenReader")
        let book = try parts.world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        keep(book, showingItsScreen: true, in: parts)
        let model = makeModel(parts)

        let reopened = model.lifeCycle.reopenAtLaunch(in: model)

        XCTAssertEqual(reopened, PhoneLifeCycle.LaunchReopened(showsReader: true, lowPriorityWords: nil), "The reader's arrival says the title")
        XCTAssertEqual(model.session.reader?.book.id, book.id)
        XCTAssertEqual(model.path, [.reader])
        let reader = try XCTUnwrap(model.session.reader)
        waitForReaderToLoad(reader)
        XCTAssertFalse(reader.isPlaybackActivelyAdvancing, "Reopened playing")
    }

    /// A book left with the Library showing is not opened: the Library opens,
    /// with nothing said, and the book waits in its Continue row.
    func testABookLeftWithTheLibraryShowingIsNotOpened() throws {
        let parts = try makeParts("PhoneReopenLibrary")
        let book = try parts.world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        keep(book, showingItsScreen: false, in: parts)
        let model = makeModel(parts)

        let reopened = model.lifeCycle.reopenAtLaunch(in: model)

        XCTAssertEqual(reopened, .nothing)
        XCTAssertNil(model.session.reader)
        XCTAssertEqual(model.path, [])
    }

    /// After the app ended while opening a book, the book is not opened, and
    /// the crash guard's sentence is what is said.
    func testABookThatClosedTheAppWhileOpeningIsNotOpenedAndIsNamed() throws {
        // The last run's mark is on disk before this run's session is made.
        // The keys the run kept as it ended are on disk beside the mark.
        var opening: Book?
        let parts = try makeParts("PhoneReopenCrash") { world, preferences in
            let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
            preferences.set(book.id.uuidString, forKey: PhoneSession.openingBookKey)
            Self.keep(book, showingItsScreen: true, in: preferences)
            opening = book
        }
        XCTAssertNotNil(opening)
        let model = makeModel(parts)

        let reopened = model.lifeCycle.reopenAtLaunch(in: model)

        XCTAssertEqual(reopened, PhoneLifeCycle.LaunchReopened(
            showsReader: false,
            lowPriorityWords: "TextMouth closed while opening Tide Tables, so it wasn't reopened."
        ))
        XCTAssertNil(model.session.reader)
        XCTAssertEqual(model.path, [])
        // And nothing is left that would reopen the book at the next launch.
        XCTAssertNil(parts.preferences.string(forKey: PhoneSession.reopenBookKey), "The crashed book's key outlived the verdict")
    }

    /// A file opened at launch wins over reopening: nothing is opened, and
    /// nothing said.
    func testAFileOpenedAtLaunchWinsOverReopening() throws {
        let parts = try makeParts("PhoneReopenFile")
        let book = try parts.world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        keep(book, showingItsScreen: true, in: parts)
        let model = makeModel(parts)
        model.lifeCycle.openedFiles = { _ in }
        model.lifeCycle.sceneOpened([URL(fileURLWithPath: "/nonexistent/Arrived.epub")])

        let reopened = model.lifeCycle.reopenAtLaunch(in: model)

        XCTAssertEqual(reopened, .nothing)
        XCTAssertNil(model.session.reader)
        XCTAssertEqual(model.path, [])
    }

    /// A reader already open, as when a Play from the lock screen woke the app,
    /// is left as it is: nothing is opened over it, and the screen stays.
    func testAReaderAlreadyOpenIsLeftAsItIs() throws {
        let parts = try makeParts("PhoneReopenOpen")
        let kept = try parts.world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let playing = try parts.world.makeSilentAudioBook(title: "Ferry Notes", trackDurations: [5])
        keep(kept, showingItsScreen: true, in: parts)
        let model = makeModel(parts)
        let reader = try XCTUnwrap(model.session.open(playing))

        let reopened = model.lifeCycle.reopenAtLaunch(in: model)

        XCTAssertEqual(reopened, .nothing)
        XCTAssertTrue(model.session.reader === reader)
        XCTAssertEqual(model.path, [])
    }

    /// The words wait past the reader screen's first focus post, so they
    /// follow Play rather than go first.
    func testTheWordsWaitPastTheFirstFocusPost() {
        XCTAssertGreaterThan(PhoneLifeCycle.wordsDelay, PhoneFocusPolicy.screenChangedDelay)
        XCTAssertLessThan(PhoneLifeCycle.wordsDelay, PhoneFocusPolicy.layoutChangedDelay)
    }

    // MARK: - Helpers

    /// What a model is made over.
    private struct Parts {
        let world: IntegrationWorld
        let session: PhoneSession
        let sounds: SoundEffectService
        let preferences: UserDefaults
        let config: ConfigService
    }

    /// Keeps `book` for the next launch in `parts`' preferences, as a session
    /// leaves them when the app leaves the screen.
    private func keep(_ book: Book, showingItsScreen: Bool, in parts: Parts) {
        Self.keep(book, showingItsScreen: showingItsScreen, in: parts.preferences)
    }

    /// The same, into any preferences: for keys that must be on disk before
    /// the session is made.
    private static func keep(_ book: Book, showingItsScreen: Bool, in preferences: UserDefaults) {
        preferences.set(book.id.uuidString, forKey: PhoneSession.reopenBookKey)
        preferences.set(showingItsScreen, forKey: PhoneSession.reopenShowsReaderKey)
        preferences.set(false, forKey: PhoneSession.reopenFromReadingListKey)
    }

    /// Private parts for a model, whose readers close as the test ends.
    /// `beforeTheSession` runs on the world and the preferences before the
    /// session is made, as a launch finds what the last run left on disk: the
    /// session reads its crash guard (`PhoneSession.openingBookKey`) as it is
    /// made, so a mark written later is this run's own.
    private func makeParts(
        _ label: String,
        beforeTheSession: (IntegrationWorld, UserDefaults) throws -> Void = { _, _ in }
    ) throws -> Parts {
        let world = try makeIntegrationWorld(label)
        let sounds = SoundEffectService(
            preferences: makeSandboxedPreferences("\(label) Sounds"),
            player: HeldSoundEffectPlayer(holding: false)
        )
        let preferences = makeSandboxedPreferences(label)
        try beforeTheSession(world, preferences)
        let media = NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        let session = PhoneSession(
            library: world.library,
            settings: world.settings,
            soundEffects: sounds,
            notificationCenter: world.notifications,
            autoplayRequests: world.autoplayRequests,
            preferences: preferences,
            makeReader: { book in world.openReader(for: book, nowPlaying: media) }
        )
        addTeardownBlock { session.closeReader() }
        let configFile = try makeSandboxDirectory("\(label) Config").appendingPathComponent("config.json")
        return Parts(
            world: world,
            session: session,
            sounds: sounds,
            preferences: preferences,
            config: ConfigService(fileURL: configFile)
        )
    }

    /// A model over `parts`.
    private func makeModel(_ parts: Parts) -> PhoneAppModel {
        PhoneAppModel(
            library: parts.world.library,
            settings: parts.world.settings,
            soundEffects: parts.sounds,
            session: parts.session,
            config: parts.config
        )
    }
}
