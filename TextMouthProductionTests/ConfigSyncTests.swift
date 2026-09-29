import XCTest
@testable import TextMouth

/// Regression coverage for config/AppStorage mapping and watcher replacement.
@MainActor
final class ConfigSyncTests: XCTestCase {
    func testPlaybackControlSettingsPublishRefreshesForOpenReaders() {
        let defaults = UserDefaults.standard
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
        let defaults = UserDefaults.standard
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
        let defaults = UserDefaults.standard
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

    func testAtomicReplacementRearmsWatcherDuringInternalSave() {
        let actions = ConfigService.watcherActions(for: .rename, isSaving: true)

        XCTAssertFalse(actions.reload)
        XCTAssertTrue(actions.rearm)
    }

    func testExternalAtomicReplacementReloadsAndRearmsWatcher() {
        let actions = ConfigService.watcherActions(for: [.write, .rename], isSaving: false)

        XCTAssertTrue(actions.reload)
        XCTAssertTrue(actions.rearm)
    }

    func testExternalDataPathRequestsMigrationWithoutImmediatelySwitchingRoot() {
        let notificationCenter = NotificationCenter()
        let viewModel = SettingsViewModel(
            notificationCenter: notificationCenter,
            initializeServices: false
        )
        var config = ConfigService.AppConfig()
        config.dataDirectoryPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouth-External-Request-\(UUID().uuidString)")
            .path
        let originalRoot = TextMouthPaths.root
        let expectation = XCTNSNotificationExpectation(
            name: .dataDirectoryChangeRequested,
            object: nil,
            notificationCenter: notificationCenter
        )
        expectation.handler = { note in
            note.userInfo?["path"] as? String == config.dataDirectoryPath
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
        let saved = try jsonObject(customizedConfig())
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
        var file = try jsonObject(customizedConfig())
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
        TextMouthPaths.flushLogs()

        // Include the rotated generation in case this write started a new file.
        let logFile = TextMouthPaths.debugLogFile
        let lines = [logFile, logFile.appendingPathExtension(TextMouthPaths.rotatedLogExtension)]
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
            .split(separator: "\n")
        let thresholdLines = lines.filter {
            $0.contains("config.json rewindSmartThreshold") && $0.contains("\(marker)")
        }
        let unitLines = lines.filter { $0.contains(unit) }
        XCTAssertEqual(thresholdLines.count, 1)
        XCTAssertEqual(unitLines.count, 1)
        XCTAssertTrue(thresholdLines.first?.contains("with 600.0") ?? false)
        XCTAssertTrue(unitLines.first?.contains("config.json shiftSkipForwardUnit") ?? false)
    }

    // MARK: - Helpers

    /// A throwaway preferences suite, deleted when the test ends, so tests
    /// never read or change the user's real settings.
    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "com.textmouth.tests.config-sync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
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

    /// Parses saved config bytes into a dictionary for field-by-field checks.
    private func jsonObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A config in which every field holds a supported, non-default value,
    /// so a field reset to its default is always detectable.
    private func customizedConfig() -> ConfigService.AppConfig {
        var config = ConfigService.AppConfig()
        config.selectedVoiceID = "com.apple.voice.compact.fr-FR.Thomas"
        config.wordsPerMinute = 425
        config.pitchMultiplier = 1.4
        config.selectedLanguage = "fr"
        config.skipForwardUnit = SkipUnit.heading.rawValue
        config.skipBackwardUnit = SkipUnit.sentence.rawValue
        config.importDeleteBehavior = .askEachTime
        config.dataDirectoryPath = "/Volumes/Archive/TextMouth Library"
        config.confirmBeforeDelete = false
        config.shiftSkipForwardUnit = SkipUnit.seconds60.rawValue
        config.shiftSkipBackwardUnit = SkipUnit.paragraph.rawValue
        config.rewindOnResumeUnit = RewindUnit.paragraph.rawValue
        config.rewindSmartMode = true
        config.rewindSmartThreshold = 125
        config.sleepFadeOutDuration = 6
        config.sleepTimerAutoClose = false
        config.endOfBookBehavior = EndOfBookBehavior.continueNext.rawValue
        config.punctuationPauseLevel = 2
        config.lastOpenedBookID = "8E4C2D71-5B0A-4F6B-9C3E-2A7D1F9B6E05"
        config.autoPlayOnNavigate = true
        config.moveToTrashInsteadOfDeleting = false
        config.bluetoothMonitoringEnabled = false
        config.bluetoothDisconnectDelay = 7
        config.restartTimerGestureEnabled = true
        config.restartTimerGesturePattern = "togglePlayPause,nextTrack"
        config.restartTimerGestureWindow = 3.5
        return config
    }
}
