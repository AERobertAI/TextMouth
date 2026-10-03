import XCTest
@testable import TextMouth

// Fixtures shared by the config.json test classes (`ConfigSyncTests` and
// `ConfigWatcherTests`), so each exists once.

extension ConfigService.AppConfig {
    /// A config in which every field holds a supported, non-default value,
    /// so a field reset to its default is always detectable.
    static var everyFieldCustomized: Self {
        var config = Self()
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
        config.playbackNavigationUnitControlMode = PlaybackNavigationUnitControlMode.separate.rawValue
        config.showBookmarkInPlaybackControls = true
        config.showSpeedInPlaybackControls = false
        config.soundEffectsEnabled = false
        config.soundEffectsVolume = 0.35
        // Every event, as TextMouth writes them, each with another sound.
        config.soundEffectAssignments = ([
            .play: "Glass", .pause: "None", .skipForward: "Funk",
            .skipBackward: "Bottle", .whereAmIStart: "Hero", .whereAmIEnd: "Purr",
        ] as [SoundEvent: String]).keyedByRawValue
        config.substitutionsEnabled = false
        // Every action, as TextMouth writes them, three of them changed.
        var shortcuts = ShortcutAction.defaultBindings
        shortcuts[.togglePlayback] = [KeyBinding(key: "space"), KeyBinding(key: "p", control: true)]
        shortcuts[.whereAmI] = [KeyBinding(key: "w", option: true)]
        shortcuts[.releaseMediaControls] = [KeyBinding(key: "escape", shift: true)]
        config.keyboardShortcuts = SettingsPolicy.keyboardShortcuts.fileEntries(shortcuts)
        return config
    }
}

extension XCTestCase {
    /// A throwaway preferences store, kept in the sandbox and emptied when
    /// the test ends, so tests never read or change the user's real
    /// settings (see `makeSandboxedPreferences`).
    func isolatedDefaults() throws -> UserDefaults {
        makeSandboxedPreferences("config")
    }

    /// A config.json location in a directory of this test's own inside the
    /// isolated test root. The directory is removed when the test ends.
    func makeConfigFileURL() throws -> URL {
        let directory = TextMouthPaths.root
            .appendingPathComponent("ConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("config.json")
    }

    /// The debug log's lines that contain `text`, waiting first for every
    /// queued log write. The rotated generation is read too, in case one of
    /// the lines started a new file.
    func debugLogLines(containing text: String) -> [String] {
        TextMouthPaths.flushLogs()
        let logFile = TextMouthPaths.debugLogFile
        return [logFile.appendingPathExtension(TextMouthPaths.rotatedLogExtension), logFile]
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains(text) }
    }
}
