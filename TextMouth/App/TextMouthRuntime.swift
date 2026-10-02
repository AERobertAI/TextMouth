import Foundation

/// What TextMouth knows about the process it runs in, decided once at
/// launch: whether the process hosts the test suite, and the home directory
/// and preferences store that follow from that.
///
/// The hosted tests run inside the application itself. XCTest launches
/// TextMouth.app, which starts up exactly as the developer's own copy does
/// (loading the library, migrating legacy data, reading preferences) before
/// the test bundle is injected. Nothing in the app's bundle says it is under
/// test, and it shares its bundle identifier, and so its preferences, with
/// the developer's copy. Unless the app itself knows better, its startup and
/// everything a test exercises reach the developer's real library and
/// settings.
///
/// `isHostedTest` is that knowledge: the one isolation switch. Everything
/// that could reach the user's data follows from `current`:
/// - `homeDirectory` stands for the user's home. The default data directory
///   and every legacy location (the old sandbox container and the old
///   Application Support folder) are inside it.
/// - `preferences` holds every TextMouth preference.
///
/// In the app these are the user's real home and `UserDefaults.standard`.
/// In a process hosting tests they are a sandbox folder in the temporary
/// directory, named after the process, and a preferences store kept inside
/// that folder, so nothing a test does reaches the real library, legacy
/// data, or preferences.
///
/// A runtime is an immutable value, and `current` never changes. A test that
/// checks how a decision goes in the app builds its own runtime with
/// `isHostedTest: false` and asks for that decision. The hosted process
/// itself never points at the user's data, not even briefly; that matters
/// because background work such as debounced library saves and logging reads
/// these locations on other threads at any moment.
///
/// `@unchecked Sendable`: every stored property is a constant, and the one
/// type that is not `Sendable`, `UserDefaults`, is documented thread-safe.
struct TextMouthRuntime: @unchecked Sendable {
    /// Whether this process hosts the XCTest bundle: the isolation switch.
    let isHostedTest: Bool

    /// The directory standing for the user's home. The default data
    /// directory and the legacy data locations are inside it.
    let homeDirectory: URL

    /// The store holding every TextMouth preference.
    let preferences: UserDefaults

    /// The property list `preferences` is kept in when it is not the standard
    /// store: a file inside `homeDirectory` under hosted tests. Nil in the
    /// app, whose preferences the system keeps.
    let preferencesFile: URL?

    /// A runtime made of exactly these parts. Tests build one to ask how a
    /// decision goes in the app, or under hosted tests, without touching
    /// `current`.
    init(isHostedTest: Bool, homeDirectory: URL, preferences: UserDefaults, preferencesFile: URL? = nil) {
        self.isHostedTest = isHostedTest
        self.homeDirectory = homeDirectory
        self.preferences = preferences
        self.preferencesFile = preferencesFile
    }

    // MARK: - This Process

    /// The environment variable XCTest sets in a process that hosts tests.
    static let testConfigurationVariable = "XCTestConfigurationFilePath"

    /// This process's runtime, decided at first use from its environment.
    ///
    /// A process hosting tests starts with an empty preferences store: the
    /// sandbox is named after the process identifier, which the system
    /// reuses, so an earlier run's store could otherwise carry its values
    /// into this one.
    static let current: TextMouthRuntime = {
        let process = ProcessInfo.processInfo
        let runtime = detect(
            environment: process.environment,
            processIdentifier: process.processIdentifier,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        runtime.emptySandboxedPreferences()
        return runtime
    }()

    /// The runtime of a process with `environment`. It changes nothing on
    /// disk, so tests can call it for either kind of process.
    ///
    /// - Parameters:
    ///   - environment: The process environment. XCTest sets
    ///     `testConfigurationVariable` in a process that hosts tests.
    ///   - processIdentifier: Names the sandbox and its preferences store.
    ///   - temporaryDirectory: Where a process hosting tests keeps its sandbox.
    /// - Returns: The user's real home and the standard preferences for the
    ///   app; for a process hosting tests, a sandbox folder in
    ///   `temporaryDirectory` and a preferences store inside it.
    static func detect(
        environment: [String: String],
        processIdentifier: Int32,
        temporaryDirectory: URL
    ) -> TextMouthRuntime {
        guard environment[testConfigurationVariable] != nil else {
            return TextMouthRuntime(isHostedTest: false, homeDirectory: realHomeDirectory, preferences: .standard)
        }
        let sandbox = temporaryDirectory.appendingPathComponent(
            "TextMouthTests-\(processIdentifier)",
            isDirectory: true
        )
        let store = sandboxedPreferences(
            named: "com.textmouth.TextMouth.hosted-test-\(processIdentifier)",
            in: sandbox
        )
        return TextMouthRuntime(
            isHostedTest: true,
            homeDirectory: sandbox,
            preferences: store.defaults,
            preferencesFile: store.file
        )
    }

    /// The user's real home directory, read from the user database so that
    /// neither an app sandbox nor a changed `HOME` variable can redirect it.
    static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    // MARK: - Sandboxed Preferences

    /// The folder in a sandbox that holds its preferences stores.
    ///
    /// Not Library/Preferences, where an app's preferences live in a real
    /// home: the preferences system reads a path inside any folder of that
    /// name as the plain name of an ordinary preferences domain, and keeps
    /// the store in the user's real ~/Library/Preferences instead.
    static let sandboxedPreferencesFolder = "SandboxedPreferences"

    /// A preferences store kept in the property list `name`.plist in `home`'s
    /// `sandboxedPreferencesFolder`.
    ///
    /// A suite named by a plain identifier is kept in the user's real
    /// ~/Library/Preferences, and removing its values afterwards still leaves
    /// an empty file there. A suite named by an absolute path is kept in that
    /// file instead, which the preferences daemon creates on the first write,
    /// so a store made here never leaves anything outside `home`.
    ///
    /// - Returns: The store and the property list file it is kept in.
    static func sandboxedPreferences(named name: String, in home: URL) -> (defaults: UserDefaults, file: URL) {
        let location = home
            .appendingPathComponent(sandboxedPreferencesFolder, isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        // `UserDefaults(suiteName:)` refuses only the app's own identifier
        // and the global domain, and an absolute path is never either.
        guard let defaults = UserDefaults(suiteName: location.path) else {
            preconditionFailure("A preferences suite named by a path is always available: \(location.path)")
        }
        return (defaults, location.appendingPathExtension("plist"))
    }

    /// Removes every value from a sandboxed preferences store. Does nothing
    /// to the standard store, which only the app uses.
    private func emptySandboxedPreferences() {
        guard let preferencesFile else { return }
        preferences.removePersistentDomain(forName: preferencesFile.deletingPathExtension().path)
    }
}
