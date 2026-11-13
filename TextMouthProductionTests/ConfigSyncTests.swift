import Combine
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

    /// An outside edit naming an existing, empty folder still asks the
    /// library to move there; one naming a location this Mac doesn't have is
    /// ignored instead (FR02, `DataDirectoryVerificationTests`).
    func testExternalDataPathRequestsMigrationWithoutImmediatelySwitchingRoot() throws {
        let notificationCenter = NotificationCenter()
        let viewModel = SettingsViewModel(
            notificationCenter: notificationCenter,
            initializeServices: false
        )
        let requestedPath = try makeSandboxDirectory("TextMouth-External-Request").path
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

    // MARK: - Text substitutions

    /// The substitution switch applied from config.json reaches a
    /// substitution service following the same store at once and is saved
    /// back; a file without the switch, or with something other than true
    /// or false, leaves it alone.
    func testSubstitutionSwitchReachesItsServiceAndIsSaved() throws {
        let store = try isolatedDefaults()
        let substitutions = TextSubstitutionService(rules: [], isEnabled: true, preferences: store)
        let viewModel = makeIsolatedViewModel(store)
        var config = ConfigService.AppConfig()
        config.substitutionsEnabled = false

        viewModel.applyConfigChanges(config)

        XCTAssertFalse(substitutions.isEnabled)
        var saved = ConfigService.AppConfig()
        viewModel.writePreferences(into: &saved)
        XCTAssertEqual(saved.substitutionsEnabled, false)

        viewModel.applyConfigChanges(try decodeConfig("{}"))
        viewModel.applyConfigChanges(try decodeConfig(#"{"substitutionsEnabled": "on"}"#))
        XCTAssertFalse(substitutions.isEnabled)
    }

    /// The repeated-symbol settings applied from config.json reach the
    /// substitution service following the same store at once, and are saved
    /// back under readable names: the style as "repeat", "count", or "omit",
    /// the threshold as a number, and the symbols as text.
    func testRepeatedSymbolSettingsReachTheirServiceAndAreSaved() throws {
        let store = try isolatedDefaults()
        let substitutions = TextSubstitutionService(rules: [], preferences: store)
        let viewModel = makeIsolatedViewModel(store)

        viewModel.applyConfigChanges(try decodeConfig("""
        {"repeatedSymbolStyle": "omit", "repeatedSymbolThreshold": -1, "repeatedSymbolSet": "#~"}
        """))

        XCTAssertEqual(substitutions.repeatedSymbolRule, RepeatedSymbolRule(style: .leaveOut, threshold: -1, symbols: "#~"))
        var saved = ConfigService.AppConfig()
        viewModel.writePreferences(into: &saved)
        XCTAssertEqual(saved.repeatedSymbolStyle, "omit")
        XCTAssertEqual(saved.repeatedSymbolThreshold, -1)
        XCTAssertEqual(saved.repeatedSymbolSet, "#~")
        let file = try jsonObject(saved)
        XCTAssertEqual(file["repeatedSymbolStyle"] as? String, "omit")
        XCTAssertEqual(file["repeatedSymbolThreshold"] as? Int, -1)
        XCTAssertEqual(file["repeatedSymbolSet"] as? String, "#~")
    }

    /// A store holding no repeated-symbol settings is saved with the
    /// standard ones, so config.json always shows the settings in force.
    func testStandardRepeatedSymbolSettingsAreSaved() throws {
        let viewModel = makeIsolatedViewModel(try isolatedDefaults())
        var saved = ConfigService.AppConfig()

        viewModel.writePreferences(into: &saved)

        XCTAssertEqual(saved.repeatedSymbolStyle, "count")
        XCTAssertEqual(saved.repeatedSymbolThreshold, 4)
        XCTAssertEqual(saved.repeatedSymbolSet, SettingsPolicy.repeatedSymbolSet.defaultValue)
    }

    /// Values the Settings controls could not produce are repaired as the
    /// file is read: a negative threshold means -1, one past 99 is 99, and
    /// the symbols keep only their punctuation and symbols, each once.
    /// Symbols left empty, as written or once repaired, keep the current
    /// ones, as any empty text in the file does.
    func testRepeatedSymbolValuesAreRepairedAsTheFileIsRead() throws {
        let store = try isolatedDefaults()
        let substitutions = TextSubstitutionService(rules: [], preferences: store)
        let viewModel = makeIsolatedViewModel(store)

        let clamped = try decodeConfig(#"{"repeatedSymbolThreshold": 150, "repeatedSymbolSet": "a * * b ="}"#)
        XCTAssertEqual(clamped.repeatedSymbolThreshold, 99)
        XCTAssertEqual(clamped.repeatedSymbolSet, "*=")
        viewModel.applyConfigChanges(clamped)
        XCTAssertEqual(substitutions.repeatedSymbolThreshold, 99)
        XCTAssertEqual(substitutions.repeatedSymbolSet, "*=")

        XCTAssertEqual(try decodeConfig(#"{"repeatedSymbolThreshold": -5}"#).repeatedSymbolThreshold, -1)
        XCTAssertEqual(try decodeConfig(#"{"repeatedSymbolThreshold": 0}"#).repeatedSymbolThreshold, 2)

        let empty = try decodeConfig(#"{"repeatedSymbolSet": ""}"#)
        let lettersOnly = try decodeConfig(#"{"repeatedSymbolSet": "abc 123"}"#)
        XCTAssertEqual(empty.repeatedSymbolSet, "")
        XCTAssertEqual(lettersOnly.repeatedSymbolSet, "")
        viewModel.applyConfigChanges(empty)
        viewModel.applyConfigChanges(lettersOnly)
        XCTAssertEqual(substitutions.repeatedSymbolSet, "*=")
    }

    /// Missing, null, or unusable repeated-symbol values leave the settings
    /// in force alone, and an unsupported style is logged once.
    func testUnusableRepeatedSymbolValuesLeaveTheSettingsAlone() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let store = try isolatedDefaults()
        let substitutions = TextSubstitutionService(rules: [], preferences: store)
        substitutions.repeatedSymbolStyle = .repeatEach
        substitutions.repeatedSymbolThreshold = 6
        substitutions.repeatedSymbolSet = "~"
        let viewModel = makeIsolatedViewModel(store)
        let style = "Loud \(UUID().uuidString)"

        let unusable = try decodeConfig("""
        {"repeatedSymbolStyle": "\(style)", "repeatedSymbolThreshold": "four", "repeatedSymbolSet": 12}
        """)
        XCTAssertEqual(unusable.repeatedSymbolStyle, "")
        XCTAssertNil(unusable.repeatedSymbolThreshold)
        XCTAssertNil(unusable.repeatedSymbolSet)
        for config in [unusable, try decodeConfig("{}"), try decodeConfig(#"{"repeatedSymbolThreshold": 4.5}"#),
                       try decodeConfig(#"{"repeatedSymbolStyle": null, "repeatedSymbolSet": null}"#)] {
            viewModel.applyConfigChanges(config)
        }

        XCTAssertEqual(substitutions.repeatedSymbolRule, RepeatedSymbolRule(style: .repeatEach, threshold: 6, symbols: "~"))
        XCTAssertEqual(debugLogLines(containing: style).count, 1)
    }

    // MARK: - Keyboard shortcuts

    /// Shortcuts applied from config.json reach the shortcut manager at
    /// once, through the record it follows: an action the file lists takes
    /// exactly its shortcuts, as the user's, and the others keep theirs.
    /// They are saved back with every action named, in readable text: an
    /// edited action as a list, every other as "default: " and its keys.
    func testShortcutsReachTheShortcutManagerAndAreSaved() throws {
        let store = try isolatedDefaults()
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)
        let viewModel = makeIsolatedViewModel(store)
        var config = ConfigService.AppConfig()
        config.keyboardShortcuts = ["Where Am I?": ["option+w"], "Release Media Controls": ["control+r"]]

        viewModel.applyConfigChanges(config)

        XCTAssertEqual(manager.bindingsFor(.whereAmI), [KeyBinding(key: "w", option: true)])
        XCTAssertEqual(manager.bindingsFor(.releaseMediaControls), [KeyBinding(key: "r", control: true)])
        XCTAssertEqual(manager.bindingsFor(.togglePlayback), ShortcutAction.defaultBindings[.togglePlayback])
        XCTAssertEqual(manager.edits.editedActions, [.releaseMediaControls, .whereAmI])

        var saved = ConfigService.AppConfig()
        viewModel.writePreferences(into: &saved)
        XCTAssertEqual(saved.keyboardShortcuts["Where Am I?"], ["option+w"])
        XCTAssertEqual(saved.keyboardShortcuts["Play / Pause"], "default: space, k")
        XCTAssertEqual(Set(saved.keyboardShortcuts.keys), Set(ShortcutAction.allCases.map(\.rawValue)))
    }

    /// A shortcut config.json gives one action moves there from the action
    /// that had it, as recording it in Settings would, so no key triggers
    /// two actions; an empty list leaves an action without a shortcut.
    func testAShortcutTheFileGivesAnActionMovesThere() throws {
        let store = try isolatedDefaults()
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)
        let viewModel = makeIsolatedViewModel(store)
        var config = ConfigService.AppConfig()
        config.keyboardShortcuts = ["Where Am I?": ["k"], "Go to Library": []]

        viewModel.applyConfigChanges(config)

        XCTAssertEqual(manager.bindingsFor(.whereAmI), [KeyBinding(key: "k")])
        XCTAssertEqual(manager.bindingsFor(.togglePlayback), [KeyBinding(key: "space")])
        XCTAssertTrue(manager.bindingsFor(.goToLibrary).isEmpty)
    }

    /// Shortcuts config.json holds in a form TextMouth cannot use leave the
    /// current ones as they are and are logged, a mistyped shortcut leaving
    /// its whole action alone, while the usable entries beside them apply.
    func testUnusableShortcutsKeepTheCurrentOnesAndAreLogged() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let store = try isolatedDefaults()
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)
        let viewModel = makeIsolatedViewModel(store)
        let mistyped = "hyper\(Int.random(in: 100_000...999_999))+k"
        let unknownAction = "Teleport \(UUID().uuidString)"

        let config = try decodeConfig("""
        {
          "keyboardShortcuts": {
            "Play / Pause": ["space", "\(mistyped)"],
            "Where Am I?": ["Option + W"],
            "\(unknownAction)": ["t"],
            "Go Back": 7
          }
        }
        """)
        viewModel.applyConfigChanges(config)

        XCTAssertEqual(config.keyboardShortcuts, ["Where Am I?": ["option+w"]])
        XCTAssertEqual(manager.bindingsFor(.whereAmI), [KeyBinding(key: "w", option: true)])
        XCTAssertEqual(manager.bindingsFor(.togglePlayback), ShortcutAction.defaultBindings[.togglePlayback])
        XCTAssertEqual(manager.bindingsFor(.goBack), ShortcutAction.defaultBindings[.goBack])
        XCTAssertEqual(manager.edits.editedActions, [.whereAmI])
        XCTAssertEqual(debugLogLines(containing: mistyped).count, 1)
        XCTAssertEqual(debugLogLines(containing: unknownAction).count, 1)
        XCTAssertFalse(debugLogLines(containing: "config.json keyboardShortcuts.Go Back: could not be read").isEmpty)
    }

    /// The double-press time (FR12) is read from config.json moved into 0.2
    /// to 2 seconds and to the nearest tenth, the move logged; applied, it
    /// reaches the shortcut manager at once; and it is saved back as the
    /// tenth in force, half a second while the store holds none. A file
    /// without it, or with one that cannot be read, leaves it alone.
    func testTheDoublePressTimeIsReadInTenthsAppliedAndSaved() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let store = try isolatedDefaults()
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)
        let viewModel = makeIsolatedViewModel(store)
        var standard = ConfigService.AppConfig()
        viewModel.writePreferences(into: &standard)
        XCTAssertEqual(try jsonObject(standard)["shortcutDoublePressSeconds"] as? Double, 0.5)

        let read: [(text: String, seconds: Double?)] = [
            ("0.8", 0.8), ("0.75", 0.8), ("0.05", 0.2), ("7", 2), ("1", 1), ("\"fast\"", nil), ("null", nil),
        ]
        for (text, seconds) in read {
            XCTAssertEqual(try decodeConfig(#"{"shortcutDoublePressSeconds": \#(text)}"#).shortcutDoublePressSeconds, seconds, text)
        }
        XCTAssertNil(try decodeConfig("{}").shortcutDoublePressSeconds)
        XCTAssertFalse(debugLogLines(containing: "config.json shortcutDoublePressSeconds").isEmpty, "a moved value is logged")

        viewModel.applyConfigChanges(try decodeConfig(#"{"shortcutDoublePressSeconds": 1.24}"#))
        XCTAssertEqual(manager.doublePressTime, 1.2)
        XCTAssertEqual(store.double(forKey: "shortcutDoublePressSeconds"), 1.2)
        viewModel.applyConfigChanges(try decodeConfig("{}"))
        XCTAssertEqual(manager.doublePressTime, 1.2, "a file without it leaves it alone")

        var saved = ConfigService.AppConfig()
        viewModel.writePreferences(into: &saved)
        let text = String(decoding: try ConfigService.fileData(for: saved), as: UTF8.self)
        XCTAssertTrue(text.contains(#""shortcutDoublePressSeconds" : 1.2,"#), text)
    }

    // MARK: - Where the logs are written

    /// The log location applied from config.json is stored where the log
    /// writer reads it, and saved back as "dataDirectory" or "machine"; a
    /// store holding none is saved with the default, so config.json always
    /// shows the choice in force.
    func testTheLogLocationIsAppliedAndSavedByItsName() throws {
        let store = try isolatedDefaults()
        let viewModel = makeIsolatedViewModel(store)
        var standard = ConfigService.AppConfig()
        viewModel.writePreferences(into: &standard)
        XCTAssertEqual(try jsonObject(standard)["logLocation"] as? String, "dataDirectory")

        viewModel.applyConfigChanges(try decodeConfig(#"{"logLocation": "machine"}"#))

        XCTAssertEqual(LogLocation.preference.read(from: store), .machine)
        XCTAssertEqual(viewModel.logLocation, .machine)
        var saved = ConfigService.AppConfig()
        viewModel.writePreferences(into: &saved)
        XCTAssertEqual(try jsonObject(saved)["logLocation"] as? String, "machine")
    }

    /// A log location config.json holds that TextMouth can't use, another
    /// word, another spelling, or not text at all, is repaired to "not
    /// chosen" as the file is read and logged once; it, a missing one, a
    /// null, and an empty one all leave the choice in force alone.
    func testUnusableLogLocationsLeaveTheChoiceAlone() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let store = try isolatedDefaults()
        let viewModel = makeIsolatedViewModel(store)
        viewModel.logLocation = .machine
        let unsupported = "cloud-\(UUID().uuidString)"

        let unusable = try decodeConfig(#"{"logLocation": "\#(unsupported)"}"#)
        XCTAssertEqual(unusable.logLocation, "")
        XCTAssertEqual(try decodeConfig(#"{"logLocation": "Machine"}"#).logLocation, "")
        XCTAssertEqual(try decodeConfig(#"{"logLocation": 7}"#).logLocation, "")
        for config in [unusable, try decodeConfig("{}"), try decodeConfig(#"{"logLocation": null}"#),
                       try decodeConfig(#"{"logLocation": ""}"#)] {
            viewModel.applyConfigChanges(config)
        }

        XCTAssertEqual(LogLocation.preference.read(from: store), .machine)
        XCTAssertEqual(debugLogLines(containing: unsupported).count, 1)
    }

    /// A choice made in Storage settings is stored where the log writer
    /// reads it at once, and saved to config.json with the next save, which
    /// waits for changes to pause (PERF17); so is one made outside the
    /// settings model, as `defaults write` makes one, which the model also
    /// announces, so the picker shows it.
    func testALogLocationChosenAnywhereIsSavedToConfigJSON() throws {
        let store = try isolatedDefaults()
        let url = try makeConfigFileURL()
        let service = ConfigService(fileURL: url)
        let viewModel = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: store,
            configService: service
        )
        var announcements = 0
        let subscription = viewModel.objectWillChange.sink { announcements += 1 }
        defer { subscription.cancel() }

        viewModel.logLocation = .machine

        XCTAssertEqual(store.string(forKey: "logLocation"), "machine")
        XCTAssertTrue(service.hasScheduledSave, "no save of config.json was asked for")
        service.flushScheduledSave()
        XCTAssertEqual(try jsonObject(from: Data(contentsOf: url))["logLocation"] as? String, "machine")

        let announcedBefore = announcements
        LogLocation.preference.write(.dataDirectory, to: store)
        service.flushScheduledSave()

        XCTAssertEqual(try jsonObject(from: Data(contentsOf: url))["logLocation"] as? String, "dataDirectory")
        XCTAssertGreaterThan(announcements, announcedBefore, "the settings model did not announce the change")
        XCTAssertEqual(viewModel.logLocation, .dataDirectory)
    }

    // MARK: - Portability

    /// Every portable preference survives config.json (TODO C04): each is
    /// set to a value unlike its default, the file is written, the stores
    /// are reset, and the file is applied, after which every value is back,
    /// in the preferences store and in the services that follow it. The
    /// expected set is `AppConfig.Portability`'s, and the samples must cover
    /// it, so a portable preference listed there but left out of the mirror
    /// fails here.
    func testEveryPortablePreferenceSurvivesARoundTripThroughConfigJSON() throws {
        let samples = try Self.portablePreferenceSamples()
        XCTAssertEqual(
            Set(samples.keys),
            Set(ConfigService.AppConfig.Portability.mirrored.map(\.storeKey)),
            "every portable preference needs a sample below"
        )
        let url = try makeConfigFileURL()

        // Every portable preference set, then written to the file.
        let original = try isolatedDefaults()
        for (key, value) in samples {
            original.set(value, forKey: key)
        }
        let writer = ConfigService(fileURL: url)
        writer.config.importDeleteBehavior = .askEachTime
        writer.config.confirmBeforeDelete = false
        writer.config.moveToTrashInsteadOfDeleting = false
        SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: original,
            configService: writer
        ).syncToConfig()
        // The file follows once changes pause (PERF17); write it now.
        writer.flushScheduledSave()

        // The stores reset: an empty preferences store, services following
        // it, and the file read afresh; then the file applied.
        let reset = try isolatedDefaults()
        let sounds = SoundEffectService(preferences: reset)
        let substitutions = TextSubstitutionService(rules: [], preferences: reset)
        let shortcuts = KeyboardShortcutManager(userDefaults: reset, installsEventMonitor: false)
        let reader = ConfigService(fileURL: url)
        let restored = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: reset,
            configService: reader
        )
        restored.applyConfigChanges(reader.config)

        for (key, value) in samples {
            XCTAssertTrue(Self.sameStoredValue(reset.object(forKey: key), value), "\(key) did not survive config.json")
        }
        XCTAssertEqual(reader.config.importDeleteBehavior, .askEachTime)
        XCTAssertFalse(reader.config.confirmBeforeDelete)
        XCTAssertFalse(reader.config.moveToTrashInsteadOfDeleting)
        // The services took the values up as they arrived.
        XCTAssertFalse(sounds.soundsEnabled)
        XCTAssertEqual(sounds.volume, 0.35)
        XCTAssertEqual(sounds.assignments, SoundEffectService.assignmentsPreference.read(from: original))
        XCTAssertFalse(substitutions.isEnabled)
        XCTAssertEqual(
            substitutions.repeatedSymbolRule,
            RepeatedSymbolRule(style: .leaveOut, threshold: 7, symbols: "*=~")
        )
        XCTAssertEqual(shortcuts.bindings, KeyboardShortcutManager.bindingsPreference.read(from: original))
    }

    /// Every preference the settings model keeps in the store, and every one
    /// the services keep, is listed as portable, and nothing else is: a new
    /// preference cannot be left out of config.json unnoticed. SwiftUI's
    /// AppStorage shows reflection its key at `location.key`; were that to
    /// change, this test says so rather than passing.
    func testEveryStoredPreferenceIsListedAsPortable() throws {
        let viewModel = makeIsolatedViewModel(try isolatedDefaults())
        let storages = Mirror(reflecting: viewModel).children.filter {
            String(describing: type(of: $0.value)).hasPrefix("AppStorage<")
        }
        let keys = storages.compactMap { Mirror(reflecting: $0.value).descendant("location", "key") as? String }

        XCTAssertFalse(storages.isEmpty)
        XCTAssertEqual(keys.count, storages.count, "AppStorage no longer shows its key at location.key")
        let stored = Set(keys + SettingsViewModel.servicePreferenceKeys)
        let listed = Set(ConfigService.AppConfig.Portability.mirrored.map(\.storeKey))
        XCTAssertEqual(stored.subtracting(listed), [], "kept in the store but not listed in AppConfig.Portability")
        XCTAssertEqual(listed.subtracting(stored), [], "listed as portable but kept by neither the model nor a service")
    }

    /// The record of P07's one-time move of finished books to their ends
    /// describes what this Mac has done, not a setting, so it is listed as
    /// machine-local, and config.json neither mirrors nor holds it.
    func testTheFinishedBooksMoveRecordIsMachineLocal() throws {
        let portability = ConfigService.AppConfig.Portability.self
        let key = LibraryViewModel.finishedBooksAtEndKey

        XCTAssertEqual(key, "library.finishedBooksAtEndVersion")
        XCTAssertTrue(portability.localStoreKeys.contains(key))
        XCTAssertFalse(portability.mirrored.contains { $0.storeKey == key })
        XCTAssertFalse(try jsonObject(.everyFieldCustomized).keys.contains(key))
    }

    /// Every field config.json holds is listed, once, as portable or
    /// machine-local, and every listed field is in the file; no machine-local
    /// store key is.
    func testEveryConfigFieldIsListedOnce() throws {
        let portability = ConfigService.AppConfig.Portability.self
        let fields = Set(try jsonObject(.everyFieldCustomized).keys)
        let listed = portability.mirrored.map(\.field) + portability.fileOnly + portability.localFields

        XCTAssertEqual(fields, Set(listed))
        XCTAssertEqual(listed.count, Set(listed).count, "a field is listed twice")
        XCTAssertTrue(fields.isDisjoint(with: portability.localStoreKeys))
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

    /// A value unlike its default for every portable preference, by store
    /// key, in the form its owner keeps it in the preferences store.
    private static func portablePreferenceSamples() throws -> [String: Any] {
        // The record of the shortcuts the user edited (FR12): two actions.
        let shortcuts = ShortcutEdits([
            .togglePlayback: [KeyBinding(key: "p", control: true)],
            .whereAmI: [KeyBinding(key: "w", option: true), KeyBinding(key: "w", control: true)],
        ])
        let sounds: [SoundEvent: String] = [
            .play: "Glass", .pause: "None", .skipForward: "Funk",
            .skipBackward: "Bottle", .whereAmIStart: "Hero", .whereAmIEnd: "Purr",
        ]
        return [
            // Voice.
            "selectedVoiceID": "com.apple.voice.compact.fr-FR.Thomas",
            "wordsPerMinute": 425.0,
            "pitchMultiplier": 1.4,
            "selectedLanguage": "fr",
            // Playback.
            "skipForwardUnit": SkipUnit.heading.rawValue,
            "skipBackwardUnit": SkipUnit.sentence.rawValue,
            "shiftSkipForwardUnit": SkipUnit.seconds60.rawValue,
            "shiftSkipBackwardUnit": SkipUnit.paragraph.rawValue,
            "rewindOnResumeUnit": RewindUnit.paragraph.rawValue,
            "rewindSmartMode": true,
            "rewindSmartThreshold": 125.0,
            "punctuationPauseLevel": 2.0,
            "autoPlayOnNavigate": true,
            "endOfBookBehavior": EndOfBookBehavior.continueNext.rawValue,
            "nextBookWindow": NextBookWindow.newWindow.rawValue,
            "sleepFadeOutDuration": 6.0,
            "sleepTimerAutoClose": false,
            "playbackNavigationUnitControlMode": PlaybackNavigationUnitControlMode.separate.rawValue,
            "showBookmarkInPlaybackControls": true,
            "showSpeedInPlaybackControls": false,
            "showExportInReaderToolbar": true,
            "includeSpeedWithTimes": true,
            "showsPageInReader": false,
            "saysPageInWhereAmI": false,
            // Shortcuts, text, and sounds, kept by their services.
            "keyboardShortcutEdits": try XCTUnwrap(shortcuts.storedData),
            "shortcutDoublePressSeconds": 1.2,
            "substitutionsEnabled": false,
            "repeatedSymbolStyle": RepeatedSymbolStyle.leaveOut.rawValue,
            "repeatedSymbolThreshold": 7,
            "repeatedSymbolSet": "*=~",
            // Recording, kept by the Record window: its microphone and its
            // level announcements.
            "recordingInputDeviceID": "AppleUSBAudioEngine:Studio Microphone:4100000:1",
            "recordingAnnouncesLevel": true,
            "recordingLevelAnnouncementSeconds": 25,
            "recordingOriginalPolicy": AudioOriginalPolicy.Choice.keep.rawValue,
            "recordingOriginalDays": 14.0,
            // Audio editing: whether an installed ffmpeg is used, and the
            // editor window's preview of a filter and half second after each
            // move (FR04).
            "useInstalledFFmpeg": false,
            "audioEditorPreviewsFilters": false,
            "audioEditorPlaysAfterMoves": false,
            "soundEffectsEnabled": false,
            "soundEffectsVolume": Float(0.35),
            "soundEffectAssignments": try JSONEncoder().encode(sounds.keyedByRawValue),
            // Feeds (FR03), kept by the feed engine.
            "feedRefreshAtLaunch": false,
            "feedRefreshIntervalHours": 6,
            "feedItems": FeedItemPolicy.Choice.onlyNewestListed.rawValue,
            "feedNewestCount": 12,
            "feedDeleteDownloadsDaysAfterPlayed": 0,
            "feedRefreshAlert": true,
            "feedNotifications": true,
            // Miscellaneous.
            "bluetoothMonitoringEnabled": false,
            "bluetoothDisconnectDelay": 7.0,
            "restartTimerGestureEnabled": true,
            "restartTimerGesturePattern": "togglePlayPause,nextTrack",
            "restartTimerGestureWindow": 3.5,
            // Storage: where the log writer writes.
            "logLocation": LogLocation.machine.rawValue,
            // Transcription: the language it uses, and the offer after an
            // import.
            "transcriptionLocale": TranscriptFixtures.languageOtherThanTheDefault,
            "offerTranscriptionAfterImport": true,
            // Library: the Library window's views, as the views store keeps
            // them, a JSON array in data.
            LibraryViewDefinitionList.fileKey: try JSONEncoder().encode(ConfigService.AppConfig.customizedLibraryViews),
            // And what a title's leading article does in its lists.
            SettingsPolicy.leadingArticles.key: LeadingArticles.ignoredWhenTypingAndSorting.rawValue,
            // Braille: the table braille files are read and written with, and
            // the braille file characters an import reads a BRF or BRL file
            // with (braillecodes).
            "brailleTable": "en-us-g1.ctb",
            "brailleFileCode": "ascii-eurobraille",
        ]
    }

    /// Whether a value read back from a preferences store is `expected`.
    /// Data holding JSON compares by what it holds, since a dictionary's
    /// entries are encoded in no fixed order; any other value compares as
    /// the property list object it is.
    private static func sameStoredValue(_ stored: Any?, _ expected: Any) -> Bool {
        if let storedData = stored as? Data, let expectedData = expected as? Data {
            let storedJSON = try? JSONSerialization.jsonObject(with: storedData) as? NSObject
            let expectedJSON = try? JSONSerialization.jsonObject(with: expectedData) as? NSObject
            return storedJSON != nil && storedJSON == expectedJSON
        }
        return (stored as? NSObject)?.isEqual(expected) == true
    }

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

    /// The fixture every round-trip test of config.json uses writes a
    /// shortcut in the object form too, as TextMouth writes an action working
    /// in a kind of window the user chose: Where Am I?, edited to Option-W
    /// and working in Library windows, is an object with its keys and its
    /// "worksIn", and that entry survives the file.
    func testTheFixtureWritesAnActionsScopeAsAnObjectAndItSurvivesTheFile() throws {
        let expected: ShortcutListing = .object(keys: ["option+w"], worksIn: "Library windows")
        XCTAssertEqual(ConfigService.AppConfig.everyFieldCustomized.keyboardShortcuts["Where Am I?"], expected)

        let decoded = try ConfigService.decode(ConfigService.fileData(for: .everyFieldCustomized))
        XCTAssertEqual(decoded.keyboardShortcuts["Where Am I?"], expected)
    }

    /// Parses saved config bytes into a dictionary for field-by-field checks.
    private func jsonObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
