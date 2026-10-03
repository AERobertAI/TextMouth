import Foundation

// MARK: - Files Another Mac Writes Too (FR02 Polish: Several Macs)

/// A small file of the data directory that TextMouth reads whole and
/// replaces whole, and that another Mac sharing the library writes too, such
/// as reading_stats.json and substitutions.json.
///
/// In a cloud library such a file can be only in the cloud, when the sync
/// service removed its content to free space, so it is read with dataless
/// files left in the cloud: a read that would download it, waiting on the
/// network, here on the main thread, fails at once instead.
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

    /// Asks the sync service to download the file at `url`, which a read
    /// found only in the cloud; returns at once, and a failure changes
    /// nothing, since the file is read again before anything replaces it.
    @MainActor
    static func requestDownload(of url: URL) {
        try? CloudServices.itemStatus.requestDownload(of: url)
    }
}
