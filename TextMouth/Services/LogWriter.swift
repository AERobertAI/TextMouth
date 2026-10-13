import Foundation
import os

// MARK: - Where the Lines Go

/// Where the diagnostic logs' lines go, and why there: what
/// `TextMouthPaths.logDestination(for:dataDirectory:thisMacsFolder:isUnavailable:)`,
/// the one resolution of the logs' folder, decides (the user's decision of
/// October 3).
struct LogDestination: Equatable, Sendable {
    /// Why lines go to a folder.
    enum Reason: Equatable, Sendable {
        /// The data directory's Logs folder, where Storage settings put the
        /// logs by default.
        case dataDirectory
        /// This Mac's Logs folder, ~/Library/Logs/TextMouth, as Storage
        /// settings ask.
        case thisMac
        /// This Mac's Logs folder in place of the data directory's, which
        /// can't take lines now, for the reason given. Lines go back to the
        /// data directory once it can.
        case fallback(LogFallback)

        /// Whether lines go to this Mac's Logs folder, as Storage settings
        /// ask or in place of the data directory's.
        var isThisMac: Bool {
            self != .dataDirectory
        }

        /// Whether two reasons send lines to the same kind of place for the
        /// same kind of cause: the data directory, this Mac as asked, or
        /// this Mac in place of the data directory, whatever its reason.
        func isSameKind(as other: Reason) -> Bool {
            switch (self, other) {
            case (.dataDirectory, .dataDirectory), (.thisMac, .thisMac), (.fallback, .fallback):
                return true
            default:
                return false
            }
        }
    }

    /// The folder the lines are written into.
    let folder: URL
    /// Why that folder.
    let reason: Reason
}

/// Why the data directory's Logs folder can't take lines now, so they go to
/// this Mac's Logs folder instead. Nothing is ever made at a data directory
/// that is missing, or in one the library model found unavailable (FR02).
enum LogFallback: Equatable, Sendable {
    /// The library model found the data directory unavailable: every
    /// Library window shows the Library Not Available screen.
    case libraryUnavailable
    /// The data directory's folder is missing, as when its drive is
    /// unplugged, and the library model hasn't noticed yet.
    case dataDirectoryMissing
    /// The data directory is there, but its Logs folder isn't, until the
    /// data directory's folders are made again
    /// (`TextMouthPaths.ensureDirectoryStructure`).
    case logsFolderMissing
    /// The data directory's Logs folder can't be written, for the reason
    /// given, such as a full disk or a folder only in the cloud.
    case logsFolderUnusable(String)

    /// Why, as a log line says it, naming the data directory at
    /// `dataDirectory` by its short name, never by its absolute path.
    func logDescription(of dataDirectory: URL) -> String {
        let name = DataDirectoryPaths.shortName(of: dataDirectory)
        switch self {
        case .libraryUnavailable:
            return "the library in \(name) isn't available"
        case .dataDirectoryMissing:
            return "the data directory \(name) is missing"
        case .logsFolderMissing:
            return "the data directory \(name) has no Logs folder"
        case .logsFolderUnusable(let reason):
            return "the Logs folder in \(name) can't be written: \(reason)"
        }
    }
}

// MARK: - The Writer

/// Writes the diagnostic logs' lines, beneath `DiagnosticLog`, the policy
/// that decides what a line may say and alone hands lines to this writer
/// (through `TextMouthPaths.appendLog`).
///
/// Lines are written on one serial queue, so logging never blocks the
/// caller, even on the main thread during playback, and lines from
/// different callers never interleave. Each line is addressed by its log's
/// name (`DiagnosticLog.File`), and its folder is resolved only as the line
/// is written (`TextMouthPaths.logDestination`): inside the data directory
/// in use then, the current storage generation's, or in this Mac's Logs
/// folder, as Storage settings choose. So a change of that choice takes
/// effect for the next line written, and after a data-directory move
/// publishes its copy, lines go into the Logs folder the move carried
/// along. Each file is opened for the line and closed after it, so nothing
/// holds a log open in a folder no longer used; logs already written are
/// never moved.
///
/// While the data directory's Logs folder can't take lines, as while the
/// library isn't available, lines go to this Mac's Logs folder, and they
/// go back once it can. The writer says so in the debug log of the folder
/// it arrives in, with one `LOG_LOCATION` line each time lines change
/// place, and never makes a folder in the data directory: its Logs folder
/// is made with the data directory's other folders.
///
/// Logging is diagnostic only, so every failure is swallowed: a full disk,
/// an unwritable file, or a folder that cannot be made must never crash or
/// stall the app. Each log keeps at most two generations: itself, up to
/// `TextMouthPaths.maxLogFileSize`, and one older `.previous`. That keeps
/// the churn small when the logs are in a folder a sync service uploads,
/// and the writer never downloads a log to add a line to it.
///
/// The app writes through `shared`; tests make writers of their own over
/// folders of their own, each with its own queue.
final class LogWriter: Sendable {
    /// What a writer works with, as closures read for every line.
    struct Environment: Sendable {
        /// Where Storage settings ask for the logs.
        var location: @Sendable () -> LogLocation
        /// The data directory in use.
        var dataDirectory: @Sendable () -> URL
        /// Whether the library model found the data directory at a root
        /// unavailable.
        var isUnavailable: @Sendable (_ dataDirectory: URL) -> Bool
        /// This Mac's own Logs folder.
        var thisMacsFolder: @Sendable () -> URL
        /// Renames a file, replacing whatever is at the new name in the same
        /// step; tests make it fail.
        var rename: @Sendable (_ from: URL, _ to: URL) throws -> Void
        /// Whether a file's content is only in the cloud, so writing to it
        /// would download it first; tests say so of files that aren't.
        var isOnlyInCloud: @Sendable (_ file: URL) -> Bool

        /// An environment of the given parts, renaming with rename(2) and
        /// asking the file system which files are only in the cloud, unless
        /// a test passes its own.
        init(
            location: @escaping @Sendable () -> LogLocation,
            dataDirectory: @escaping @Sendable () -> URL,
            isUnavailable: @escaping @Sendable (_ dataDirectory: URL) -> Bool,
            thisMacsFolder: @escaping @Sendable () -> URL,
            rename: @escaping @Sendable (_ from: URL, _ to: URL) throws -> Void = { try SavedFile.renameReplacing($0, $1) },
            isOnlyInCloud: @escaping @Sendable (_ file: URL) -> Bool = { DatalessFiles.isDataless($0) }
        ) {
            self.location = location
            self.dataDirectory = dataDirectory
            self.isUnavailable = isUnavailable
            self.thisMacsFolder = thisMacsFolder
            self.rename = rename
            self.isOnlyInCloud = isOnlyInCloud
        }

        /// The app's: Storage settings' choice in this process's
        /// preferences, the current storage generation's data directory, the
        /// library model's gate (`DataDirectoryGate`), and this Mac's
        /// ~/Library/Logs/TextMouth (`MachineLocalPaths.logs`).
        static let app = Environment(
            location: { LogLocation.preference.read(from: TextMouthRuntime.current.preferences) },
            dataDirectory: { TextMouthPaths.root },
            isUnavailable: { DataDirectoryGate.isClosed($0) },
            thisMacsFolder: { MachineLocalPaths.logs }
        )

        /// Where lines go under `location`, as things are now in this
        /// environment.
        func destination(for location: LogLocation) -> LogDestination {
            TextMouthPaths.logDestination(
                for: location,
                dataDirectory: dataDirectory(),
                thisMacsFolder: thisMacsFolder(),
                isUnavailable: isUnavailable
            )
        }

        /// Where lines go now.
        var destination: LogDestination {
            destination(for: location())
        }
    }

    /// The writer every log line of the app goes through.
    static let shared = LogWriter(environment: .app)

    /// What this writer works with.
    private let environment: Environment

    /// Why the last line went where it went, or nil before the first line:
    /// what tells the writer that lines change place, which it says in the
    /// log. Read and changed only on the writer's queue; the lock makes
    /// that safe to state.
    private let lastReason = OSAllocatedUnfairLock<LogDestination.Reason?>(initialState: nil)

    /// The serial queue every write runs on. Logging uses synchronous
    /// FileHandle I/O, which blocks its thread; without this queue, logging
    /// during playback callbacks would block the main thread and freeze the
    /// interface whenever the disk is slow (Spotlight indexing, a Time
    /// Machine backup).
    private let queue: DispatchQueue

    /// A writer working with `environment`, on a queue of its own.
    init(environment: Environment) {
        self.environment = environment
        queue = DispatchQueue(label: "com.textmouth.logging", qos: .utility)
    }

    // MARK: - Writing

    /// Appends `message` to the log `file`, timestamped now, on the writer's
    /// queue. Safe to call from any thread: it never waits for the write.
    func append(_ message: String, to file: DiagnosticLog.File) {
        let data = Self.line(message)
        queue.async { [self] in
            write(data, to: file)
        }
    }

    /// `message` as one line of a log: after the time now, and ending its
    /// line, as every line of every log is.
    static func line(_ message: String) -> Data {
        Data("\(Date()): \(message)\n".utf8)
    }

    /// Blocks until every line queued so far has been written, or dropped.
    /// A data-directory move calls this before it copies anything, and
    /// tests before they read a log.
    func flush() {
        queue.sync {}
    }

    /// Writes `data` into `file` where lines go now
    /// (`Environment.destination`). A line the data directory's Logs folder
    /// refuses goes to this Mac's Logs folder instead, and the next line
    /// tries the data directory again. Runs on the writer's queue.
    private func write(_ data: Data, to file: DiagnosticLog.File) {
        let destination = environment.destination
        do {
            try write(data, to: file, in: destination)
        } catch where destination.reason == .dataDirectory {
            let fallback = LogDestination(
                folder: environment.thisMacsFolder(),
                reason: .fallback(.logsFolderUnusable(Self.describe(error)))
            )
            try? write(data, to: file, in: fallback)
        } catch {
            // Intentionally dropped: see the type's description.
        }
    }

    /// Writes `data` into `file` in `destination`'s folder, after a line in
    /// that folder's debug log saying why lines go there now, when the last
    /// line went to another kind of place. This Mac's folder is made when it
    /// is missing; a folder in the data directory never is.
    private func write(_ data: Data, to file: DiagnosticLog.File, in destination: LogDestination) throws {
        if destination.reason.isThisMac {
            try Self.makeThisMacsFolder(destination.folder)
        }
        let note = Self.locationNote(
            arrivingAt: destination,
            after: lastReason.withLock { $0 },
            dataDirectory: environment.dataDirectory()
        )
        if let note {
            let debugLog = destination.folder.appendingPathComponent(DiagnosticLog.File.debug.rawValue, isDirectory: false)
            try append(Self.line(note), to: debugLog)
        }
        lastReason.withLock { $0 = destination.reason }
        try append(data, to: destination.folder.appendingPathComponent(file.rawValue, isDirectory: false))
    }

    /// The line that goes before the first line written to `destination`
    /// after the last one went to another kind of place, `previous`, saying
    /// why lines go there now; nil while they stay in the same kind of
    /// place, and for the very first line when it goes where Storage
    /// settings ask. The data directory at `dataDirectory` is named by its
    /// short name, and this Mac's folder as ~/Library/Logs/TextMouth.
    static func locationNote(
        arrivingAt destination: LogDestination,
        after previous: LogDestination.Reason?,
        dataDirectory: URL
    ) -> String? {
        let thisMac = "this Mac's Logs folder, \(MachineLocalPaths.logsName)"
        switch (previous, destination.reason) {
        case (let last?, let reason) where last.isSameKind(as: reason):
            return nil
        case (_, .fallback(let fallback)):
            return "LOG_LOCATION: writing the logs in \(thisMac), because \(fallback.logDescription(of: dataDirectory)); "
                + "they go back to the data directory's Logs folder once it can take them"
        case (nil, _):
            return nil
        case (.fallback?, .dataDirectory):
            return "LOG_LOCATION: writing the logs in the data directory's Logs folder again; "
                + "the lines written while it couldn't take them are in \(thisMac)"
        case (_, .dataDirectory):
            return "LOG_LOCATION: writing the logs in the data directory's Logs folder, as Storage settings ask; "
                + "logs written before stay in \(thisMac)"
        case (_, .thisMac):
            return "LOG_LOCATION: writing the logs in \(thisMac), as Storage settings ask; "
                + "logs written before stay where they are"
        }
    }

    // MARK: - Files

    /// Makes `folder`, this Mac's Logs folder, with the folders above it,
    /// when it is missing, as on the first line written there. It is the
    /// only folder made for the logs: the data directory's Logs folder is
    /// made with the data directory's other folders.
    static func makeThisMacsFolder(_ folder: URL) throws {
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Appends `data` to the log at `logFile`, starting the file when it is
    /// missing, and starting a fresh one, the full log kept as the older
    /// generation, once the log has reached the cap.
    ///
    /// Nothing is downloaded on the way (`DatalessFiles.withoutDownloading`):
    /// a log whose content a sync service left only in the cloud would have
    /// to download before it could take a line, holding up the queue, and
    /// whoever waits for it, on the network. Such a log is kept as the older
    /// generation, as a full one is, and a fresh file takes the line.
    ///
    /// The legacy `seekToEndOfFile`/`write(_:)` calls raised Objective-C
    /// exceptions on a failed write and took the whole app down (observed
    /// with ENOSPC); the throwing FileHandle calls report failures as errors
    /// instead. The end offset `seekToEnd()` returns doubles as the size
    /// check that decides whether to rotate before writing.
    private func append(_ data: Data, to logFile: URL) throws {
        try DatalessFiles.withoutDownloading {
            guard FileManager.default.fileExists(atPath: logFile.path) else {
                try data.write(to: logFile)
                return
            }
            guard !environment.isOnlyInCloud(logFile) else {
                try startAfresh(logFile, with: data)
                return
            }
            let handle: FileHandle
            do {
                handle = try FileHandle(forWritingTo: logFile)
            } catch where DatalessFiles.isDownloadRefusal(error) {
                // The sync service took the content away since the check.
                try startAfresh(logFile, with: data)
                return
            }
            let currentSize = try handle.seekToEnd()
            if currentSize >= TextMouthPaths.maxLogFileSize {
                try handle.close()
                try startAfresh(logFile, with: data)
            } else {
                defer { try? handle.close() }
                try handle.write(contentsOf: data)
            }
        }
    }

    /// Rotates the log at `logFile` and starts a fresh one holding `data`.
    /// A log that had to be started over in place begins with a line saying
    /// why its earlier lines are gone.
    private func startAfresh(_ logFile: URL, with data: Data) throws {
        switch rotate(logFile) {
        case .kept:
            try data.write(to: logFile)
        case .startedOver(let reason):
            let note = Self.rotationNote(for: logFile.lastPathComponent, reason: reason)
            try Self.replaceContents(of: logFile, with: Self.line(note) + data)
        }
    }

    // MARK: - Rotation

    /// What became of a full log when it was rotated.
    private enum Rotation {
        /// It was kept as the one older generation, `.previous`.
        case kept
        /// It could not be renamed, for `reason`, so it is to be started
        /// over in place, its lines lost.
        case startedOver(reason: String)
    }

    /// Keeps the full log at `logFile` as its one older generation,
    /// `.previous`, so a log never takes more than two generations.
    ///
    /// One rename does it, replacing the generation before in the same step
    /// (rename(2)), so the older generation is never missing, not even for a
    /// moment a sync service could upload. The rename needs no content, so a
    /// log only in the cloud is never downloaded for it. A rename refused,
    /// as one in a File Provider folder can be while the provider holds the
    /// file, is tried once more; when that is refused too, the caller starts
    /// the log over in place, so it still never grows past the cap.
    private func rotate(_ logFile: URL) -> Rotation {
        let previous = logFile.appendingPathExtension(TextMouthPaths.rotatedLogExtension)
        var refusal: Error?
        for _ in 1...2 {
            do {
                try environment.rename(logFile, previous)
                return .kept
            } catch {
                refusal = error
            }
        }
        return .startedOver(reason: refusal.map(Self.describe) ?? "no reason given")
    }

    /// Makes the log at `logFile` hold only `data`, its earlier lines gone:
    /// truncated in place, or, when it is only in the cloud and cannot be
    /// opened without downloading it, removed and written afresh.
    private static func replaceContents(of logFile: URL, with data: Data) throws {
        do {
            // Writing without the atomic option truncates the file first.
            try data.write(to: logFile)
        } catch where DatalessFiles.isDownloadRefusal(error) {
            try FileManager.default.removeItem(at: logFile)
            try data.write(to: logFile)
        }
    }

    /// What begins a log started over in place, the one named `name`,
    /// because the rename that keeps a full log was refused, for `reason`.
    static func rotationNote(for name: String, reason: String) -> String {
        let limit = TextMouthPaths.maxLogFileSize / (1024 * 1024)
        return "LOG_ROTATION: \(name) reached \(limit) MB but couldn't be renamed to "
            + "\(name).\(TextMouthPaths.rotatedLogExtension) (\(reason)), so it was started over without its earlier lines"
    }

    /// Why a file operation failed, as a log line may say it: the system's
    /// short description, such as "Operation not permitted", or that the
    /// file is only in the cloud; never a path.
    static func describe(_ error: Error) -> String {
        if DatalessFiles.isDownloadRefusal(error) {
            return "it is only in the cloud"
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(nsError.code)))
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return describe(underlying)
        }
        return "error \(nsError.code) in \(nsError.domain)"
    }
}
