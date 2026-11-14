import Foundation

/// TextMouth's one policy for its diagnostic logs: what a line may say,
/// which lines are written, and how many (TODO Q07). Log lines go through
/// here, to `TextMouthPaths.appendLog` and the log writer beneath it
/// (`LogWriter`), which writes them without ever blocking or crashing the
/// app and rotates each file at 2 MB into a single `.previous` generation.
/// Nothing else calls that writer, as `LogContentPolicyTests` checks.
///
/// ## What a line may contain
///
/// The logs never leave the user's Mac, but they are still no place for what
/// the user reads:
/// - **Never book text.** No chapter text, excerpt, spoken chunk, heading,
///   bookmark note, search result, or accessibility label (a label can be any
///   of those). Log offsets, lengths, counts, and indexes instead.
/// - **Never the contents of substitution rules.** Their patterns and
///   replacements are the user's own words, often taken from a book. Log how
///   many rules there are, or which one by position.
/// - **File names and package-relative paths, never absolute paths.** Every
///   line is written with the data directory's location removed from the
///   paths in it (`Library/Fiction/Dune-…tmb/content.md`), and
///   `loggablePath(_:)` names anything outside the data directory by its name
///   alone.
/// - **Book titles only in `event` lines.** A trace line names a book by the
///   first eight characters of its ID.
///
/// `LogContentPolicyTests` scans the source for log calls that break these
/// rules.
///
/// ## Which lines are written
///
/// - `event`: a one-off line worth having whenever it happens: a failure, a
///   fallback, a repair, a migration, a sleep timer starting or expiring.
///   Most begin with an upper-case tag (`IMPORT_FAILED:`, `FOLDER_REPAIR:`)
///   that tooling and the TODO search for, so a tag never changes. Event
///   lines are always written, exactly as given apart from the content rules,
///   and echoed to the console.
/// - `trace`: routine chatter, logged on every tick or playback event:
///   positions, skips, chapter changes, look-ahead renders, speech chunks,
///   VoiceOver focus attempts, media-route bookkeeping. Trace lines are
///   written only while tracing is on (see `TraceSwitch`), marked
///   `TRACE <category>:`, and at most `traceLinesPerSecond` a second in each
///   category; the lines over that limit are dropped and counted, and one
///   `TRACE_SUPPRESSED:` line in the debug log reports them, at most once a
///   minute for each category.
enum DiagnosticLog {

    // MARK: - Levels, Categories, and Files

    /// Whether a line is always written, or only while tracing.
    enum Level: Sendable {
        /// A one-off line: always written.
        case event
        /// Routine chatter: written only while tracing is on, within the
        /// rate limit.
        case trace
    }

    /// The part of the app a line is about. Trace lines are rate-limited
    /// separately in each category and marked with its name.
    enum Category: String, CaseIterable, Sendable {
        /// Speech, audiobook playback, chapters, the sleep timer, and media
        /// controls.
        case playback
        /// VoiceOver focus requests in windows and sheets.
        case focus
        /// Importing books and reading their files.
        case `import`
        /// The data directory: the library index, book packages, settings,
        /// and migrations.
        case storage
        /// Listening statistics.
        case statistics
        /// The app as a whole: its launch, and the app-wide actions it
        /// routes to its windows (`LibraryWindowRouter`).
        case app
        /// Podcast and article feeds (FR03): their records, refreshes, and
        /// downloads. Lines name a feed's host, never its whole address,
        /// which can carry a private feed's token.
        case feeds
    }

    /// The log files, all in one folder: the data directory's Logs folder,
    /// or this Mac's ~/Library/Logs/TextMouth, as Storage settings choose
    /// and the data directory allows (`TextMouthPaths.logDestination`). Each
    /// keeps at most two generations: itself and one `.previous`.
    enum File: String, CaseIterable, Sendable {
        /// The main log: every line that has no log of its own below.
        case debug = "textmouth_debug.log"
        /// The sleep timer's log: each timer from start to expiry, with the
        /// shortcuts and window routing that reached it.
        case sleepTimer = "textmouth_timer.log"
        /// Speech's log: the switches between direct speech and rendered
        /// audio, and how each chunk of direct speech started and finished.
        case speechTransitions = "textmouth_transition.log"

        /// Where the file is now: in the folder lines go to now.
        var url: URL {
            TextMouthPaths.logsDir.appendingPathComponent(rawValue)
        }
    }

    // MARK: - Limits

    /// How many trace lines of one category are written in a second, at
    /// most, and in one burst. A VoiceOver focus request writes about two
    /// dozen lines over its first second, so one passes whole; a flood, such
    /// as a held skip key, is cut to this rate.
    static let traceLinesPerSecond = 20

    /// The shortest time between two reports of dropped trace lines in one
    /// category.
    static let suppressionReportInterval: TimeInterval = 60

    /// The tag of the line that reports dropped trace lines.
    static let suppressionTag = "TRACE_SUPPRESSED"

    // MARK: - Writing Lines

    /// Writes `message` as an event: always, to `file`, and to the console.
    /// - Parameters:
    ///   - category: The part of the app the line is about.
    ///   - message: The line, normally beginning with its tag.
    ///   - file: The log to write it to: the debug log unless the line
    ///     belongs to the sleep timer's or speech's own log.
    static func event(_ category: Category, _ message: String, in file: File = .debug) {
        Gate.shared.record(.event, category, message, in: file)
    }

    /// Writes `message` as a trace line, while tracing is on and the rate
    /// limit allows. The message is not even built otherwise.
    /// - Parameters:
    ///   - category: The part of the app the line is about.
    ///   - message: The line. It must hold no book title (see the policy).
    ///   - file: The log to write it to.
    static func trace(_ category: Category, _ message: @autoclosure () -> String, in file: File = .debug) {
        Gate.shared.record(.trace, category, message(), in: file)
    }

    /// Writes `message` at `level`, for the helpers that log lines of both
    /// levels to one file.
    static func log(_ level: Level, _ category: Category, _ message: @autoclosure () -> String, in file: File = .debug) {
        Gate.shared.record(level, category, message(), in: file)
    }

    // MARK: - Content

    /// How a log line names the file or folder at `path`: its path inside the
    /// data directory, or only its name when it lies anywhere else. A relative
    /// path is already loggable and is returned as it is.
    static func loggablePath(_ path: String) -> String {
        loggablePath(path, dataDirectory: TextMouthPaths.root)
    }

    /// How a log line names the file or folder at `url` (see
    /// `loggablePath(_:)` for a path).
    static func loggablePath(_ url: URL) -> String {
        loggablePath(url.path)
    }

    /// `loggablePath(_:)` with the data directory given, so tests can supply
    /// their own.
    static func loggablePath(_ path: String, dataDirectory: URL) -> String {
        for prefix in dataDirectoryPrefixes(of: dataDirectory) where path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        guard path.hasPrefix("/") else { return path }
        return (path as NSString).lastPathComponent
    }

    /// `message` as a log line may hold it: on one line, every line break
    /// made a space so each entry stays one line, and with the data
    /// directory's location removed from every path in it.
    static func policed(_ message: String, dataDirectory: URL) -> String {
        let oneLine = message.components(separatedBy: .newlines).joined(separator: " ")
        return dataDirectoryPrefixes(of: dataDirectory).reduce(oneLine) { line, prefix in
            line.replacingOccurrences(of: prefix, with: "")
        }
    }

    /// The ways a path inside `dataDirectory` can begin, each ending in a
    /// slash, longest first so that no spelling is cut out of a longer one.
    ///
    /// The system reaches /var, /tmp, and /etc through /private, so a path
    /// there may be spelled either way: the app's own `/var/folders/…` and a
    /// resolved `/private/var/folders/…`. The root directory itself has no
    /// prefix to remove: stripping "/" would remove every slash.
    static func dataDirectoryPrefixes(of dataDirectory: URL) -> [String] {
        var path = dataDirectory.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        guard path.count > 1 else { return [] }
        var spellings = [path]
        if path.hasPrefix("/private/") {
            spellings.append(String(path.dropFirst("/private".count)))
        } else if ["/var/", "/tmp/", "/etc/"].contains(where: { path.hasPrefix($0) }) {
            spellings.append("/private" + path)
        }
        return spellings.map { $0 + "/" }.sortedStably { $0.count > $1.count }
    }

    /// The line reporting that `dropped` trace lines of `category` were
    /// dropped, at most `limit` a second being kept, the first of them at
    /// `firstDropped`.
    static func suppressionNote(
        _ dropped: TraceRateLimiter.DroppedLines,
        category: Category,
        limit: Int,
        firstDropped: Date
    ) -> String {
        let lines = dropped.count == 1 ? "line" : "lines"
        return "\(suppressionTag): dropped \(dropped.count) \(category.rawValue) trace \(lines) "
            + "since \(firstDropped), over the limit of \(limit) a second"
    }
}

// MARK: - The Trace Switch

extension DiagnosticLog {

    /// Whether trace lines are written. Tracing is off unless the developer
    /// turns it on, in either of two ways:
    /// - the environment variable `TEXTMOUTH_TRACE_LOG`, set to anything but
    ///   an empty value, `0`, `false`, `no`, or `off`, for one launch;
    /// - the hidden preference `diagnosticTraceLogging`, which has no control
    ///   in Settings: `defaults write com.textmouth.TextMouth
    ///   diagnosticTraceLogging -bool YES`, and `-bool NO` to turn it off.
    ///   It is read from the runtime's preferences store for every trace
    ///   line, so a change applies at once, and hosted tests use their own
    ///   sandboxed store.
    enum TraceSwitch {
        /// The environment variable that turns tracing on for one launch.
        static let environmentVariable = "TEXTMOUTH_TRACE_LOG"

        /// The hidden preference that turns tracing on until turned off.
        /// Read leniently, so `-bool YES`, `-int 1`, and `-string true` all
        /// count.
        static let preference = StoredPreference<Bool>(
            key: "diagnosticTraceLogging",
            read: { store, key in store.bool(forKey: key) },
            write: { value, store, key in store.set(value, forKey: key) }
        )

        /// Values of the environment variable that leave tracing off.
        private static let offValues: Set<String> = ["", "0", "false", "no", "off"]

        /// Whether a process with `environment` traces from launch.
        static func environmentTurnsTracingOn(_ environment: [String: String]) -> Bool {
            guard let value = environment[environmentVariable] else { return false }
            return !offValues.contains(value.trimmingCharacters(in: .whitespaces).lowercased())
        }

        /// Whether tracing is on, given what the environment says and the
        /// preferences store that may hold the hidden preference.
        static func isOn(environmentTurnsTracingOn: Bool, preferences: UserDefaults) -> Bool {
            environmentTurnsTracingOn || preference.read(from: preferences)
        }

        /// Whether this process traces now. The environment cannot change
        /// while the app runs, so it is read once.
        static var isOnInThisProcess: Bool {
            isOn(
                environmentTurnsTracingOn: processEnvironmentTurnsTracingOn,
                preferences: TextMouthRuntime.current.preferences
            )
        }

        /// What this process's environment says, read at first use.
        private static let processEnvironmentTurnsTracingOn =
            environmentTurnsTracingOn(ProcessInfo.processInfo.environment)
    }
}

// MARK: - The Rate Limit

extension DiagnosticLog {

    /// The rate limit of one category's trace lines: a token bucket holding
    /// up to `linesPerSecond` tokens and refilled at that rate, one token per
    /// line written. It also counts the lines it drops, for one report at
    /// most every `reportInterval`.
    ///
    /// A pure value with no clock of its own: every call says when it is, in
    /// seconds of a monotonic clock, so tests can step through time.
    struct TraceRateLimiter: Sendable {
        /// What becomes of one trace line.
        struct Admission: Equatable, Sendable {
            /// Whether the line is written.
            let writesLine: Bool
            /// Lines dropped since the last report, to report before this
            /// line; nil when there is nothing to report yet.
            let droppedLines: DroppedLines?
        }

        /// Trace lines dropped since the last report.
        struct DroppedLines: Equatable, Sendable {
            /// How many were dropped.
            let count: Int
            /// How long ago, in seconds, the first of them was dropped.
            let secondsSinceFirst: TimeInterval
        }

        /// Lines written per second at most, and in one burst.
        let linesPerSecond: Int
        /// The shortest time between two reports of dropped lines.
        let reportInterval: TimeInterval

        /// Lines that may be written now, fractions included.
        private var tokens: Double
        /// When the tokens were last brought up to date.
        private var lastRefill: TimeInterval?
        /// Lines dropped since the last report.
        private var droppedCount = 0
        /// When the first of those lines was dropped.
        private var firstDrop: TimeInterval?
        /// When dropped lines were last reported.
        private var lastReport: TimeInterval?

        /// A limiter with a full bucket.
        init(
            linesPerSecond: Int = DiagnosticLog.traceLinesPerSecond,
            reportInterval: TimeInterval = DiagnosticLog.suppressionReportInterval
        ) {
            self.linesPerSecond = max(1, linesPerSecond)
            self.reportInterval = reportInterval
            tokens = Double(self.linesPerSecond)
        }

        /// Decide one line arriving at `now`: written while a token is left,
        /// dropped and counted otherwise. A line that is written carries the
        /// report of the lines dropped before it once the last report is at
        /// least `reportInterval` old, so a burst is reported as soon as the
        /// limit lets a line through again, and a lasting flood once a
        /// `reportInterval`.
        mutating func admit(at now: TimeInterval) -> Admission {
            refill(at: now)
            // A token's worth less a rounding error still pays for a line.
            guard tokens >= 1 - 1e-9 else {
                droppedCount += 1
                if firstDrop == nil { firstDrop = now }
                return Admission(writesLine: false, droppedLines: nil)
            }
            tokens = max(0, tokens - 1)
            return Admission(writesLine: true, droppedLines: takeReport(at: now))
        }

        /// Add the tokens earned since the last refill, never more than a
        /// full bucket. A time earlier than the last refill adds nothing.
        private mutating func refill(at now: TimeInterval) {
            guard let lastRefill else {
                self.lastRefill = now
                return
            }
            guard now > lastRefill else { return }
            let earned = (now - lastRefill) * Double(linesPerSecond)
            tokens = min(Double(linesPerSecond), tokens + earned)
            self.lastRefill = now
        }

        /// The lines dropped since the last report, when there are any and
        /// that report is at least `reportInterval` old at `now`; reporting
        /// them starts a new count.
        private mutating func takeReport(at now: TimeInterval) -> DroppedLines? {
            guard droppedCount > 0, let firstDrop else { return nil }
            if let lastReport, now - lastReport < reportInterval { return nil }
            let report = DroppedLines(count: droppedCount, secondsSinceFirst: max(0, now - firstDrop))
            droppedCount = 0
            self.firstDrop = nil
            lastReport = now
            return report
        }
    }
}

// MARK: - The Gate

extension DiagnosticLog {

    /// Applies the policy to each line and hands what passes to the writer:
    /// events always, trace lines while tracing is on and their category's
    /// rate limit allows. The app uses `shared`; tests make their own, with
    /// their own switch, clock, data directory, and writer.
    ///
    /// `@unchecked Sendable`: the closures are `@Sendable` constants, and
    /// the one mutable property, the limiters, is only read or changed while
    /// holding `lock`.
    final class Gate: @unchecked Sendable {
        /// The gate the app's log lines pass.
        static let shared = Gate()

        /// Whether trace lines are written now.
        private let isTracing: @Sendable () -> Bool
        /// The current time, in seconds of a monotonic clock.
        private let now: @Sendable () -> TimeInterval
        /// The data directory whose location lines leave out.
        private let dataDirectory: @Sendable () -> URL
        /// Writes one finished line to one log file.
        private let write: @Sendable (_ line: String, _ file: File) -> Void
        /// Shows one event line in the console.
        private let echo: @Sendable (_ line: String) -> Void
        /// How many trace lines of a category are written a second.
        let traceLinesPerSecond: Int
        /// The shortest time between two reports of dropped lines.
        let reportInterval: TimeInterval

        /// Guards `limiters`: lines arrive from every thread.
        private let lock = NSLock()
        /// Each category's rate limit, made at its first trace line.
        private var limiters: [Category: TraceRateLimiter] = [:]

        /// A gate. The defaults are the app's: the trace switch, the system's
        /// uptime, the current data directory, the shared log writer, and
        /// standard output.
        init(
            isTracing: @escaping @Sendable () -> Bool = { TraceSwitch.isOnInThisProcess },
            now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            dataDirectory: @escaping @Sendable () -> URL = { TextMouthPaths.root },
            traceLinesPerSecond: Int = DiagnosticLog.traceLinesPerSecond,
            reportInterval: TimeInterval = DiagnosticLog.suppressionReportInterval,
            write: @escaping @Sendable (_ line: String, _ file: File) -> Void = { line, file in
                TextMouthPaths.appendLog(to: file, message: line)
            },
            echo: @escaping @Sendable (_ line: String) -> Void = { print($0) }
        ) {
            self.isTracing = isTracing
            self.now = now
            self.dataDirectory = dataDirectory
            self.traceLinesPerSecond = traceLinesPerSecond
            self.reportInterval = reportInterval
            self.write = write
            self.echo = echo
        }

        /// Write `message` at `level` to `file`, if the policy lets it
        /// through. A trace line's message is built only when it will be
        /// written.
        func record(_ level: Level, _ category: Category, _ message: @autoclosure () -> String, in file: File) {
            switch level {
            case .event:
                let line = DiagnosticLog.policed(message(), dataDirectory: dataDirectory())
                write(line, file)
                echo(line)
            case .trace:
                guard isTracing() else { return }
                let admission = admit(category)
                if let dropped = admission.droppedLines {
                    let firstDropped = Date().addingTimeInterval(-dropped.secondsSinceFirst)
                    write(
                        DiagnosticLog.suppressionNote(
                            dropped,
                            category: category,
                            limit: traceLinesPerSecond,
                            firstDropped: firstDropped
                        ),
                        .debug
                    )
                }
                guard admission.writesLine else { return }
                let line = DiagnosticLog.policed(message(), dataDirectory: dataDirectory())
                write("TRACE \(category.rawValue): \(line)", file)
            }
        }

        /// Ask `category`'s rate limit about one trace line arriving now.
        private func admit(_ category: Category) -> TraceRateLimiter.Admission {
            lock.lock()
            defer { lock.unlock() }
            let fresh = TraceRateLimiter(linesPerSecond: traceLinesPerSecond, reportInterval: reportInterval)
            return limiters[category, default: fresh].admit(at: now())
        }
    }
}
