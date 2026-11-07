import XCTest
@testable import TextMouth

/// `PhoneAppModel`: the phone's fixed settings are applied once, over a private
/// world. The app's own `init()`, which loads the real library, is not called:
/// its one line of difference is which parts it makes.
@MainActor
final class PhoneAppModelTests: XCTestCase {
    /// The first model sets one navigation unit for both directions, and turns
    /// off moving to the Trash.
    func testTheFirstModelSetsWhatThePhoneFixes() throws {
        let parts = try makeParts("PhoneModelFirst")
        parts.world.settings.playbackNavigationUnitControlMode = .separate
        XCTAssertTrue(parts.removal.preferences.movesToTrash, "A new configuration moves to the Trash")

        let model = makeModel(parts)

        XCTAssertEqual(parts.world.settings.playbackNavigationUnitControlMode, .shared)
        XCTAssertFalse(parts.removal.preferences.movesToTrash)
        XCTAssertTrue(model.session === parts.session)
        XCTAssertTrue(model.library === parts.world.library)
        XCTAssertTrue(model.settings === parts.world.settings)
    }

    /// A later launch, here a later model over the same preferences, leaves
    /// them as they are, so a value changed since is never overridden.
    func testALaterModelLeavesThemAsTheyAre() throws {
        let parts = try makeParts("PhoneModelLater")
        _ = makeModel(parts)
        parts.world.settings.playbackNavigationUnitControlMode = .separate
        parts.removal.setMovesToTrash(true)

        _ = makeModel(parts)

        XCTAssertEqual(parts.world.settings.playbackNavigationUnitControlMode, .separate)
        XCTAssertTrue(parts.removal.preferences.movesToTrash)
    }

    // MARK: - Support

    /// What a model is made over.
    private struct Parts {
        let world: IntegrationWorld
        let session: PhoneSession
        let sounds: SoundEffectService
        let preferences: UserDefaults
        let removal: RemovalPreferencesModel
    }

    /// Private parts for a model, whose reader, should a test open one, closes
    /// as the test ends.
    private func makeParts(_ label: String) throws -> Parts {
        let world = try makeIntegrationWorld(label)
        let sounds = SoundEffectService(
            preferences: makeSandboxedPreferences("\(label) Sounds"),
            player: HeldSoundEffectPlayer(holding: false)
        )
        let preferences = makeSandboxedPreferences(label)
        let session = PhoneSession(
            library: world.library,
            settings: world.settings,
            soundEffects: sounds,
            notificationCenter: world.notifications,
            autoplayRequests: world.autoplayRequests,
            preferences: preferences
        )
        addTeardownBlock { session.closeReader() }
        let configFile = try makeSandboxDirectory("\(label) Removal").appendingPathComponent("config.json")
        let removal = RemovalPreferencesModel(configService: ConfigService(fileURL: configFile))
        return Parts(world: world, session: session, sounds: sounds, preferences: preferences, removal: removal)
    }

    /// A model over `parts`.
    private func makeModel(_ parts: Parts) -> PhoneAppModel {
        PhoneAppModel(
            library: parts.world.library,
            settings: parts.world.settings,
            soundEffects: parts.sounds,
            session: parts.session,
            preferences: parts.preferences,
            removalPreferences: parts.removal
        )
    }
}
