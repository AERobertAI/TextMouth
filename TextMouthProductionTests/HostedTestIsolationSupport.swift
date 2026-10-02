import XCTest
@testable import TextMouth

// MARK: - The User's Real Account

/// Facts about the real user account running the suite, looked up without
/// `TextMouthRuntime`, so isolation checks never trust the code they check.
enum RealUserAccount {
    /// The account's home directory, from the user database.
    static var homeDirectory: URL {
        let path = NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

// MARK: - The Sandbox

/// This process's sandbox, which stands for the user's home while the
/// hosted tests run.
enum HostedTestSandbox {
    /// The sandbox directory. Stops the run when this process is not
    /// isolated, so no fixture is ever made in the user's real home.
    static var home: URL {
        let runtime = TextMouthRuntime.current
        precondition(runtime.isHostedTest, "This process is not isolated; refusing to use the user's home")
        return runtime.homeDirectory
    }
}

extension XCTestCase {
    /// A new, empty directory inside this process's sandbox, removed when the
    /// test ends. `label` starts its name, for anyone reading the sandbox.
    func makeSandboxDirectory(_ label: String) throws -> URL {
        let directory = HostedTestSandbox.home
            .appendingPathComponent("Scratch", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

// MARK: - Sandboxed Preferences

/// A preferences store for one test, kept inside this process's sandbox.
///
/// `UserDefaults(suiteName:)` with a plain name keeps its property list in
/// the user's real ~/Library/Preferences, and removing the values afterwards
/// still leaves an empty file there; earlier runs of this suite left
/// thousands. These stores live in the sandbox's own Library/Preferences
/// folder instead (see `TextMouthRuntime.sandboxedPreferences(named:in:)`).
///
/// `@unchecked Sendable` so teardown blocks can discard it: both properties
/// are constants, and `UserDefaults` is documented thread-safe.
struct SandboxedPreferences: @unchecked Sendable {
    /// The store.
    let defaults: UserDefaults
    /// The property list it is kept in, inside the sandbox.
    let file: URL

    /// A new, empty store whose name starts with `label`.
    init(_ label: String) {
        let store = TextMouthRuntime.sandboxedPreferences(
            named: "com.textmouth.tests.\(label).\(UUID().uuidString)",
            in: HostedTestSandbox.home
        )
        defaults = store.defaults
        file = store.file
    }

    /// Removes every value. The emptied property list stays in the sandbox:
    /// the preferences daemon writes the removal itself, later, so deleting
    /// the file here could not keep it gone.
    func discard() {
        defaults.removePersistentDomain(forName: file.deletingPathExtension().path)
    }
}

extension XCTestCase {
    /// A new, empty sandboxed preferences store for this test, discarded when
    /// the test ends. `label` names it for anyone reading the sandbox.
    func makeSandboxedPreferences(_ label: String) -> UserDefaults {
        let store = SandboxedPreferences(label)
        addTeardownBlock { store.discard() }
        return store.defaults
    }
}

// MARK: - Preserving Preferences

/// The values some keys held in a preferences store at one moment, absent
/// keys included, so they can be put back exactly.
///
/// `@unchecked Sendable` so a teardown block can restore it: it is never
/// mutated after it is made, its values are property list objects, and
/// `UserDefaults` is documented thread-safe.
struct PreferenceSnapshot: @unchecked Sendable {
    /// The store the values came from.
    let store: UserDefaults
    /// Each key with its value then, or nil when it had none.
    let values: [(key: String, value: Any?)]

    /// Records the current values of `keys` in `store`.
    init(_ keys: [String], in store: UserDefaults) {
        self.store = store
        values = keys.map { ($0, store.object(forKey: $0)) }
    }

    /// Puts every recorded key back as it was, removing the ones that were absent.
    func restore() {
        for (key, value) in values {
            if let value {
                store.set(value, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
    }
}

extension XCTestCase {
    /// Records `keys` in `store` (this process's preferences unless stated)
    /// and puts them back when the test ends.
    ///
    /// The hosted preferences store is shared by every test in the process, so
    /// a test that changes a key in it must leave it as it found it.
    func preservePreferences(_ keys: [String], in store: UserDefaults = TextMouthRuntime.current.preferences) {
        let snapshot = PreferenceSnapshot(keys, in: store)
        addTeardownBlock { snapshot.restore() }
    }
}
