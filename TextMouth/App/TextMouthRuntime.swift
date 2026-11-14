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
/// data, or preferences. The sandbox lasts as long as its process: the
/// hosted tests delete it as they finish, and sweep away the sandboxes of
/// processes that ended without deleting theirs (see Sandbox Lifetime).
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

    /// Whether `homeDirectory`, the sandbox of a process hosting tests, stays
    /// after the process finishes with it: only when `keepSandboxVariable`
    /// asks. Always false in the app, whose home is the user's.
    let keepsSandbox: Bool

    /// A runtime made of exactly these parts. Tests build one to ask how a
    /// decision goes in the app, or under hosted tests, without touching
    /// `current`.
    init(
        isHostedTest: Bool,
        homeDirectory: URL,
        preferences: UserDefaults,
        preferencesFile: URL? = nil,
        keepsSandbox: Bool = false
    ) {
        self.isHostedTest = isHostedTest
        self.homeDirectory = homeDirectory
        self.preferences = preferences
        self.preferencesFile = preferencesFile
        self.keepsSandbox = isHostedTest && keepsSandbox
    }

    // MARK: - This Process

    /// The environment variable XCTest sets in a process that hosts tests.
    static let testConfigurationVariable = "XCTestConfigurationFilePath"

    /// This process's runtime, decided at first use from its environment.
    ///
    /// A process hosting tests starts with an empty sandbox and an empty
    /// preferences store: the sandbox is named after the process identifier,
    /// which the system reuses, so an earlier run that crashed, or kept its
    /// sandbox, could otherwise carry its library and its values into this
    /// one. Everything this process writes derives its place from `current`,
    /// so nothing has used the sandbox yet when it is cleared here.
    static let current: TextMouthRuntime = {
        let process = ProcessInfo.processInfo
        let runtime = detect(
            environment: process.environment,
            processIdentifier: process.processIdentifier,
            temporaryDirectory: FileManager.default.temporaryDirectory
        )
        if runtime.isHostedTest {
            clearEarlierSandbox(at: runtime.homeDirectory)
        }
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
    ///   `temporaryDirectory` and a preferences store inside it, kept after
    ///   the process when `keepSandboxVariable` is 1.
    static func detect(
        environment: [String: String],
        processIdentifier: Int32,
        temporaryDirectory: URL
    ) -> TextMouthRuntime {
        #if os(iOS)
        #if DEBUG
        // The iPhone app a UI test launches runs as a hosted test does, in a
        // sandbox of its own, when it asks to (PhoneLaunchRequest): XCTest
        // names its configuration only in a process hosting a test bundle.
        var environment = environment
        if PhoneLaunchRequest.runsInSandbox(environment) {
            environment[testConfigurationVariable] = PhoneLaunchRequest.sandboxVariable
        }
        #endif
        #endif
        guard environment[testConfigurationVariable] != nil else {
            return TextMouthRuntime(isHostedTest: false, homeDirectory: realHomeDirectory, preferences: .standard)
        }
        let sandbox = temporaryDirectory.appendingPathComponent(
            "\(sandboxNamePrefix)\(processIdentifier)",
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
            preferencesFile: store.file,
            keepsSandbox: environment[keepSandboxVariable] == "1"
        )
    }

    /// The user's real home directory, read from the user database so that
    /// neither an app sandbox nor a changed `HOME` variable can redirect it.
    static var realHomeDirectory: URL {
        #if os(iOS)
        // On iOS the sandbox redirecting the home is exactly what is wanted:
        // an app may write only inside its own container, which
        // NSHomeDirectory() names. The user database names the wrong place on
        // every iOS: /var/mobile on an iPhone, which the sandbox refuses, and,
        // in the Simulator, which runs as the Mac's user, that user's real
        // home, whose ~/.TextMouth is the live library of the Mac app.
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #else
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
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

    // MARK: - Sandbox Lifetime

    /// Every hosted-test sandbox is a folder in the temporary directory named
    /// this prefix followed by the identifier of the process it belongs to.
    static let sandboxNamePrefix = "TextMouthTests-"

    /// The environment variable that keeps a process's sandbox after the
    /// hosted tests finish, for a developer to look inside, when it is 1:
    /// TEXTMOUTH_KEEP_SANDBOX=1, or TEST_RUNNER_TEXTMOUTH_KEEP_SANDBOX=1 for
    /// xcodebuild, which passes it on to the process hosting the tests.
    static let keepSandboxVariable = "TEXTMOUTH_KEEP_SANDBOX"

    /// The file in a kept sandbox that keeps later sweeps away from it. A
    /// kept sandbox stays until a developer deletes it.
    static let keptSandboxMarker = "KEPT-SANDBOX.txt"

    /// The identifier of the process the sandbox folder named `name` belongs
    /// to, or nil when the name is not a sandbox's: exactly
    /// `sandboxNamePrefix` followed by a positive decimal number.
    static func sandboxProcess(named name: String) -> Int32? {
        guard name.hasPrefix(sandboxNamePrefix) else { return nil }
        let digits = name.dropFirst(sandboxNamePrefix.count)
        guard !digits.isEmpty,
              digits.allSatisfy({ ("0"..."9").contains($0) }),
              let process = Int32(digits),
              process > 0 else { return nil }
        return process
    }

    /// Whether the process `process` is running: it exists, though it may
    /// belong to another user, who alone may signal it.
    static func isProcessRunning(_ process: Int32) -> Bool {
        kill(process, 0) == 0 || errno == EPERM
    }

    /// When the process `process` started, or nil when no process has that
    /// identifier.
    static func startDate(ofProcess process: Int32) -> Date? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, process]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        // With no such process the call succeeds but reports nothing.
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }

    /// How long after a folder named for a process was made a process with
    /// that identifier may have started and still be the one that made it.
    /// A process makes such a folder only once it runs (a sandbox as it
    /// starts, an archive extraction directory during an import), so only a
    /// change of the clock between the two can put its start later; an hour
    /// allows for any such change.
    static let folderMakerStartAllowance: TimeInterval = 60 * 60

    /// Whether the process that made a folder named for `process`, made at
    /// `made`, is still running: the one rule of both sweeps of folders that
    /// ended processes leave behind, the hosted-test sandboxes' here
    /// (`abandonedSandboxes`) and the archive extraction directories' at
    /// startup (`ArchiveExtractionDirectory.removeLeftovers`, #652).
    /// Process identifiers are reused, so a running process with the
    /// identifier that started more than `folderMakerStartAllowance` after
    /// `made` is a later process, and the one that made the folder has
    /// ended. When either date is unknown, a running process with the
    /// identifier counts as the maker, so a sweep never deletes a folder a
    /// process may still be using.
    static func isFolderMakerRunning(_ process: Int32, folderMade made: Date?) -> Bool {
        guard isProcessRunning(process) else { return false }
        guard let made, let started = startDate(ofProcess: process) else { return true }
        return started <= made.addingTimeInterval(folderMakerStartAllowance)
    }

    /// Whether `sandbox` was kept by its process (see `keepsSandbox`).
    static func isKept(_ sandbox: URL) -> Bool {
        FileManager.default.fileExists(atPath: sandbox.appendingPathComponent(keptSandboxMarker).path)
    }

    /// The sandboxes in `temporaryDirectory` that hosted-test processes left
    /// behind and nothing uses any more: folders named for a process other
    /// than `currentProcess` that, as `isMakerRunning` decides from that
    /// process's identifier and when the folder was made, has ended. Kept
    /// sandboxes stay, and so does anything that is not a plain folder, such
    /// as a symbolic link, which could lead anywhere. In name order.
    static func abandonedSandboxes(
        in temporaryDirectory: URL,
        currentProcess: Int32,
        isMakerRunning: (_ process: Int32, _ sandboxMade: Date?) -> Bool = isFolderMakerRunning
    ) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: keys
        )) ?? []
        return entries.filter { entry in
            guard let process = sandboxProcess(named: entry.lastPathComponent),
                  process != currentProcess,
                  let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  !isKept(entry) else { return false }
            return !isMakerRunning(process, values.creationDate)
        }
        .sortedStably { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Deletes the sandboxes earlier hosted-test processes left behind in
    /// `temporaryDirectory`, as `abandonedSandboxes` finds them: those of
    /// processes that crashed or were stopped before they could delete their
    /// own, and the few files a finished process's late background work
    /// wrote again. One that cannot be deleted now, such as one another
    /// run's sweep is deleting at the same moment, waits for the next sweep.
    /// - Returns: The sandboxes deleted.
    @discardableResult
    static func removeAbandonedSandboxes(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        currentProcess: Int32 = ProcessInfo.processInfo.processIdentifier,
        isMakerRunning: (_ process: Int32, _ sandboxMade: Date?) -> Bool = isFolderMakerRunning
    ) -> [URL] {
        abandonedSandboxes(in: temporaryDirectory, currentProcess: currentProcess, isMakerRunning: isMakerRunning)
            .filter { (try? FileManager.default.removeItem(at: $0)) != nil }
    }

    /// Ends this process's use of its sandbox as the hosted tests finish:
    /// deletes it, or, when `keepsSandbox`, marks it kept so that later
    /// sweeps leave it alone. Does nothing in the app, whose home is the
    /// user's own, nor to a home that is not named as a sandbox is.
    func finishWithSandbox() {
        guard isHostedTest, Self.sandboxProcess(named: homeDirectory.lastPathComponent) != nil else { return }
        if keepsSandbox {
            let note = "This test sandbox was kept because \(Self.keepSandboxVariable) was 1. "
                + "Later test runs leave it alone; delete this folder when you are done with it.\n"
            try? note.write(to: homeDirectory.appendingPathComponent(Self.keptSandboxMarker), atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: homeDirectory)
        }
    }

    /// Clears `sandbox`, a hosted-test process's sandbox, of what an earlier
    /// process with the same identifier left there, before the new process
    /// uses it. A kept one is moved aside, beside it under its name followed
    /// by "-kept-" and a unique suffix, which no sweep takes for a sandbox;
    /// any other is deleted, as is a kept one that could not be moved.
    static func clearEarlierSandbox(at sandbox: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: sandbox.path) else { return }
        if isKept(sandbox) {
            let aside = sandbox.deletingLastPathComponent().appendingPathComponent(
                "\(sandbox.lastPathComponent)-kept-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
            if (try? manager.moveItem(at: sandbox, to: aside)) != nil { return }
        }
        try? manager.removeItem(at: sandbox)
    }
}
