import Combine
import Foundation

/// The person's own interface lines in force (FR39): the lines of `interface_text.json` in the data directory that apply,
/// handed to the engine (`InterfaceTextEngine.setOverrides`), and what came of reading the file, for the Interface
/// Language group of Settings and the debug log.
///
/// **Reading.** The file is read once the library is open (`start()`, from the library model's launch), again when the
/// library's launch files arrive from the cloud (`fileMayHaveArrived()`), after a move of the data directory, when the app
/// becomes active, and on every change of the file, through the app's one file watcher (`FileEventWatcher`). Every read
/// goes to a background queue, refuses to download a file that is only in the cloud, and is read, checked, and applied
/// without holding the first window back. A read that a newer one overtakes is dropped.
///
/// **Applying.** A change in the lines in force reaches the open windows as a switch of language does
/// (`InterfaceLanguage.refresh`): SwiftUI bodies read their lines again, and the menus and window titles follow.
///
/// **Writing.** This type never writes the file. Only Edit Interface Text… (`fillFileForEditing`, the Mac) and the person do.
/// No launch, sync, or move of the data directory writes it, so a data directory in the cloud sees no write at launch.
///
/// **The log.** One `INTERFACE_TEXT_LOADED` line for each change of what the file comes to (counts), and one
/// `INTERFACE_TEXT_IGNORED` line for each ignored line (ID, language, reason), in English.
@MainActor
final class InterfaceTextOverrides: ObservableObject {
    /// The service the apps use: the app's engine, the file in the data directory in use.
    static let shared = InterfaceTextOverrides()

    /// What reading the file came to, as of the last read that changed anything.
    @Published private(set) var outcome: InterfaceTextOverridesOutcome = .empty

    // MARK: - Settings (fixed at creation)

    private let engine: InterfaceTextEngine
    /// The file, as the data directory in use names it now.
    private let fileURL: @MainActor () -> URL
    /// Whether the data directory is unavailable now (FR02): nothing is read or watched while it is.
    private let isUnavailable: @MainActor () -> Bool
    /// Tells the open windows to read their lines again.
    private let linesDidChange: @MainActor () -> Void
    /// Where a log line goes: the app's debug log.
    private let log: @MainActor (String) -> Void
    private let calls: FileEventWatcher.Calls
    private let quietPeriod: Duration
    /// The pauses before each look for a file that is not there (tests shorten them).
    private let retryDelays: [Duration]

    // MARK: - State

    /// The bytes last read, so that a read of the same bytes is not checked again.
    private var lastData: Data?
    /// The number of the latest read asked for: an older read that returns after it is dropped.
    private var readNumber = 0
    private var hasStarted = false
    private var subscriptions: Set<AnyCancellable> = []
    private lazy var watcher = FileEventWatcher(
        file: { [weak self] in self?.fileURL() },
        isAvailable: { [weak self] in self.map { !$0.isUnavailable() } ?? false },
        quietPeriod: quietPeriod,
        retryDelays: retryDelays,
        calls: calls,
        settled: { [weak self] _ in self?.reload() }
    )

    /// A service over `engine` and the file `fileURL` names. The app's own passes none of them; tests pass an engine over
    /// tables of their own, a file in their sandbox, and recorders.
    init(
        engine: InterfaceTextEngine = .shared,
        fileURL: @escaping @MainActor () -> URL = { TextMouthPaths.interfaceTextFile },
        isUnavailable: @escaping @MainActor () -> Bool = { TextMouthPaths.isDataDirectoryUnavailable },
        linesDidChange: @escaping @MainActor () -> Void = { InterfaceLanguage.refresh() },
        log: @escaping @MainActor (String) -> Void = { DiagnosticLog.event(.app, $0) },
        calls: FileEventWatcher.Calls = .system,
        quietPeriod: Duration = .milliseconds(300),
        retryDelays: [Duration] = FileEventWatcher.defaultRetryDelays
    ) {
        self.engine = engine
        self.fileURL = fileURL
        self.isUnavailable = isUnavailable
        self.linesDidChange = linesDidChange
        self.log = log
        self.calls = calls
        self.quietPeriod = quietPeriod
        self.retryDelays = retryDelays
    }

    // MARK: - Starting

    /// Reads the file and follows it from now on. The library model calls it once the library is open; a second call does
    /// nothing. The first read never holds anything back: it runs on a background queue.
    func start(observing center: NotificationCenter = .default) {
        guard !hasStarted else { return }
        hasStarted = true
        watcher.start()
        // The data directory came back after it was missing, or another folder became it: the file is where the data
        // directory is now, so the watcher moves to it and the file is read again.
        center.publisher(for: .dataDirectoryDidBecomeAvailable)
            .merge(with: center.publisher(for: .dataDirectoryDidMove))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.dataDirectoryChanged() }
            .store(in: &subscriptions)
        // A file the person made while the app ran has no watcher yet, and one saved while the app was in the background
        // may have been missed.
        center.publisher(for: PlatformApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.dataDirectoryChanged() }
            .store(in: &subscriptions)
        reload()
    }

    /// Stops following the file: for tests, and for the end of the app.
    func stop() {
        watcher.stop()
        subscriptions.removeAll()
        hasStarted = false
        readNumber += 1
    }

    /// The file may have come down from the cloud (the library's launch files, `LibraryLaunchFileTakeUp`): reads it.
    func fileMayHaveArrived() {
        watcher.rearm()
        reload()
    }

    /// The data directory is another folder, or is back: follows the file to where it is now, and reads it.
    private func dataDirectoryChanged() {
        watcher.rearm()
        reload()
    }

    // MARK: - Reading

    /// What one read of the file found.
    private enum Read: Sendable {
        /// No file: no lines and no problem.
        case missing
        /// The file is only in the cloud, or the pack is not there to check it against: nothing changes.
        case notNow
        /// The same bytes as the last read: nothing changes.
        case same
        /// The file exists and could not be read (or is no regular file).
        case unreadable
        /// The file is larger than any file of lines can be.
        case tooLarge
        /// The name holds something that is not a regular file.
        case notARegularFile
        /// The file's bytes, and what checking them came to.
        case read(Data, InterfaceTextOverridesOutcome)
    }

    /// Reads the file on a background queue, then applies what it found. Asking again before the read returns drops the
    /// first read's answer.
    func reload() {
        guard hasStarted, !isUnavailable() else { return }
        readNumber += 1
        let number = readNumber
        let url = fileURL()
        let previous = lastData
        let engine = engine
        Task { [weak self] in
            let read = await OffMainWork.run { Self.read(url, previous: previous, engine: engine) }
            self?.finish(read, number: number)
        }
    }

    /// What `url` names now: nothing, a regular file (or a link to one), or something else (a folder, a pipe, a link to
    /// nothing). Only the first is "no file", which is no problem; the last is one, and Edit never writes over it.
    private enum Kind { case missing, regular, other }

    /// The kind of thing at `url`, by the file system's own answer (`stat` follows a link, `lstat` does not).
    private nonisolated static func kind(of url: URL) -> Kind {
        var info = stat()
        if stat(url.path, &info) == 0 { return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) ? .regular : .other }
        var link = stat()
        // A link whose target is not there: something is at the name, and it is not a file.
        return lstat(url.path, &link) == 0 ? .other : .missing
    }

    /// The bytes of the file at `url`, read with a bound and only if it is a regular file (`SmallTextFile`: a FIFO by that
    /// name would block forever, and a huge file would be read whole), and never downloaded from the cloud.
    /// - Returns: nil when the file is larger than `InterfaceTextOverridesFile.largestSize`.
    /// - Throws: the error reading it, a refusal to download (`DatalessFiles.isDownloadRefusal`), or a missing file.
    private nonisolated static func bytes(at url: URL) throws -> Data? {
        try DatalessFiles.withoutDownloading { try SmallTextFile.data(at: url, byteLimit: InterfaceTextOverridesFile.largestSize) }
    }

    /// Reads and checks the file at `url`, off the main thread. Never downloads a file that is only in the cloud.
    private nonisolated static func read(_ url: URL, previous: Data?, engine: InterfaceTextEngine) -> Read {
        let data: Data
        do {
            guard kind(of: url) != .other else { return .notARegularFile }
            guard let bytes = try bytes(at: url) else { return .tooLarge }
            data = bytes
        } catch {
            if DatalessFiles.isDownloadRefusal(error) { return .notNow }
            return Self.isMissingFile(error) ? .missing : .unreadable
        }
        if data == previous { return .same }
        // The English of the pack is what each line is checked against, and nothing else (no notes are decoded); with no
        // pack nothing can be checked, so nothing changes.
        guard let reference = engine.reference(language: "en", withNotes: false) else { return .notNow }
        return .read(data, InterfaceTextOverridesFile.read(data, reference: reference))
    }

    /// Records that Edit Interface Text… could not do its work, as `INTERFACE_TEXT_EDIT_FAILED: <reason>` (an event of the
    /// app category). The reason is English and holds no path or line text.
    nonisolated static func logEditFailure(_ reason: String) {
        DiagnosticLog.event(.app, "INTERFACE_TEXT_EDIT_FAILED: \(reason)")
    }

    /// Records that Export Interface Text… could not do its work, as `INTERFACE_TEXT_EXPORT_FAILED: <reason>`.
    nonisolated static func logExportFailure(_ reason: String) {
        DiagnosticLog.event(.app, "INTERFACE_TEXT_EXPORT_FAILED: \(reason)")
    }

    /// `error` as the log may hold it: its domain and code, never a path.
    nonisolated static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)" // l10n: no (debug log text)
    }

    /// Whether `error` says the file is not there.
    private nonisolated static func isMissingFile(_ error: Error) -> Bool {
        (error as? CocoaError)?.code == .fileReadNoSuchFile || (error as NSError).code == NSFileNoSuchFileError
    }

    /// Applies what a read found, unless a newer read has been asked for since.
    private func finish(_ read: Read, number: Int) {
        guard number == readNumber else { return }
        switch read {
        case .notNow, .same:
            return
        case .missing:
            lastData = nil
            adopt(.empty)
        case .unreadable:
            // The lines in force stay, as the person may be partway through a save; the problem shows. The bytes last read
            // are forgotten, so the same bytes read well later are checked and applied, and the problem goes.
            lastData = nil
            var kept = outcome
            kept.fileProblem = .unreadable
            adopt(kept)
        case .tooLarge:
            lastData = nil
            adopt(.ignoredWhole(.tooLarge))
        case .notARegularFile:
            // As an unreadable file: the lines in force stay, and the problem shows.
            lastData = nil
            var kept = outcome
            kept.fileProblem = .notARegularFile
            adopt(kept)
        case .read(let data, let checked):
            lastData = data
            adopt(checked)
        }
    }

    /// Makes `checked` what the file comes to: the engine takes its lines, the windows read theirs again when the lines
    /// in force changed, and the log says what happened.
    private func adopt(_ checked: InterfaceTextOverridesOutcome) {
        let before = outcome
        guard checked != before else { return }
        outcome = checked
        if checked.lines != before.lines {
            engine.setOverrides(checked.lines)
            linesDidChange()
        }
        writeLog(for: checked, before: before)
    }

    // MARK: - The log

    /// The most ignored lines the log names; the rest are one line with their count.
    static let largestIgnoredLog = 100

    /// One `INTERFACE_TEXT_LOADED` line for what the file comes to, and one `INTERFACE_TEXT_IGNORED` line for each of the
    /// first 100 ignored lines (then one with the count of the rest), or for the whole file; in English, holding only IDs
    /// and language codes the app knows (`logged`), never a line's text.
    private func writeLog(for checked: InterfaceTextOverridesOutcome, before: InterfaceTextOverridesOutcome) {
        var counts = "\(checked.inUse.count) lines in use, \(checked.ignored.count) ignored, \(checked.unchanged) left alone" // l10n: no (debug log text)
        switch checked.fileProblem {
        case nil: break
        // An unreadable file leaves the lines in use: it is not ignored whole.
        case .unreadable?, .notARegularFile?: counts += ", the file could not be read and the lines in use stay" // l10n: no (debug log text)
        case .some: counts += ", the whole file ignored" // l10n: no (debug log text)
        }
        log("INTERFACE_TEXT_LOADED: \(counts)")
        if let problem = checked.fileProblem {
            log("INTERFACE_TEXT_IGNORED: the whole file: \(problem.logSentence)") // l10n: no (debug log text)
        }
        for ignored in checked.ignored.prefix(Self.largestIgnoredLog) {
            let id = Self.logged(ignored.key.id, isKnown: ignored.idIsKnown)
            // The carried language's code, never the key as written, which may hold anything after a carried prefix.
            let language = ignored.carriedLanguage ?? Self.logged(ignored.key.language, isKnown: false)
            log("INTERFACE_TEXT_IGNORED: line \(id) in \(language): \(ignored.reason.logSentence)") // l10n: no (debug log text)
        }
        if checked.ignored.count > Self.largestIgnoredLog {
            log("INTERFACE_TEXT_IGNORED: and \(checked.ignored.count - Self.largestIgnoredLog) more lines") // l10n: no (debug log text)
        }
    }

    /// `key` as the log may hold it: as it is when the app knows it (an ID the pack has, a language it carries), since those are
    /// the app's own words; any other key is the person's content, so only its length is logged.
    nonisolated static func logged(_ key: String, isKnown: Bool) -> String {
        isKnown ? key : "(\(key.count) characters)" // l10n: no (debug log text)
    }

    // MARK: - Writing for Edit Interface Text…

    /// What filling the file for editing came to.
    enum FillResult: Equatable {
        /// The file was made, or the interface language was added to it.
        case written
        /// The file was left as it is: it has the language, or the person is mending it.
        case leftAsItIs
        /// The file's `version` is not one this TextMouth knows, so it was left as it is.
        case unknownVersion
        /// The file could not be written; the system's reason, in English, for the log.
        case failed(String)
    }

    /// The file's place, for opening it.
    var file: URL { fileURL() }

    /// Fills the file for editing, on the person's request only (the Mac's Edit Interface Text…): when the file does not
    /// exist yet, or lacks the interface language, it is written with every line of the language as the pack has it now
    /// (`InterfaceTextOverridesWriter.filled`); otherwise it is left as it is. A file only in the cloud is never written
    /// over: it is left as it is, for the editor to download; neither is a file whose `version` is not known. The reading,
    /// the checking, and the writing of a file of about 2 MB run on a background queue.
    func fillFileForEditing(language: String = InterfaceLanguage.current.language) async -> FillResult {
        guard !isUnavailable() else { return .failed("the data directory is not available") } // l10n: no (debug log text)
        let url = fileURL()
        let engine = engine
        let result = await OffMainWork.run { Self.fill(url, language: language, engine: engine) }
        if result == .written {
            // The watcher is told at once, and the file read again, so what was written shows as the lines in force (none,
            // since every line equals its base).
            watcher.rearm()
            reload()
        }
        return result
    }

    /// The work of `fillFileForEditing`, off the main thread.
    private nonisolated static func fill(_ url: URL, language: String, engine: InterfaceTextEngine) -> FillResult {
        var existing: Data?
        // Never written over: a folder, a pipe, or a link (to nothing too) is not a file TextMouth made or may replace.
        if kind(of: url) == .other { return .failed("what the file's name holds is not a regular file") } // l10n: no (debug log text)
        do {
            guard let bytes = try bytes(at: url) else { return .leftAsItIs }
            existing = bytes
        } catch {
            if DatalessFiles.isDownloadRefusal(error) { return .leftAsItIs }
            guard isMissingFile(error) else { return .failed(describe(error)) }
        }
        if let existing, InterfaceTextOverridesWriter.hasUnknownVersion(existing) { return .unknownVersion }
        guard let reference = engine.reference(language: language),
              let data = InterfaceTextOverridesWriter.filled(existing: existing, reference: reference)
        else { return .leftAsItIs }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return .failed(describe(error))
        }
        return .written
    }

    // MARK: - Export Interface Text…

    /// The bytes an Export writes for `language`: every line as it reads now, the person's own lines in place of the pack's
    /// and marked, with each line's English and note, and no `base`. Nil when there is no pack to export from.
    func exportData(language: String = InterfaceLanguage.current.language) -> Data? {
        guard let reference = engine.reference(language: language) else { return nil }
        return InterfaceTextOverridesWriter.export(reference: reference, own: engine.ownLines[language] ?? [:])
    }

    /// The name an Export suggests: the file's own name with the language, so that it is not taken for the data
    /// directory's file.
    static func exportFileName(language: String) -> String {
        "interface_text-\(language).json" // l10n: no (a file's name on disk)
    }
}
