import XCTest
@testable import TextMouth

/// The preferences store's building blocks (TODO C04): a preference defined
/// once, with its owner, and the observer through which owners and the
/// settings model follow every change to it, whoever makes it. Every test
/// uses a sandboxed store of its own.
@MainActor
final class PreferenceStoreTests: XCTestCase {
    // MARK: - Stored Preferences

    /// A flag reads its default until a value is saved, then reads what was
    /// saved under its key; a value of another type reads as the default.
    func testFlagReadsItsDefaultUntilAValueIsSaved() {
        let store = makeSandboxedPreferences("stored-flag")
        let flag = StoredPreference.flag("someSwitch", default: true)

        XCTAssertTrue(flag.read(from: store))

        flag.write(false, to: store)
        XCTAssertFalse(flag.read(from: store))
        XCTAssertEqual(store.object(forKey: "someSwitch") as? Bool, false)

        store.set("off", forKey: "someSwitch")
        XCTAssertTrue(flag.read(from: store), "text is not a switch")
    }

    // MARK: - Observing

    /// A change made on the main thread reaches the handler before the write
    /// returns, naming its key. Writing the same value again, and changing a
    /// key nobody observes, report nothing; removing a value is a change.
    func testObserverReportsEachChangeBeforeTheWriteReturns() {
        let store = makeSandboxedPreferences("observer-changes")
        var reported: [String] = []
        let observer = PreferenceObserver(keys: ["first", "second"], in: store) { reported.append($0) }

        store.set(1, forKey: "first")
        XCTAssertEqual(reported, ["first"])

        store.set(1, forKey: "first")
        store.set(true, forKey: "unobserved")
        XCTAssertEqual(reported, ["first"], "neither the same value nor another key is reported")

        store.set("two", forKey: "second")
        store.removeObject(forKey: "first")
        XCTAssertEqual(reported, ["first", "second", "first"])
        withExtendedLifetime(observer) {}
    }

    /// Every observer of a key hears each change to it, as the settings
    /// model and a service that both follow one preference must.
    func testEveryObserverOfAKeyHearsTheChange() {
        let store = makeSandboxedPreferences("observer-shared-key")
        var heardBy: [String] = []
        let service = PreferenceObserver(keys: ["shared"], in: store) { _ in heardBy.append("service") }
        let settings = PreferenceObserver(keys: ["shared"], in: store) { _ in heardBy.append("settings") }

        store.set(3, forKey: "shared")

        XCTAssertEqual(heardBy.sorted(), ["service", "settings"])
        withExtendedLifetime((service, settings)) {}
    }

    /// A change made on another thread reaches the handler on the main thread.
    func testChangeFromAnotherThreadReachesTheHandlerOnTheMainThread() {
        let preferences = SandboxedPreferences("observer-other-thread")
        addTeardownBlock { preferences.discard() }
        let delivered = expectation(description: "the change reaches the handler")
        var ranOnMainThread = false
        let observer = PreferenceObserver(keys: ["key"], in: preferences.defaults) { _ in
            ranOnMainThread = Thread.isMainThread
            delivered.fulfill()
        }

        DispatchQueue.global().async {
            preferences.defaults.set(5, forKey: "key")
        }

        wait(for: [delivered], timeout: 5)
        XCTAssertTrue(ranOnMainThread)
        withExtendedLifetime(observer) {}
    }

    /// Releasing the observer ends observing: later changes call nothing.
    func testReleasedObserverReportsNothingMore() {
        let store = makeSandboxedPreferences("observer-released")
        var reports = 0
        var observer: PreferenceObserver? = PreferenceObserver(keys: ["key"], in: store) { _ in reports += 1 }

        store.set(1, forKey: "key")
        observer = nil
        store.set(2, forKey: "key")

        XCTAssertNil(observer)
        XCTAssertEqual(reports, 1)
    }

    // MARK: - Sound Effects

    /// Sound preferences written to the store by someone else, as the
    /// settings model writes an edit of config.json, take effect in the
    /// service at once, each published once.
    func testSoundEffectsFollowChangesMadeInTheirStore() {
        let store = makeSandboxedPreferences("sounds-follow")
        let sounds = SoundEffectService(preferences: store)
        var publications = 0
        let subscription = sounds.objectWillChange.sink { publications += 1 }

        SoundEffectService.enabledPreference.write(false, to: store)
        SoundEffectService.volumePreference.write(0.2, to: store)
        SoundEffectService.assignmentsPreference.write([.play: "Glass", .pause: "None"], to: store)

        XCTAssertFalse(sounds.soundsEnabled)
        XCTAssertEqual(sounds.volume, 0.2)
        XCTAssertEqual(sounds.assignments, [.play: "Glass", .pause: "None"])
        XCTAssertEqual(publications, 3)
        subscription.cancel()
    }

    /// Taking a value from the store writes nothing back: once a preference
    /// is removed, the service uses its default and the store stays empty.
    func testSoundEffectsWriteNothingBackWhileFollowingTheirStore() {
        let store = makeSandboxedPreferences("sounds-no-write-back")
        store.set(false, forKey: "soundEffectsEnabled")
        store.set(Float(0.3), forKey: "soundEffectsVolume")
        let sounds = SoundEffectService(preferences: store)

        store.removeObject(forKey: "soundEffectsEnabled")
        store.removeObject(forKey: "soundEffectsVolume")

        XCTAssertTrue(sounds.soundsEnabled)
        XCTAssertEqual(sounds.volume, 0.5)
        XCTAssertNil(store.object(forKey: "soundEffectsEnabled"))
        XCTAssertNil(store.object(forKey: "soundEffectsVolume"))
    }

    /// The volume reads any stored number, as other numeric preferences do,
    /// clamped to the slider's range: a Double written with `defaults write`
    /// no longer falls back to half volume.
    func testSoundEffectVolumeReadsAnyStoredNumberWithinRange() {
        let store = makeSandboxedPreferences("sounds-volume")
        let cases: [(stored: Any, expected: Float)] = [
            (Float(0.25), 0.25), (0.3, 0.3), (4.0, 1), (-1.0, 0), (1, 1), (Double.nan, 0.5),
        ]
        for (stored, expected) in cases {
            store.set(stored, forKey: "soundEffectsVolume")
            XCTAssertEqual(SoundEffectService.volumePreference.read(from: store), expected, "\(stored)")
        }
        store.removeObject(forKey: "soundEffectsVolume")
        XCTAssertEqual(SoundEffectService.volumePreference.read(from: store), 0.5, "nothing stored")
    }
}
