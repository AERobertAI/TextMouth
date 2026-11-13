import XCTest
@testable import TextMouth

// Fixtures shared by the config.json test classes (`ConfigSyncTests` and
// `ConfigWatcherTests`), and the settings model of a test's own that the
// settings tests share (`makeIsolatedSettings`), so each exists once.

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
        config.nextBookWindow = NextBookWindow.newWindow.rawValue
        config.punctuationPauseLevel = 2
        config.lastOpenedBookID = "8E4C2D71-5B0A-4F6B-9C3E-2A7D1F9B6E05"
        config.autoPlayOnNavigate = true
        config.moveToTrashInsteadOfDeleting = false
        config.keepsOriginalOfConvertedAudio = true
        config.bluetoothMonitoringEnabled = false
        config.bluetoothDisconnectDelay = 7
        config.restartTimerGestureEnabled = true
        config.restartTimerGesturePattern = "togglePlayPause,nextTrack"
        config.restartTimerGestureWindow = 3.5
        config.playbackNavigationUnitControlMode = PlaybackNavigationUnitControlMode.separate.rawValue
        config.showBookmarkInPlaybackControls = true
        config.showSpeedInPlaybackControls = false
        config.showExportInReaderToolbar = true
        config.includeSpeedWithTimes = true
        config.showsPageInReader = false
        config.saysPageInWhereAmI = false
        config.soundEffectsEnabled = false
        config.soundEffectsVolume = 0.35
        // Every event, as TextMouth writes them, each with another sound.
        config.soundEffectAssignments = ([
            .play: "Glass", .pause: "None", .skipForward: "Funk",
            .skipBackward: "Bottle", .whereAmIStart: "Hero", .whereAmIEnd: "Purr",
        ] as [SoundEvent: String]).keyedByRawValue
        // Feeds (FR03), each unlike its default.
        config.feedRefreshAtLaunch = false
        config.feedRefreshIntervalHours = 6
        config.feedItems = FeedItemPolicy.Choice.onlyNewestListed.rawValue
        config.feedNewestCount = 12
        config.feedDeleteDownloadsDaysAfterPlayed = 0
        config.feedRefreshAlert = true
        config.feedNotifications = true
        config.substitutionsEnabled = false
        config.repeatedSymbolStyle = RepeatedSymbolStyle.leaveOut.rawValue
        config.repeatedSymbolThreshold = 7
        config.repeatedSymbolSet = "*=~"
        config.recordingInputDeviceID = "AppleUSBAudioEngine:Studio Microphone:4100000:1"
        config.recordingAnnouncesLevel = true
        config.recordingLevelAnnouncementSeconds = 25
        config.recordingOriginalPolicy = AudioOriginalPolicy.Choice.keep.rawValue
        config.recordingOriginalDays = 14
        config.useInstalledFFmpeg = false
        config.audioEditorPreviewsFilters = false
        config.audioEditorPlaysAfterMoves = false
        // Every action, as TextMouth writes them (FR12): three edited, two
        // written as lists of their keys and Where Am I?, which works in
        // Library windows, as an object with its "worksIn"; every other as
        // "default: " and its keys.
        let shortcuts = ShortcutEdits([
            .togglePlayback: [KeyBinding(key: "space"), KeyBinding(key: "p", control: true)],
            .whereAmI: [KeyBinding(key: "w", option: true)],
            .releaseMediaControls: [KeyBinding(key: "escape", shift: true)],
        ], scopes: [.whereAmI: .library])
        config.keyboardShortcuts = SettingsPolicy.keyboardShortcuts.fileEntries(
            shortcuts.listings(defaults: ShortcutAction.defaultBindings)
        )
        config.shortcutDoublePressSeconds = 1.2
        config.logLocation = LogLocation.machine.rawValue
        config.transcriptionLocale = TranscriptFixtures.languageOtherThanTheDefault
        config.offerTranscriptionAfterImport = true
        config.libraryViews = customizedLibraryViews
        // Leading articles passed over when typing, unlike the default.
        config.leadingArticles = LeadingArticles.ignoredWhenTyping.rawValue
        config.brailleTable = "en-us-g1.ctb"
        // The braille file characters (braillecodes), unlike the default,
        // North American Braille ASCII.
        config.brailleFileCode = "ascii-eurobraille"
        return config
    }

    /// The Library window's views (October 30, 2026) unlike the shipped
    /// ones: Feeds hidden, and a view of the listener's own after the rest,
    /// its identity fixed, so every use of the fixture holds the same list.
    static var customizedLibraryViews: [JSONValue] {
        var list = LibraryViewDefinitionList.shipped
        list.setVisibility(.hidden, of: .feeds)
        let id = UUID(uuid: (0x6F, 0x96, 0x19, 0xFF, 0x8B, 0x86, 0xD0, 0x11, 0xB4, 0x2D, 0x00, 0xC0, 0x4F, 0xC9, 0x64, 0xFF))
        list.add(
            LibraryViewDefinition(
                id: .custom(id),
                name: "Unread EPUBs",
                visibility: .always,
                filter: LibraryViewFilter(
                    lists: [.books],
                    conditions: [
                        LibraryViewCondition(test: .format(.epub)),
                        LibraryViewCondition(test: .readingState(.unopened)),
                    ]
                )
            ),
            after: nil
        )
        return list.fileEntries
    }
}

extension XCTestCase {
    /// A throwaway preferences store, kept in the sandbox and emptied when
    /// the test ends, so tests never read or change the user's real
    /// settings (see `makeSandboxedPreferences`).
    func isolatedDefaults() throws -> UserDefaults {
        makeSandboxedPreferences("config")
    }

    /// A settings model of the test's own, so changing the global settings
    /// touches neither this process's preferences nor its config.json: its
    /// preferences are a sandboxed store, discarded when the test ends, and
    /// its config.json is `configFile`, or a file in a folder of the test's
    /// own, written with `configWrite` (an atomic write unless the test
    /// counts or refuses writes) and never watched for changes. It posts to
    /// a notification center of its own and starts no services. `label`
    /// names the store and the folder for anyone reading the sandbox.
    /// (REV13: the playback settings, A10, Settings-fit, and save-cost tests
    /// each built this model themselves.)
    @MainActor
    func makeIsolatedSettings(
        _ label: String = "isolated-settings",
        configFile: URL? = nil,
        configWrite: @escaping @MainActor (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) throws -> SettingsViewModel {
        let file = try configFile ?? makeTestDirectory(label).appendingPathComponent("config.json")
        let configService = ConfigService(fileURL: file, fileOperations: ConfigService.FileOperations(
            write: configWrite,
            openForEvents: { _ in -1 },
            close: { _ in }
        ))
        return SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: makeSandboxedPreferences(label),
            configService: configService
        )
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
    /// queued log write. Lines go to the data directory's Logs folder, or to
    /// this Mac's while the data directory can't take them, so both debug
    /// logs are read, each line being in one of them only. The rotated
    /// generations are read too, in case one of the lines started a new file.
    func debugLogLines(containing text: String) -> [String] {
        TextMouthPaths.flushLogs()
        let folders = [
            TextMouthPaths.root.appendingPathComponent(TextMouthPaths.logsFolderName, isDirectory: true),
            MachineLocalPaths.logs,
        ]
        return folders
            .flatMap { folder -> [URL] in
                let logFile = folder.appendingPathComponent(DiagnosticLog.File.debug.rawValue, isDirectory: false)
                return [logFile.appendingPathExtension(TextMouthPaths.rotatedLogExtension), logFile]
            }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains(text) }
    }

    /// The debug log's lines that name the file at `url`, which lies inside
    /// the data directory, as the log policy names it: by its path inside
    /// the data directory (`DiagnosticLog.loggablePath`). A line naming it
    /// by its absolute path instead fails the test where this is called.
    func debugLogLines(naming url: URL, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        XCTAssertEqual(
            debugLogLines(containing: url.path),
            [],
            "the debug log named \(url.lastPathComponent) by its absolute path",
            file: file,
            line: line
        )
        return debugLogLines(containing: DiagnosticLog.loggablePath(url))
    }

    /// The debug log's lines written while `body` runs, in the order they were
    /// written: the bytes the log gained meanwhile, after every queued write.
    /// It reads bytes rather than comparing lines, because a line's time is
    /// to the second only. Two exports that end alike within one second write
    /// the same line twice, and a comparison of lines would take the second
    /// for the first. A log rotated meanwhile starts a new file that holds only
    /// the new lines.
    ///
    /// For work that awaits, as `DOCXMalformedXMLTests` and
    /// `ReadingStatsDayAttributionTests` read the log for work that doesn't.
    /// The log's folder must not change while `body` runs: call
    /// `TextMouthPaths.ensureDirectoryStructure()` first.
    func debugLogLines(writtenWhile body: () async throws -> Void) async rethrows -> [String] {
        let log = TextMouthPaths.debugLogFile
        TextMouthPaths.flushLogs()
        let before = (try? Data(contentsOf: log)) ?? Data()
        try await body()
        TextMouthPaths.flushLogs()
        let after = (try? Data(contentsOf: log)) ?? Data()
        let written = after.starts(with: before) ? after.dropFirst(before.count) : after
        return String(decoding: written, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty }
    }
}

/// Writes, as each test ends, a config.json save the test left waiting
/// (PERF17). A settings change, or a reader opening, asks
/// `ConfigService.shared` for a save that waits a moment for more changes;
/// left waiting, it would happen during the next test, writing the test
/// root's config.json and settling that test's settings failures as it
/// runs. Written as the test that asked for it ends, it can touch no other
/// test. The test bundle's principal class registers it.
///
/// `@unchecked Sendable`: XCTest reports to observers on the main thread,
/// where `sawBundleStart` alone is set.
final class ConfigSaveFlush: NSObject, XCTestObservation, @unchecked Sendable {
    /// The observer the principal class registers.
    static let shared = ConfigSaveFlush()

    /// Whether XCTest reported the start of the bundle to this observer,
    /// which proves the principal class registered it.
    private(set) var sawBundleStart = false

    func testBundleWillStart(_ testBundle: Bundle) {
        sawBundleStart = true
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        // XCTest reports test cases on the main thread, where the service lives.
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            ConfigService.shared.flushScheduledSave()
        }
    }
}
