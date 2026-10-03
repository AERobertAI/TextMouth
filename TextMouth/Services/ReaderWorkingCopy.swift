import Darwin
import Foundation

// MARK: - FR02 Working Copies

/// A copy of an open audiobook's package that its reader plays from (FR02).
///
/// A sync service may remove the download of any file it manages: when the
/// disk runs low, when the user asks, or (Dropbox) on its own. File Provider
/// keeps a file only while it is held open, and AVPlayer holds only the file
/// it is playing, so an open audiobook's other chapter files could vanish, or
/// never arrive, while it plays. So once an audiobook in a cloud library is
/// on this Mac, its reader clones the book's package into this Mac's own
/// Working Copies folder (`MachineLocalPaths.workingCopies`), where no sync
/// service reaches, and plays every file from the clone. On APFS,
/// `FileManager.copyItem` makes a clone, which shares the original's storage:
/// it takes no extra space and is made almost at once.
///
/// Each copy has a folder of its own, `<book ID>-<UUID>`, holding the package
/// (or an old book's single file) under its own name, so every file keeps its
/// name and extension, which AVFoundation goes by. The copy is only read:
/// positions, bookmarks, and settings still save through the library to the
/// package. The reader deletes its copy when it closes.
struct ReaderWorkingCopy: Equatable, Sendable {
    /// The copy's own folder, inside the Working Copies folder.
    let folder: URL
    /// The copied package, or single file, inside `folder`.
    let root: URL
    /// Where the copied package is in the library now: where it was copied
    /// from, or where a library move has taken it since.
    private(set) var source: URL

    /// A copy at `root`, inside its own `folder`, of the package at `source`.
    init(folder: URL, root: URL, source: URL) {
        self.folder = folder
        self.root = root
        self.source = source
    }

    /// The file inside the copy at the same place as `url` is inside the
    /// package: a chapter's file, a clip's file, or the package itself. A
    /// URL outside the package is returned as it is, so it plays from where
    /// it is.
    func location(of url: URL) -> URL {
        let sourcePath = source.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == sourcePath {
            return root
        }
        let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        guard path.hasPrefix(prefix) else { return url }
        return root.appendingPathComponent(String(path.dropFirst(prefix.count)))
    }

    /// Notes that the library moved the copied package to `newSource`. The
    /// copy itself stays where it is, so playback reading it goes on; files
    /// named by where the book is now still find their copies.
    mutating func sourceMoved(to newSource: URL) {
        source = newSource
    }

    /// Deletes the copy's folder and everything in it.
    func remove() throws {
        try FileManager.default.removeItem(at: folder)
    }
}

/// What making a working copy came to.
enum ReaderWorkingCopyResult: Equatable, Sendable {
    /// The copy was made.
    case made(ReaderWorkingCopy)
    /// No copy was made, for the reason given, in words for the log. The
    /// book plays from its package, each chapter's file checked first.
    case skipped(String)

    /// The copy, when one was made.
    var copy: ReaderWorkingCopy? {
        if case .made(let copy) = self { return copy }
        return nil
    }
}

/// This Mac's Working Copies folder, where readers make their working copies
/// (FR02).
///
/// A crash can leave copies behind. The first time a reader makes a copy in
/// a session, every folder already in the Working Copies folder is deleted
/// first: no reader can be playing from one yet. Copies are made one at a
/// time, so that sweep can never delete a copy another reader has just made.
///
/// `@unchecked Sendable`: readers make copies from background queues, and
/// the one mutable property is read and written only while `lock` is held.
final class ReaderWorkingCopies: @unchecked Sendable {
    /// The app's Working Copies folder.
    static let shared = ReaderWorkingCopies(folder: MachineLocalPaths.workingCopies)

    /// Clones `source` to `destination`, which must not exist yet.
    typealias Cloner = @Sendable (_ source: URL, _ destination: URL) throws -> Void

    /// The folder the copies are made in.
    let folder: URL
    /// Makes each copy: `FileManager.copyItem`, which clones on APFS, unless
    /// a test makes it fail.
    private let clone: Cloner
    /// Makes copies one at a time.
    private let lock = NSLock()
    /// Whether the copies a crash left behind have been swept away.
    private var hasSwept = false

    /// Working copies made in `folder` by `clone`.
    init(folder: URL, clone: @escaping Cloner = { try ReaderWorkingCopies.cloneWithFileManager($0, $1) }) {
        self.folder = folder
        self.clone = clone
    }

    /// Clones `source` to `destination` as the app does: `FileManager.copyItem`,
    /// which makes an APFS clone on the same volume.
    static func cloneWithFileManager(_ source: URL, _ destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Makes a working copy of `package`. A package on another volume is not
    /// copied, since the copy could not be a clone and would take as much
    /// space and time as the book; nor is one whose clone fails, or whose
    /// clone holds a file `isDataless` finds only in the cloud. Each of those
    /// is skipped, with its reason, and nothing of the attempt is left.
    ///
    /// Call it off the main thread, inside `DatalessFiles.withoutDownloading`,
    /// so cloning never waits on the network.
    func makeCopy(of package: BookPackage, isDataless: (URL) -> Bool) -> ReaderWorkingCopyResult {
        lock.withLock {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                return .skipped("the Working Copies folder could not be made (\(Self.describe(error)))")
            }
            if !hasSwept {
                hasSwept = true
                sweepLeftovers()
            }
            guard Self.isOnSameVolume(package.url, as: folder) else {
                return .skipped("the book is on another volume")
            }

            let copyFolder = folder.appendingPathComponent(
                "\(package.bookID.uuidString)-\(UUID().uuidString)",
                isDirectory: true
            )
            let root = copyFolder.appendingPathComponent(package.url.lastPathComponent, isDirectory: package.isPackage)
            do {
                try fileManager.createDirectory(at: copyFolder, withIntermediateDirectories: false)
                try clone(package.url, root)
                // A clone of a file whose content was only in the cloud would
                // hold nothing to play.
                try LocalBookFiles.requireOnThisMac(root, isDataless: isDataless)
            } catch {
                try? fileManager.removeItem(at: copyFolder)
                return .skipped("cloning failed (\(Self.describe(error)))")
            }
            return .made(ReaderWorkingCopy(folder: copyFolder, root: root, source: package.url))
        }
    }

    /// Deletes everything in the Working Copies folder: the copies a crash
    /// left behind. Called with `lock` held, before the session's first copy.
    private func sweepLeftovers() {
        let fileManager = FileManager.default
        let leftovers = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let removed = leftovers.filter { (try? fileManager.removeItem(at: $0)) != nil }.count
        if removed > 0 {
            DiagnosticLog.event(.storage, "WORKING_COPIES_SWEPT: \(removed) left behind")
        }
    }

    /// Whether the item at `item` is on the same volume as `folder`, so a
    /// copy of it into `folder` is a clone. False when either volume is
    /// unknown.
    static func isOnSameVolume(_ item: URL, as folder: URL) -> Bool {
        guard let itemVolume = (try? item.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject,
              let folderVolume = (try? folder.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        else { return false }
        return itemVolume.isEqual(folderVolume)
    }

    /// An error as a log line names it: its domain and code, never its
    /// description, which can hold a path.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}

// MARK: - Files on This Mac

/// Checks whether a book's files are on this Mac, reading no file's content
/// and downloading nothing (FR02).
enum LocalBookFiles {
    /// Where one file's content is.
    enum Availability: Equatable, Sendable {
        /// On this Mac: reading it waits on nothing.
        case onThisMac
        /// Only in the cloud: reading it would wait on the network.
        case inCloud
        /// Nothing is there, or it cannot be looked at. Reading it fails at
        /// once, as it did before any of this, and the player says why.
        case missing
    }

    /// The error a read of a file only in the cloud meets inside
    /// `DatalessFiles.withoutDownloading(_:)`. It is thrown for such a file
    /// found before reading, so that one and a read refused while reading
    /// are handled alike (see `DatalessFiles.isDownloadRefusal(_:)`).
    static var downloadRefusal: NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(EDEADLK))
    }

    /// Throws `downloadRefusal` when the item at `url`, or anything inside it,
    /// is only in the cloud by `isDataless`, or a folder inside it cannot be
    /// listed. Hidden files (".DS_Store" and the like) are passed over: a
    /// book never reads them, and a sync service need not download them.
    ///
    /// Call it inside `DatalessFiles.withoutDownloading(_:)`, where listing a
    /// folder whose own contents are only in the cloud fails at once instead
    /// of waiting.
    static func requireOnThisMac(_ url: URL, isDataless: (URL) -> Bool) throws {
        if isDataless(url) {
            throw downloadRefusal
        }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }

        // The enumerator reports a folder it cannot list here, and stops.
        let listing = ListingFailure()
        let items = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                listing.record(error)
                return false
            }
        )
        while let item = items?.nextObject() as? URL {
            if isDataless(item) {
                throw downloadRefusal
            }
        }
        if listing.error != nil {
            throw downloadRefusal
        }
    }

    /// Where the content of the file at `url` is, found with one lstat(2)
    /// made with downloading switched off, so it never waits on the network:
    /// a lookup through a folder whose contents are only in the cloud is
    /// refused at once (`EDEADLK`), and counts as in the cloud.
    static func availability(of url: URL, isDataless: (URL) -> Bool) -> Availability {
        DatalessFiles.withoutDownloading {
            var status = stat()
            var lookupError: Int32 = 0
            let found = url.withUnsafeFileSystemRepresentation { path -> Bool in
                guard let path else { return false }
                if lstat(path, &status) == 0 {
                    return true
                }
                lookupError = errno
                return false
            }
            guard found else {
                return lookupError == EDEADLK ? .inCloud : .missing
            }
            return isDataless(url) ? .inCloud : .onThisMac
        }
    }

    /// The first error a folder listing met, kept for after the listing.
    /// `@unchecked Sendable`: the enumerator calls its error handler on the
    /// thread listing, the only thread that reads it.
    private final class ListingFailure: @unchecked Sendable {
        /// The error, or nil while there was none.
        private(set) var error: Error?

        /// Keeps `error` unless an earlier one was kept.
        func record(_ error: Error) {
            if self.error == nil {
                self.error = error
            }
        }
    }
}
