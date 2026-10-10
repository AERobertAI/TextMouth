import XCTest
@testable import TextMouth

/// The shortcuts in config.json with the record of the user's edits (FR12):
/// the forms read from a file, names in any letter case, an entry naming
/// where its action works (FR12's branch E), a key two edited actions hold
/// after an edit, the file as the design shows it, and the move to the
/// record at launch, on files and stores shaped like this user's. Every file
/// and store is the test's own; nothing reads the user's own config.json or
/// preferences.
@MainActor
final class ShortcutConfigFileTests: XCTestCase {

    // MARK: - Keys Used Below

    private let shiftR = KeyBinding(key: "r", shift: true)
    private let shiftCommandB = KeyBinding(key: "b", command: true, shift: true)
    private let optionShiftCommandB = KeyBinding(key: "b", command: true, option: true, shift: true)
    private let shiftCommandT = KeyBinding(key: "t", command: true, shift: true)

    // MARK: - Reading a File

    /// A file names actions in any letter case, without a repair logged for
    /// it; a list makes an action the user's, "default" gives an edited one
    /// back, and other text is one shortcut.
    func testAFileNamesActionsInAnyCaseInEitherForm() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let store = try isolatedDefaults()
        KeyboardShortcutManager.editsPreference.write(ShortcutEdits([.goBack: [KeyBinding(key: "[", control: true)]]), to: store)
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)
        let viewModel = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: store)
        let lowerCaseName = "where am i?"

        let config = try ConfigService.decode(Data("""
        {
          "keyboardShortcuts": {
            "\(lowerCaseName)": ["option+w"],
            "GO BACK": "default: command+[",
            "Go to Library": "Cmd+J",
            "Play / Pause": "default: space, k"
          }
        }
        """.utf8))
        viewModel.applyConfigChanges(config)

        XCTAssertEqual(manager.edits, ShortcutEdits([
            .whereAmI: [KeyBinding(key: "w", option: true)],
            .goToLibrary: [KeyBinding(key: "j", command: true)],
        ]))
        XCTAssertEqual(manager.bindingsFor(.goBack), ShortcutAction.defaultBindings[.goBack])
        XCTAssertTrue(debugLogLines(containing: "keyboardShortcuts.\(lowerCaseName): names nothing").isEmpty)
    }

    /// An entry written as an object makes its action the user's working
    /// where it says (FR12's branch E), its field names, its action's name,
    /// and its kind of window in any letter case, and the settings model
    /// writes it back in the Works in pop-up's words; the action that lost
    /// its key there says "none" after "default".
    func testAnObjectNamesWhereItsActionWorks() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let store = try isolatedDefaults()
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)
        let viewModel = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: store)

        let config = try ConfigService.decode(Data("""
        {
          "keyboardShortcuts": {
            "new from text...": {"Keys": ["Shift+Command+T"], "worksIn": "every window"},
            "Where Am I?": {"keys": "w", "Works In": "LIBRARY"}
          }
        }
        """.utf8))
        viewModel.applyConfigChanges(config)

        XCTAssertEqual(manager.scope(of: .newFromText), .app)
        XCTAssertEqual(manager.bindingsFor(.newFromText), [shiftCommandT])
        XCTAssertEqual(manager.bindingsFor(.showSleepTimer), [], "New from Text has Shift-Command-T in reader windows too")
        XCTAssertEqual(manager.scope(of: .whereAmI), .library)
        var written = ConfigService.AppConfig()
        viewModel.writePreferences(into: &written)
        XCTAssertEqual(written.keyboardShortcuts["New from Text…"], .object(keys: ["shift+command+t"], worksIn: "Every window"))
        XCTAssertEqual(written.keyboardShortcuts["Where Am I?"], .object(keys: ["w"], worksIn: "Library windows"))
        XCTAssertEqual(written.keyboardShortcuts["Show Sleep Timer"], "default in reader windows: none")
        XCTAssertEqual(written.keyboardShortcuts["Add Feed…"], "default in Library windows: shift+command+f")
    }

    /// An entry naming a kind of window its action cannot work in is left
    /// out and logged, the action keeping what it has, and the file is to be
    /// saved again; one naming a kind TextMouth does not know cannot be read
    /// at all, and leaves its action as it is.
    func testAnObjectNamingWhereItsActionCannotWorkIsLeftOut() throws {
        let store = try isolatedDefaults()
        let record = ShortcutEdits([.releaseMediaControls: [shiftR]])
        KeyboardShortcutManager.editsPreference.write(record, to: store)

        let saveAgain = KeyboardShortcutManager.adopt(
            [.addFeed: .object(keys: ["shift+command+a"], worksIn: "Reader windows")],
            in: store
        )

        XCTAssertTrue(saveAgain)
        XCTAssertEqual(KeyboardShortcutManager.editsPreference.read(from: store), record)
        XCTAssertFalse(debugLogLines(
            containing: "config.json keyboardShortcuts.Add Feed…: works in reader windows, which it cannot; keeping its shortcuts"
        ).isEmpty)
        let unknown = try ConfigService.decode(Data(#"{"keyboardShortcuts": {"Add Feed…": {"keys": ["shift+command+a"], "worksIn": "kitchen"}}}"#.utf8))
        XCTAssertNil(unknown.keyboardShortcuts["Add Feed…"])
    }

    /// The file lists this user's shortcuts as the design's excerpt shows:
    /// Release Media Controls as a list, every other action "default: " and
    /// its keys, the full summaries' double presses among them, in the
    /// file's alphabetical order.
    func testTheFileListsThisUsersShortcutsAsTheDesignShows() throws {
        var config = ConfigService.AppConfig()
        config.keyboardShortcuts = SettingsPolicy.keyboardShortcuts.fileEntries(
            ShortcutEdits([.releaseMediaControls: [shiftR]]).listings(defaults: ShortcutAction.defaultBindings)
        )

        let text = String(decoding: try ConfigService.fileData(for: config), as: UTF8.self)

        let excerpt = [
            #"  "keyboardShortcuts" : {"#,
            #"    "Add Bookmark" : "default: command+b","#,
            #"    "Add to Reading List" : "default: none","#,
            #"    "Next Bookmark" : "default: option+shift+command+b","#,
            #"    "Play \/ Pause" : "default: space, k","#,
            #"    "Release Media Controls" : ["#,
            #"      "shift+r""#,
            #"    ],"#,
            #"    "Show Bookmarks" : "default: shift+command+b","#,
            #"    "Speak Full Info" : "default: i twice","#,
            #"    "Speak Info" : "default: i","#,
            #"    "Where Am I?" : "default: w","#,
            #"    "Where Am I? Full Summary" : "default: w twice""#,
            #"  },"#,
        ]
        // Each line whole, after the one before it: the next search starts at
        // the newline ending the line found, which begins the next line.
        var searchFrom = text.startIndex
        for line in excerpt {
            guard let found = text.range(of: "\n" + line + "\n", range: searchFrom..<text.endIndex) else {
                XCTFail("\(line) is not in the file after the lines before it:\n\(text)")
                return
            }
            searchFrom = text.index(before: found.upperBound)
        }
    }

    // MARK: - A Key Two Edited Actions Hold

    /// An edit of config.json giving one action a key another edited action
    /// keeps listing leaves it to the action whose entry changed, logs it
    /// naming the key and both actions, and saves the file again at once, so
    /// it shows the keys in force.
    func testAnEditGivingAnEditedActionsKeyAwaySavesTheKeysInForce() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let url = try makeConfigFileURL()
        let store = try isolatedDefaults()
        var file = launchConsistentConfig(edits: ShortcutEdits([.releaseMediaControls: [shiftR]]))
        try ConfigService.fileData(for: file).write(to: url)
        let (service, settings) = launch(url, store: store)

        file.keyboardShortcuts["Where Am I?"] = ["w", "shift+r"]
        try ConfigService.fileData(for: file).write(to: url, options: .atomic)
        service.handleFileEvent(.write)
        waitPastConfigSaveDelay()

        XCTAssertEqual(
            KeyboardShortcutManager.editsPreference.read(from: store),
            ShortcutEdits([.releaseMediaControls: [], .whereAmI: [KeyBinding(key: "w"), shiftR]])
        )
        let saved = try ConfigService.decode(Data(contentsOf: url))
        XCTAssertEqual(saved.keyboardShortcuts["Release Media Controls"], [])
        XCTAssertEqual(saved.keyboardShortcuts["Where Am I?"], ["w", "shift+r"])
        XCTAssertFalse(debugLogLines(
            containing: #"config.json keyboardShortcuts.Release Media Controls: shared "shift+r" with "Where Am I?", which keeps it"#
        ).isEmpty)
        withExtendedLifetime(settings) {}
    }

    // MARK: - The Move at Launch

    /// The October 5 build's actions: every action but the six added since.
    private var actionsOfTheOctober5Build: [ShortcutAction] {
        ShortcutMigrationTests.actionsOfTheOctober5Build
    }

    /// Every action of the October 5 build at today's default, but Release
    /// Media Controls on Shift-R and Next Bookmark on Shift-Command-B: the
    /// shape of this user's saved map and config.json.
    private func shortcutsShapedLikeThisUsers() -> [ShortcutAction: [KeyBinding]] {
        var map: [ShortcutAction: [KeyBinding]] = [:]
        for action in actionsOfTheOctober5Build {
            map[action] = ShortcutAction.defaultBindings[action] ?? []
        }
        map[.releaseMediaControls] = [shiftR]
        map[.nextBookmark] = [shiftCommandB]
        return map
    }

    /// config.json in the old form, as the October 5 build wrote it: every
    /// action of `map` a list of its keys, with every other setting one a
    /// launch keeps as it is.
    private func oldFormFile(listing map: [ShortcutAction: [KeyBinding]]) throws -> Data {
        var config = launchConsistentConfig(edits: ShortcutEdits())
        config.keyboardShortcuts = map.mapValues(ShortcutListing.edited).keyedByRawValue
        return try ConfigService.fileData(for: config)
    }

    /// The whole map saved in `store` as every release before the record
    /// saved it, and its bytes.
    @discardableResult
    private func saveWholeMap(_ map: [ShortcutAction: [KeyBinding]], in store: UserDefaults) throws -> Data {
        let data = try JSONEncoder().encode(map.keyedByRawValue)
        store.set(data, forKey: KeyboardShortcutManager.savedMapKey)
        return data
    }

    /// This user's first launch of a build with the record: the saved map
    /// and config.json written together by the October 5 build move to a
    /// record holding Release Media Controls alone; Next Bookmark takes
    /// Option-Shift-Command-B, Show Bookmarks keeps Shift-Command-B, and the
    /// launch saves config.json in the new form. The saved map is left
    /// exactly as it was, and a second launch changes nothing.
    func testThisUsersFirstLaunchMovesTheirShortcutsToTheRecord() throws {
        let url = try makeConfigFileURL()
        let store = try isolatedDefaults()
        let map = shortcutsShapedLikeThisUsers()
        let savedMap = try saveWholeMap(map, in: store)
        try oldFormFile(listing: map).write(to: url)

        let first = launch(url, store: store)

        let record = KeyboardShortcutManager.editsPreference.read(from: store)
        XCTAssertEqual(record, ShortcutEdits([.releaseMediaControls: [shiftR]]))
        XCTAssertEqual(store.data(forKey: KeyboardShortcutManager.savedMapKey), savedMap, "the saved map is never written")
        let saved = try ConfigService.decode(Data(contentsOf: url))
        XCTAssertEqual(saved.keyboardShortcuts.count, ShortcutAction.allCases.count)
        XCTAssertEqual(saved.keyboardShortcuts["Release Media Controls"], ["shift+r"])
        XCTAssertEqual(saved.keyboardShortcuts["Next Bookmark"], "default: option+shift+command+b")
        XCTAssertEqual(saved.keyboardShortcuts["Show Bookmarks"], "default: shift+command+b")
        XCTAssertEqual(saved.keyboardShortcuts["Speak Info"], "default: i")
        XCTAssertEqual(saved.keyboardShortcuts["Speak Full Info"], "default: i twice")
        XCTAssertEqual(saved.keyboardShortcuts["Where Am I? Full Summary"], "default: w twice")
        XCTAssertEqual(saved.keyboardShortcuts["Add to Reading List"], "default: none")
        // The menu commands' keys, newer than the map (FR12's branch D).
        XCTAssertEqual(saved.keyboardShortcuts["Open Book…"], "default: command+o")
        XCTAssertEqual(saved.keyboardShortcuts["New from Text…"], "default in Library windows: shift+command+t", "each in its own kind of window")
        XCTAssertEqual(saved.keyboardShortcuts["Show Sleep Timer"], "default in reader windows: shift+command+t")
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)
        XCTAssertEqual(manager.bindingsFor(.nextBookmark), [optionShiftCommandB])
        XCTAssertEqual(manager.bindingsFor(.showBookmarkList), [shiftCommandB])
        XCTAssertEqual(manager.bindingsFor(.releaseMediaControls), [shiftR])
        XCTAssertFalse(debugLogLines(
            containing: "SHORTCUT_EDITS_MOVED: made the record of edited shortcuts from customKeyboardBindings (72 actions) "
                + "and config.json (72 actions); edited: Release Media Controls"
        ).isEmpty)

        let bytes = try Data(contentsOf: url)
        let second = launch(url, store: store)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(KeyboardShortcutManager.editsPreference.read(from: store), record)
        withExtendedLifetime((first, second)) {}
    }

    /// An edit made in config.json while TextMouth was closed, unlike the
    /// saved map, wins at the move.
    func testAnEditMadeInTheFileWhileClosedWinsAtTheMove() throws {
        let url = try makeConfigFileURL()
        let store = try isolatedDefaults()
        let map = shortcutsShapedLikeThisUsers()
        try saveWholeMap(map, in: store)
        var edited = map
        edited[.releaseMediaControls] = [KeyBinding(key: "r", control: true)]
        try oldFormFile(listing: edited).write(to: url)

        let launched = launch(url, store: store)

        XCTAssertEqual(
            KeyboardShortcutManager.editsPreference.read(from: store),
            ShortcutEdits([.releaseMediaControls: [KeyBinding(key: "r", control: true)]])
        )
        withExtendedLifetime(launched) {}
    }

    /// Without a config.json, or with one that cannot be read, the saved map
    /// moves alone; a file that cannot be read stays as it is, to be
    /// corrected, and a missing one is written in the new form.
    func testTheSavedMapMovesAloneWithoutAReadableFile() throws {
        let map = shortcutsShapedLikeThisUsers()
        for unreadable in [false, true] {
            let url = try makeConfigFileURL()
            let store = try isolatedDefaults()
            try saveWholeMap(map, in: store)
            let broken = Data("{ \"keyboardShortcuts\": ".utf8)
            if unreadable {
                try broken.write(to: url)
            }

            let launched = launch(url, store: store)

            XCTAssertEqual(KeyboardShortcutManager.editsPreference.read(from: store), ShortcutEdits([.releaseMediaControls: [shiftR]]))
            if unreadable {
                XCTAssertEqual(try Data(contentsOf: url), broken)
            } else {
                XCTAssertEqual(try ConfigService.decode(Data(contentsOf: url)).keyboardShortcuts["Next Bookmark"], "default: option+shift+command+b")
            }
            withExtendedLifetime(launched) {}
        }
    }

    /// A config.json in the new form already, found with no record in the
    /// store, is read as any edit is, and nothing is moved: the saved map is
    /// left out, and the record is written from the file.
    func testAFileInTheNewFormIsReadAndNothingIsMoved() throws {
        let url = try makeConfigFileURL()
        let store = try isolatedDefaults()
        try saveWholeMap(shortcutsShapedLikeThisUsers(), in: store)
        try ConfigService.fileData(for: launchConsistentConfig(edits: ShortcutEdits([.whereAmI: [KeyBinding(key: "w", option: true)]])))
            .write(to: url)

        let launched = launch(url, store: store)

        XCTAssertEqual(KeyboardShortcutManager.editsPreference.read(from: store), ShortcutEdits([.whereAmI: [KeyBinding(key: "w", option: true)]]))
        withExtendedLifetime(launched) {}
    }

    /// This user's config.json in the new form, written by a build without
    /// the full summaries (FR12's branch C), gains them at the next launch
    /// as "default: i twice" and "default: w twice", which they then have;
    /// Release Media Controls keeps Shift-R as the user's own, and the
    /// record is left as it was.
    func testAFileWrittenBeforeTheFullSummariesGainsThemAsDefaults() throws {
        let url = try makeConfigFileURL()
        let store = try isolatedDefaults()
        let record = ShortcutEdits([.releaseMediaControls: [shiftR]])
        KeyboardShortcutManager.editsPreference.write(record, to: store)
        var file = launchConsistentConfig(edits: record)
        file.keyboardShortcuts["Speak Full Info"] = nil
        file.keyboardShortcuts["Where Am I? Full Summary"] = nil
        try ConfigService.fileData(for: file).write(to: url)

        let launched = launch(url, store: store)

        let saved = try ConfigService.decode(Data(contentsOf: url))
        XCTAssertEqual(saved.keyboardShortcuts["Speak Full Info"], "default: i twice")
        XCTAssertEqual(saved.keyboardShortcuts["Where Am I? Full Summary"], "default: w twice")
        XCTAssertEqual(saved.keyboardShortcuts["Release Media Controls"], ["shift+r"])
        XCTAssertEqual(saved.keyboardShortcuts.count, ShortcutAction.allCases.count)
        XCTAssertEqual(KeyboardShortcutManager.editsPreference.read(from: store), record)
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)
        XCTAssertEqual(manager.bindingsFor(.speakFullInfo), [KeyBinding(key: "i", isDoublePress: true)])
        XCTAssertEqual(manager.bindingsFor(.whereAmIFull), [KeyBinding(key: "w", isDoublePress: true)])
        XCTAssertEqual(manager.bindingsFor(.releaseMediaControls), [shiftR])
        withExtendedLifetime(launched) {}
    }

    /// This user's record and config.json with the menu commands' keys
    /// (FR12's branch D, item 5): a file written before them gains each as
    /// "default" and its key, New from Text Shift-Command-T in Library
    /// windows, which Show Sleep Timer has in reader windows (FR12's branch
    /// E); Release Media Controls keeps Shift-R as the user's own, every
    /// other action follows the defaults, and the record is left as it was.
    /// A second launch changes nothing.
    func testAFileWrittenBeforeTheMenuKeysGainsThemAsDefaults() throws {
        let url = try makeConfigFileURL()
        let store = try isolatedDefaults()
        let record = ShortcutEdits([.releaseMediaControls: [shiftR]])
        KeyboardShortcutManager.editsPreference.write(record, to: store)
        var file = launchConsistentConfig(edits: record)
        for action in ShortcutAction.keyEquivalentActions {
            file.keyboardShortcuts[action.rawValue] = nil
        }
        try ConfigService.fileData(for: file).write(to: url)

        let first = launch(url, store: store)

        let saved = try ConfigService.decode(Data(contentsOf: url))
        let menuKeys: [String: ShortcutListing] = [
            "Open Book…": "default: command+o",
            "New from Text…": "default in Library windows: shift+command+t",
            "New Recording…": "default: option+command+n",
            "Import DAISY Folder…": "default in Library windows: shift+command+o",
            "Add Feed…": "default in Library windows: shift+command+f",
            "Copy Reading Position": "default in reader windows: shift+command+p",
            "Search in Book": "default in reader windows: command+f",
            "Recording Window: Record": "default: command+r",
            "Recording Window: Pause or Resume": "default: command+p",
            "Recording Window: Stop": "default: command+.",
        ]
        for (name, entry) in menuKeys {
            XCTAssertEqual(saved.keyboardShortcuts[name], entry, name)
        }
        XCTAssertEqual(saved.keyboardShortcuts["Release Media Controls"], ["shift+r"])
        XCTAssertEqual(saved.keyboardShortcuts["Show Sleep Timer"], "default in reader windows: shift+command+t")
        XCTAssertEqual(saved.keyboardShortcuts.count, ShortcutAction.allCases.count)
        let lists = saved.keyboardShortcuts.filter { !$0.value.followsDefaults }
        XCTAssertEqual(Array(lists.keys), ["Release Media Controls"], "nothing else is the user's")
        XCTAssertEqual(KeyboardShortcutManager.editsPreference.read(from: store), record)

        let bytes = try Data(contentsOf: url)
        let second = launch(url, store: store)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(KeyboardShortcutManager.editsPreference.read(from: store), record)
        withExtendedLifetime((first, second)) {}
    }

    /// This user's config.json as a build before the kinds of windows wrote
    /// it (FR12's branch E): every default without one, New from Text's and
    /// Show Sleep Timer's both "default: shift+command+t". It reads as it
    /// always did, the record left as it was, each action with its key in
    /// its own kind of window, and the launch writes each default's kind of
    /// window after "default"; a second launch changes nothing.
    func testAFileWrittenBeforeTheKindsOfWindowsReadsAsItAlwaysDid() throws {
        let url = try makeConfigFileURL()
        let store = try isolatedDefaults()
        let record = ShortcutEdits([.releaseMediaControls: [shiftR]])
        KeyboardShortcutManager.editsPreference.write(record, to: store)
        var file = launchConsistentConfig(edits: record)
        let writtenBefore: [String: ShortcutListing] = [
            "New from Text…": "default: shift+command+t",
            "Show Sleep Timer": "default: shift+command+t",
            "Import DAISY Folder…": "default: shift+command+o",
            "Add Feed…": "default: shift+command+f",
            "Copy Reading Position": "default: shift+command+p",
            "Search in Book": "default: command+f",
        ]
        file.keyboardShortcuts.merge(writtenBefore) { _, before in before }
        try ConfigService.fileData(for: file).write(to: url)

        let first = launch(url, store: store)

        XCTAssertEqual(KeyboardShortcutManager.editsPreference.read(from: store), record)
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)
        XCTAssertEqual(manager.scope(of: .newFromText), .library)
        XCTAssertEqual(manager.bindingsFor(.newFromText), [shiftCommandT])
        XCTAssertEqual(manager.bindingsFor(.showSleepTimer), [shiftCommandT])
        let saved = try ConfigService.decode(Data(contentsOf: url))
        XCTAssertEqual(saved.keyboardShortcuts["New from Text…"], "default in Library windows: shift+command+t")
        XCTAssertEqual(saved.keyboardShortcuts["Show Sleep Timer"], "default in reader windows: shift+command+t")
        XCTAssertEqual(saved.keyboardShortcuts["Release Media Controls"], ["shift+r"])

        let bytes = try Data(contentsOf: url)
        let second = launch(url, store: store)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(KeyboardShortcutManager.editsPreference.read(from: store), record)
        withExtendedLifetime((first, second)) {}
    }

    // MARK: - The Whole Map's Key

    /// customKeyboardBindings is retired: listed as such, neither mirrored
    /// nor kept as a machine-local key, and written by nothing, whether the
    /// shortcuts change in Settings, are reset, or come from config.json.
    func testTheWholeMapsKeyIsReadOnceAndNeverWritten() throws {
        let portability = ConfigService.AppConfig.Portability.self
        XCTAssertEqual(portability.retiredStoreKeys, ["customKeyboardBindings", "feedKeepEntries", "feedAutoDownload"])
        XCTAssertFalse(portability.mirrored.map(\.storeKey).contains("customKeyboardBindings"))
        XCTAssertFalse(portability.localStoreKeys.contains("customKeyboardBindings"))
        XCTAssertFalse(SettingsViewModel.servicePreferenceKeys.contains("customKeyboardBindings"))

        let store = try isolatedDefaults()
        let savedMap = try saveWholeMap(shortcutsShapedLikeThisUsers(), in: store)
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)
        let viewModel = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: store)
        manager.addBinding(KeyBinding(key: "j", control: true), to: .whereAmI)
        manager.resetToDefault(.whereAmI)
        manager.resetToDefaults()
        var config = ConfigService.AppConfig()
        config.keyboardShortcuts = ["Release Media Controls": ["shift+r"]]
        viewModel.applyConfigChanges(config)
        viewModel.writePreferences(into: &config)

        XCTAssertEqual(store.data(forKey: KeyboardShortcutManager.savedMapKey), savedMap)
    }

    // MARK: - Helpers

    /// `everyFieldCustomized` with the data directory in use and `edits`'
    /// shortcuts, so a launch on it changes nothing but the shortcuts it is
    /// given.
    private func launchConsistentConfig(edits: ShortcutEdits) -> ConfigService.AppConfig {
        var config = ConfigService.AppConfig.everyFieldCustomized
        config.dataDirectoryPath = ConfigService.AppConfig.currentDataDirectoryPath
        config.keyboardShortcuts = SettingsPolicy.keyboardShortcuts.fileEntries(edits.listings(defaults: ShortcutAction.defaultBindings))
        return config
    }

    /// Launches the way the app does on `store` and the config.json at
    /// `url`: a service that loads the file, then a settings model that
    /// reconciles the two, moving the shortcuts to the record when the store
    /// holds none, and starts the watcher, which stops when the test ends.
    private func launch(_ url: URL, store: UserDefaults) -> (service: ConfigService, settings: SettingsViewModel) {
        let service = ConfigService(fileURL: url)
        addTeardownBlock { service.shutdown() }
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: true,
            userDefaults: store,
            configService: service
        )
        return (service, settings)
    }
}
