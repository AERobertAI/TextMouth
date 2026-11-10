import XCTest
@testable import TextMouth

/// The hosted suite runs inside the real application, so everything that
/// could reach the user's library, legacy data, or preferences follows one
/// switch, `TextMouthRuntime.isHostedTest` (TODO Q01). These tests check the
/// switch both ways and each location and store that follows it.
@MainActor
final class HostedTestIsolationTests: XCTestCase {

    // MARK: - The Isolation Switch

    /// The time scale of timing tests can only widen a limit: a number of 1 or more is taken, anything else is 1, so a
    /// stray value never tightens a limit, and a Mac with nothing set keeps every limit as written.
    func testTheTimeScaleOnlyWidensALimit() {
        XCTAssertEqual(TestMachine.scale(from: "2.5"), 2.5)
        XCTAssertEqual(TestMachine.scale(from: "1"), 1)
        for odd in [nil, "", "0.5", "0", "-3", "many", "nan", "inf"] as [String?] {
            XCTAssertEqual(TestMachine.scale(from: odd), 1, "\(String(describing: odd)) should mean no scale")
        }
        XCTAssertEqual(TestMachine.allowed(2), 2 * TestMachine.timeScale)
        XCTAssertGreaterThanOrEqual(TestMachine.timeScale, 1)
    }

    /// This process hosts the tests, so its runtime is the isolated one: a
    /// home in the temporary directory named after the process, and
    /// preferences that are not the user's.
    func testThisProcessIsIsolated() throws {
        let runtime = TextMouthRuntime.current

        XCTAssertTrue(runtime.isHostedTest)
        XCTAssertEqual(
            runtime.homeDirectory.lastPathComponent,
            "TextMouthTests-\(ProcessInfo.processInfo.processIdentifier)"
        )
        XCTAssertEqual(
            runtime.homeDirectory.deletingLastPathComponent().standardizedFileURL.path,
            FileManager.default.temporaryDirectory.standardizedFileURL.path
        )
        XCTAssertFalse(runtime.preferences === UserDefaults.standard)
        let file = try XCTUnwrap(runtime.preferencesFile)
        XCTAssertTrue(file.path.hasPrefix(runtime.homeDirectory.path + "/"), file.path)
    }

    /// The variable XCTest sets makes a hosted-test runtime, whose sandbox
    /// and preferences store are named after the process.
    func testTestConfigurationVariableMakesAnIsolatedRuntime() throws {
        let temporary = try makeSandboxDirectory("detect-hosted")

        let runtime = TextMouthRuntime.detect(
            environment: [TextMouthRuntime.testConfigurationVariable: "/tmp/Run.xctestconfiguration"],
            processIdentifier: 4242,
            temporaryDirectory: temporary
        )

        XCTAssertTrue(runtime.isHostedTest)
        XCTAssertEqual(runtime.homeDirectory, temporary.appendingPathComponent("TextMouthTests-4242", isDirectory: true))
        XCTAssertFalse(runtime.preferences === UserDefaults.standard)
        XCTAssertEqual(
            runtime.preferencesFile?.path,
            runtime.homeDirectory.path + "/SandboxedPreferences/com.textmouth.TextMouth.hosted-test-4242.plist"
        )
    }

    /// Without that variable the runtime is the app's: the user's real home
    /// and the standard preferences. Deciding so reads and changes nothing.
    func testEnvironmentWithoutTestConfigurationMakesTheAppRuntime() {
        let runtime = TextMouthRuntime.detect(
            environment: [:],
            processIdentifier: 4242,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )

        XCTAssertFalse(runtime.isHostedTest)
        XCTAssertEqual(runtime.homeDirectory.standardizedFileURL.path, RealUserAccount.homeDirectory.standardizedFileURL.path)
        XCTAssertTrue(runtime.preferences === UserDefaults.standard)
        XCTAssertNil(runtime.preferencesFile)
    }

    // MARK: - Preferences

    /// The hosted store keeps its values in its own property list inside the
    /// sandbox; the user's preferences never see them, and nothing appears in
    /// the user's Preferences folder.
    func testHostedPreferencesStayInsideTheSandbox() throws {
        let runtime = TextMouthRuntime.current
        let key = "hostedIsolationProbe-\(UUID().uuidString)"
        preservePreferences([key])

        runtime.preferences.set("kept in the sandbox", forKey: key)

        // Another store opened on the same property list sees the value...
        let file = try XCTUnwrap(runtime.preferencesFile)
        let sameFile = try XCTUnwrap(UserDefaults(suiteName: file.deletingPathExtension().path))
        XCTAssertEqual(sameFile.string(forKey: key), "kept in the sandbox")
        // ...the user's preferences do not...
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        // ...and the preferences daemon writes the file inside the sandbox,
        // not under its name in the user's Preferences folder, where a store
        // in a folder named Library/Preferences would silently end up.
        XCTAssertTrue(waitUntil(timeout: 10) { FileManager.default.fileExists(atPath: file.path) }, file.path)
        let usersPreferences = RealUserAccount.homeDirectory
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent(file.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: usersPreferences.path), usersPreferences.path)
    }

    /// A store made for one test lives in the sandbox too, and discarding it
    /// removes its values.
    func testPerTestPreferencesStayInsideTheSandbox() throws {
        let store = SandboxedPreferences("isolation-probe")
        defer { store.discard() }
        let key = "isolationProbe-\(UUID().uuidString)"

        store.defaults.set(true, forKey: key)

        XCTAssertTrue(store.file.path.hasPrefix(HostedTestSandbox.home.path + "/"), store.file.path)
        XCTAssertTrue(waitUntil(timeout: 10) { FileManager.default.fileExists(atPath: store.file.path) }, store.file.path)
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        store.discard()
        XCTAssertNil(store.defaults.object(forKey: key))
    }

    // MARK: - The Data Root

    /// The hosted data root is the default location in the sandbox, never
    /// the user's ~/.TextMouth.
    func testHostedDataRootIsTheSandboxDefaultLocation() {
        let home = TextMouthRuntime.current.homeDirectory
        let usersLibrary = RealUserAccount.homeDirectory.appendingPathComponent(".TextMouth", isDirectory: true)

        XCTAssertEqual(TextMouthPaths.root, TextMouthPaths.defaultRoot)
        XCTAssertEqual(TextMouthPaths.defaultRoot, home.appendingPathComponent(".TextMouth", isDirectory: true))
        XCTAssertTrue(TextMouthPaths.root.path.contains("TextMouthTests-"))
        XCTAssertNotEqual(TextMouthPaths.root.standardizedFileURL.path, usersLibrary.standardizedFileURL.path)
        XCTAssertFalse(TextMouthPaths.isCustomPath)
    }

    /// The legacy locations lie outside the data root, so each needs the
    /// sandbox of its own: the test host's startup would otherwise migrate,
    /// quarantine, or delete a developer's real legacy library.
    func testLegacyLocationsStayInsideTheSandbox() throws {
        let home = TextMouthRuntime.current.homeDirectory
        let sandboxPrefix = home.standardizedFileURL.path + "/"
        let legacyLocations = [
            try XCTUnwrap(TextMouthPaths.oldAppSupportDir),
            try XCTUnwrap(TextMouthPaths.oldLibraryFile),
            try XCTUnwrap(TextMouthPaths.oldBooksDir),
            TextMouthPaths.sandboxContainerRoot(in: home)
        ]

        for location in legacyLocations {
            XCTAssertTrue(
                location.standardizedFileURL.path.hasPrefix(sandboxPrefix),
                "\(location.path) is outside the sandbox"
            )
        }
    }

    /// In the app the default and legacy locations are where every release
    /// has looked, in the user's real home. Computing them touches nothing.
    func testAppLocationsAreInTheRealHome() throws {
        let home = TextMouthRuntime.detect(
            environment: [:],
            processIdentifier: 4242,
            temporaryDirectory: FileManager.default.temporaryDirectory
        ).homeDirectory
        let realHome = RealUserAccount.homeDirectory.standardizedFileURL.path
        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )

        XCTAssertEqual(TextMouthPaths.defaultRoot(in: home).path, realHome + "/.TextMouth")
        XCTAssertEqual(
            TextMouthPaths.sandboxContainerRoot(in: home).path,
            realHome + "/Library/Containers/com.textmouth.TextMouth/Data/.TextMouth"
        )
        // The system's Application Support folder, as the oldest releases used.
        XCTAssertEqual(
            TextMouthPaths.legacyApplicationSupportDirectory(in: home).path,
            applicationSupport.appendingPathComponent("TextMouth").path
        )
    }

    // MARK: - Sandbox Container Migration

    /// A library an old sandboxed release left in its container moves into
    /// the default location of the same home, with its book's path rewritten,
    /// and the container keeps its copy. The home is a folder in the
    /// sandbox, so the copy never leaves it.
    func testContainerLibraryMigratesIntoItsHomesDefaultLocation() throws {
        let home = try makeSandboxDirectory("container-home")
        let container = TextMouthPaths.sandboxContainerRoot(in: home)
        let library = try makeLibrary(at: container)
        try LibraryIndexSandbox.encoded(library).write(to: container.appendingPathComponent("library.json"))
        let defaultRoot = TextMouthPaths.defaultRoot(in: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultRoot.path))

        LibraryViewModel(initializeServices: false).migrateFromSandboxContainer(home: home)

        let migrated = try readIndex(in: defaultRoot)
        let book = try XCTUnwrap(migrated.books.first)
        XCTAssertEqual(migrated.books.map(\.id), library.books.map(\.id))
        XCTAssertTrue(book.filePath.hasPrefix(defaultRoot.path + "/"), book.filePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.books[0].filePath), "the container keeps its copy")
    }

    /// A default location that exists is the current library, so nothing is
    /// copied over it.
    func testContainerMigrationLeavesAnExistingDefaultLocationAlone() throws {
        let home = try makeSandboxDirectory("container-home-existing")
        let container = TextMouthPaths.sandboxContainerRoot(in: home)
        try LibraryIndexSandbox.encoded(try makeLibrary(at: container))
            .write(to: container.appendingPathComponent("library.json"))
        let defaultRoot = TextMouthPaths.defaultRoot(in: home)
        try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        try Data("current library".utf8).write(to: defaultRoot.appendingPathComponent("keep.txt"))

        LibraryViewModel(initializeServices: false).migrateFromSandboxContainer(home: home)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: defaultRoot.path), ["keep.txt"])
    }

    /// The library index in the data directory at `root`, decoded as the app
    /// writes it.
    private func readIndex(in root: URL) throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Library.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
    }

    // MARK: - The Custom Data Directory

    /// In the app the root follows the custom location its preferences hold,
    /// and returns to the default when that is removed or empty.
    func testAppRootFollowsItsCustomLocation() throws {
        let home = try makeSandboxDirectory("app-home")
        let store = makeSandboxedPreferences("custom-root")
        let app = TextMouthRuntime(isHostedTest: false, homeDirectory: home, preferences: store)
        XCTAssertEqual(TextMouthPaths.root(for: app), TextMouthPaths.defaultRoot(in: home))

        let chosen = home.appendingPathComponent("Chosen Library", isDirectory: true)
        TextMouthPaths.setCustomRoot(chosen, in: store)
        XCTAssertEqual(store.string(forKey: "textMouthDataDirectory"), chosen.path)
        XCTAssertEqual(TextMouthPaths.root(for: app).path, chosen.path)

        store.set("", forKey: "textMouthDataDirectory")
        XCTAssertEqual(TextMouthPaths.root(for: app), TextMouthPaths.defaultRoot(in: home))

        TextMouthPaths.setCustomRoot(chosen, in: store)
        TextMouthPaths.setCustomRoot(nil, in: store)
        XCTAssertNil(store.object(forKey: "textMouthDataDirectory"))
        XCTAssertEqual(TextMouthPaths.root(for: app), TextMouthPaths.defaultRoot(in: home))
    }

    /// Under hosted tests the root stays the sandbox default even when the
    /// preferences name another location.
    func testHostedRootIgnoresACustomLocation() throws {
        let home = try makeSandboxDirectory("hosted-home")
        let store = makeSandboxedPreferences("custom-root-hosted")
        TextMouthPaths.setCustomRoot(home.appendingPathComponent("Elsewhere", isDirectory: true), in: store)

        let hosted = TextMouthRuntime(isHostedTest: true, homeDirectory: home, preferences: store)

        XCTAssertEqual(TextMouthPaths.root(for: hosted), TextMouthPaths.defaultRoot(in: home))
    }

    /// Choosing a data directory writes this process's sandboxed preferences,
    /// never the user's, and the hosted root stays where it is.
    func testSetCustomRootWritesTheSandboxedPreferences() throws {
        let key = "textMouthDataDirectory"
        preservePreferences([key])
        let usersValue = UserDefaults.standard.string(forKey: key)
        let rootBefore = TextMouthPaths.root
        let chosen = try makeSandboxDirectory("chosen-root")

        TextMouthPaths.setCustomRoot(chosen)

        XCTAssertEqual(TextMouthRuntime.current.preferences.string(forKey: key), chosen.path)
        XCTAssertEqual(TextMouthPaths.root, rootBefore)
        XCTAssertFalse(TextMouthPaths.isCustomPath)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), usersValue)

        TextMouthPaths.setCustomRoot(nil)

        XCTAssertNil(TextMouthRuntime.current.preferences.object(forKey: key))
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), usersValue)
    }

    // MARK: - Sound Effects

    /// The keys of the sound effect preferences, unchanged since the first release.
    private static let soundKeys = ["soundEffectsEnabled", "soundEffectsVolume", "soundEffectAssignments"]

    /// The sound preferences load from the store the service is given and
    /// save back to it under their original keys; the user's preferences
    /// stay as they were.
    func testSoundEffectsReadAndWriteTheirStore() throws {
        let store = makeSandboxedPreferences("sound-effects")
        let usersPreferences = UserPreferenceFingerprint()
        store.set(false, forKey: "soundEffectsEnabled")
        store.set(Float(0.25), forKey: "soundEffectsVolume")
        store.set(try JSONEncoder().encode(["Play": "Glass"]), forKey: "soundEffectAssignments")

        let sounds = SoundEffectService(preferences: store)

        XCTAssertFalse(sounds.soundsEnabled)
        XCTAssertEqual(sounds.volume, 0.25)
        XCTAssertEqual(sounds.assignments, [.play: "Glass"])

        sounds.soundsEnabled = true
        sounds.volume = 0.75
        sounds.assignments[.pause] = "None"

        XCTAssertEqual(store.object(forKey: "soundEffectsEnabled") as? Bool, true)
        XCTAssertEqual(store.float(forKey: "soundEffectsVolume"), 0.75)
        let savedAssignments = try XCTUnwrap(store.data(forKey: "soundEffectAssignments"))
        XCTAssertEqual(
            try JSONDecoder().decode([String: String].self, from: savedAssignments),
            ["Play": "Glass", "Pause": "None"]
        )
        XCTAssertEqual(UserPreferenceFingerprint(), usersPreferences)
    }

    /// Without a store of its own, the service uses this process's
    /// preferences, as the app's shared one does.
    func testSoundEffectsDefaultToThisProcessPreferences() {
        preservePreferences(Self.soundKeys)
        let usersPreferences = UserPreferenceFingerprint()
        let preferences = TextMouthRuntime.current.preferences

        let sounds = SoundEffectService()
        sounds.soundsEnabled = false
        sounds.volume = 0.3
        XCTAssertEqual(preferences.object(forKey: "soundEffectsEnabled") as? Bool, false)
        XCTAssertEqual(preferences.float(forKey: "soundEffectsVolume"), 0.3)

        sounds.resetToDefaults()
        XCTAssertEqual(preferences.object(forKey: "soundEffectsEnabled") as? Bool, true)
        XCTAssertEqual(preferences.float(forKey: "soundEffectsVolume"), 0.5)
        XCTAssertNotNil(preferences.data(forKey: "soundEffectAssignments"))
        XCTAssertEqual(UserPreferenceFingerprint(), usersPreferences)
    }

    // MARK: - Text Substitutions

    /// The substitution switch reads its saved value from the store it is
    /// given and saves changes there under its original key; the user's
    /// preferences stay as they were.
    func testSubstitutionSwitchReadsAndWritesItsStore() {
        let store = makeSandboxedPreferences("substitutions")
        let usersPreferences = UserPreferenceFingerprint()
        XCTAssertTrue(TextSubstitutionService.storedIsEnabled(in: store), "on until the user turns it off")
        store.set(false, forKey: "substitutionsEnabled")
        XCTAssertFalse(TextSubstitutionService.storedIsEnabled(in: store))

        let service = TextSubstitutionService(rules: [], isEnabled: false, preferences: store)
        service.isEnabled = true

        XCTAssertEqual(store.object(forKey: "substitutionsEnabled") as? Bool, true)
        XCTAssertEqual(UserPreferenceFingerprint(), usersPreferences)
    }

    /// A test's own service given no store saves the switch nowhere, so
    /// toggling it leaves nothing behind for the shared service or for
    /// later tests.
    func testTestSubstitutionServiceSavesTheSwitchOnlyToAGivenStore() {
        let key = "substitutionsEnabled"
        preservePreferences([key])
        let preferences = TextMouthRuntime.current.preferences
        preferences.removeObject(forKey: key)
        let usersPreferences = UserPreferenceFingerprint()

        let service = TextSubstitutionService(rules: [], isEnabled: true)
        service.isEnabled = false

        XCTAssertFalse(service.isEnabled)
        XCTAssertNil(preferences.object(forKey: key))
        XCTAssertEqual(UserPreferenceFingerprint(), usersPreferences)
    }

    /// The app's shared service saves the switch to this process's
    /// preferences.
    func testSharedSubstitutionSwitchUsesThisProcessPreferences() {
        preservePreferences(["substitutionsEnabled"])
        let usersPreferences = UserPreferenceFingerprint()
        let shared = TextSubstitutionService.shared
        let original = shared.isEnabled
        defer { shared.isEnabled = original }

        shared.isEnabled = !original

        XCTAssertEqual(
            TextMouthRuntime.current.preferences.object(forKey: "substitutionsEnabled") as? Bool,
            !original
        )
        XCTAssertEqual(UserPreferenceFingerprint(), usersPreferences)
    }

    // MARK: - Window Restoration

    /// Launch turns window restoration off in the store it is given, under
    /// the key AppKit reads.
    func testWindowRestorationSettingIsSavedToItsStore() {
        let store = makeSandboxedPreferences("window-restoration")

        AppDelegate.disableWindowRestoration(in: store)

        XCTAssertEqual(store.object(forKey: "NSQuitAlwaysKeepsWindows") as? Bool, false)
    }

    /// The hosted app's launch saves the setting to the sandboxed store,
    /// never to the user's preferences.
    func testHostedLaunchSavesWindowRestorationToTheSandbox() {
        let key = "NSQuitAlwaysKeepsWindows"
        preservePreferences([key])
        let usersPreferences = UserPreferenceFingerprint()
        TextMouthRuntime.current.preferences.removeObject(forKey: key)

        AppDelegate.disableWindowRestoration()

        XCTAssertEqual(TextMouthRuntime.current.preferences.object(forKey: key) as? Bool, false)
        XCTAssertEqual(UserPreferenceFingerprint(), usersPreferences)
    }

    // MARK: - Services Built Without a Store

    /// The settings model, the shortcut manager, and the sleep timer built
    /// without a store of their own, as the app builds them, save to this
    /// process's preferences and never to the user's.
    func testSettingsShortcutsAndSleepTimerDefaultToThisProcessPreferences() {
        let preferences = TextMouthRuntime.current.preferences
        let keys = ["autoPlayOnNavigate", "keyboardShortcutEdits", "sleepTimer.lastUsedDuration"]
        preservePreferences(keys)
        let usersPreferences = UserPreferenceFingerprint(UserPreferenceFingerprint.textMouthKeys + keys)
        for key in keys {
            preferences.removeObject(forKey: key)
        }

        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        settings.autoPlayOnNavigate.toggle()
        XCTAssertEqual(preferences.object(forKey: "autoPlayOnNavigate") as? Bool, settings.autoPlayOnNavigate)

        KeyboardShortcutManager(installsEventMonitor: false).resetToDefaults()
        XCTAssertNotNil(preferences.data(forKey: "keyboardShortcutEdits"))

        let timer = SleepTimerService()
        defer { timer._resetForTesting() }
        timer.start(duration: .minutes(45), ownerID: UUID(), onExpire: {})
        XCTAssertNotNil(preferences.data(forKey: "sleepTimer.lastUsedDuration"))

        XCTAssertEqual(UserPreferenceFingerprint(UserPreferenceFingerprint.textMouthKeys + keys), usersPreferences)
    }

    // MARK: - VoiceOver Announcements

    /// The app posts its announcements to VoiceOver; a process hosting tests
    /// records them instead.
    func testOnlyTheAppPostsAnnouncements() {
        let app = TextMouthRuntime.detect(
            environment: [:],
            processIdentifier: 4242,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )

        XCTAssertEqual(VoiceOverAnnouncer.defaultDelivery(for: app), .post)
        XCTAssertEqual(VoiceOverAnnouncer.defaultDelivery(for: .current), .record)
    }

    /// An announcement a test does not capture itself is recorded, where a
    /// test can still find it, and never reaches VoiceOver on the machine
    /// running the suite.
    func testUncapturedAnnouncementIsRecordedInsteadOfPosted() {
        let message = "Isolation check \(UUID().uuidString)"

        VoiceOverAnnouncer.announce(message, priority: .low)

        XCTAssertEqual(
            VoiceOverAnnouncer.recordedAnnouncements.last,
            VoiceOverAnnouncement(message: message, priority: .low)
        )
    }

    /// The recording poster delivers to the record and nowhere else; a
    /// capture a test installs still takes precedence over it.
    func testRecordingPosterKeepsAnnouncementsAndYieldsToACapture() {
        let recording = VoiceOverAnnouncer.makePoster(delivering: .record)
        let countBefore = VoiceOverAnnouncer.recordedAnnouncements.count

        recording(VoiceOverAnnouncement(message: "Recorded", priority: .medium), nil)
        let captured = recordingAnnouncements {
            VoiceOverAnnouncer.announce("Captured")
        }

        XCTAssertEqual(VoiceOverAnnouncer.recordedAnnouncements.count, countBefore + 1)
        XCTAssertEqual(VoiceOverAnnouncer.recordedAnnouncements.last?.message, "Recorded")
        XCTAssertEqual(captured.announcements.map(\.message), ["Captured"])
    }

    // MARK: - Reader Windows

    /// The bundle's principal class registered the reader window check, and
    /// XCTest is reporting this run to it.
    func testReaderWindowCheckIsRegistered() {
        XCTAssertTrue(ReaderWindowLeakCheck.shared.sawBundleStart)
    }

    /// The check closes exactly the reader windows that were not open when
    /// the test began, recognizing them as the app's menus do, and names
    /// them for the failure.
    func testReaderWindowCheckClosesOnlyNewReaderWindows() {
        let earlierReader = makeOffscreenWindow(identifier: "book-reader-AppWindow-1", title: "Book: Earlier")
        let leftOpen = makeOffscreenWindow(identifier: "book-reader-AppWindow-2", title: "Book: Left Open")
        let library = makeOffscreenWindow(identifier: nil, title: "All Folders")
        let settings = makeOffscreenWindow(identifier: "com_apple_SwiftUI_Settings_window", title: "General")
        let closes = WindowCloseRecorder(watching: [earlierReader, leftOpen, library, settings])

        let titles = ReaderWindowLeakCheck.closeNewReaderWindows(
            among: [earlierReader, leftOpen, library, settings],
            except: [ObjectIdentifier(earlierReader)]
        )

        XCTAssertEqual(titles, ["\"Book: Left Open\""])
        XCTAssertEqual(closes.closedTitles, ["Book: Left Open"])
    }

    /// A titled window that is never shown, so it cannot reach the screen or
    /// VoiceOver, closed when the test ends.
    private func makeOffscreenWindow(identifier: String?, title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        // Tests own this window; AppKit must not release it again on close.
        window.isReleasedWhenClosed = false
        window.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        window.title = title
        addTeardownBlock { window.close() }
        return window
    }

    // MARK: - Sandbox Lifetime (PERF26)

    /// The bundle's principal class registered the sandbox cleanup, and
    /// XCTest is reporting this run to it.
    func testSandboxCleanupIsRegistered() {
        XCTAssertTrue(HostedSandboxCleanup.shared.sawBundleStart)
    }

    /// A sandbox's folder name says which process it belongs to; no other
    /// name, however close, is taken for a sandbox's.
    func testOnlyASandboxNameNamesAProcess() {
        XCTAssertEqual(TextMouthRuntime.sandboxProcess(named: "TextMouthTests-4242"), 4242)
        let others = [
            "TextMouthTests-", "TextMouthTests-0", "TextMouthTests-12x", "TextMouthTests-+12",
            "TextMouthTests--12", "TextMouthTests- 12", "TextMouthTests-99999999999",
            "TextMouthTests-4242-kept-1A2B3C4D", "textmouthtests-4242", "Other-4242", "4242",
        ]
        for name in others {
            XCTAssertNil(TextMouthRuntime.sandboxProcess(named: name), name)
        }
    }

    /// The sweep deletes exactly the sandboxes of processes that have ended.
    /// It leaves this process's, a running process's, a kept one, a file
    /// with a sandbox's name, a symbolic link to a folder (and the folder it
    /// leads to), and every other name.
    func testSweepDeletesOnlySandboxesOfEndedProcesses() throws {
        let temporary = try makeSandboxDirectory("sandbox-sweep")
        let manager = FileManager.default
        func folder(_ name: String, holding file: String? = nil) throws -> URL {
            let url = temporary.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            if let file {
                try Data("x".utf8).write(to: url.appendingPathComponent(file))
            }
            return url
        }
        let ended = try folder("TextMouthTests-111")
        let endedWithLibrary = try folder("TextMouthTests-112", holding: "library.json")
        let leftAlone = [
            try folder("TextMouthTests-222"),
            try folder("TextMouthTests-1000"),
            try folder("TextMouthTests-333", holding: TextMouthRuntime.keptSandboxMarker),
            try folder("TextMouthTests-12x"),
            try folder("Other-666"),
        ]
        let fileNamedLikeASandbox = temporary.appendingPathComponent("TextMouthTests-444")
        try Data("x".utf8).write(to: fileNamedLikeASandbox)
        let linkTarget = try folder("Elsewhere", holding: "precious.txt")
        let link = temporary.appendingPathComponent("TextMouthTests-555")
        try manager.createSymbolicLink(at: link, withDestinationURL: linkTarget)
        // Process 1000 is "this" process; 222 is running; every other has
        // ended. Each process asked about is told when its folder was made.
        var madeDates: [Int32: Date] = [:]
        let isMakerRunning: (Int32, Date?) -> Bool = { process, made in
            madeDates[process] = made ?? .distantPast
            return process == 222
        }

        let found = TextMouthRuntime.abandonedSandboxes(in: temporary, currentProcess: 1000, isMakerRunning: isMakerRunning)
        XCTAssertEqual(found.map(\.lastPathComponent), ["TextMouthTests-111", "TextMouthTests-112"])
        XCTAssertEqual(Set(madeDates.keys), [111, 112, 222], "Only plain, unkept folders of other processes are asked about")
        for (process, made) in madeDates {
            XCTAssertLessThan(abs(made.timeIntervalSinceNow), 600, "process \(process) was not told when its folder was made")
        }

        let removed = TextMouthRuntime.removeAbandonedSandboxes(
            in: temporary,
            currentProcess: 1000,
            isMakerRunning: isMakerRunning
        )
        XCTAssertEqual(removed.map(\.lastPathComponent), ["TextMouthTests-111", "TextMouthTests-112"])
        XCTAssertFalse(manager.fileExists(atPath: ended.path))
        XCTAssertFalse(manager.fileExists(atPath: endedWithLibrary.path))
        for url in leftAlone {
            XCTAssertTrue(manager.fileExists(atPath: url.path), url.lastPathComponent)
        }
        XCTAssertTrue(manager.fileExists(atPath: fileNamedLikeASandbox.path))
        XCTAssertNotNil(try? manager.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertTrue(manager.fileExists(atPath: linkTarget.appendingPathComponent("precious.txt").path))
    }

    /// This process and any process that exists count as running; one
    /// that does not exist has ended.
    func testRunningProcessesAreRecognized() {
        XCTAssertTrue(TextMouthRuntime.isProcessRunning(ProcessInfo.processInfo.processIdentifier))
        // launchd, which belongs to root: signalling it is refused, yet it runs.
        XCTAssertTrue(TextMouthRuntime.isProcessRunning(1))
        XCTAssertFalse(TextMouthRuntime.isProcessRunning(Int32.max))
    }

    /// A running process's start is known, and comes after the Mac's own
    /// start, launchd's; a process that does not exist has none.
    func testProcessStartDates() throws {
        let launchdStarted = try XCTUnwrap(TextMouthRuntime.startDate(ofProcess: 1))
        let ownStart = try XCTUnwrap(TextMouthRuntime.startDate(ofProcess: ProcessInfo.processInfo.processIdentifier))
        XCTAssertLessThanOrEqual(launchdStarted, ownStart)
        XCTAssertLessThanOrEqual(ownStart, Date())
        XCTAssertNil(TextMouthRuntime.startDate(ofProcess: Int32.max))
    }

    /// Process identifiers are reused. A sandbox named for a running process
    /// that started well after the sandbox was made belongs to an earlier
    /// process with that identifier, which has ended: the sweep deletes it.
    /// One made after its process started stays, and so does one made up to
    /// an hour before, which only a change of the clock explains.
    func testSandboxOfAnIdentifierALaterProcessTookIsSwept() throws {
        // launchd, process 1, has been running since the Mac started up.
        let launchdStarted = try XCTUnwrap(TextMouthRuntime.startDate(ofProcess: 1))
        let hour: TimeInterval = 60 * 60
        XCTAssertTrue(TextMouthRuntime.isFolderMakerRunning(1, folderMade: launchdStarted))
        XCTAssertTrue(TextMouthRuntime.isFolderMakerRunning(1, folderMade: Date()))
        XCTAssertTrue(TextMouthRuntime.isFolderMakerRunning(1, folderMade: launchdStarted.addingTimeInterval(-0.5 * hour)))
        XCTAssertFalse(TextMouthRuntime.isFolderMakerRunning(1, folderMade: launchdStarted.addingTimeInterval(-2 * hour)))
        XCTAssertTrue(TextMouthRuntime.isFolderMakerRunning(1, folderMade: nil), "An unknown date keeps a running process's")
        XCTAssertFalse(TextMouthRuntime.isFolderMakerRunning(Int32.max, folderMade: Date()))

        // The sweep, as runs make it, judging by when each folder was made.
        let manager = FileManager.default
        let currentProcess = ProcessInfo.processInfo.processIdentifier
        let earlier = try makeSandboxDirectory("sandbox-identifier-taken")
        let taken = earlier.appendingPathComponent("TextMouthTests-1", isDirectory: true)
        try manager.createDirectory(at: taken, withIntermediateDirectories: true)
        try manager.setAttributes([.creationDate: launchdStarted.addingTimeInterval(-2 * hour)], ofItemAtPath: taken.path)
        let later = try makeSandboxDirectory("sandbox-identifier-kept")
        let current = later.appendingPathComponent("TextMouthTests-1", isDirectory: true)
        try manager.createDirectory(at: current, withIntermediateDirectories: true)

        XCTAssertEqual(
            TextMouthRuntime.removeAbandonedSandboxes(in: earlier, currentProcess: currentProcess).map(\.lastPathComponent),
            ["TextMouthTests-1"]
        )
        XCTAssertFalse(manager.fileExists(atPath: taken.path))
        XCTAssertEqual(TextMouthRuntime.removeAbandonedSandboxes(in: later, currentProcess: currentProcess), [])
        XCTAssertTrue(manager.fileExists(atPath: current.path))
    }

    /// As its tests finish, a hosted process deletes its sandbox, with
    /// everything the tests wrote there.
    func testFinishedSandboxIsDeleted() throws {
        let temporary = try makeSandboxDirectory("sandbox-finish")
        let runtime = hostedRuntime(processIdentifier: 4242, in: temporary)
        XCTAssertFalse(runtime.keepsSandbox)
        let library = runtime.homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        runtime.finishWithSandbox()

        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.homeDirectory.path))
    }

    /// TEXTMOUTH_KEEP_SANDBOX=1 keeps the sandbox, marked so that no later
    /// run's sweep deletes it once the process has ended.
    func testKeptSandboxOutlivesItsProcessAndLaterSweeps() throws {
        let temporary = try makeSandboxDirectory("sandbox-keep")
        let runtime = hostedRuntime(processIdentifier: 4243, in: temporary, keep: "1")
        XCTAssertTrue(runtime.keepsSandbox)
        try FileManager.default.createDirectory(at: runtime.homeDirectory, withIntermediateDirectories: true)

        runtime.finishWithSandbox()

        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.homeDirectory.path))
        XCTAssertTrue(TextMouthRuntime.isKept(runtime.homeDirectory))
        XCTAssertEqual(
            TextMouthRuntime.removeAbandonedSandboxes(in: temporary, currentProcess: 1, isMakerRunning: { _, _ in false }),
            []
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.homeDirectory.path))
    }

    /// Only the value 1 keeps a sandbox, and only a hosted process has one:
    /// the app, even with the variable set, keeps and deletes nothing.
    func testOnlyAHostedProcessAskedWithOneKeepsItsSandbox() throws {
        let temporary = try makeSandboxDirectory("sandbox-keep-values")
        for (value, keeps) in [("1", true), ("0", false), ("", false), ("yes", false)] {
            XCTAssertEqual(hostedRuntime(processIdentifier: 4244, in: temporary, keep: value).keepsSandbox, keeps, value)
        }
        XCTAssertFalse(hostedRuntime(processIdentifier: 4244, in: temporary).keepsSandbox, "unset")

        let appRuntime = TextMouthRuntime.detect(
            environment: [TextMouthRuntime.keepSandboxVariable: "1"],
            processIdentifier: 4245,
            temporaryDirectory: temporary
        )
        XCTAssertFalse(appRuntime.isHostedTest)
        XCTAssertFalse(appRuntime.keepsSandbox)

        // An app runtime is given a home of the test's own: finishing must
        // leave it, as it leaves the user's real home.
        let home = temporary.appendingPathComponent("TextMouthTests-4246", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        TextMouthRuntime(isHostedTest: false, homeDirectory: home, preferences: makeSandboxedPreferences("app-home"))
            .finishWithSandbox()
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path))
    }

    /// A hosted runtime never deletes a home that is not named as a sandbox
    /// is, whoever built it.
    func testFinishingLeavesAHomeNotNamedAsASandbox() throws {
        let home = try makeSandboxDirectory("not-a-sandbox-name")
        TextMouthRuntime(isHostedTest: true, homeDirectory: home, preferences: makeSandboxedPreferences("odd-home"))
            .finishWithSandbox()
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.path))
    }

    /// A sandbox an earlier process with this process's identifier left
    /// behind is cleared before this process uses it. A kept one is moved
    /// aside, whole, under a name no sweep takes for a sandbox's.
    func testEarlierSandboxUnderTheSameIdentifierIsCleared() throws {
        let temporary = try makeSandboxDirectory("sandbox-earlier")
        let manager = FileManager.default

        let stale = temporary.appendingPathComponent("TextMouthTests-777", isDirectory: true)
        try manager.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: stale.appendingPathComponent("library.json"))
        TextMouthRuntime.clearEarlierSandbox(at: stale)
        XCTAssertFalse(manager.fileExists(atPath: stale.path))

        let kept = temporary.appendingPathComponent("TextMouthTests-778", isDirectory: true)
        try manager.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: kept.appendingPathComponent("library.json"))
        try Data("note".utf8).write(to: kept.appendingPathComponent(TextMouthRuntime.keptSandboxMarker))
        TextMouthRuntime.clearEarlierSandbox(at: kept)
        XCTAssertFalse(manager.fileExists(atPath: kept.path))
        let aside = try manager.contentsOfDirectory(atPath: temporary.path).filter { $0.hasPrefix("TextMouthTests-778-kept-") }
        XCTAssertEqual(aside.count, 1)
        let movedLibrary = temporary.appendingPathComponent(aside.first ?? "").appendingPathComponent("library.json")
        XCTAssertEqual(try? String(contentsOf: movedLibrary, encoding: .utf8), "kept")
        XCTAssertNil(TextMouthRuntime.sandboxProcess(named: aside.first ?? ""))

        // Nothing there: nothing to do.
        TextMouthRuntime.clearEarlierSandbox(at: stale)
        XCTAssertFalse(manager.fileExists(atPath: stale.path))
    }

    /// A hosted-test runtime for the process `processIdentifier`, with its
    /// sandbox in `temporary`, and TEXTMOUTH_KEEP_SANDBOX set to `keep`
    /// when it is given.
    private func hostedRuntime(processIdentifier: Int32, in temporary: URL, keep: String? = nil) -> TextMouthRuntime {
        var environment = [TextMouthRuntime.testConfigurationVariable: "/tmp/Run.xctestconfiguration"]
        environment[TextMouthRuntime.keepSandboxVariable] = keep
        return TextMouthRuntime.detect(
            environment: environment,
            processIdentifier: processIdentifier,
            temporaryDirectory: temporary
        )
    }

    // MARK: - Sentinel Proof

    /// The startup repair, the sandbox-container and legacy migrations, sound
    /// and substitution changes, the launch's window-restoration setting, and
    /// a change of data directory leave every real location TextMouth used to
    /// touch, and the user's real preferences, exactly as they were.
    func testRepresentativeWorkLeavesTheUsersDataAlone() throws {
        let sentinels = try plantSentinels()

        try performRepresentativeWork(home: TextMouthRuntime.current.homeDirectory)

        sentinels.verify()
    }

    /// The same holds when the default location does not exist yet: the one
    /// case in which the old startup copied a container library into the
    /// real ~/.TextMouth. The migration's home is an empty folder in the
    /// sandbox holding only an old container, which migrates there and
    /// nowhere else.
    func testRepresentativeWorkLeavesTheUsersDataAloneWithoutADefaultLocation() throws {
        let sentinels = try plantSentinels()
        let emptyHome = try makeSandboxDirectory("empty-home")
        let container = TextMouthPaths.sandboxContainerRoot(in: emptyHome)
        try LibraryIndexSandbox.encoded(try makeLibrary(at: container))
            .write(to: container.appendingPathComponent("library.json"))

        try performRepresentativeWork(home: emptyHome)

        let migratedIndex = TextMouthPaths.defaultRoot(in: emptyHome).appendingPathComponent("library.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedIndex.path), "the container migrates inside the sandbox")
        sentinels.verify()
    }

    /// Plants sentinels at the real locations and removes them when the test
    /// ends, whether it passes or not.
    private func plantSentinels() throws -> RealLocationSentinels {
        let sentinels = try RealLocationSentinels.plant()
        addTeardownBlock { sentinels.remove() }
        return sentinels
    }

    /// Does, as the app does, the work that used to reach the user's data,
    /// and puts every shared value back afterwards. `home` is where the
    /// sandbox-container migration looks.
    private func performRepresentativeWork(home: URL) throws {
        preservePreferences(UserPreferenceFingerprint.textMouthKeys)

        // Startup: the container migration, the directory structure, the
        // index load with its repair (migrating a legacy Application Support
        // index), and the directory rebuild that removes the emptied legacy
        // folder; then the launch's window-restoration setting.
        let index = try LibraryIndexSandbox.capture()
        defer { index.restore() }
        try index.stageValid(Library(), at: index.legacyURL)
        let library = LibraryViewModel(initializeServices: false)
        library.migrateFromSandboxContainer(home: home)
        try TextMouthPaths.ensureDirectoryStructure()
        library.loadLibraryIndex()
        try FileImportService.rebuildDirectoryStructure(library: &library.library)
        LibraryPersistenceService.flushPendingSave()
        AppDelegate.disableWindowRestoration()

        // Sound and substitution settings, changed and put back.
        let sounds = SoundEffectService()
        sounds.soundsEnabled.toggle()
        sounds.volume = 0.2
        sounds.assignments[.play] = "None"
        sounds.resetToDefaults()
        let substitutions = TextSubstitutionService.shared
        let substitutionsWereOn = substitutions.isEnabled
        substitutions.isEnabled.toggle()
        substitutions.isEnabled = substitutionsWereOn

        // A change of data directory, and back.
        TextMouthPaths.setCustomRoot(try makeSandboxDirectory("chosen-data-directory"))
        TextMouthPaths.setCustomRoot(nil)
    }
}

/// Records which of some windows close, in order, by being their delegate.
@MainActor
private final class WindowCloseRecorder: NSObject, NSWindowDelegate {
    /// The titles of the watched windows that closed, oldest first.
    private(set) var closedTitles: [String] = []

    /// Becomes the delegate of every window in `windows`, which keep it only
    /// weakly; the caller holds the recorder for as long as it watches.
    init(watching windows: [NSWindow]) {
        super.init()
        for window in windows {
            window.delegate = self
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        closedTitles.append(window.title)
    }
}
