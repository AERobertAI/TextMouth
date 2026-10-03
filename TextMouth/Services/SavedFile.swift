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
    /// is downloaded. Returns the copy, or nil when none could be made.
    static func preserveUnusable(_ url: URL, bytes: Data?) -> URL? {
        DatalessFiles.withoutDownloading {
            LibraryIndexQuarantine.preserve(url, bytes: bytes)
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
}
