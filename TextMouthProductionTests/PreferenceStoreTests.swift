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

    /// The Sound Effects tab's Reset to Defaults gives the defaults back in
    /// a store of the test's own, says so in one pinned sentence, and keeps
    /// its button words. Nothing is played: only preferences change.
    func testTheSoundEffectsTabsResetResetsAndSaysSo() {
        let store = makeSandboxedPreferences("sounds-reset-says-so")
        let sounds = SoundEffectService(preferences: store)
        sounds.assignments[.play] = "Glass"
        sounds.volume = 0.9
        sounds.soundsEnabled = false
        var spoken: [String] = []

        SoundEffectsSettingsView.resetEverySound(sounds) { spoken.append($0) }

        XCTAssertEqual(sounds.assignments, SoundEffectService.defaultAssignments)
        XCTAssertEqual(sounds.volume, 0.5)
        XCTAssertTrue(sounds.soundsEnabled)
        XCTAssertEqual(spoken, [SoundEffectsSettingsWording.resetDone])
        XCTAssertEqual(SoundEffectsSettingsWording.resetDone, "The sound effects are reset to the defaults.")
        XCTAssertEqual(SoundEffectsSettingsWording.resetTitle, "Reset to Defaults")
        XCTAssertEqual(SoundEffectsSettingsWording.resetLabel, "Reset all sound effects to defaults")
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

    // MARK: - Text Substitutions

    /// The substitution switch written to the store by someone else takes
    /// effect in the service at once and is published once, which is what
    /// open readers re-prepare their speech on; nothing is written back.
    func testSubstitutionSwitchFollowsChangesMadeInItsStore() {
        let store = makeSandboxedPreferences("substitutions-follow")
        let substitutions = TextSubstitutionService(rules: [], isEnabled: true, preferences: store)
        var publications = 0
        let subscription = substitutions.objectWillChange.sink { publications += 1 }

        TextSubstitutionService.enabledPreference.write(false, to: store)
        XCTAssertFalse(substitutions.isEnabled)
        XCTAssertEqual(publications, 1)

        store.removeObject(forKey: "substitutionsEnabled")
        XCTAssertTrue(substitutions.isEnabled, "on until the user turns it off")
        XCTAssertNil(store.object(forKey: "substitutionsEnabled"), "nothing written back")
        subscription.cancel()
    }

    /// The app's shared service follows this process's preferences, which
    /// the settings model applies config.json to.
    func testSharedSubstitutionServiceFollowsThisProcessPreferences() {
        let key = TextSubstitutionService.enabledPreference.key
        preservePreferences([key])
        let shared = TextSubstitutionService.shared
        let wasEnabled = shared.isEnabled
        defer { TextSubstitutionService.enabledPreference.write(wasEnabled, to: TextMouthRuntime.current.preferences) }

        TextSubstitutionService.enabledPreference.write(!wasEnabled, to: TextMouthRuntime.current.preferences)

        XCTAssertEqual(shared.isEnabled, !wasEnabled)
    }

    /// Testing a rule in its editor shows what that rule alone does, with
    /// substitutions on, and leaves the app's rules and its substitution
    /// switch untouched: the switch never changes in the store, so nothing
    /// that follows it, config.json included, hears of the test.
    func testTestingARuleLeavesTheAppsRulesAndSwitchAlone() {
        let preferences = TextMouthRuntime.current.preferences
        let key = TextSubstitutionService.enabledPreference.key
        preservePreferences([key])
        let shared = TextSubstitutionService.shared
        TextSubstitutionService.enabledPreference.write(false, to: preferences)
        let rules = shared.rules
        var switchChanges = 0
        let observer = PreferenceObserver(keys: [key], in: preferences) { _ in switchChanges += 1 }
        let rule = SubstitutionRule(pattern: "TM", replacement: "TextMouth")

        let result = SubstitutionRuleEditorView.testResult(of: rule, on: "TM reads aloud")

        XCTAssertEqual(result, "TextMouth reads aloud")
        XCTAssertEqual(switchChanges, 0)
        XCTAssertFalse(shared.isEnabled)
        XCTAssertEqual(shared.rules, rules)
        withExtendedLifetime(observer) {}
    }

    // MARK: - Repeated Symbols

    /// The repeated-symbol settings written to the store by someone else,
    /// as the settings model writes an edit of config.json, take effect in
    /// the service at once, each published once, which is what open readers
    /// re-prepare their speech on; nothing is written back.
    func testRepeatedSymbolSettingsFollowChangesMadeInTheirStore() {
        let store = makeSandboxedPreferences("repeated-symbols-follow")
        let substitutions = TextSubstitutionService(rules: [], preferences: store)
        var publications = 0
        let subscription = substitutions.objectWillChange.sink { publications += 1 }

        TextSubstitutionService.repeatedSymbolStylePreference.write(.leaveOut, to: store)
        TextSubstitutionService.repeatedSymbolThresholdPreference.write(-1, to: store)
        TextSubstitutionService.repeatedSymbolSetPreference.write("=~", to: store)

        XCTAssertEqual(
            substitutions.repeatedSymbolRule,
            RepeatedSymbolRule(style: .leaveOut, threshold: -1, symbols: "=~")
        )
        XCTAssertEqual(publications, 3)

        for key in ["repeatedSymbolStyle", "repeatedSymbolThreshold", "repeatedSymbolSet"] {
            store.removeObject(forKey: key)
        }
        XCTAssertEqual(substitutions.repeatedSymbolRule, .standard, "back to the standard settings")
        XCTAssertEqual(publications, 6)
        for key in ["repeatedSymbolStyle", "repeatedSymbolThreshold", "repeatedSymbolSet"] {
            XCTAssertNil(store.object(forKey: key), "\(key): nothing written back")
        }
        subscription.cancel()
    }

    /// Settings changed through the service are saved under their keys, in
    /// readable forms, already validated: an unsupported threshold is
    /// clamped and a set keeps only its symbols, each once.
    func testRepeatedSymbolSettingsAreSavedValidated() {
        let store = makeSandboxedPreferences("repeated-symbols-save")
        let substitutions = TextSubstitutionService(rules: [], preferences: store)

        substitutions.repeatedSymbolStyle = .repeatEach
        substitutions.repeatedSymbolThreshold = 150
        substitutions.repeatedSymbolSet = "* * = a1 *"

        XCTAssertEqual(store.string(forKey: "repeatedSymbolStyle"), "repeat")
        XCTAssertEqual(store.object(forKey: "repeatedSymbolThreshold") as? Int, 99)
        XCTAssertEqual(store.string(forKey: "repeatedSymbolSet"), "*=")
        XCTAssertEqual(substitutions.repeatedSymbolThreshold, 99)
        XCTAssertEqual(substitutions.repeatedSymbolSet, "*=")

        substitutions.repeatedSymbolThreshold = -12
        XCTAssertEqual(substitutions.repeatedSymbolThreshold, -1)
        XCTAssertEqual(store.object(forKey: "repeatedSymbolThreshold") as? Int, -1)
    }

    /// Setting a threshold or symbol set already in force publishes nothing,
    /// so open readers are not asked to prepare their speech again; nor does
    /// a value that validates to the one in force.
    func testUnchangedRepeatedSymbolSettingsPublishNothing() {
        let substitutions = TextSubstitutionService(rules: [])
        var publications = 0
        let subscription = substitutions.objectWillChange.sink { publications += 1 }

        substitutions.repeatedSymbolThreshold = 4
        substitutions.repeatedSymbolSet = SettingsPolicy.repeatedSymbolSet.defaultValue
        substitutions.repeatedSymbolSet = SettingsPolicy.repeatedSymbolSet.defaultValue + " **"
        XCTAssertEqual(publications, 0)

        substitutions.repeatedSymbolThreshold = 6
        XCTAssertEqual(publications, 1)
        subscription.cancel()
    }

    /// A service without a store starts from the standard settings and
    /// saves its changes nowhere, as the rule editor's Test button needs.
    func testAServiceWithoutAStoreKeepsItsRepeatedSymbolSettingsToItself() {
        let keys = TextSubstitutionService.preferenceKeys
        let before = PreferenceSnapshot(keys, in: TextMouthRuntime.current.preferences)
        let substitutions = TextSubstitutionService(rules: [])

        XCTAssertEqual(substitutions.repeatedSymbolRule, .standard)
        substitutions.repeatedSymbolStyle = .leaveOut
        substitutions.repeatedSymbolThreshold = 9
        substitutions.repeatedSymbolSet = "~"

        let after = PreferenceSnapshot(keys, in: TextMouthRuntime.current.preferences)
        for (earlier, later) in zip(before.values, after.values) {
            XCTAssertEqual(earlier.value as? NSObject, later.value as? NSObject, earlier.key)
        }
    }

    /// The repeated-symbol settings do not depend on the substitution
    /// switch: with the rules off, runs are still collapsed.
    func testRepeatedSymbolsApplyWithSubstitutionsOff() {
        let substitutions = TextSubstitutionService(rules: [], isEnabled: false)

        XCTAssertTrue(substitutions.repeatedSymbolRule.collapsesRuns)
        XCTAssertEqual(substitutions.repeatedSymbolRule.apply(to: "* * * *").text, "4 asterisks")
    }

    /// The app's shared service follows this process's preferences for the
    /// repeated-symbol settings too.
    func testSharedServiceFollowsTheRepeatedSymbolSettings() {
        let preferences = TextMouthRuntime.current.preferences
        preservePreferences(TextSubstitutionService.preferenceKeys)
        let shared = TextSubstitutionService.shared
        let style = shared.repeatedSymbolStyle
        let threshold = shared.repeatedSymbolThreshold
        defer {
            TextSubstitutionService.repeatedSymbolStylePreference.write(style, to: preferences)
            TextSubstitutionService.repeatedSymbolThresholdPreference.write(threshold, to: preferences)
        }
        let otherStyle: RepeatedSymbolStyle = style == .leaveOut ? .sayCount : .leaveOut

        TextSubstitutionService.repeatedSymbolStylePreference.write(otherStyle, to: preferences)
        TextSubstitutionService.repeatedSymbolThresholdPreference.write(threshold == 7 ? 8 : 7, to: preferences)

        XCTAssertEqual(shared.repeatedSymbolStyle, otherStyle)
        XCTAssertEqual(shared.repeatedSymbolThreshold, threshold == 7 ? 8 : 7)
    }

    // MARK: - Keyboard Shortcuts

    /// A record of the user's edits written to the store by someone else
    /// takes effect in the manager at once, published once, so key presses
    /// match its keys.
    func testShortcutsFollowChangesMadeInTheirStore() {
        let store = makeSandboxedPreferences("shortcuts-follow")
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)
        var publications = 0
        let subscription = manager.objectWillChange.sink { publications += 1 }
        let changed = ShortcutEdits([.whereAmI: [KeyBinding(key: "w", option: true)]])

        KeyboardShortcutManager.editsPreference.write(changed, to: store)

        var expected = ShortcutEdits().effectiveBindings(defaults: ShortcutAction.defaultBindings)
        expected[.whereAmI] = [KeyBinding(key: "w", option: true)]
        XCTAssertEqual(manager.edits, changed)
        XCTAssertEqual(manager.bindings, expected)
        XCTAssertEqual(manager.bindingsFor(.whereAmI), [KeyBinding(key: "w", option: true)])
        XCTAssertEqual(KeyboardShortcutManager.bindingsPreference.read(from: store), expected)
        XCTAssertEqual(publications, 1)
        subscription.cancel()
    }

    /// The shortcuts are saved as the record of the actions the user
    /// edited (FR12): JSON under keyboardShortcutEdits in the form the whole
    /// map was saved in, keyed by each edited action's name and holding only
    /// those; the whole map's key, customKeyboardBindings, is never written.
    func testShortcutsKeepTheirSavedKeyAndForm() throws {
        let store = makeSandboxedPreferences("shortcuts-form")
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)

        manager.updateBindings(for: .whereAmI, to: [KeyBinding(key: "w", option: true)])

        let data = try XCTUnwrap(store.data(forKey: "keyboardShortcutEdits"))
        let saved = try JSONDecoder().decode([String: [KeyBinding]].self, from: data)
        XCTAssertEqual(saved, ["Where Am I?": [KeyBinding(key: "w", option: true)]])
        XCTAssertNil(store.object(forKey: "customKeyboardBindings"))
    }
}
