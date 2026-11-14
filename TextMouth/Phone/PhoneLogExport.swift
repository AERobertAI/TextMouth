import Foundation

/// Gathers TextMouth's recent logs into one text file, for Settings' Share
/// Logs… on the phone (the iPhone interface spec, under "Settings"): without
/// this, a first run on a phone can't be diagnosed.
///
/// The logs hold no book text, as `LogContentPolicyTests` requires of every
/// line, so the file doesn't either. It's capped at about 2 MB, by keeping
/// the newest text. Each log gets a fair share of that, and whatever a small
/// log doesn't need goes to the large ones, so a busy debug log can't crowd
/// out the sleep timer's or speech's. Within a log, the newest generation
/// comes first, and its older one, `.previous`, gets what it leaves. The file
/// reads in time order within each log, under a heading naming the log by its
/// place, never by an absolute path. A log only in the cloud is left where it
/// is, never downloaded, as `LogWriter` treats one.
enum PhoneLogExport {
    /// About how much text the file holds, leaving out its headings: as much
    /// as one full log.
    static let byteLimit = Int(TextMouthPaths.maxLogFileSize)

    /// The file's name, as whoever receives it sees it.
    static let fileName = "TextMouth Logs.txt"

    /// What a gathering works with, as closures read while it runs, so a test
    /// can give it a sandbox and never touch a real log.
    struct Environment: Sendable {
        /// Writes out the lines queued so far, so the file holds them too.
        /// Blocks, which is why it runs off the main thread.
        var flush: @Sendable () -> Void
        /// The folders that can hold logs, the one in use first.
        var logFolders: @Sendable () -> [URL]
        /// The file's first line.
        var heading: @Sendable () -> String
        /// The folder the file is written in, which is made when it's missing.
        /// A fixed one, so a later gathering replaces the file, and no copies
        /// pile up.
        var scratchFolder: @Sendable () -> URL
        /// Whether a file's content is only in the cloud, so reading it would
        /// download it first; tests say so of files that aren't.
        var isOnlyInCloud: @Sendable (_ file: URL) -> Bool
        /// About how much text the file holds; tests give a small figure.
        var byteLimit: Int

        /// An environment of the given parts, asking the file system which
        /// files are only in the cloud, and holding as much as the app's file,
        /// unless a test says otherwise.
        init(
            flush: @escaping @Sendable () -> Void,
            logFolders: @escaping @Sendable () -> [URL],
            heading: @escaping @Sendable () -> String,
            scratchFolder: @escaping @Sendable () -> URL,
            isOnlyInCloud: @escaping @Sendable (_ file: URL) -> Bool = { DatalessFiles.isDataless($0) },
            byteLimit: Int = PhoneLogExport.byteLimit
        ) {
            self.flush = flush
            self.logFolders = logFolders
            self.heading = heading
            self.scratchFolder = scratchFolder
            self.isOnlyInCloud = isOnlyInCloud
            self.byteLimit = byteLimit
        }

        /// The app's: its log writer, the folder lines go to now, then the
        /// other places they can go when that one can't take them, the build's
        /// identity as the heading, and a folder in the app's temporary
        /// directory, which the system clears as it needs to.
        static let app = Environment(
            flush: { LogWriter.shared.flush() },
            logFolders: {
                uniqueFolders([
                    TextMouthPaths.logDestination.folder,
                    TextMouthPaths.root.appendingPathComponent(TextMouthPaths.logsFolderName, isDirectory: true),
                    MachineLocalPaths.logs,
                ])
            },
            heading: { "\(BuildIdentity.current.diagnosticLine) gatheredAt=\(Date())" },
            scratchFolder: {
                FileManager.default.temporaryDirectory.appendingPathComponent("TextMouth Logs", isDirectory: true)
            }
        )
    }

    // MARK: - Gathering

    /// Writes the file off the main thread, replacing the last one, and
    /// returns where it is. Throws when the file can't be written, as on a
    /// full disk; a log that can't be read is left out instead.
    static func gather(in environment: Environment = .app) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            environment.flush()
            // A log the cloud takes away between looking and reading is
            // refused rather than downloaded, and left out like any other.
            let text = DatalessFiles.withoutDownloading { gatheredText(in: environment) }
            let folder = environment.scratchFolder()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(fileName, isDirectory: false)
            try Data(text.utf8).write(to: file, options: .atomic)
            return file
        }.value
    }

    /// `folders` with each folder once, in the order first given: the one in
    /// use is usually also one of the places logs can go.
    static func uniqueFolders(_ folders: [URL]) -> [URL] {
        var seen = Set<String>()
        return folders.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// How much of `limit` each log gets, given how much each holds: what it
    /// holds, when that fits an equal share of what's left, and otherwise an
    /// equal share. Going from the smallest up, what a small log doesn't need
    /// is left for the larger ones.
    static func shares(of limit: Int, among sizes: [Int]) -> [Int] {
        var shares = Array(repeating: 0, count: sizes.count)
        var left = limit
        let smallestFirst = sizes.indices.sortedStably { sizes[$0] < sizes[$1] }
        for (position, index) in smallestFirst.enumerated() {
            let equalShare = left / (smallestFirst.count - position)
            shares[index] = min(sizes[index], equalShare)
            left -= shares[index]
        }
        return shares
    }

    /// Whether the share sheet is done when it reports back. It reports with
    /// no activity when the person closes it, and with an activity once that's
    /// done. It also reports an activity not completed, as when a person backs
    /// out of Mail, while it stays open: that one isn't the end (REPORTED by
    /// developers; Apple's header says only that it's called "after activity
    /// performs or view controller is dismissed").
    static func shareSheetIsFinished(choseActivity: Bool, completed: Bool) -> Bool {
        completed || !choseActivity
    }

    // MARK: - The File's Text

    /// One generation of one log, and how much it holds now.
    private struct Generation {
        let file: URL
        let byteCount: Int
    }

    /// Everything the file says: the heading, then each log's newest text.
    private static func gatheredText(in environment: Environment) -> String {
        let logs = environment.logFolders().flatMap { folder in
            DiagnosticLog.File.allCases.map { generations(of: $0, in: folder, environment: environment) }
        }
        let allotted = shares(of: environment.byteLimit, among: logs.map { $0.reduce(0) { $0 + $1.byteCount } })
        return zip(logs, allotted).reduce(environment.heading() + "\n") { text, entry in
            text + sections(of: entry.0, upTo: entry.1)
        }
    }

    /// `log`'s generations in `folder`, the older one first, as they read in
    /// time. One missing, not a file, or only in the cloud holds nothing.
    private static func generations(
        of log: DiagnosticLog.File,
        in folder: URL,
        environment: Environment
    ) -> [Generation] {
        let current = folder.appendingPathComponent(log.rawValue, isDirectory: false)
        let previous = current.appendingPathExtension(TextMouthPaths.rotatedLogExtension)
        return [previous, current].map { file in
            Generation(file: file, byteCount: environment.isOnlyInCloud(file) ? 0 : byteCount(of: file))
        }
    }

    /// How much the regular file at `file` holds; 0 when there is none.
    private static func byteCount(of file: URL) -> Int {
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return 0 }
        return values?.fileSize ?? 0
    }

    /// The newest `share` bytes of `generations`, each under its heading. The
    /// newest generation is read first, so the older one has only what it
    /// leaves, and they're put back in time order.
    private static func sections(of generations: [Generation], upTo share: Int) -> String {
        var left = share
        var sections: [String] = []
        for generation in generations.reversed() where left > 0 && generation.byteCount > 0 {
            guard let bytes = try? newestBytes(of: generation.file, upTo: left), !bytes.isEmpty else { continue }
            left -= min(generation.byteCount, left)
            sections.insert(section(of: generation.file, holding: bytes), at: 0)
        }
        return sections.joined()
    }

    /// The last `byteCount` bytes of `file`, or the whole file when it's no
    /// longer. A cut starts on the next whole line, so no line is left in part
    /// and no character is cut in two; only one line too long to fit is left
    /// cut, since its newest end is better than nothing.
    private static func newestBytes(of file: URL, upTo byteCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let start = end - min(end, UInt64(byteCount))
        try handle.seek(toOffset: start)
        let bytes = try handle.read(upToCount: byteCount) ?? Data()
        guard start > 0,
              let newline = bytes.firstIndex(of: UInt8(ascii: "\n")),
              bytes.index(after: newline) < bytes.endIndex else {
            return bytes
        }
        return bytes.suffix(from: bytes.index(after: newline))
    }

    /// `bytes` of `file` under a heading naming the file by its folder's name
    /// and its own, as text. A byte that isn't UTF-8 becomes the replacement
    /// character, so the file is always plain text. The section ends its last
    /// line, so the next heading starts on its own.
    private static func section(of file: URL, holding bytes: Data) -> String {
        let place = file.deletingLastPathComponent().lastPathComponent + "/" + file.lastPathComponent
        let text = String(decoding: bytes, as: UTF8.self)
        return "\n=== \(place) ===\n" + text + (text.hasSuffix("\n") ? "" : "\n")
    }
}
