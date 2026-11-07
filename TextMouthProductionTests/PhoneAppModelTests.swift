import XCTest
@testable import TextMouth

/// `PhoneAppModel`: the phone's settings at every launch, the navigation path
/// and the reader's screen, and the life cycle's wiring, over a private world.
/// The app's own `init()`, which loads the real library, is not called: its
/// only difference is which parts it makes.
@MainActor
final class PhoneAppModelTests: XCTestCase {
    /// Every model, as at every launch, sets one navigation unit for both
    /// directions, Trash off, and Keep Original, whatever an edit left.
    func testEveryLaunchSetsWhatThePhoneFixes() throws {
        let parts = try makeParts("PhoneModelDefaults")
        parts.world.settings.playbackNavigationUnitControlMode = .separate
        XCTAssertTrue(parts.config.config.moveToTrashInsteadOfDeleting, "A new configuration moves to the Trash")

        _ = makeModel(parts)
        XCTAssertEqual(parts.world.settings.playbackNavigationUnitControlMode, .shared)
        XCTAssertFalse(parts.config.config.moveToTrashInsteadOfDeleting)
        XCTAssertEqual(parts.config.config.importDeleteBehavior, .keepOriginal)

        parts.world.settings.playbackNavigationUnitControlMode = .none
        parts.config.config.moveToTrashInsteadOfDeleting = true
        _ = makeModel(parts)
        XCTAssertEqual(parts.world.settings.playbackNavigationUnitControlMode, .shared, "A later launch kept the edit")
        XCTAssertFalse(parts.config.config.moveToTrashInsteadOfDeleting, "A later launch kept the edit")
    }

    /// Showing the reader pushes its screen once; taking it off the path tells
    /// the session, which closes a book opened and never engaged with.
    func testThePathShowsAndLeavesTheReader() throws {
        let parts = try makeParts("PhoneModelPath")
        let book = try parts.world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let model = makeModel(parts)
        let reader = try XCTUnwrap(parts.session.open(book))
        waitForReaderToLoad(reader)

        model.showReader()
        model.showReader()
        XCTAssertEqual(model.path, [.reader])

        model.path = []
        XCTAssertTrue(reader.hasClosed, "Leaving the screen did not reach the session")
    }

    /// A book the session opens for an import pushes the reader's screen.
    func testABookOpenedForAnImportShowsItsScreen() throws {
        let parts = try makeParts("PhoneModelImport")
        let book = try parts.world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let model = makeModel(parts)

        parts.world.library.readerOpener(book.id)

        XCTAssertEqual(model.path, [.reader])
    }

    /// Going to the background keeps whether the reader's screen showed; the
    /// session's hold is the life cycle's.
    func testTheLifeCycleReachesTheSession() throws {
        let parts = try makeParts("PhoneModelLifeCycle")
        let book = try parts.world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5])
        let model = makeModel(parts)
        let reader = try XCTUnwrap(parts.session.open(book))
        waitForReaderToLoad(reader)
        model.showReader()

        model.lifeCycle.sceneDidEnterBackground()
        XCTAssertTrue(parts.preferences.bool(forKey: PhoneSession.reopenShowsReaderKey))

        var held: [String] = []
        model.lifeCycle.beginHold = { name in
            held.append(name)
            return {}
        }
        _ = parts.session.beginHold("A hand-over")
        XCTAssertEqual(held, ["A hand-over"])
    }

    // MARK: - Support

    /// What a model is made over.
    private struct Parts {
        let world: IntegrationWorld
        let session: PhoneSession
        let sounds: SoundEffectService
        let preferences: UserDefaults
        let config: ConfigService
    }

    /// Private parts for a model, whose readers close as the test ends.
    private func makeParts(_ label: String) throws -> Parts {
        let world = try makeIntegrationWorld(label)
        let sounds = SoundEffectService(
            preferences: makeSandboxedPreferences("\(label) Sounds"),
            player: HeldSoundEffectPlayer(holding: false)
        )
        let preferences = makeSandboxedPreferences(label)
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
