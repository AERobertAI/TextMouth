import Foundation

/// Writes the diagnostic logs' lines, beneath `DiagnosticLog`, the policy
/// that decides what a line may say and alone hands lines to this writer
/// (through `TextMouthPaths.appendLog`).
///
/// Lines are written on one serial queue, so logging never blocks the
/// caller, even on the main thread during playback, and lines from
/// different callers never interleave. Each line is addressed by its log's
/// name (`DiagnosticLog.File`), and its folder is resolved only as the line
/// is written, so a line queued before the folder changed goes into the
/// folder in use when it is written. Each file is opened for the line and
/// closed after it, so nothing holds a log open in a folder no longer used.
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
        /// The folder lines are written into now.
        var folder: @Sendable () -> URL
        /// Renames a file, replacing whatever is at the new name in the same
        /// step; tests make it fail.
        var rename: @Sendable (_ from: URL, _ to: URL) throws -> Void
        /// Whether a file's content is only in the cloud, so writing to it
        /// would download it first; tests say so of files that aren't.
        var isOnlyInCloud: @Sendable (_ file: URL) -> Bool

        /// An environment writing into `folder`, renaming with rename(2)
        /// and asking the file system which files are only in the cloud,
        /// unless a test passes its own.
        init(
            folder: @escaping @Sendable () -> URL,
            rename: @escaping @Sendable (_ from: URL, _ to: URL) throws -> Void = { try LogWriter.renameReplacing($0, $1) },
            isOnlyInCloud: @escaping @Sendable (_ file: URL) -> Bool = { DatalessFiles.isDataless($0) }
        ) {
            self.folder = folder
            self.rename = rename
            self.isOnlyInCloud = isOnlyInCloud
        }
    }

    /// The writer every log line of the app goes through.
    static let shared = LogWriter(environment: Environment(folder: { TextMouthPaths.logsDir }))

    /// What this writer works with.
    private let environment: Environment

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

    /// Writes `data` into `file` in the folder in use now, making that
    /// folder first when it is missing. Runs on the writer's queue.
    private func write(_ data: Data, to file: DiagnosticLog.File) {
        let folder = environment.folder()
        do {
            try Self.makeFolder(folder)
            try append(data, to: folder.appendingPathComponent(file.rawValue, isDirectory: false))
        } catch {
            // Intentionally dropped: see the type's description.
        }
    }

    // MARK: - Files

    /// Makes `folder`, with the folders above it, when it is missing, as on
    /// the first launch after the logs left the data directory (FR02).
    private static func makeFolder(_ folder: URL) throws {
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

    /// Renames `from` to `to` with rename(2), which replaces whatever is at
    /// `to` in the same step, as `FileManager.moveItem` never does.
    /// - Throws: The POSIX error the rename failed with.
    static func renameReplacing(_ from: URL, _ to: URL) throws {
        let failure = from.withUnsafeFileSystemRepresentation { fromPath in
            to.withUnsafeFileSystemRepresentation { toPath -> Int32 in
                guard let fromPath, let toPath else { return EINVAL }
                return Darwin.rename(fromPath, toPath) == 0 ? 0 : errno
            }
        }
        guard failure == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
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
