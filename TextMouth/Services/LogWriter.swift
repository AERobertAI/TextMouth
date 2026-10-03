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
/// `TextMouthPaths.maxLogFileSize`, and one older `.previous`.
///
/// The app writes through `shared`; tests make writers of their own over
/// folders of their own, each with its own queue.
final class LogWriter: Sendable {
    /// What a writer works with, as closures read for every line.
    struct Environment: Sendable {
        /// The folder lines are written into now.
        var folder: @Sendable () -> URL
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
        guard let data = "\(Date()): \(message)\n".data(using: .utf8) else { return }
        queue.async { [self] in
            write(data, to: file)
        }
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
            try Self.append(data, to: folder.appendingPathComponent(file.rawValue, isDirectory: false))
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
    /// missing and rotating it first once it has reached the cap.
    ///
    /// The legacy `seekToEndOfFile`/`write(_:)` calls raised Objective-C
    /// exceptions on a failed write and took the whole app down (observed
    /// with ENOSPC); the throwing FileHandle calls report failures as errors
    /// instead. The end offset `seekToEnd()` returns doubles as the size
    /// check that decides whether to rotate before writing.
    private static func append(_ data: Data, to logFile: URL) throws {
        guard FileManager.default.fileExists(atPath: logFile.path) else {
            try data.write(to: logFile)
            return
        }
        let handle = try FileHandle(forWritingTo: logFile)
        let currentSize = try handle.seekToEnd()
        if currentSize >= TextMouthPaths.maxLogFileSize {
            try handle.close()
            rotate(logFile)
            try data.write(to: logFile)
        } else {
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
        }
    }

    /// Keeps the full log as its one `.previous` generation and lets the
    /// caller start a fresh file, so a log never takes more than two
    /// generations. Failures leave the current file in place.
    private static func rotate(_ logFile: URL) {
        let rotated = logFile.appendingPathExtension(TextMouthPaths.rotatedLogExtension)
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: logFile, to: rotated)
    }
}
