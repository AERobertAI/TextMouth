import CryptoKit
import XCTest
@testable import TextMouth

// MARK: - The Machine's Speed

/// How much longer than on the development Mac a test that times the app may let it take, for the few timing tests
/// that cannot compare the app with itself on the same machine (the cancel tests do, and need no scale).
///
/// The factor is 1 everywhere except on a GitHub runner, whose script (`Scripts/agents/run-on-runner.py`) hands
/// `TEXTMOUTH_TEST_TIME_SCALE` to the test host as `TEST_RUNNER_TEXTMOUTH_TEST_TIME_SCALE`: a limit that holds on this
/// Mac with room to spare, and a virtual machine's slower cores (a hostile index read took 1.35 s there against
/// its limit of 1.0) would otherwise fail a test that checks only that the app does not run away. A value below 1, or one that is
/// not a number, is read as 1, so the scale can only widen a limit, and nothing on the development Mac sets it.
enum TestMachine {
    /// The factor the limits of timing tests are multiplied by.
    static let timeScale: Double = scale(from: ProcessInfo.processInfo.environment["TEXTMOUTH_TEST_TIME_SCALE"])

    /// The factor `text` (the environment's value, or nil) stands for: the number when it is one of 1 or more, else 1.
    static func scale(from text: String?) -> Double {
        guard let text, let scale = Double(text), scale.isFinite, scale >= 1 else { return 1 }
        return scale
    }

    /// `seconds` as a limit on this machine: the same on the development Mac, longer where the scale says.
    static func allowed(_ seconds: TimeInterval) -> TimeInterval {
        seconds * timeScale
    }
}

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

/// Fingerprints of the user's real TextMouth preferences, read without
/// writing anything.
///
/// The test host shares its bundle identifier with the developer's own copy
/// of TextMouth, so its persistent preferences domain is the developer's
/// real settings. Each value is fingerprinted by the SHA-256 digest of its
/// binary property list, so two readings are equal exactly when every value
/// is byte-for-byte the same, absent values included.
struct UserPreferenceFingerprint: Equatable, CustomStringConvertible {
    /// The keys TextMouth itself saves outside its settings window: the ones
    /// a test exercising the data directory, sounds, feeds, substitutions,
    /// repeated symbols, window restoration, the sleep timer, shortcuts,
    /// recording, or where the logs are written would change if it reached
    /// the user's preferences.
    static let textMouthKeys = [
        "textMouthDataDirectory",
        "textMouthDataDirectoryBookmark",
        "textMouthLibraryIdentity",
        "textMouthSessionMacID",
        "soundEffectsEnabled",
        "soundEffectsVolume",
        "soundEffectAssignments",
        "feedRefreshAtLaunch",
        "feedRefreshIntervalHours",
        "feedKeepEntries",
        "feedAutoDownload",
        "feedItems",
        "feedNewestCount",
        "feedDeleteDownloadsDaysAfterPlayed",
        "feedRefreshAlert",
        "feedNotifications",
        "substitutionsEnabled",
        "repeatedSymbolStyle",
        "repeatedSymbolThreshold",
        "repeatedSymbolSet",
        "recordingInputDeviceID",
        "recordingAnnouncesLevel",
        "recordingLevelAnnouncementSeconds",
        "recordingOriginalPolicy",
        "recordingOriginalDays",
        "NSQuitAlwaysKeepsWindows",
        "sleepTimer.lastUsedDuration",
        "customKeyboardBindings",
        "keyboardShortcutEdits",
        "logLocation",
        "transcriptionLocale",
        "offerTranscriptionAfterImport",
        "brailleTable"
    ]

    /// Each key's digest, or "absent" when the user has no value for it.
    let digests: [String: String]

    /// Reads `keys` from the persistent domain the developer's app uses.
    init(_ keys: [String] = textMouthKeys) {
        let domain = Bundle.main.bundleIdentifier
            .flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
        var digests: [String: String] = [:]
        for key in keys {
            digests[key] = domain[key].map(Self.digest) ?? "absent"
        }
        self.digests = digests
    }

    /// One line per key, for assertion messages.
    var description: String {
        digests.keys.sorted().map { "\($0): \(digests[$0] ?? "")" }.joined(separator: "\n")
    }

    /// The SHA-256 digest of `value`'s binary property list, in hexadecimal.
    private static func digest(_ value: Any) -> String {
        guard let bytes = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else {
            return "not a property list"
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
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

// MARK: - Sentinels at the Real Locations

/// Proof that the hosted tests leave the user's real data alone (TODO Q01).
///
/// Before TODO Q01 the hosted app computed real locations outside its data
/// root whatever it was doing: the user's ~/.TextMouth, the data directory an
/// old sandboxed release left in its container, and the oldest releases'
/// Application Support folder. `plant()` puts a sentinel file in each of
/// those that exists (named after this process, and created only where no
/// file of that name is), notes each that does not exist, and fingerprints
/// the user's real TextMouth preferences. After the work under test,
/// `verify()` checks that every sentinel is byte-for-byte unchanged, every
/// location exists exactly when it did, and the preferences are the same;
/// `remove()` deletes the sentinels.
///
/// Whole directories are never compared, and nothing in them but the
/// sentinel is read: the developer's own copy of TextMouth may be running and
/// writing to ~/.TextMouth at any moment.
///
/// `@unchecked Sendable` so a teardown block can remove the sentinels: it is
/// never mutated after `plant()` makes it.
struct RealLocationSentinels: @unchecked Sendable {
    /// One real location as `plant()` found it.
    struct Location {
        /// The directory.
        let directory: URL
        /// Whether anything was at `directory`.
        let existed: Bool
        /// The sentinel planted in it, when it was a directory.
        let sentinel: URL?
    }

    /// The real locations, spelled out from the account's home exactly as
    /// the code before TODO Q01 computed them, with none of the code under
    /// test: the default data directory, the old sandbox container and the
    /// data directory in it, and the oldest releases' folder.
    static var realLocations: [URL] {
        let home = RealUserAccount.homeDirectory
        return [
            home.appendingPathComponent(".TextMouth", isDirectory: true),
            home.appendingPathComponent("Library/Containers/com.textmouth.TextMouth", isDirectory: true),
            home.appendingPathComponent("Library/Containers/com.textmouth.TextMouth/Data/.TextMouth", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/TextMouth", isDirectory: true)
        ]
    }

    /// What every sentinel holds.
    let sentinelBytes: Data
    /// Each real location, in the order of `realLocations`.
    let locations: [Location]
    /// The user's real TextMouth preferences when the sentinels were planted.
    let preferences: UserPreferenceFingerprint

    /// Plants the sentinels and records what is at each real location now.
    /// A failure removes any sentinel already planted before it throws.
    static func plant() throws -> RealLocationSentinels {
        let process = ProcessInfo.processInfo.processIdentifier
        let name = ".textmouth-test-sentinel-\(process)"
        let bytes = Data("TextMouth hosted-test sentinel for process \(process). Safe to delete.\n".utf8)
        var locations: [Location] = []
        do {
            for directory in realLocations {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
                guard exists, isDirectory.boolValue else {
                    locations.append(Location(directory: directory, existed: exists, sentinel: nil))
                    continue
                }
                let sentinel = directory.appendingPathComponent(name, isDirectory: false)
                // Created only when no file by that name exists, so a
                // sentinel can never replace anything.
                try bytes.write(to: sentinel, options: .withoutOverwriting)
                locations.append(Location(directory: directory, existed: true, sentinel: sentinel))
            }
        } catch {
            RealLocationSentinels(sentinelBytes: bytes, locations: locations, preferences: UserPreferenceFingerprint())
                .remove()
            throw error
        }
        return RealLocationSentinels(sentinelBytes: bytes, locations: locations, preferences: UserPreferenceFingerprint())
    }

    /// Fails the running test for every difference from what `plant()`
    /// recorded.
    func verify(file: StaticString = #filePath, line: UInt = #line) {
        for location in locations {
            let path = location.directory.path
            XCTAssertEqual(
                FileManager.default.fileExists(atPath: path),
                location.existed,
                location.existed ? "\(path) disappeared" : "\(path) was created",
                file: file,
                line: line
            )
            if let sentinel = location.sentinel {
                XCTAssertEqual(
                    try? Data(contentsOf: sentinel),
                    sentinelBytes,
                    "The sentinel in \(path) changed or disappeared",
                    file: file,
                    line: line
                )
            }
        }
        XCTAssertEqual(
            UserPreferenceFingerprint(),
            preferences,
            "The user's real TextMouth preferences changed",
            file: file,
            line: line
        )
    }

    /// Deletes the sentinels this process planted, and nothing else.
    func remove() {
        for location in locations {
            if let sentinel = location.sentinel {
                try? FileManager.default.removeItem(at: sentinel)
            }
        }
    }
}
