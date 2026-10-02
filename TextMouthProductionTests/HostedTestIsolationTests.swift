import XCTest
@testable import TextMouth

/// The hosted suite runs inside the real application, so everything that
/// could reach the user's library, legacy data, or preferences follows one
/// switch, `TextMouthRuntime.isHostedTest` (TODO Q01). These tests check the
/// switch both ways and each location and store that follows it.
@MainActor
final class HostedTestIsolationTests: XCTestCase {

    // MARK: - The Isolation Switch

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
}
