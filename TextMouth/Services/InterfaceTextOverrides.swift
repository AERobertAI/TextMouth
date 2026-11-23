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
        quietPeriod: Duration = .milliseconds(300)
    ) {
        self.engine = engine
        self.fileURL = fileURL
        self.isUnavailable = isUnavailable
        self.linesDidChange = linesDidChange
        self.log = log
        self.calls = calls
        self.quietPeriod = quietPeriod
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
        /// The file exists and could not be read.
        case unreadable
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

    /// Reads and checks the file at `url`, off the main thread. Never downloads a file that is only in the cloud.
    private nonisolated static func read(_ url: URL, previous: Data?, engine: InterfaceTextEngine) -> Read {
        let data: Data
        do {
            data = try DatalessFiles.withoutDownloading { try Data(contentsOf: url) }
        } catch {
            if DatalessFiles.isDownloadRefusal(error) { return .notNow }
            return Self.isMissingFile(error) ? .missing : .unreadable
        }
        if data == previous { return .same }
        // The English of the pack is what each line is checked against; with no pack nothing can be checked, so nothing
        // changes.
        guard let reference = engine.reference(language: "en") else { return .notNow }
        return .read(data, InterfaceTextOverridesFile.read(data, reference: reference))
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
            // The lines in force stay, as the person may be partway through a save; the problem shows.
            var kept = outcome
            kept.fileProblem = .unreadable
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

    /// One `INTERFACE_TEXT_LOADED` line for what the file comes to, and one `INTERFACE_TEXT_IGNORED` line for each ignored
    /// line, or for the whole file; in English, holding IDs and language codes of lines (never a line's text).
    private func writeLog(for checked: InterfaceTextOverridesOutcome, before: InterfaceTextOverridesOutcome) {
        log("INTERFACE_TEXT_LOADED: \(checked.inUse.count) lines in use, \(checked.ignored.count) ignored, \(checked.unchanged) left alone" // l10n: no (debug log text)
            + (checked.fileProblem == nil ? "" : ", the whole file ignored")) // l10n: no (debug log text)
        if let problem = checked.fileProblem {
            log("INTERFACE_TEXT_IGNORED: the whole file: \(problem.logSentence)") // l10n: no (debug log text)
        }
        for ignored in checked.ignored {
            log("INTERFACE_TEXT_IGNORED: line \(Self.loggable(ignored.key.id)) in \(Self.loggable(ignored.key.language)): \(ignored.reason.logSentence)") // l10n: no (debug log text)
        }
    }

    /// `text` as the log may hold it. An ID or a language code is ASCII letters, digits, and dots; the person's file may
    /// hold anything as a key, so a key is kept to those characters and to 64 of them, and shown as a count otherwise.
    nonisolated static func loggable(_ text: String) -> String {
        let allowed = text.unicodeScalars.allSatisfy { scalar in
            (0x30...0x39).contains(scalar.value) || (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
                || scalar == "." || scalar == "-"
        }
        guard allowed, text.count <= 64 else { return "(\(text.count) characters)" } // l10n: no (debug log text)
        return text
    }

    // MARK: - Writing for Edit Interface Text…

    /// What filling the file for editing came to.
    enum FillResult: Equatable {
        /// The file was made, or the interface language was added to it.
        case written
        /// The file was left as it is: it has the language, or the person is mending it.
        case leftAsItIs
        /// The file could not be written; the system's reason, in English, for the log.
        case failed(String)
    }

    /// The file's place, for opening it.
    var file: URL { fileURL() }

    /// Fills the file for editing, on the person's request only (the Mac's Edit Interface Text…): when the file does not
    /// exist yet, or lacks the interface language, it is written with every line of the language as the pack has it now
    /// (`InterfaceTextOverridesWriter.filled`); otherwise it is left as it is. A file only in the cloud is never written
    /// over: it is left as it is, for the editor to download.
    func fillFileForEditing(language: String = InterfaceLanguage.current.language) -> FillResult {
        guard !isUnavailable() else { return .failed("the data directory is not available") } // l10n: no (debug log text)
        let url = fileURL()
        var existing: Data?
        do {
            existing = try DatalessFiles.withoutDownloading { try Data(contentsOf: url) }
        } catch {
            if DatalessFiles.isDownloadRefusal(error) { return .leftAsItIs }
            guard Self.isMissingFile(error) else { return .failed(String(describing: error)) }
        }
        guard let reference = engine.reference(language: language),
              let data = InterfaceTextOverridesWriter.filled(existing: existing, reference: reference)
        else { return .leftAsItIs }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return .failed(String(describing: error))
        }
        // The watcher is told at once, and the file read again, so what was written shows as the lines in force (none,
        // since every line equals its base).
        watcher.rearm()
        reload()
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
