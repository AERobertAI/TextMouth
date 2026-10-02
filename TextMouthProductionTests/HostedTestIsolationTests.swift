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
}
