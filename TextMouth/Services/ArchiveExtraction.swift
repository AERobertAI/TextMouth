import Foundation
import ZIPFoundation

// MARK: - Cancellation

/// Asked between the steps of a long import whether the reader cancelled
/// it; the import stops at its next step once it returns true.
typealias ImportCancellationCheck = @Sendable () -> Bool

/// Thrown inside an import when its cancellation check says to stop. A ZIP
/// batch catches it and reports where it stopped, so it never reaches the
/// reader as a failure.
struct ImportCancelled: Error, Equatable {}

/// The cancellation the library's queued imports share (TODO I05):
/// cancelling it stops each of them at its next check. The library cancels
/// on the main thread while imports check on the import queue, so the flag
/// is locked.
final class ImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    /// Whether the imports sharing this cancellation are to stop.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Stops the imports sharing this cancellation at their next check.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// This cancellation as the check an import asks.
    var check: ImportCancellationCheck {
        { [self] in isCancelled }
    }

    /// Records in the console and the debug log that the import of
    /// `fileName` was cancelled, and where it stopped:
    /// `IMPORT_CANCELLED: <file>: <where>`, an event on one line
    /// (`DiagnosticLog`).
    static func log(_ fileName: String, stopped place: String) {
        DiagnosticLog.event(.import, "IMPORT_CANCELLED: \(fileName): \(place)")
    }
}

// MARK: - Extraction

/// Extracts ZIP archives for imports, entry by entry, within a budget
/// (TODO I05). It takes the place of ZIPFoundation's `unzipItem`, which
/// extracts a whole archive at once, with no bound on what it writes and no
/// way to stop it partway.
enum ArchiveExtractor {

    /// Opens the ZIP archive at `url` for reading.
    /// - Throws: Cocoa's "no such file" error when nothing is at `url`, and
    ///   `FileImportError.unreadableArchive` when ZIPFoundation cannot open
    ///   it, since its own errors carry no description a listener could use.
    static func open(_ url: URL) throws -> Archive {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            return try Archive(url: url, accessMode: .read)
        } catch {
            throw FileImportError.unreadableArchive
        }
    }

    /// Extracts the ZIP archive at `url` into `directory`, which is created
    /// if needed. The archive is inspected and admitted to `budget` before
    /// anything is written; then each entry is extracted in turn, the
    /// cancellation check asked before each one and between the chunks of a
    /// large one, and `progress` told the entries done of the total, at the
    /// start and then at most once per percent.
    ///
    /// Each file is held to the size the archive records for it and charged
    /// to `budget` as it is written, so an archive whose sizes lie stops at
    /// the first excess chunk. Every entry's path must lead inside
    /// `directory`; a link must point inside its own folder, as ZIPFoundation
    /// requires; and each file must match the checksum the archive stores.
    /// Whatever was extracted before a failure is left for the caller to
    /// remove with the directory.
    /// - Parameter nestedArchive: the name of an archive found inside the
    ///   archive being imported, which a refusal for lack of space names.
    /// - Throws: `ArchiveBudgetError` when the budget refuses the archive,
    ///   `ArchiveEntryOverflow` when a file holds more than it declares,
    ///   `ImportCancelled` when the check says to stop, `FileImportError`
    ///   when the archive is damaged or holds a path or link leading outside
    ///   it, and the file system's own error, such as a full disk, when
    ///   writing fails.
    static func extract(
        archiveAt url: URL,
        into directory: URL,
        budget: ArchiveBudget,
        nestedArchive: String? = nil,
        isCancelled: ImportCancellationCheck = { false },
        progress: ((_ done: Int, _ total: Int) -> Void)? = nil
    ) throws {
        let archive = try open(url)
        let inspection = ArchiveInspection(of: archive)
        try budget.admit(inspection, extractingInto: directory, nestedArchive: nestedArchive)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var report = ProgressReporter(total: inspection.entryCount, progress: progress)
        report(0)
        var done = 0
        for entry in archive {
            if isCancelled() { throw ImportCancelled() }
            do {
                try extract(entry, of: archive, into: directory, budget: budget, isCancelled: isCancelled)
            } catch Archive.ArchiveError.uncontainedSymlink {
                throw FileImportError.archiveLinksOutside
            } catch is Archive.ArchiveError {
                // ZIPFoundation's own errors carry no description a
                // listener could use.
                throw FileImportError.unreadableArchive
            }
            done += 1
            report(done)
        }
    }

    /// Where the entry at `path` goes inside `directory`, or nil when its
    /// path leads outside it. As in ZIPFoundation's own `unzipItem`, a
    /// leading slash does not make the path absolute and repeated slashes
    /// count as one; here a ".." that would climb above `directory` refuses
    /// the path even when a later component would come back inside.
    static func containedDestination(of path: String, in directory: URL) -> URL? {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        return components.reduce(directory) { $0.appendingPathComponent(String($1)) }
    }

    // MARK: Entries

    /// Extracts `entry` of `archive` into `directory`: a folder is created, a
    /// link is made as ZIPFoundation makes it, and a file is written.
    private static func extract(
        _ entry: Entry,
        of archive: Archive,
        into directory: URL,
        budget: ArchiveBudget,
        isCancelled: ImportCancellationCheck
    ) throws {
        guard let destination = containedDestination(of: entry.path, in: directory) else {
            throw FileImportError.archivePathOutside
        }
        switch entry.type {
        case .directory:
            // Created plainly: an archive's own permissions could make a
            // folder that the files inside it, or its removal, cannot enter.
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        case .symlink:
            try extractLink(entry, of: archive, to: destination, budget: budget)
        case .file:
            try extractFile(entry, of: archive, to: destination, budget: budget, isCancelled: isCancelled)
        }
    }

    /// Makes the link `entry` describes at `destination` through ZIPFoundation,
    /// which refuses one pointing outside its own folder.
    private static func extractLink(_ entry: Entry, of archive: Archive, to destination: URL, budget: ArchiveBudget) throws {
        // No path macOS accepts is longer than PATH_MAX, so a longer "link"
        // is damage; it is refused before ZIPFoundation reads it whole.
        guard entry.uncompressedSize <= UInt64(PATH_MAX) else { throw FileImportError.unreadableArchive }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let checksum = try archive.extract(entry, to: destination, skipCRC32: false, allowUncontainedSymlinks: false)
        guard checksum == entry.checksum else { throw FileImportError.unreadableArchive }
        try budget.charge(Int64(clamping: entry.uncompressedSize))
    }

    /// Writes the file `entry` describes to `destination`, chunk by chunk:
    /// held to its recorded size, charged to `budget`, stopped between chunks
    /// when the cancellation check says so, and compared with its checksum.
    private static func extractFile(
        _ entry: Entry,
        of archive: Archive,
        to destination: URL,
        budget: ArchiveBudget,
        isCancelled: ImportCancellationCheck
    ) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let handle = try createFile(at: destination)
        defer { try? handle.close() }

        let checksum: CRC32
        do {
            checksum = try ArchiveEntryReader.stream(entry, in: archive) { chunk in
                do {
                    if isCancelled() { throw ImportCancelled() }
                    try budget.charge(Int64(chunk.count))
                    try handle.write(contentsOf: chunk)
                } catch {
                    throw StoppedWriting(reason: error)
                }
            }
        } catch let stopped as StoppedWriting {
            throw stopped.reason
        } catch let overflow as ArchiveEntryOverflow {
            throw overflow
        } catch {
            // Anything else came from reading the archive: its data is
            // damaged or cut short.
            throw FileImportError.unreadableArchive
        }
        guard checksum == entry.checksum else { throw FileImportError.unreadableArchive }
    }

    /// Why writing an extracted file stopped: a cancellation, the budget, or
    /// the disk. It is carried through ZIPFoundation's read loop wrapped, so
    /// it is never mistaken for damage in the archive.
    private struct StoppedWriting: Error {
        let reason: any Error
    }

    /// Creates the file at `url` for writing, failing rather than replacing
    /// anything already there or following a link there.
    private static func createFile(at url: URL) throws -> FileHandle {
        var failure: Int32 = 0
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                failure = EINVAL
                return -1
            }
            let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if descriptor < 0 { failure = errno }
            return descriptor
        }
        guard descriptor >= 0 else {
            // A second entry of the same path is refused as unzipItem refuses it.
            if failure == EEXIST {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO, userInfo: [NSFilePathErrorKey: url.path])
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

/// Tells an extraction's progress callback the entries done of the total:
/// at the start, then whenever the whole percentage done changes, so a large
/// archive sends at most about a hundred updates to the main thread.
private struct ProgressReporter {
    /// The archive's entries.
    let total: Int
    /// Told the entries done of the total.
    let progress: ((Int, Int) -> Void)?
    /// The percentage done last told; none at first.
    private var lastPercent = -1

    init(total: Int, progress: ((Int, Int) -> Void)?) {
        self.total = total
        self.progress = progress
    }

    /// Tells `progress` that `done` entries are out, unless the whole
    /// percentage done is the one last told.
    mutating func callAsFunction(_ done: Int) {
        guard let progress else { return }
        let percent = total == 0 ? 100 : done * 100 / total
        guard percent != lastPercent else { return }
        lastPercent = percent
        progress(done, total)
    }
}

// MARK: - Extraction Directories

/// A directory a ZIP batch extracts its archive into (TODO I05), made in an
/// "Archive Extraction" folder on the same disk as the library: the
/// free-space check then speaks for the disk the books go to, and copying
/// each book into its package clones it there instead of taking its space
/// twice. The batch removes it on every exit.
///
/// The folder is this Mac's own (`MachineLocalPaths.archiveExtraction`)
/// while the data directory is on its volume, the startup disk, which is
/// still the disk the books go to; a data directory in a cloud folder then
/// never uploads an archive being extracted. While the data directory is on
/// another volume, the folder is the data directory's own, as before
/// (`ImportScratchSpace`, FR02).
///
/// Its name is `extract-<process>-<UUID>`: recognizable, so the sweep at
/// startup removes only extraction directories, and naming the process that
/// made it, so the sweep leaves alone one that another running copy of
/// TextMouth on this Mac is still using. When the directory was made tells
/// that copy from a later process that took its identifier (#652).
final class ArchiveExtractionDirectory {
    /// The name of the folder extraction directories are made in.
    static let folderName = "Archive Extraction"
    /// What every extraction directory's name starts with.
    static let namePrefix = "extract-"

    /// The folder extraction directories are made in: this Mac's, or the
    /// data directory's when that is on another volume.
    static var defaultParent: URL {
        ImportScratchSpace.archiveExtractionFolder()
    }

    /// The extraction directory.
    let directory: URL
    /// Whether `remove()` has run.
    private var isRemoved = false

    /// The names of the extraction directories this process's imports are
    /// using, which the sweep leaves alone. Tests and other callers can
    /// import on other threads, so the set is locked.
    private static let inUse = NamesInUse()

    private init(directory: URL) {
        self.directory = directory
    }

    /// The directory's name.
    var name: String { directory.lastPathComponent }
    /// Where the archive being imported is extracted.
    var archiveDirectory: URL { directory.appendingPathComponent("archive", isDirectory: true) }
    /// Where archives found inside it are extracted, each in a folder of its own.
    var nestedDirectory: URL { directory.appendingPathComponent("nested", isDirectory: true) }

    /// Makes a new, empty extraction directory in `parent`, creating
    /// `parent` if needed and keeping it out of Time Machine backups, since
    /// what it holds lasts only as long as an import. The new name is
    /// marked in use before anything exists under it, so no sweep can take it.
    static func make(in parent: URL = defaultParent) throws -> ArchiveExtractionDirectory {
        try ImportScratchSpace.prepareFolder(parent)
        let made = ArchiveExtractionDirectory(
            directory: parent.appendingPathComponent("\(namePrefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
        )
        inUse.insert(made.name, at: made.directory)
        do {
            try FileManager.default.createDirectory(at: made.directory, withIntermediateDirectories: false)
        } catch {
            inUse.remove(made.name)
            throw error
        }
        return made
    }

    /// Removes the directory with everything extracted into it. Running it
    /// again does nothing.
    func remove() {
        guard !isRemoved else { return }
        isRemoved = true
        Self.removeDirectory(directory)
        Self.inUse.remove(name)
    }

    // MARK: Sweeping Leftovers

    /// Removes, at startup, the extraction directories that imports
    /// interrupted by a crash or a forced quit left (FR02): in this Mac's
    /// Archive Extraction folder, and in the data directory's own, where
    /// earlier versions extracted and where extraction still happens while
    /// the data directory is on another volume. The data directory's folder
    /// is listed with dataless files left in the cloud, and while this Mac's
    /// folder is the one in use it is removed once nothing is left in it, so
    /// later launches find nothing there to list.
    /// - Returns: How many directories were removed.
    @discardableResult
    static func removeLeftovers() -> Int {
        let inLibrary = ImportScratchSpace.inLibraryArchiveExtraction
        var removed = removeLeftovers(in: MachineLocalPaths.archiveExtraction)
        DatalessFiles.withoutDownloading {
            removed += removeLeftovers(in: inLibrary)
            if ImportScratchSpace.isOnThisMac() {
                // Removes the folder only when it is empty.
                _ = rmdir(inLibrary.path)
            }
        }
        return removed
    }

    /// Removes the extraction directories in `parent` that no import is
    /// using, as a crash or a forced quit leaves them: those whose process
    /// has ended, and this process's own that none of its imports is using
    /// (a process before it had the same identifier). Whether another
    /// process's directory is still its maker's follows the sandbox sweep's
    /// rule (`TextMouthRuntime.isFolderMakerRunning`): a running process
    /// with the identifier in its name made it only if that process started
    /// no later than an hour after the directory was made, so a later
    /// process that took the identifier keeps no leftover (#652). An
    /// interrupted extraction is never resumed, so each goes with everything
    /// inside it, and the removal is logged, naming the directory by its
    /// path inside this Mac's TextMouth folder or the data directory
    /// (`ImportScratchSpace.loggablePath`). A directory another running
    /// process made is left alone, as is anything not named as an
    /// extraction directory, and anything so named that is not a plain
    /// folder, such as a symbolic link, which could lead anywhere.
    /// - Parameter isMakerRunning: Whether the process that made a
    ///   directory named for a process identifier still runs, given when
    ///   the directory was made (nil when unknown); tests supply their own
    ///   answer.
    /// - Returns: How many directories were removed.
    @discardableResult
    static func removeLeftovers(
        in parent: URL,
        isMakerRunning: (_ process: Int32, _ directoryMade: Date?) -> Bool = TextMouthRuntime.isFolderMakerRunning
    ) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        let ownProcess = getpid()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]
        var removed = 0
        for name in names {
            guard let process = processIdentifier(inName: name) else { continue }
            let leftover = parent.appendingPathComponent(name, isDirectory: true)
            // Read before deciding anything: only a plain folder can go, and
            // when it was made tells whether another process made it.
            guard let values = try? leftover.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            // This process's own directory is abandoned once none of its
            // imports holds it; another's, once the process that made it ended.
            let isAbandoned = process == ownProcess
                ? !inUse.contains(name)
                : !isMakerRunning(process, values.creationDate)
            guard isAbandoned else { continue }
            if removeDirectory(leftover) {
                removed += 1
                DiagnosticLog.event(
                    .import,
                    "ARCHIVE_EXTRACTION_REMOVED: \(ImportScratchSpace.loggablePath(leftover)): left by an interrupted import"
                )
            }
        }
        return removed
    }

    /// The process identifier in `name` when it is an extraction directory's
    /// name: `extract-`, a positive process identifier in digits, a hyphen,
    /// and a UUID. Nil for any other name.
    static func processIdentifier(inName name: String) -> Int32? {
        guard name.hasPrefix(namePrefix) else { return nil }
        let rest = name.dropFirst(namePrefix.count)
        guard let hyphen = rest.firstIndex(of: "-") else { return nil }
        let digits = rest[..<hyphen]
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }),
              let process = Int32(digits), process > 0,
              UUID(uuidString: String(rest[rest.index(after: hyphen)...])) != nil else {
            return nil
        }
        return process
    }

    // MARK: Helpers

    /// Removes `directory` with everything inside it and reports whether it
    /// is gone. One that could not be removed is logged, by its path inside
    /// this Mac's TextMouth folder or the data directory, so the next sweep
    /// is not its only record.
    @discardableResult
    private static func removeDirectory(_ directory: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: directory)
            return true
        } catch {
            guard FileManager.default.fileExists(atPath: directory.path) else { return true }
            DiagnosticLog.event(
                .import,
                "ARCHIVE_EXTRACTION_LEFT: \(ImportScratchSpace.loggablePath(directory)): could not be removed: "
                    + error.localizedDescription
            )
            return false
        }
    }
}
