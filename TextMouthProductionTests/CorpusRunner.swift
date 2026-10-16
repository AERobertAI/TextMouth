import Foundation
@testable import TextMouth

// The walk behind the corpus report: finds the files of a folder, copies each
// into a sandbox, imports the copy off the main thread with a time limit, and
// turns what happened into a `CorpusFileEntry`. The report's wording is the
// builder's (`CorpusReport.swift`); the opt-in test that writes the report is
// `CorpusReportTests`.

// MARK: - Settings

/// The limits of a run, read from the environment so a person can change
/// them without touching the code.
struct CorpusSettings {
    /// The most files read; the rest are named in the report as cut.
    var maxFiles = 200
    /// How long one file's import may take before the walk goes on.
    var fileSeconds = 180

    /// The variable that sets `maxFiles`.
    static let maxFilesVariable = "TEXTMOUTH_CORPUS_MAX_FILES"
    /// The variable that sets `fileSeconds`.
    static let fileSecondsVariable = "TEXTMOUTH_CORPUS_FILE_SECONDS"

    /// The settings `environment` asks for. A value that is not a whole
    /// number of at least 1 is ignored, and the default stands.
    static func from(environment: [String: String]) -> CorpusSettings {
        var settings = CorpusSettings()
        if let value = environment[maxFilesVariable].flatMap({ Int($0) }), value >= 1 { settings.maxFiles = value }
        if let value = environment[fileSecondsVariable].flatMap({ Int($0) }), value >= 1 { settings.fileSeconds = value }
        return settings
    }
}

// MARK: - Result Box

/// A value one thread sets and another reads, so a file's import can run off
/// the main thread while the walk waits for it with a time limit.
final class CorpusResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    /// The value, once set; nil until then.
    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Sets the value. A second call is ignored: the first answer stands.
    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        if stored == nil { stored = newValue }
    }
}

// MARK: - Runner

/// Walks a corpus folder and imports what it finds, one file at a time.
///
/// The user's files are only ever read: each is copied into `sandbox` first
/// and the copy is imported, since an import may be followed by the deletion
/// of an original, depending on a setting (the deletion is the library's, and
/// this class never reaches it, but the copy keeps that true).
final class CorpusRunner {
    /// A file found in the folder.
    struct Item: Equatable {
        /// The path from the folder, with `/` between components.
        var relativePath: String
        var url: URL
    }

    /// The corpus folder (read only).
    let folder: URL
    /// The folder the files are copied into; the runner empties what it
    /// makes there and never touches anything else.
    let sandbox: URL
    /// The library folder, by path, that imports publish into. The runner
    /// removes each package it makes as soon as it has been read.
    let libraryFolderPath: String
    let settings: CorpusSettings

    init(folder: URL, sandbox: URL, libraryFolderPath: String, settings: CorpusSettings) {
        self.folder = folder
        self.sandbox = sandbox
        self.libraryFolderPath = libraryFolderPath
        self.settings = settings
    }

    // MARK: Walking

    /// Every regular file under `folder`, sorted by relative path. Hidden
    /// files (`.DS_Store` among them) and the insides of packages are left
    /// out; a package itself is not a file and is not listed.
    static func files(in folder: URL) -> [Item] {
        let base = folder.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var items: [Item] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base.path + "/") else { continue }
            items.append(Item(relativePath: String(path.dropFirst(base.path.count + 1)), url: url))
        }
        return items.sorted { $0.relativePath < $1.relativePath }
    }

    /// Reads the files of the folder, calling `progress` with the entries
    /// so far after each one so a report can be written as the run goes.
    /// - Returns: the entries, and how many files the folder holds.
    func run(progress: (_ entries: [CorpusFileEntry], _ foundCount: Int) -> Void) -> (entries: [CorpusFileEntry], foundCount: Int) {
        let found = Self.files(in: folder)
        var entries: [CorpusFileEntry] = []
        progress(entries, found.count)
        for (number, item) in found.prefix(settings.maxFiles).enumerated() {
            entries.append(entry(for: item, number: number))
            progress(entries, found.count)
        }
        return (entries, found.count)
    }

    // MARK: One File

    /// What becomes of one file: skipped when it is Ogg audio (or a ZIP of
    /// it), otherwise copied and imported with the time limit.
    func entry(for item: Item, number: Int) -> CorpusFileEntry {
        let name = item.url.lastPathComponent
        let ext = item.url.pathExtension.lowercased()
        // Ogg is never decoded in the test host (B06: Apple's Vorbis decoder
        // hung a Mac). A ZIP that holds Ogg would be converted by the import.
        if CorpusReportBuilder.oggExtensions.contains(ext) || (ext == "zip" && Self.zipHoldsOgg(item.url)) {
            return CorpusFileEntry(
                relativePath: item.relativePath, format: BookFormat.detect(from: item.url)?.displayName,
                outcome: .skipped(CorpusReportBuilder.oggSkipReason), importSeconds: nil
            )
        }

        // Copy first: the import works on the copy and the original is never
        // opened for writing.
        let copyFolder = sandbox.appendingPathComponent("copies/\(number)", isDirectory: true)
        let copy = copyFolder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: copyFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: item.url, to: copy)
        } catch {
            return CorpusFileEntry(
                relativePath: item.relativePath, format: nil,
                outcome: .refused("The file could not be copied into the test's sandbox: \(error.localizedDescription)"),
                importSeconds: nil
            )
        }
        let format = BookFormat.detect(from: copy)?.displayName

        let started = Date()
        let finished = importWithLimit(copy: copy, relativePath: item.relativePath)
        let seconds = Date().timeIntervalSince(started)

        let outcome: CorpusOutcome
        switch finished {
        case .some(.success(let facts)):
            outcome = .imported(facts)
        case .some(.failure(let error)):
            outcome = .refused(error.localizedDescription)
        case .none:
            // The import is still running and cannot be stopped; its copy
            // stays where it is until the sandbox is removed.
            return CorpusFileEntry(
                relativePath: item.relativePath, format: format,
                outcome: .timedOut(seconds: settings.fileSeconds), importSeconds: seconds
            )
        }
        // The import is over: the copy is no longer needed.
        try? FileManager.default.removeItem(at: copyFolder)
        return CorpusFileEntry(relativePath: item.relativePath, format: format, outcome: outcome, importSeconds: seconds)
    }

    /// Imports `copy` on a background queue and waits for it, at most
    /// `settings.fileSeconds`. Nil means it did not finish in time.
    private func importWithLimit(copy: URL, relativePath: String) -> Result<CorpusFacts, any Error>? {
        let libraryFolderPath = self.libraryFolderPath
        return Self.runWithLimit(seconds: TimeInterval(settings.fileSeconds)) {
            Result { try Self.importFacts(of: copy, named: relativePath, intoLibraryFolder: libraryFolderPath) }
        }
    }

    /// Runs `operation` on a background queue and waits for its value, at
    /// most `seconds`. Nil means it was not done in time; it then goes on
    /// running, since a thread cannot be stopped, and its value is dropped.
    /// The calling thread keeps its run loop turning while it waits, as an
    /// operation that hands work to the main queue needs.
    static func runWithLimit<Value: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () -> Value) -> Value? {
        let box = CorpusResultBox<Value>()
        DispatchQueue.global(qos: .userInitiated).async { box.set(operation()) }
        let deadline = Date().addingTimeInterval(seconds)
        while box.value == nil && Date() < deadline {
            // Turn the run loop for a slice; when it has no work it returns
            // at once, so sleep rather than spin.
            let slice = Date()
            RunLoop.current.run(mode: .default, before: slice.addingTimeInterval(0.05))
            if Date().timeIntervalSince(slice) < 0.01 { Thread.sleep(forTimeInterval: 0.02) }
        }
        return box.value
    }

    /// Imports `copy` as a reader does, reads it back, and records what it
    /// is. The package the import made is removed before this returns,
    /// whether or not the book could be read.
    static func importFacts(of copy: URL, named relativePath: String, intoLibraryFolder folderPath: String) throws -> CorpusFacts {
        let imported = try FileImportService.importFileWithReport(from: copy, toFolder: folderPath)
        defer { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }
        let opened = try BookContentAnalysisService.load(book: imported.book)
        let dump = DocumentDump(fileName: relativePath, book: imported.book, opened: opened, report: imported.report)
        return CorpusFacts(
            dump: dump, firstLines: CorpusReportBuilder.firstLines(of: opened.content.chapters.map(\.text))
        )
    }

    // MARK: ZIP

    /// Whether the ZIP at `url` lists an Ogg file, by the names the system's
    /// `unzip` prints. False when the listing cannot be made, so a damaged
    /// ZIP is imported (and refused) like any other.
    static func zipHoldsOgg(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        // Read before waiting so a long listing cannot fill the pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let names = String(decoding: data, as: UTF8.self).split(separator: "\n")
        return names.contains { name in
            CorpusReportBuilder.oggExtensions.contains((String(name) as NSString).pathExtension.lowercased())
        }
    }
}
