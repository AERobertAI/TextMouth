import XCTest
@testable import TextMouth

/// Regression coverage for config/AppStorage mapping and watcher replacement.
@MainActor
final class ConfigSyncTests: XCTestCase {
    func testPlaybackControlSettingsPublishRefreshesForOpenReaders() {
        let defaults = TextMouthRuntime.current.preferences
        let keys = [
            "showBookmarkInPlaybackControls",
            "showSpeedInPlaybackControls",
            "playbackNavigationUnitControlMode",
            "skipForwardUnit",
            "skipBackwardUnit",
        ]
        let previousDefaults = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, defaults.object(forKey: $0))
        })
        defer {
            for key in keys {
                if let value = previousDefaults[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let viewModel = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false
        )
        let configService = ConfigService.shared
        let previousConfig = configService.config
        defer {
            configService.config = previousConfig
            configService.saveToDisk()
        }
        let initialRevision = viewModel.playbackControlsSettingsRevision

        viewModel.playbackNavigationUnitControlMode =
            viewModel.playbackNavigationUnitControlMode == .shared ? .separate : .shared
        viewModel.showBookmarkInPlaybackControls.toggle()
        viewModel.showSpeedInPlaybackControls.toggle()
        viewModel.skipForwardUnit = viewModel.skipForwardUnit == .heading ? .seconds10 : .heading
        viewModel.skipBackwardUnit = viewModel.skipBackwardUnit == .paragraph ? .seconds30 : .paragraph

        XCTAssertEqual(viewModel.playbackControlsSettingsRevision, initialRevision + 5)
    }

    func testSettingsPushAllPreviouslyOmittedFieldsToConfig() {
        let defaults = TextMouthRuntime.current.preferences
        let keys = [
            "shiftSkipForwardUnit", "shiftSkipBackwardUnit",
            "endOfBookBehavior", "punctuationPauseLevel",
        ]
        let previousDefaults = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, defaults.object(forKey: $0))
        })
        let viewModel = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false
        )
        let service = ConfigService.shared
        let previous = service.config
        defer {
            service.config = previous
            service.saveToDisk()
            for key in keys {
                if let value = previousDefaults[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        viewModel.shiftSkipForwardUnitRaw = SkipUnit.seconds60.rawValue
        viewModel.shiftSkipBackwardUnitRaw = SkipUnit.sentence.rawValue
        viewModel.endOfBookBehaviorRaw = EndOfBookBehavior.loop.rawValue
        viewModel.punctuationPauseLevel = 2
        viewModel.syncToConfig()

        XCTAssertEqual(service.config.shiftSkipForwardUnit, SkipUnit.seconds60.rawValue)
        XCTAssertEqual(service.config.shiftSkipBackwardUnit, SkipUnit.sentence.rawValue)
        XCTAssertEqual(service.config.endOfBookBehavior, EndOfBookBehavior.loop.rawValue)
        XCTAssertEqual(service.config.punctuationPauseLevel, 2)
    }

    func testExternalConfigAppliesAllPreviouslyOmittedFields() {
        let defaults = TextMouthRuntime.current.preferences
        let keys = [
            "shiftSkipForwardUnit", "shiftSkipBackwardUnit",
            "endOfBookBehavior", "punctuationPauseLevel",
        ]
        let previousDefaults = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, defaults.object(forKey: $0))
        })
        defer {
            for key in keys {
                if let value = previousDefaults[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        let viewModel = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false
        )
        var config = ConfigService.AppConfig()
        config.shiftSkipForwardUnit = SkipUnit.heading.rawValue
        config.shiftSkipBackwardUnit = SkipUnit.paragraph.rawValue
        config.endOfBookBehavior = EndOfBookBehavior.continueNext.rawValue
        config.punctuationPauseLevel = 3

        viewModel.applyConfigChanges(config)

        XCTAssertEqual(viewModel.shiftSkipForwardUnit, .heading)
        XCTAssertEqual(viewModel.shiftSkipBackwardUnit, .paragraph)
        XCTAssertEqual(viewModel.endOfBookBehavior, .continueNext)
        XCTAssertEqual(viewModel.punctuationPauseLevel, 3)
    }

    /// TextMouth's own atomic save replaces the watched file, so the watcher
    /// follows the new file, but the bytes are its own, so nothing reloads.
    func testOwnAtomicSaveRearmsWatcherWithoutReloading() {
        let saved = Data("saved by TextMouth".utf8)
        let actions = ConfigService.watcherActions(for: .rename, fileContents: saved, lastHandledContents: saved)

        XCTAssertFalse(actions.reload)
        XCTAssertTrue(actions.rearm)
    }

    /// An editor's atomic save replaces the file with bytes TextMouth did not
    /// write: the watcher follows the new file and reloads it.
    func testExternalAtomicReplacementReloadsAndRearmsWatcher() {
        let actions = ConfigService.watcherActions(
            for: [.write, .rename],
            fileContents: Data("saved by an editor".utf8),
            lastHandledContents: Data("saved by TextMouth".utf8)
        )

        XCTAssertTrue(actions.reload)
        XCTAssertTrue(actions.rearm)
    }

    func testExternalDataPathRequestsMigrationWithoutImmediatelySwitchingRoot() {
        let notificationCenter = NotificationCenter()
        let viewModel = SettingsViewModel(
            notificationCenter: notificationCenter,
            initializeServices: false
        )
        let requestedPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouth-External-Request-\(UUID().uuidString)")
            .path
        var config = ConfigService.AppConfig()
        config.dataDirectoryPath = requestedPath
        let originalRoot = TextMouthPaths.root
        let expectation = XCTNSNotificationExpectation(
            name: .dataDirectoryChangeRequested,
            object: nil,
            notificationCenter: notificationCenter
        )
        // The handler may run on another thread, so it holds the path by
        // value rather than reading the test's variable.
        expectation.handler = { note in
            note.userInfo?["path"] as? String == requestedPath
        }

        viewModel.applyConfigChanges(config)

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(TextMouthPaths.root, originalRoot)
    }

    // MARK: - Preference store read path

    /// An empty store reads every preference's default, including the ones
    /// whose defaults now come from `SettingsPolicy`.
    func testEmptyStoreReadsEveryDefault() throws {
        let viewModel = makeIsolatedViewModel(try isolatedDefaults())

        XCTAssertEqual(viewModel.selectedVoiceID, "")
        XCTAssertEqual(viewModel.wordsPerMinute, 200)
        XCTAssertEqual(viewModel.pitchMultiplier, 1)
        XCTAssertEqual(viewModel.selectedLanguage, "en")
        XCTAssertEqual(viewModel.skipForwardUnit, .seconds15)
        XCTAssertEqual(viewModel.skipBackwardUnit, .seconds15)
        XCTAssertEqual(viewModel.shiftSkipForwardUnit, .seconds30)
        XCTAssertEqual(viewModel.shiftSkipBackwardUnit, .seconds30)
        XCTAssertEqual(viewModel.rewindOnResumeUnit, RewindUnit.none)
        XCTAssertFalse(viewModel.rewindSmartMode)
        XCTAssertEqual(viewModel.rewindSmartThreshold, 70)
        XCTAssertEqual(viewModel.sleepFadeOutDuration, 0)
        XCTAssertTrue(viewModel.sleepTimerAutoClose)
        XCTAssertEqual(viewModel.endOfBookBehavior, .stop)
        XCTAssertEqual(viewModel.punctuationPauseLevel, 0)
        XCTAssertFalse(viewModel.autoPlayOnNavigate)
        XCTAssertFalse(viewModel.showBookmarkInPlaybackControls)
        XCTAssertTrue(viewModel.showSpeedInPlaybackControls)
        XCTAssertEqual(viewModel.playbackNavigationUnitControlMode, PlaybackNavigationUnitControlMode.none)
        XCTAssertTrue(viewModel.bluetoothMonitoringEnabled)
        XCTAssertEqual(viewModel.bluetoothDisconnectDelay, 2)
        XCTAssertFalse(viewModel.restartTimerGestureEnabled)
        XCTAssertEqual(viewModel.restartTimerGesturePattern, "previousTrack,previousTrack,previousTrack")
        XCTAssertEqual(viewModel.restartTimerGestureWindow, 2)
    }

    /// Every preference reads the key it has always used, from the injected
    /// store only, so saved preferences keep loading after the refactor.
    func testEveryPreferenceReadsItsKeyFromTheInjectedStore() throws {
        let defaults = try isolatedDefaults()
        let stored: [String: Any] = [
            "selectedVoiceID": "voice.injected",
            "wordsPerMinute": 333.0,
            "pitchMultiplier": 1.7,
            "selectedLanguage": "sv",
            "skipForwardUnit": SkipUnit.heading.rawValue,
            "skipBackwardUnit": SkipUnit.sentence.rawValue,
            "shiftSkipForwardUnit": SkipUnit.bookmark.rawValue,
            "shiftSkipBackwardUnit": SkipUnit.subheading.rawValue,
            "rewindOnResumeUnit": RewindUnit.paragraph.rawValue,
            "rewindSmartMode": true,
            "rewindSmartThreshold": 95.0,
            "sleepFadeOutDuration": 4.0,
            "sleepTimerAutoClose": false,
            "endOfBookBehavior": EndOfBookBehavior.loop.rawValue,
            "punctuationPauseLevel": 2.0,
            "autoPlayOnNavigate": true,
            "showBookmarkInPlaybackControls": true,
            "showSpeedInPlaybackControls": false,
            "playbackNavigationUnitControlMode": PlaybackNavigationUnitControlMode.separate.rawValue,
            "bluetoothMonitoringEnabled": false,
            "bluetoothDisconnectDelay": 6.0,
            "restartTimerGestureEnabled": true,
            "restartTimerGesturePattern": "nextTrack,nextTrack",
            "restartTimerGestureWindow": 4.5,
        ]
        for (key, value) in stored {
            defaults.set(value, forKey: key)
        }

        let viewModel = makeIsolatedViewModel(defaults)

        XCTAssertEqual(viewModel.selectedVoiceID, "voice.injected")
        XCTAssertEqual(viewModel.wordsPerMinute, 333)
        XCTAssertEqual(viewModel.pitchMultiplier, 1.7)
        XCTAssertEqual(viewModel.selectedLanguage, "sv")
        XCTAssertEqual(viewModel.skipForwardUnit, .heading)
        XCTAssertEqual(viewModel.skipBackwardUnit, .sentence)
        XCTAssertEqual(viewModel.shiftSkipForwardUnit, .bookmark)
        XCTAssertEqual(viewModel.shiftSkipBackwardUnit, .subheading)
        XCTAssertEqual(viewModel.rewindOnResumeUnit, .paragraph)
        XCTAssertTrue(viewModel.rewindSmartMode)
        XCTAssertEqual(viewModel.rewindSmartThreshold, 95)
        XCTAssertEqual(viewModel.sleepFadeOutDuration, 4)
        XCTAssertFalse(viewModel.sleepTimerAutoClose)
        XCTAssertEqual(viewModel.endOfBookBehavior, .loop)
        XCTAssertEqual(viewModel.punctuationPauseLevel, 2)
        XCTAssertTrue(viewModel.autoPlayOnNavigate)
        XCTAssertTrue(viewModel.showBookmarkInPlaybackControls)
        XCTAssertFalse(viewModel.showSpeedInPlaybackControls)
        XCTAssertEqual(viewModel.playbackNavigationUnitControlMode, .separate)
        XCTAssertFalse(viewModel.bluetoothMonitoringEnabled)
        XCTAssertEqual(viewModel.bluetoothDisconnectDelay, 6)
        XCTAssertTrue(viewModel.restartTimerGestureEnabled)
        XCTAssertEqual(viewModel.restartTimerGesturePattern, "nextTrack,nextTrack")
        XCTAssertEqual(viewModel.restartTimerGestureWindow, 4.5)
    }

    /// Values written straight into the store, as `defaults write` does,
    /// never leave the model unvalidated: numbers are clamped (non-finite
    /// ones become the default) and unsupported choices read as the default.
    func testInjectedPreferencesAreValidatedOnRead() throws {
        let defaults = try isolatedDefaults()
        defaults.set(1e308, forKey: "wordsPerMinute")
        defaults.set(-4.0, forKey: "pitchMultiplier")
        defaults.set(Double.infinity, forKey: "rewindSmartThreshold")
        defaults.set(Double.nan, forKey: "sleepFadeOutDuration")
        defaults.set(-2.0, forKey: "punctuationPauseLevel")
        defaults.set(0.0, forKey: "bluetoothDisconnectDelay")
        defaults.set("9000", forKey: "restartTimerGestureWindow")
        defaults.set("17 seconds", forKey: "skipForwardUnit")
        defaults.set("Chapter", forKey: "rewindOnResumeUnit")
        defaults.set("Shuffle", forKey: "endOfBookBehavior")
        defaults.set("Floating Menu", forKey: "playbackNavigationUnitControlMode")

        let viewModel = makeIsolatedViewModel(defaults)

        XCTAssertEqual(viewModel.wordsPerMinute, 650)
        XCTAssertEqual(viewModel.pitchMultiplier, 0.5)
        XCTAssertEqual(viewModel.rewindSmartThreshold, 70)
        XCTAssertEqual(viewModel.sleepFadeOutDuration, 0)
        XCTAssertEqual(viewModel.punctuationPauseLevel, 0)
        XCTAssertEqual(viewModel.bluetoothDisconnectDelay, 1)
        XCTAssertEqual(viewModel.restartTimerGestureWindow, 10)
        XCTAssertEqual(viewModel.skipForwardUnit, .seconds15)
        XCTAssertEqual(viewModel.rewindOnResumeUnit, RewindUnit.none)
        XCTAssertEqual(viewModel.endOfBookBehavior, .stop)
        XCTAssertEqual(viewModel.playbackNavigationUnitControlMode, PlaybackNavigationUnitControlMode.none)
    }

    /// A stored speed or pitch of 0, or text that reads as 0, means "not
    /// chosen yet", as the speech engine has always read it: the model
    /// reports the default rather than the slowest speed or lowest pitch.
    func testStoredZeroSpeedAndPitchReadAsTheDefaults() throws {
        let defaults = try isolatedDefaults()
        defaults.set(0.0, forKey: "wordsPerMinute")
        defaults.set("not a number", forKey: "pitchMultiplier")

        let viewModel = makeIsolatedViewModel(defaults)

        XCTAssertEqual(viewModel.wordsPerMinute, 200)
        XCTAssertEqual(viewModel.pitchMultiplier, 1)
    }

    // MARK: - Applying and saving config.json

    /// Extreme values in a config snapshot are clamped before assignment, so
    /// the stored preferences themselves stay in range, not just the reads.
    func testApplyingExtremeConfigValuesKeepsTheStoreInRange() throws {
        let defaults = try isolatedDefaults()
        let initial: [String: Any] = [
            "wordsPerMinute": 300.0, "pitchMultiplier": 1.2, "rewindSmartThreshold": 95.0,
            "sleepFadeOutDuration": 5.0, "punctuationPauseLevel": 1.0, "bluetoothDisconnectDelay": 3.0,
            "restartTimerGestureWindow": 4.0, "skipForwardUnit": SkipUnit.heading.rawValue,
        ]
        for (key, value) in initial {
            defaults.set(value, forKey: key)
        }
        let viewModel = makeIsolatedViewModel(defaults)
        var config = ConfigService.AppConfig()
        config.wordsPerMinute = 1e308
        config.pitchMultiplier = -.infinity
        config.rewindSmartThreshold = .nan
        config.sleepFadeOutDuration = -5
        config.punctuationPauseLevel = 99
        config.bluetoothDisconnectDelay = 1e9
        config.restartTimerGestureWindow = 0.01
        config.skipForwardUnit = "17 seconds"
        config.endOfBookBehavior = EndOfBookBehavior.loop.rawValue

        viewModel.applyConfigChanges(config)

        XCTAssertEqual(defaults.double(forKey: "wordsPerMinute"), 650)
        XCTAssertEqual(defaults.double(forKey: "pitchMultiplier"), 1.2, "a non-finite pitch means not chosen")
        XCTAssertEqual(defaults.double(forKey: "rewindSmartThreshold"), 70, "a non-finite number acts as missing")
        XCTAssertEqual(defaults.double(forKey: "sleepFadeOutDuration"), 0)
        XCTAssertEqual(defaults.double(forKey: "punctuationPauseLevel"), 3)
        XCTAssertEqual(defaults.double(forKey: "bluetoothDisconnectDelay"), 10)
        XCTAssertEqual(defaults.double(forKey: "restartTimerGestureWindow"), 0.5)
        XCTAssertEqual(defaults.string(forKey: "skipForwardUnit"), SkipUnit.heading.rawValue)
        XCTAssertEqual(defaults.string(forKey: "endOfBookBehavior"), EndOfBookBehavior.loop.rawValue)
        for rule in allNumericRules {
            XCTAssertTrue(rule.range.contains(defaults.double(forKey: rule.key)), rule.key)
        }
    }

    /// An unset speed or pitch, empty text, and empty or unsupported choices
    /// leave the current preferences alone, and announce no speech change.
    func testUnsetAndUnsupportedConfigValuesLeaveSettingsAlone() throws {
        let defaults = try isolatedDefaults()
        let stored: [String: Any] = [
            "selectedVoiceID": "voice.kept", "wordsPerMinute": 300.0, "pitchMultiplier": 1.2,
            "selectedLanguage": "de", "skipForwardUnit": SkipUnit.heading.rawValue,
            "rewindOnResumeUnit": RewindUnit.sentence.rawValue,
            "restartTimerGesturePattern": "nextTrack,nextTrack",
        ]
        for (key, value) in stored {
            defaults.set(value, forKey: key)
        }
        let notificationCenter = NotificationCenter()
        let viewModel = SettingsViewModel(
            notificationCenter: notificationCenter,
            initializeServices: false,
            userDefaults: defaults
        )
        let noSpeechChange = XCTNSNotificationExpectation(
            name: .speechSettingsChanged,
            object: nil,
            notificationCenter: notificationCenter
        )
        noSpeechChange.isInverted = true
        // A fresh config leaves speed and pitch at 0 ("not chosen yet").
        var config = ConfigService.AppConfig()
        config.skipForwardUnit = "Sideways"
        config.rewindOnResumeUnit = ""
        config.restartTimerGesturePattern = ""

        viewModel.applyConfigChanges(config)

        wait(for: [noSpeechChange], timeout: 0.1)
        XCTAssertEqual(viewModel.selectedVoiceID, "voice.kept")
        XCTAssertEqual(viewModel.wordsPerMinute, 300)
        XCTAssertEqual(viewModel.pitchMultiplier, 1.2)
        XCTAssertEqual(viewModel.selectedLanguage, "de")
        XCTAssertEqual(viewModel.skipForwardUnit, .heading)
        XCTAssertEqual(viewModel.rewindOnResumeUnit, .sentence)
        XCTAssertEqual(viewModel.restartTimerGesturePattern, "nextTrack,nextTrack")
    }

    /// Saving writes the validated preferences, so a value injected with
    /// `defaults write` reaches config.json repaired, and the fields other
    /// screens manage keep their values.
    func testSavedPreferencesAreTheValidatedValues() throws {
        let defaults = try isolatedDefaults()
        defaults.set(1e308, forKey: "wordsPerMinute")
        defaults.set(-3.0, forKey: "punctuationPauseLevel")
        defaults.set("17 seconds", forKey: "skipForwardUnit")
        defaults.set("Shuffle", forKey: "endOfBookBehavior")
        let viewModel = makeIsolatedViewModel(defaults)
        let original = ConfigService.AppConfig.everyFieldCustomized
        var config = original

        viewModel.writePreferences(into: &config)

        XCTAssertEqual(config.wordsPerMinute, 650)
        XCTAssertEqual(config.punctuationPauseLevel, 0)
        XCTAssertEqual(config.skipForwardUnit, SkipUnit.seconds15.rawValue)
        XCTAssertEqual(config.endOfBookBehavior, EndOfBookBehavior.stop.rawValue)
        XCTAssertEqual(config.importDeleteBehavior, original.importDeleteBehavior)
        XCTAssertEqual(config.confirmBeforeDelete, original.confirmBeforeDelete)
        XCTAssertEqual(config.lastOpenedBookID, original.lastOpenedBookID)
        XCTAssertEqual(config.moveToTrashInsteadOfDeleting, original.moveToTrashInsteadOfDeleting)
    }

    /// A file with one extreme value round-trips through the settings model:
    /// the value is clamped on load and saved clamped, and every other
    /// preference is saved exactly as the file had it.
    func testLoadingThenSavingRewritesOnlyTheClampedPreference() throws {
        var file = try jsonObject(.everyFieldCustomized)
        file["punctuationPauseLevel"] = 40
        let loaded = try JSONDecoder().decode(
            ConfigService.AppConfig.self,
            from: JSONSerialization.data(withJSONObject: file)
        )
        let viewModel = makeIsolatedViewModel(try isolatedDefaults())

        viewModel.applyConfigChanges(loaded)
        var saved = loaded
        viewModel.writePreferences(into: &saved)

        let rewritten = try jsonObject(saved)
        XCTAssertEqual(rewritten["punctuationPauseLevel"] as? Double, 3)
        // The data directory is always the one in use, never the file's.
        for (key, value) in file where key != "punctuationPauseLevel" && key != "dataDirectoryPath" {
            XCTAssertEqual(rewritten[key] as? NSObject, value as? NSObject, key)
        }
    }

    // MARK: - The playback bar

    /// The playback bar's preferences are applied from config.json, which
    /// refreshes open playback bars once per change, and saved back to it.
    func testPlaybackBarPreferencesAreAppliedAndSaved() throws {
        let viewModel = makeIsolatedViewModel(try isolatedDefaults())
        let revision = viewModel.playbackControlsSettingsRevision
        var config = ConfigService.AppConfig()
        config.playbackNavigationUnitControlMode = PlaybackNavigationUnitControlMode.shared.rawValue
        config.showBookmarkInPlaybackControls = true
        config.showSpeedInPlaybackControls = false

        viewModel.applyConfigChanges(config)

        XCTAssertEqual(viewModel.playbackNavigationUnitControlMode, .shared)
        XCTAssertTrue(viewModel.showBookmarkInPlaybackControls)
        XCTAssertFalse(viewModel.showSpeedInPlaybackControls)
        XCTAssertEqual(viewModel.playbackControlsSettingsRevision, revision + 3)

        var saved = ConfigService.AppConfig()
        viewModel.writePreferences(into: &saved)
        XCTAssertEqual(saved.playbackNavigationUnitControlMode, PlaybackNavigationUnitControlMode.shared.rawValue)
        XCTAssertEqual(saved.showBookmarkInPlaybackControls, true)
        XCTAssertEqual(saved.showSpeedInPlaybackControls, false)
    }

    /// A file that leaves the playback bar's switches out, as files from
    /// earlier versions do, or holds values TextMouth cannot use, leaves
    /// every one of these preferences as it is, and logs each unusable value.
    func testMissingOrUnusablePlaybackBarPreferencesLeaveThemAlone() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let defaults = try isolatedDefaults()
        defaults.set(PlaybackNavigationUnitControlMode.separate.rawValue, forKey: "playbackNavigationUnitControlMode")
        defaults.set(true, forKey: "showBookmarkInPlaybackControls")
        defaults.set(false, forKey: "showSpeedInPlaybackControls")
        let viewModel = makeIsolatedViewModel(defaults)
        let revision = viewModel.playbackControlsSettingsRevision
        let menuChoice = "Floating Menu \(UUID().uuidString)"

        viewModel.applyConfigChanges(try decodeConfig("""
        {"playbackNavigationUnitControlMode": "\(menuChoice)", "showBookmarkInPlaybackControls": "no"}
        """))
        viewModel.applyConfigChanges(try decodeConfig("{}"))

        XCTAssertEqual(viewModel.playbackNavigationUnitControlMode, .separate)
        XCTAssertTrue(viewModel.showBookmarkInPlaybackControls)
        XCTAssertFalse(viewModel.showSpeedInPlaybackControls)
        XCTAssertEqual(viewModel.playbackControlsSettingsRevision, revision, "nothing changed")
        XCTAssertEqual(debugLogLines(containing: menuChoice).count, 1)
        XCTAssertFalse(debugLogLines(containing: "config.json showBookmarkInPlaybackControls: could not be read").isEmpty)
    }

    // MARK: - Sound effects

    /// Sound preferences applied from config.json reach the sound service at
    /// once, through the store it follows: an event the file names takes
    /// its sound and the others keep theirs. They are saved back with every
    /// event named.
    func testSoundPreferencesReachTheSoundServiceAndAreSaved() throws {
        let store = try isolatedDefaults()
        let sounds = SoundEffectService(preferences: store)
        let viewModel = makeIsolatedViewModel(store)
        var config = ConfigService.AppConfig()
        config.soundEffectsEnabled = false
        config.soundEffectsVolume = 0.8
        config.soundEffectAssignments = ["Play": "Glass"]

        viewModel.applyConfigChanges(config)

        XCTAssertFalse(sounds.soundsEnabled)
        XCTAssertEqual(sounds.volume, 0.8)
        XCTAssertEqual(sounds.assignments[.play], "Glass")
        XCTAssertEqual(sounds.assignments[.pause], "Tink", "an event the file leaves out keeps its sound")

        var saved = ConfigService.AppConfig()
        viewModel.writePreferences(into: &saved)
        XCTAssertEqual(saved.soundEffectsEnabled, false)
        XCTAssertEqual(saved.soundEffectsVolume, 0.8)
        XCTAssertEqual(saved.soundEffectAssignments["Play"], "Glass")
        XCTAssertEqual(Set(saved.soundEffectAssignments.keys), Set(SoundEvent.allCases.map(\.rawValue)))
    }

    /// Sound preferences config.json holds in a form TextMouth cannot use
    /// leave the current ones as they are and are logged, while the usable
    /// entries beside them are applied, named as the Sounds settings name
    /// them.
    func testUnusableSoundPreferencesKeepTheCurrentOnesAndAreLogged() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let store = try isolatedDefaults()
        let sounds = SoundEffectService(preferences: store)
        let viewModel = makeIsolatedViewModel(store)
        let missingSound = "Pope-\(UUID().uuidString)"
        let unknownEvent = "Fanfare-\(UUID().uuidString)"

        let config = try decodeConfig("""
        {
          "soundEffectsEnabled": "off",
          "soundEffectsVolume": "loud",
          "soundEffectAssignments": {
            "Play": "\(missingSound)", "Pause": 7, "\(unknownEvent)": "Glass", "Skip Forward": "funk"
          }
        }
        """)
        viewModel.applyConfigChanges(config)

        XCTAssertNil(config.soundEffectsEnabled)
        XCTAssertNil(config.soundEffectsVolume)
        XCTAssertEqual(config.soundEffectAssignments, ["Skip Forward": "Funk"])
        XCTAssertTrue(sounds.soundsEnabled)
        XCTAssertEqual(sounds.volume, 0.5)
        XCTAssertEqual(sounds.assignments, SoundEffectService.defaultAssignments.merging([.skipForward: "Funk"]) { $1 })
        XCTAssertEqual(debugLogLines(containing: missingSound).count, 1)
        XCTAssertEqual(debugLogLines(containing: unknownEvent).count, 1)
        XCTAssertFalse(debugLogLines(containing: "config.json soundEffectAssignments.Pause: could not be read").isEmpty)
    }

    // MARK: - Decoding config.json

    /// Extreme numbers are clamped, and wrongly typed, unrepresentable, or
    /// unsupported values fall back to their defaults, while every valid field
    /// beside them is kept. Before validation, any one of these made the whole
    /// file fail to load.
    func testMalformedConfigDecodesFieldByField() throws {
        let config = try decodeConfig("""
        {
          "wordsPerMinute": 1e308,
          "pitchMultiplier": -3,
          "punctuationPauseLevel": 99,
          "sleepFadeOutDuration": -5,
          "restartTimerGestureWindow": 0.1,
          "rewindSmartThreshold": "seventy",
          "bluetoothDisconnectDelay": 1e999,
          "rewindSmartMode": "yes",
          "importDeleteBehavior": "Shred Original",
          "skipForwardUnit": "17 seconds",
          "skipBackwardUnit": "Paragraph",
          "endOfBookBehavior": "Loop to Start",
          "confirmBeforeDelete": false,
          "selectedLanguage": "fr"
        }
        """)

        // Numbers of the right type are clamped into the supported range.
        XCTAssertEqual(config.wordsPerMinute, 650)
        XCTAssertEqual(config.pitchMultiplier, 0.5)
        XCTAssertEqual(config.punctuationPauseLevel, 3)
        XCTAssertEqual(config.sleepFadeOutDuration, 0)
        XCTAssertEqual(config.restartTimerGestureWindow, 0.5)
        // Unreadable fields (text, an unrepresentable number, text for a
        // Bool) take their defaults, exactly like missing fields.
        XCTAssertEqual(config.rewindSmartThreshold, 70)
        XCTAssertEqual(config.bluetoothDisconnectDelay, 2)
        XCTAssertFalse(config.rewindSmartMode)
        // Unsupported choices fall back: the enum field to its default, and
        // raw-value fields to "not chosen", which keeps the current setting.
        XCTAssertEqual(config.importDeleteBehavior, .keepOriginal)
        XCTAssertEqual(config.skipForwardUnit, "")
        // Valid fields beside the damaged ones are untouched.
        XCTAssertEqual(config.skipBackwardUnit, SkipUnit.paragraph.rawValue)
        XCTAssertEqual(config.endOfBookBehavior, EndOfBookBehavior.loop.rawValue)
        XCTAssertFalse(config.confirmBeforeDelete)
        XCTAssertEqual(config.selectedLanguage, "fr")
    }

    /// Missing and null fields keep their defaults, and 0 still means "speed
    /// and pitch not chosen yet" instead of being clamped to the minimum.
    func testMissingNullAndUnsetFieldsKeepTheirDefaults() throws {
        XCTAssertEqual(try decodeConfig("{}"), ConfigService.AppConfig())

        let config = try decodeConfig("""
        {"wordsPerMinute": 0, "pitchMultiplier": 0, "confirmBeforeDelete": null, "importDeleteBehavior": null}
        """)

        XCTAssertEqual(config.wordsPerMinute, 0)
        XCTAssertEqual(config.pitchMultiplier, 0)
        XCTAssertTrue(config.confirmBeforeDelete)
        XCTAssertEqual(config.importDeleteBehavior, .keepOriginal)
    }

    /// Every field is decoded on its own: damaging any single field in a way
    /// no field accepts leaves every other field exactly as saved, and gives
    /// the damaged field the value a missing field gets.
    func testOneUnreadableFieldNeverResetsAnyOtherField() throws {
        let saved = try jsonObject(.everyFieldCustomized)
        var missingFieldValues = try jsonObject(ConfigService.AppConfig())
        // An unreadable data directory keeps the one in use rather than the
        // default, because applying the default would move the library.
        missingFieldValues["dataDirectoryPath"] = ConfigService.AppConfig.currentDataDirectoryPath

        for damagedKey in saved.keys.sorted() {
            var file = saved
            file[damagedKey] = ["unexpected": [1, 2, 3]]
            let decoded = try JSONDecoder().decode(
                ConfigService.AppConfig.self,
                from: JSONSerialization.data(withJSONObject: file)
            )

            let result = try jsonObject(decoded)
            for key in saved.keys {
                let expected = key == damagedKey ? missingFieldValues[key] : saved[key]
                XCTAssertEqual(
                    result[key] as? NSObject,
                    expected as? NSObject,
                    "\(key) after damaging \(damagedKey)"
                )
            }
        }
    }

    /// Saving after a load that repaired one field writes the repaired value
    /// and every other field exactly as it was: nothing is reset to defaults.
    func testSavingAfterARepairedLoadRewritesOnlyTheRepairedField() throws {
        var file = try jsonObject(.everyFieldCustomized)
        file["wordsPerMinute"] = 1e308
        let loaded = try JSONDecoder().decode(
            ConfigService.AppConfig.self,
            from: JSONSerialization.data(withJSONObject: file)
        )

        let rewritten = try jsonObject(from: ConfigService.fileData(for: loaded))

        XCTAssertEqual(rewritten["wordsPerMinute"] as? Double, 650)
        XCTAssertEqual(Set(rewritten.keys), Set(file.keys))
        for (key, value) in file where key != "wordsPerMinute" {
            XCTAssertEqual(rewritten[key] as? NSObject, value as? NSObject, key)
        }
    }

    /// Each repaired field produces exactly one debug-log line naming the
    /// field, the value that was on disk, and its replacement.
    func testEachRepairedFieldIsLoggedOnce() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let marker = Int.random(in: 100_000...999_999)
        let unit = "Unit \(UUID().uuidString)"

        _ = try decodeConfig("""
        {"rewindSmartThreshold": \(marker), "shiftSkipForwardUnit": "\(unit)"}
        """)

        let thresholdLines = debugLogLines(containing: "config.json rewindSmartThreshold")
            .filter { $0.contains("\(marker)") }
        let unitLines = debugLogLines(containing: unit)
        XCTAssertEqual(thresholdLines.count, 1)
        XCTAssertEqual(unitLines.count, 1)
        XCTAssertTrue(thresholdLines.first?.contains("with 600.0") ?? false)
        XCTAssertTrue(unitLines.first?.contains("config.json shiftSkipForwardUnit") ?? false)
    }

    // MARK: - Helpers

    /// Every numeric rule the settings model stores.
    private let allNumericRules = [
        SettingsPolicy.wordsPerMinute, SettingsPolicy.pitchMultiplier,
        SettingsPolicy.rewindSmartThreshold, SettingsPolicy.sleepFadeOutDuration,
        SettingsPolicy.punctuationPauseLevel, SettingsPolicy.bluetoothDisconnectDelay,
        SettingsPolicy.restartTimerGestureWindow,
    ]

    /// A settings model bound to `defaults` that starts no services and
    /// posts only to a private notification center.
    private func makeIsolatedViewModel(_ defaults: UserDefaults) -> SettingsViewModel {
        SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults
        )
    }

    /// Decodes config.json text the way `ConfigService.loadFromDisk()` does.
    private func decodeConfig(_ json: String) throws -> ConfigService.AppConfig {
        try JSONDecoder().decode(ConfigService.AppConfig.self, from: Data(json.utf8))
    }

    /// The JSON object `ConfigService.saveToDisk()` writes for `config`.
    private func jsonObject(_ config: ConfigService.AppConfig) throws -> [String: Any] {
        try jsonObject(from: ConfigService.fileData(for: config))
    }

    /// Parses saved config bytes into a dictionary for field-by-field checks.
    private func jsonObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
