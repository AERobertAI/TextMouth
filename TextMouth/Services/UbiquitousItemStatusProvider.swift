import Foundation

// MARK: - Items That Carry Sync Flags (FR02)

/// One item's cloud state, and whether the sync service reports sync flags
/// for the item itself.
struct FlaggedItemStatus: Equatable, Sendable {
    /// The item's cloud state, as `CloudItemStatusProviding.status(of:)`
    /// gives it.
    var status: CloudItemStatus
    /// Whether the sync service reports the item's own sync flags: whether
    /// its changes have uploaded, where its content is, or whether it is
    /// downloading. False for an item it does not sync on its own, for an
    /// ordinary local item, and where nothing is.
    var carriesSyncFlags: Bool
}

/// A file-level provider that also says which items carry sync flags of
/// their own (FR02).
///
/// A sync service reports sync flags for each item it syncs. iCloud Drive
/// syncs a package, such as a book's .tmb folder, as one item: the package
/// carries the flags, while the files inside it carry none and are refused,
/// as items that don't exist, when a download or a removal is asked for one
/// of them. Google Drive and Dropbox sync each file, and every file carries
/// its own flags, as do the folders holding them, a package's folder
/// included (measured on the real drives, October 3).
/// `BookCloudStorageService` reads both, the package and its files, to
/// decide which items of a book to ask about, download, and remove.
protocol SyncFlagReporting: CloudItemStatusProviding {
    /// The cloud state of the item at `item`, as `status(of:)` reads it,
    /// and whether it carries sync flags of its own, both from one read.
    func flaggedStatus(of item: URL) -> FlaggedItemStatus
}

// MARK: - Ubiquitous Item Status (FR02)

/// The cloud state of files and folders, read from Foundation's
/// ubiquitous-item resource keys and the file system's dataless flag (FR02).
///
/// On this Mac those keys report the same way for iCloud Drive, Google
/// Drive, and Dropbox to an unsandboxed app without an iCloud entitlement,
/// so one provider serves every sync service. Every read happens inside
/// `DatalessFiles.withoutDownloading`, so none waits on the network, and
/// none reads a file's content. Reads can still wait on the file system, so
/// call them off the main thread.
///
/// The reads go through one function (`readMetadata`), and the two requests
/// through two more, so tests supply their own and need no real cloud drive.
struct UbiquitousItemStatusProvider: SyncFlagReporting {

    // MARK: Metadata

    /// What the provider reads about one item: the resource values it asks
    /// for, copied out of `URLResourceValues` (whose properties tests cannot
    /// set), and the dataless flag. A value is nil when the key was not
    /// asked for or the system gave none.
    struct Metadata: Equatable, Sendable {
        /// Whether a sync service manages the item. Nil, not false, for an
        /// ordinary local item on this Mac.
        var isUbiquitousItem: Bool?
        /// Where the sync service says the item's content is.
        var downloadingStatus: URLUbiquitousItemDownloadingStatus?
        /// Whether the sync service is downloading the item now.
        var isDownloading: Bool?
        /// Whether every local change of the item has uploaded.
        var isUploaded: Bool?
        /// Whether the sync service holds conflicting versions of the item.
        var hasUnresolvedConflicts: Bool?
        /// The sync service's last download error, in words.
        var downloadError: String?
        /// The item's size as the file system reports it. Some dataless
        /// iCloud Drive files report 0.
        var byteCount: Int64?
        /// The root folder of the volume the item is on.
        var volumeURL: URL?
        /// That volume's name, as Finder shows it.
        var volumeName: String?
        /// Whether the item is dataless: its content is only in the cloud.
        var isDataless = false
    }

    /// Reads `keys` and the dataless flag of the item at a URL; throws when
    /// nothing is there, or when the system refuses to look without
    /// downloading (`DatalessFiles.isDownloadRefusal(_:)`).
    typealias MetadataReader = @Sendable (URL, Set<URLResourceKey>) throws -> Metadata

    /// An action on the item at a URL, such as asking the sync service to
    /// download it.
    typealias ItemRequest = @Sendable (URL) throws -> Void

    /// The keys `status(of:)` reads.
    static let statusKeys: Set<URLResourceKey> = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemIsUploadedKey,
        .ubiquitousItemHasUnresolvedConflictsKey,
        .ubiquitousItemDownloadingErrorKey,
        .fileSizeKey,
    ]

    /// The keys `location(of:)` reads.
    static let locationKeys: Set<URLResourceKey> = [
        .isUbiquitousItemKey,
        .volumeURLKey,
        .volumeLocalizedNameKey,
    ]

    /// Reads an item's metadata.
    private let readMetadata: MetadataReader
    /// Asks the sync service to download an item.
    private let startDownload: ItemRequest
    /// Asks the sync service to remove an item's local copy.
    private let evict: ItemRequest

    /// A provider that reads through `readMetadata` and asks for downloads
    /// and removals through `startDownload` and `evict`: by default, the
    /// file system and `FileManager`.
    init(
        readMetadata: @escaping MetadataReader = { try UbiquitousItemStatusProvider.readFreshMetadata(of: $0, keys: $1) },
        startDownload: @escaping ItemRequest = { try FileManager.default.startDownloadingUbiquitousItem(at: $0) },
        evict: @escaping ItemRequest = { try FileManager.default.evictUbiquitousItem(at: $0) }
    ) {
        self.readMetadata = readMetadata
        self.startDownload = startDownload
        self.evict = evict
    }

    /// Reads `keys` and the dataless flag of the item at `url` from the file
    /// system: the default reader.
    ///
    /// `NSURL` keeps the resource values it read until the end of a run
    /// loop pass, and polling threads have none, so a URL the caller reuses
    /// could answer from an old reading
    /// (https://developer.apple.com/documentation/foundation/nsurl/removeallcachedresourcevalues()).
    /// A URL made fresh from the path has nothing cached.
    static func readFreshMetadata(of url: URL, keys: Set<URLResourceKey>) throws -> Metadata {
        let fresh = URL(fileURLWithPath: url.path, isDirectory: url.hasDirectoryPath)
        let values = try fresh.resourceValues(forKeys: keys)
        return Metadata(
            isUbiquitousItem: values.isUbiquitousItem,
            downloadingStatus: values.ubiquitousItemDownloadingStatus,
            isDownloading: values.ubiquitousItemIsDownloading,
            isUploaded: values.ubiquitousItemIsUploaded,
            hasUnresolvedConflicts: values.ubiquitousItemHasUnresolvedConflicts,
            downloadError: values.ubiquitousItemDownloadingError?.localizedDescription,
            byteCount: values.fileSize.map(Int64.init),
            volumeURL: values.volume,
            volumeName: values.volumeLocalizedName,
            isDataless: DatalessFiles.isDataless(fresh)
        )
    }

    // MARK: Where a Folder Lives

    /// Where the folder at `folder` lives: in a sync service's folder, on
    /// another volume, or on the startup disk. A folder that does not exist
    /// yet is judged by its path and its nearest existing ancestor.
    func location(of folder: URL) -> StorageLocation {
        DatalessFiles.withoutDownloading {
            let folder = folder.standardizedFileURL
            if let provider = Self.provider(forPath: folder) {
                return .cloud(provider)
            }
            guard let nearest = nearestExistingItem(from: folder) else {
                return .local
            }
            let (existing, metadata) = nearest
            // A link, such as ~/Google Drive, can lead into a sync service's
            // folder.
            if let provider = Self.provider(forPath: existing.resolvingSymlinksInPath()) {
                return .cloud(provider)
            }
            // A sync service manages it outside both of their places: only
            // iCloud Drive does that, for Desktop & Documents Folders.
            if metadata.isUbiquitousItem == true {
                return .cloud(.iCloudDrive)
            }
            if let volume = metadata.volumeURL, let startup = startupVolume(), !Self.isSameFolder(volume, startup) {
                return .otherVolume(name: metadata.volumeName ?? volume.lastPathComponent)
            }
            return .local
        }
    }

    /// The sync service whose folder holds `url`, named by the components of
    /// its path, or nil when the path runs through none: a folder inside
    /// .../Library/Mobile Documents/<container> is in iCloud Drive, and one
    /// inside .../Library/CloudStorage/<domain> in the File Provider drive
    /// that folder belongs to.
    ///
    /// Only the path's components count, never the home folder, so a hosted
    /// test's sandbox home has the same places. Components match without
    /// regard to case, as the startup disk does.
    static func provider(forPath url: URL) -> CloudProvider? {
        let components = url.standardizedFileURL.pathComponents
        // Each "Library" with a place's name after it and one more component
        // after that, the container or the drive's folder.
        for index in components.indices.dropLast(2) where matches(components[index], "Library") {
            let place = components[index + 1]
            if matches(place, "Mobile Documents") {
                return .iCloudDrive
            }
            if matches(place, "CloudStorage") {
                return provider(forDriveFolder: components[index + 2])
            }
        }
        return nil
    }

    /// The File Provider drive whose folder in ~/Library/CloudStorage is
    /// named `name`: Google Drive's folders begin "GoogleDrive-" and
    /// Dropbox's "Dropbox"; any other drive is named by its folder's name up
    /// to the first "-", so "OneDrive-Personal" is OneDrive.
    static func provider(forDriveFolder name: String) -> CloudProvider {
        let lowercased = name.lowercased()
        if lowercased.hasPrefix("googledrive") {
            return .googleDrive
        }
        if lowercased.hasPrefix("dropbox") {
            return .dropbox
        }
        let service = name.prefix { $0 != "-" }
        return .other(service.isEmpty ? name : String(service))
    }

    /// Whether two path components are the same name, ignoring case.
    private static func matches(_ component: String, _ name: String) -> Bool {
        component.caseInsensitiveCompare(name) == .orderedSame
    }

    /// Whether two URLs name the same folder, ignoring a trailing slash.
    private static func isSameFolder(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.path == second.standardizedFileURL.path
    }

    /// The item at `url` or, when nothing is there, at its nearest ancestor
    /// that exists, with its location metadata; nil when not even the root
    /// folder can be read.
    private func nearestExistingItem(from url: URL) -> (URL, Metadata)? {
        var candidate = url.standardizedFileURL
        while true {
            if let metadata = try? readMetadata(candidate, Self.locationKeys) {
                return (candidate, metadata)
            }
            // The root folder has no parent to try; asking for one would
            // give "/..", and then "/../..", without end.
            guard candidate.pathComponents.count > 1 else { return nil }
            candidate = candidate.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// The root folder of the startup volume, or nil when it cannot be read.
    private func startupVolume() -> URL? {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        return (try? readMetadata(root, [.volumeURLKey]))?.volumeURL
    }

    // MARK: One File

    /// The cloud state of the file at `file`, read without downloading
    /// anything (`flaggedStatus(of:)`).
    func status(of file: URL) -> CloudItemStatus {
        flaggedStatus(of: file).status
    }

    /// The cloud state of the item at `item`, and whether it carries sync
    /// flags of its own, from one read without downloading anything. An
    /// item the system refuses to look up without downloading, because a
    /// folder above it is only in the cloud, is not downloaded, and nothing
    /// is known of its flags.
    func flaggedStatus(of item: URL) -> FlaggedItemStatus {
        DatalessFiles.withoutDownloading {
            do {
                let metadata = try readMetadata(item, Self.statusKeys)
                return FlaggedItemStatus(status: Self.status(from: metadata), carriesSyncFlags: Self.carriesSyncFlags(metadata))
            } catch let error where DatalessFiles.isDownloadRefusal(error) {
                let inFolderOnlyInCloud = CloudItemStatus(
                    state: .notDownloaded,
                    isUploaded: true,
                    byteCount: nil,
                    hasUnresolvedConflicts: false,
                    downloadError: nil
                )
                return FlaggedItemStatus(status: inFolderOnlyInCloud, carriesSyncFlags: false)
            } catch {
                return FlaggedItemStatus(status: .missing, carriesSyncFlags: false)
            }
        }
    }

    /// Whether `metadata` holds sync flags of the item's own: the upload
    /// flag, the downloading status, or whether it is downloading. A sync
    /// service reports them for each item it syncs, and none for a file
    /// inside a package it syncs as one item (iCloud Drive's files report
    /// only that they are managed), nor for an ordinary local item.
    static func carriesSyncFlags(_ metadata: Metadata) -> Bool {
        metadata.isUploaded != nil || metadata.downloadingStatus != nil || metadata.isDownloading != nil
    }

    /// The status `metadata` describes. An item no sync service manages is
    /// local; a managed one is described by `state(from:)`. A missing upload
    /// flag counts as uploaded and a missing conflict flag as no conflict.
    /// A file inside a package iCloud Drive syncs as one item carries no
    /// flags at all, so the package's own flags speak for it: the book
    /// storage reads them (`carriesSyncFlags(_:)`, `flaggedStatus(of:)`).
    static func status(from metadata: Metadata) -> CloudItemStatus {
        // Only a sync service makes dataless items, so a dataless item is
        // managed even when the keys say otherwise.
        guard metadata.isUbiquitousItem == true || metadata.isDataless else {
            return .local(byteCount: metadata.byteCount)
        }
        return CloudItemStatus(
            state: state(from: metadata),
            isUploaded: metadata.isUploaded ?? true,
            byteCount: metadata.byteCount,
            hasUnresolvedConflicts: metadata.hasUnresolvedConflicts ?? false,
            downloadError: metadata.downloadError
        )
    }

    /// Where a managed item's content is: what the status keys report, with
    /// the dataless flag overruling a key that disagrees with it.
    ///
    /// The flag is the file system's own record of whether the content is
    /// on this Mac, and a sync service puts downloaded content in place only
    /// once it is complete. So a dataless item is not downloaded, or is
    /// downloading when the service says so, whatever its status key says;
    /// and an item that is not dataless is downloaded, even while the
    /// service reports it as missing or still downloading.
    static func state(from metadata: Metadata) -> CloudItemState {
        guard metadata.isDataless else {
            return .downloaded
        }
        return metadata.isDownloading == true ? .downloading : .notDownloaded
    }

    // MARK: Requests

    /// Asks the sync service to download the item at `file`
    /// (`FileManager.startDownloadingUbiquitousItem(at:)`); returns at once.
    func requestDownload(of file: URL) throws {
        try startDownload(file)
    }

    /// Asks the sync service to remove the local copy of the file at `file`
    /// (`FileManager.evictUbiquitousItem(at:)`), keeping it in the cloud.
    /// Does nothing to a file whose content is not on this Mac, or that no
    /// sync service manages: a local file has no copy in the cloud to fall
    /// back on, so its content is never deleted.
    func removeLocalCopy(of file: URL) throws {
        let state = status(of: file).state
        guard state == .downloaded || state == .downloading else { return }
        try evict(file)
    }
}
