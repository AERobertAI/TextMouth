import Darwin
import Foundation

/// The launch sweep for what an earlier TextMouth left behind when it was
/// force-quit or crashed while `/usr/bin/textutil` was converting a document
/// (review item 11 of the text formats work).
///
/// Three things can be left: a `textutil` process that outlived its parent
/// (`WatchedProcess` normally reaps it, but not when the app itself is
/// killed), the `TextMouth-textutil-<UUID>` working folder that
/// `TextutilDocumentReader` makes in the temporary directory, and the hidden
/// `.<UUID>.textutil.html` file (or, for a page-break run, the
/// `.<UUID>.textutil.txt` file) textutil writes in it. Killing the process
/// and removing the folder (which holds the file) deals with all three.
///
/// These are new functions beside the afconvert sweep's, in a file of their
/// own so that the afconvert rules in `OrphanedConversionSweep.swift` stay
/// exactly as team audiofmt keeps them. They reuse its `ProcessSnapshot`,
/// `launchdPid`, and `runningProcesses()`.
extension OrphanedConversionSweep {

    // MARK: The Rules for the Process

    /// The one program this half of the sweep may kill.
    static let textutilPath = "/usr/bin/textutil"

    /// The file name's prefix of a conversion's working folder; the folder is
    /// this followed by a UUID (`TextutilDocumentReader.withWorkingFolder`).
    static let textutilFolderPrefix = "TextMouth-textutil-"

    /// How old, in seconds, a working folder must be before it is swept.
    /// textutil is allowed 30 seconds and one more for each megabyte, 94 at
    /// the 64 MB limit; an hour leaves a conversion that is running in this
    /// process (or in another TextMouth) far out of reach.
    static let textutilFolderMinimumAge: TimeInterval = 3600

    /// The `-output` argument of a textutil command line: the argument after
    /// the first `-output`, looking only before the `--` that ends the
    /// options (the input file's name follows it and may be anything).
    /// Nil when there is none.
    static func textutilOutputArgument(in arguments: [String]) -> String? {
        let options = arguments.prefix { $0 != "--" }
        guard let flag = options.firstIndex(of: "-output") else { return nil }
        let value = options.index(after: flag)
        return value < options.endIndex ? options[value] : nil
    }

    /// Whether `argument` names one of TextMouth's hidden textutil outputs: a
    /// path whose last component starts with "." and ends with one of
    /// `TextutilConverter.temporarySuffixes` (the HTML run's or the plain
    /// text run's), with something before the suffix.
    static func isTextutilTemporaryOutputName(_ argument: String) -> Bool {
        let name = (argument as NSString).lastPathComponent
        return TextutilConverter.temporarySuffixes.contains { suffix in
            // The suffix itself starts with ".", so a name equal to it would
            // pass the first two tests with nothing in front.
            name.hasPrefix(".") && name.hasSuffix(suffix) && name.count > suffix.count
        }
    }

    /// Whether the sweep must kill `process` as an orphaned textutil: it is
    /// `/usr/bin/textutil`, run by the current user, an orphan (parent pid 1),
    /// and writing a hidden temporary output of TextMouth's. A textutil whose
    /// parent lives, or that belongs to another user or app, is never killed.
    static func shouldKillTextutil(_ process: ProcessSnapshot, currentUser: uid_t = geteuid()) -> Bool {
        guard process.path == textutilPath,
              process.userID == currentUser,
              process.parentPid == launchdPid,
              let output = textutilOutputArgument(in: process.arguments) else { return false }
        return isTextutilTemporaryOutputName(output)
    }

    /// Kills, with SIGKILL, each process of `processes` that
    /// `shouldKillTextutil` accepts, and returns their pids.
    /// - Parameters:
    ///   - processes: The running processes.
    ///   - kill: What ends a process, given the pid and the signal. The real
    ///     `Darwin.kill` by default.
    /// - Returns: The pids it killed, in the order of `processes`.
    @discardableResult
    static func sweepTextutil(
        processes: [ProcessSnapshot],
        kill: (pid_t, Int32) -> Void = { _ = Darwin.kill($0, $1) }
    ) -> [pid_t] {
        let doomed = processes.filter { shouldKillTextutil($0) }.map(\.pid)
        for pid in doomed { kill(pid, SIGKILL) }
        return doomed
    }

    // MARK: The Rules for the Folders

    /// Whether `name` is a textutil working folder's name: the prefix
    /// followed by a UUID and nothing more.
    static func isTextutilWorkingFolderName(_ name: String) -> Bool {
        guard name.hasPrefix(textutilFolderPrefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(textutilFolderPrefix.count))) != nil
    }

    /// Removes, from `root`, each real folder named `TextMouth-textutil-` and
    /// a UUID whose modification time is more than `textutilFolderMinimumAge`
    /// before `now`. A newer folder (a conversion may be running), a folder
    /// with another name, a plain file or a symbolic link named like the
    /// folder, and everything else in `root` are left alone.
    /// - Parameters:
    ///   - root: The folder to look in; the temporary directory at launch.
    ///   - now: The current time (tests pass their own).
    /// - Returns: The number of folders removed.
    @discardableResult
    static func sweepTextutilFolders(in root: URL, now: Date = Date()) -> Int {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys) else { return 0 }
        var removed = 0
        for entry in entries where isTextutilWorkingFolderName(entry.lastPathComponent) {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > textutilFolderMinimumAge else { continue }
            // A folder that cannot be removed is simply left for the next launch.
            if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: Logging

    /// The log line for a sweep that killed `killed` processes and removed
    /// `folders` working folders.
    static func textutilLogLine(killedCount killed: Int, removedFolderCount folders: Int) -> String {
        "TEXTUTIL_LEFTOVERS_SWEPT: killed \(killed) orphaned textutil process(es), "
            + "removed \(folders) old working folder(s)"
    }

    // MARK: At Launch

    /// Runs both textutil sweeps once, off the main thread at utility
    /// priority, and logs one line when anything was swept. It does nothing
    /// in hosted tests.
    /// - Parameters:
    ///   - isHostedTest: Whether this is a hosted test run.
    ///   - lister: Lists the running processes.
    ///   - kill: Ends a process.
    ///   - root: The folder holding the working folders: the temporary
    ///     directory unless a test passes its own.
    ///   - now: The current time (tests pass their own).
    ///   - completion: Called on the background queue when the sweep has
    ///     finished (tests wait on it); not called when nothing is run.
    static func sweepTextutilInBackground(
        isHostedTest: Bool = TextMouthRuntime.current.isHostedTest,
        lister: @escaping @Sendable () -> [ProcessSnapshot] = { runningProcesses() },
        kill: @escaping @Sendable (pid_t, Int32) -> Void = { _ = Darwin.kill($0, $1) },
        root: URL = FileManager.default.temporaryDirectory,
        now: @escaping @Sendable () -> Date = { Date() },
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard !isHostedTest else { return }
        DispatchQueue.global(qos: .utility).async {
            // The process first, so its folder is no longer in use when removed.
            let killed = sweepTextutil(processes: lister(), kill: kill)
            let folders = sweepTextutilFolders(in: root, now: now())
            if !killed.isEmpty || folders > 0 {
                DiagnosticLog.event(.storage, textutilLogLine(killedCount: killed.count, removedFolderCount: folders))
            }
            completion?()
        }
    }
}
