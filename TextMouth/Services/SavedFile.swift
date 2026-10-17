import Foundation

// MARK: - Files Another Mac Writes Too (FR02 Polish: Several Macs)

/// A small file that TextMouth reads whole and replaces whole: one of the
/// data directory that another Mac sharing the library writes too, such as
/// reading_stats.json and substitutions.json, or one of this Mac's own, such
/// as the books it keeps (`KeptBooks`).
///
/// In a cloud library such a file can be only in the cloud, when the sync
/// service removed its content to free space, so it is read with dataless
/// files left in the cloud: a read that would download it, waiting on the
/// network, here on the main thread, fails at once instead. It can also be
/// cut short, as a write interrupted on another Mac leaves it; a file that
/// can't be used is preserved beside itself (`LibraryIndexQuarantine`)
/// before anything replaces it, so nothing it held is lost.
enum SavedFile {
    /// What one read of a saved file found.
    enum Read: Equatable {
        /// No file: a first launch, or the file was removed.
        case missing
        /// The file's content is only in the cloud, so it was not read:
        /// reading it would have downloaded it first.
        case inCloud
        /// The file's bytes.
        case contents(Data)
        /// The file is there, but can't be read, for the reason given.
        case unreadable(String)
    }

    /// Reads a saved file's bytes. The app's reader leaves dataless files
    /// in the cloud (`readWithoutDownloading(_:)`); tests pass one that
    /// refuses as a dataless file does, since only a sync service makes them.
    typealias Reader = (URL) throws -> Data

    /// The bytes of the file at `url`, read with dataless files left in the
    /// cloud: a file only in the cloud throws the refusal
    /// `DatalessFiles.isDownloadRefusal(_:)` recognizes, at once.
    static func readWithoutDownloading(_ url: URL) throws -> Data {
        try DatalessFiles.withoutDownloading { try Data(contentsOf: url) }
    }

    /// What reading the file at `url` through `read` finds.
    static func read(_ url: URL, using read: Reader) -> Read {
        do {
            return .contents(try read(url))
        } catch where DatalessFiles.isDownloadRefusal(error) {
            return .inCloud
        } catch where BookCloudStorageService.isMissingItem(error) {
            return .missing
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Keeps a copy of the file at `url`, which can't be read or decoded,
    /// beside it, before anything replaces it: holding `bytes` when they
    /// could be read, or linked to the file when they couldn't. Earlier
    /// copies are compared with dataless files left in the cloud, so none
    /// is downloaded. `marker` separates the file's name from the copy's
    /// timestamp, ".unreadable-" unless the caller keeps copies of its own,
    /// as Edit Text does for an edited content.md (FR05). Returns the copy,
    /// or nil when none could be made.
    static func preserveUnusable(
        _ url: URL,
        bytes: Data?,
        marker: String = LibraryIndexQuarantine.nameMarker
    ) -> URL? {
        DatalessFiles.withoutDownloading {
            LibraryIndexQuarantine.preserve(url, bytes: bytes, marker: marker)
        }
    }

    /// Keeps a copy of the file at `url`, which can't be read or decoded for
    /// `reason`, as `preserveUnusable(_:bytes:)` does, and writes one event
    /// line in `category`, beginning with `tag`, that names the file, the
    /// reason, what stands in for the file now (`standIn`), and the copy.
    /// - Returns: The copy, or nil when none could be made.
    @discardableResult
    static func preserveUnusable(
        _ url: URL,
        bytes: Data?,
        because reason: String,
        logging tag: String,
        in category: DiagnosticLog.Category,
        standIn: String
    ) -> URL? {
        let copy = preserveUnusable(url, bytes: bytes)
        let preserved = copy.map { "preserved copy: \($0.lastPathComponent)" } ?? "no preserved copy could be made"
        DiagnosticLog.event(
            category,
            "\(tag): could not read \(url.lastPathComponent): \(reason); \(standIn); \(preserved)"
        )
        return copy
    }

    /// Why a save was not written over a file only in the cloud: the file
    /// holds what was saved before, on this Mac or another, which writing
    /// without reading it first would replace.
    struct InCloudError: LocalizedError {
        /// The file's name, as the sentence names it.
        let fileName: String

        var errorDescription: String? {
            "\(fileName) is only in the cloud and isn't on this Mac yet, so nothing was written over it. "
                + "Try again in a moment."
        }
    }

    /// Asks the sync service to download the file at `url`, which a read
    /// found only in the cloud; returns at once, and a failure changes
    /// nothing, since the file is read again before anything replaces it.
    @MainActor
    static func requestDownload(of url: URL) {
        try? CloudServices.itemStatus.requestDownload(of: url)
    }

    // MARK: Replacing in one step

    /// Renames `from` to `to` with rename(2), which replaces whatever is at
    /// `to` in the same step, as `FileManager.moveItem` never does. Both must
    /// be on one volume, as a partial file beside its destination is.
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

    // MARK: Writing only what changed

    /// What this process last read or wrote of some files in one data
    /// directory, so a save writes a file only when its freshly encoded bytes
    /// differ (library.json, each feed's index). The caller encodes the same
    /// content to the same bytes every time (sorted keys, a fixed row order);
    /// a save that changed nothing then writes nothing, and a checkpoint that
    /// fires every half minute while an episode plays does not rewrite a
    /// file of 900 KB for nothing.
    ///
    /// The memory is a value, held by the code that owns the files and
    /// confined to the queue it reads and writes them on; it does no
    /// locking of its own. It never replaces a read of the disk: it holds
    /// only what this process saw there, so a file that is gone is written
    /// again, and a file changed by something else is replaced the next time
    /// its content changes here.
    struct OnDiskMemory<Key: Hashable> {
        /// The data directory the bytes are in; the memory starts over when
        /// it changes, as after a data-directory move.
        private(set) var rootPath: String?
        /// Each file's bytes, as last read or written, by the caller's key.
        private var bytes: [Key: Data]

        /// A memory of `bytes` read from, or written to, the data directory
        /// at `rootPath`; empty when it knows nothing yet.
        init(rootPath: String? = nil, bytes: [Key: Data] = [:]) {
            self.rootPath = rootPath
            self.bytes = bytes
        }

        /// Forgets everything unless the memory is of the data directory at
        /// `root`: bytes of another directory say nothing about this one.
        mutating func startOver(unlessIn root: URL) {
            guard rootPath != root.path else { return }
            self = OnDiskMemory(rootPath: root.path)
        }

        /// Whether the file at `file` holds `data` already, as this process
        /// last read or wrote it, so that writing it again would change
        /// nothing. A file that is gone since is never unchanged: the same
        /// bytes are written again when it was deleted outside TextMouth.
        func holds(_ data: Data, for key: Key, at file: URL) -> Bool {
            bytes[key] == data && FileManager.default.fileExists(atPath: file.path)
        }

        /// Notes that the file by `key` holds `data` now. Call it only once
        /// the bytes are on disk (or, for a file that is not made, once they
        /// are known to be what the caller wants there). For a write, use
        /// `write(_:for:using:)`, which also forgets the older bytes when the
        /// write throws.
        mutating func remember(_ data: Data, for key: Key) {
            bytes[key] = data
        }

        /// Runs `write`, which puts `data` in the file by `key`, and keeps
        /// the memory true to the file whether it succeeds or not. When it
        /// succeeds the file holds `data`, which is remembered. When it throws
        /// the file's state is unknown (a rename on a network volume can land
        /// and still report failure), so what was remembered of it is
        /// forgotten before the error is rethrown: a later save, an undo to
        /// the older bytes included, then writes instead of being skipped as
        /// unchanged.
        /// - Throws: Whatever `write` throws, unchanged.
        mutating func write(_ data: Data, for key: Key, using write: () throws -> Void) rethrows {
            do {
                try write()
            } catch {
                forget(key)
                throw error
            }
            remember(data, for: key)
        }

        /// Forgets what the file by `key` holds, as when it was found
        /// unreadable or is about to be replaced by something else, so the
        /// next save writes it whatever it would encode to.
        mutating func forget(_ key: Key) {
            bytes[key] = nil
        }
    }
}
