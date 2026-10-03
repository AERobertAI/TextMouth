import Foundation

// MARK: - Where This Mac Keeps Its Library

/// The preferences that say where this Mac keeps its library and which
/// library it expects there (FR02), each defined once. They describe this
/// Mac, so config.json never carries them
/// (`ConfigService.AppConfig.Portability.localStoreKeys`).
///
/// `TextMouthPaths.setCustomRoot` records all three together: the path, a
/// bookmark of the folder beside it, and the identity of the library found
/// there. The library model records the identity again whenever a library
/// opens, and gives one to a library that has none.
enum DataDirectoryPreferences {
    /// The custom data directory's path; absent, or empty, for the default
    /// location. Every release has used this key, so a location chosen
    /// earlier keeps loading.
    static let customPath = StoredPreference<String?>(
        key: "textMouthDataDirectory",
        read: { store, key in store.string(forKey: key) },
        write: { value, store, key in
            if let value {
                store.set(value, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
    )

    /// A bookmark of the custom data directory (`URL.bookmarkData`), which
    /// finds the folder again after it is renamed, or after its drive
    /// mounts under another name; absent for the default location.
    static let bookmark = StoredPreference<Data?>(
        key: "textMouthDataDirectoryBookmark",
        read: { store, key in store.data(forKey: key) },
        write: { value, store, key in
            if let value {
                store.set(value, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
    )

    /// The identity of the library this Mac expects in its data directory
    /// (`LibraryIdentity.id`), or absent before one is known.
    static let expectedIdentity = StoredPreference<UUID?>(
        key: "textMouthLibraryIdentity",
        read: { store, key in store.string(forKey: key).flatMap(UUID.init(uuidString:)) },
        write: { value, store, key in
            if let value {
                store.set(value.uuidString, forKey: key)
            } else {
                store.removeObject(forKey: key)
            }
        }
    )

    /// Every key above, for the machine-local list and for tests that put
    /// them back.
    static let keys = [customPath.key, bookmark.key, expectedIdentity.key]

    /// A bookmark of the folder at `folder`, or nil when there is no folder
    /// there to bookmark yet.
    static func makeBookmark(of folder: URL) -> Data? {
        try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The identity of the library in the folder at `folder`, read without
    /// downloading anything; nil when the folder holds no marker, or one that
    /// can't be read here yet, such as a marker only in the cloud.
    static func identity(in folder: URL) -> LibraryIdentity? {
        DatalessFiles.withoutDownloading {
            try? LibraryIdentity.read(in: folder)
        }
    }
}

// MARK: - Why the Library Can't Be Used

/// Why the data directory can't be used now (FR02), as the Library Not
/// Available screen and Storage settings say it.
///
/// Each case knows the folder it is about, which the screen shows in full
/// as selectable text, and gives one plain explanation for the screen,
/// VoiceOver, and a braille display. The debug log gets `logDescription`
/// instead, which names the folder without its absolute path.
enum DataDirectoryUnavailability: Equatable, Sendable {
    /// The folder is on a drive that isn't connected: no volume is mounted
    /// at /Volumes/`volume`.
    case driveNotConnected(volume: String, folder: String)
    /// The folder can't be found inside a cloud service's folder. When
    /// `serviceFolderMissing`, the service's own folder is gone too, as when
    /// the service is signed out or not running.
    case cloudFolderMissing(CloudProvider, serviceFolderMissing: Bool, folder: String)
    /// The folder can't be found.
    case folderMissing(folder: String)
    /// Something other than a folder is at the location.
    case notAFolder(folder: String)
    /// The folder can't be read, for `reason`, such as "permission denied".
    case unreadable(folder: String, reason: String)
    /// The folder holds no library: neither an identity marker nor a
    /// library index.
    case libraryMissing(folder: String)
    /// The folder holds a library, but not the one this Mac uses: its
    /// identity marker names another.
    case differentLibrary(folder: String)
    /// The folder's identity marker can't be read, for `reason`.
    case identityUnreadable(folder: String, reason: String)
    /// The library index, or the identity marker, is only in the cloud, and
    /// TextMouth asked the sync service for it. `provider` is nil when the
    /// service is unknown.
    case notDownloaded(CloudProvider?, folder: String)

    /// The data directory's full path, as the screen shows it.
    var folder: String {
        switch self {
        case .driveNotConnected(_, let folder), .cloudFolderMissing(_, _, let folder), .folderMissing(let folder),
             .notAFolder(let folder), .unreadable(let folder, _), .libraryMissing(let folder),
             .differentLibrary(let folder), .identityUnreadable(let folder, _), .notDownloaded(_, let folder):
            return folder
        }
    }

    /// What is wrong, with where, in one plain explanation.
    var explanation: String {
        switch self {
        case .driveNotConnected(let volume, _):
            return "The drive “\(volume)” isn't connected."
        case .cloudFolderMissing(let provider, let serviceFolderMissing, let folder):
            return "The folder \(folder) can't be found. "
                + Self.likelyCause(in: provider, serviceFolderMissing: serviceFolderMissing)
        case .folderMissing(let folder):
            return "The folder \(folder) can't be found."
        case .notAFolder(let folder):
            return "There is a file at \(folder), not a folder."
        case .unreadable(let folder, let reason):
            return "TextMouth can't read the folder \(folder): \(reason)."
        case .libraryMissing:
            return "The folder is there, but the library isn't in it."
        case .differentLibrary:
            return "The folder is there, but it holds a different TextMouth library."
        case .identityUnreadable(_, let reason):
            return "The folder is there, but TextMouth can't read its library identity file: \(reason)"
        case .notDownloaded(let provider, _):
            return "The library index is in \(provider?.displayName ?? "the cloud") and isn't on this Mac yet."
        }
    }

    /// Why a folder in `provider`'s folder may be missing: the service's
    /// own folder is gone, as when it is signed out, or the folder alone is.
    private static func likelyCause(in provider: CloudProvider, serviceFolderMissing: Bool) -> String {
        guard serviceFolderMissing else {
            return "It may have been moved or renamed, or \(provider.displayName) may not have synced it to this Mac yet."
        }
        if provider == .iCloudDrive {
            return "iCloud Drive may be turned off or signed out."
        }
        return "\(provider.displayName) may be signed out or not running."
    }

    /// The reason as a debug log line gives it: the folder by its name
    /// alone (`DiagnosticLog.loggablePath`), never by its absolute path.
    var logDescription: String {
        let name = DiagnosticLog.loggablePath(folder)
        switch self {
        case .driveNotConnected(let volume, _):
            return "the drive \(volume) holding \(name) isn't connected"
        case .cloudFolderMissing(let provider, let serviceFolderMissing, _):
            return "\(name) is missing in \(provider.displayName)"
                + (serviceFolderMissing ? ", whose own folder is missing too" : "")
        case .folderMissing:
            return "\(name) is missing"
        case .notAFolder:
            return "\(name) is a file, not a folder"
        case .unreadable(_, let reason):
            return "\(name) can't be read: \(reason)"
        case .libraryMissing:
            return "\(name) holds no library"
        case .differentLibrary:
            return "\(name) holds a different library"
        case .identityUnreadable(_, let reason):
            return "the identity marker in \(name) can't be read: \(reason)"
        case .notDownloaded(let provider, _):
            return "the library index in \(name) is only in \(provider?.displayName ?? "the cloud"); asked to download it"
        }
    }

    /// Why the folder at `folder`, which doesn't exist, can't be found: its
    /// drive isn't connected, its cloud service's folder is missing, or it
    /// is simply gone. Decided from the path, with the two questions that
    /// need the file system passed in, so tests never look in /Volumes.
    /// - Parameters:
    ///   - home: The home directory whose Library holds the cloud folders.
    ///   - isMountedVolume: Whether a volume is mounted at a /Volumes path.
    ///   - exists: Whether anything exists at a path.
    static func missingFolder(
        _ folder: String,
        home: URL,
        isMountedVolume: (String) -> Bool,
        exists: (String) -> Bool
    ) -> DataDirectoryUnavailability {
        if let volume = DataDirectoryPaths.volume(holding: folder), !isMountedVolume(volume.mountPoint) {
            return .driveNotConnected(volume: volume.name, folder: folder)
        }
        if let cloud = DataDirectoryPaths.cloudFolder(holding: folder, home: home) {
            return .cloudFolderMissing(
                cloud.provider,
                serviceFolderMissing: !exists(cloud.serviceFolder),
                folder: folder
            )
        }
        return .folderMissing(folder: folder)
    }
}

// MARK: - Reading Locations From Their Paths

/// What a data directory's path alone says about where it is (FR02): the
/// drive it is on, or the cloud service whose folder holds it. A missing
/// folder has no metadata to ask, so these read the path.
enum DataDirectoryPaths {
    /// The drive mounted under /Volumes that `path` lies on: its name and
    /// its mount point. Nil for a path anywhere else.
    static func volume(holding path: String) -> (name: String, mountPoint: String)? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count >= 3, components[0] == "/", components[1] == "Volumes" else { return nil }
        return (components[2], "/Volumes/" + components[2])
    }

    /// The cloud service whose folder in `home` holds `path`, and that
    /// folder: iCloud Drive's in ~/Library/Mobile Documents, or a File
    /// Provider drive's in ~/Library/CloudStorage, named as the drive names
    /// its folder ("GoogleDrive-…", "Dropbox", "OneDrive-Personal"). Nil for
    /// a path in no such folder.
    static func cloudFolder(holding path: String, home: URL) -> (provider: CloudProvider, serviceFolder: String)? {
        let library = home.standardizedFileURL.appendingPathComponent("Library", isDirectory: true)
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let service = child(of: library.appendingPathComponent("Mobile Documents").path, holding: standardized) {
            return (.iCloudDrive, service)
        }
        if let service = child(of: library.appendingPathComponent("CloudStorage").path, holding: standardized) {
            return (provider(namedBy: (service as NSString).lastPathComponent), service)
        }
        return nil
    }

    /// The sync service a folder in ~/Library/CloudStorage belongs to, from
    /// the folder's name: Google Drive's and Dropbox's by their prefixes,
    /// any other by the part of the name before its first hyphen.
    static func provider(namedBy folderName: String) -> CloudProvider {
        if folderName.hasPrefix("GoogleDrive") { return .googleDrive }
        if folderName.hasPrefix("Dropbox") { return .dropbox }
        let service = folderName.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        return .other(service.isEmpty ? folderName : service)
    }

    /// Whether `path` lies inside a Trash folder: a home's .Trash or a
    /// volume's .Trashes. A bookmark follows a folder moved to the Trash, and
    /// a library there must not be opened as if it had only been renamed.
    static func isInTrash(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// The direct child of `parent` that `path` is, or lies inside: the
    /// service's folder for a path deeper in it. Nil when `path` is not
    /// below `parent`.
    private static func child(of parent: String, holding path: String) -> String? {
        guard path.hasPrefix(parent + "/") else { return nil }
        guard let name = path.dropFirst(parent.count + 1).split(separator: "/").first else { return nil }
        return parent + "/" + name
    }
}

// MARK: - The Check

/// Whether the data directory can be used, read from file-system metadata
/// alone (FR02). The library model runs it at launch, before anything is
/// created or loaded, on Try Again, and when the folder may have gone.
///
/// The default location, ~/.TextMouth, is always available: it is created
/// when missing, as on a first launch. A custom location is available only
/// when its folder exists, can be read, and holds this library: an identity
/// marker naming the library this Mac expects, or, for a library given no
/// identity yet, a library index. When the folder is missing but its
/// bookmark leads to a folder holding this library under another path, as
/// after the folder was renamed or its drive remounted under another name,
/// that folder is the data directory.
///
/// The whole check runs inside `DatalessFiles.withoutDownloading`, so it
/// never waits on the network: the identity marker's few bytes are the only
/// content it reads, and only when they are on this Mac. When the index or
/// the marker is only in the cloud, it asks the sync service to download
/// them, and the library stays unavailable until a later check finds them.
struct DataDirectoryCheck {
    /// The data directory, as the current storage generation names it.
    var root: URL
    /// Whether `root` is the default location.
    var isDefaultLocation: Bool
    /// The identity of the library this Mac expects there, if it knows one.
    var expectedIdentity: UUID?
    /// The bookmark of the folder, which can find it under another path.
    var bookmark: Data?
    /// The home directory, whose Library holds the cloud services' folders.
    var home: URL

    /// What the check found.
    enum Outcome: Equatable {
        /// The library is there. Its identity is nil when it has none yet.
        /// `relocatedTo` names the folder the bookmark found when the path
        /// is missing; nil when the library is at `root`.
        case available(LibraryIdentity?, relocatedTo: URL?)
        /// The library can't be used, for this reason.
        case unavailable(DataDirectoryUnavailability)
    }

    /// The check of the data directory at `root`, with this Mac's
    /// expectations from `preferences`, for a process with `runtime`.
    static func of(root: URL, preferences: UserDefaults, runtime: TextMouthRuntime = .current) -> DataDirectoryCheck {
        DataDirectoryCheck(
            root: root,
            isDefaultLocation: root.standardizedFileURL.path
                == TextMouthPaths.defaultRoot(in: runtime.homeDirectory).standardizedFileURL.path,
            expectedIdentity: DataDirectoryPreferences.expectedIdentity.read(from: preferences),
            bookmark: DataDirectoryPreferences.bookmark.read(from: preferences),
            home: runtime.homeDirectory
        )
    }

    /// Runs the check, asking `itemStatus` where files are and for the
    /// downloads it needs. Never waits on the network.
    func run(itemStatus: any CloudItemStatusProviding) -> Outcome {
        DatalessFiles.withoutDownloading {
            assess(itemStatus: itemStatus)
        }
    }

    /// The folder the bookmark leads to when the data directory's path is
    /// missing and that folder holds this library under another path, with
    /// the library's identity. Reads metadata, and the marker only when it
    /// is on this Mac. Launch takes its first data directory from here
    /// (`TextMouthPaths.root(for:)`), before anything else reads one.
    func relocatedLibrary() -> (folder: URL, identity: LibraryIdentity?)? {
        DatalessFiles.withoutDownloading {
            guard case .missing = FolderState(of: root) else { return nil }
            return libraryFoundByBookmark()
        }
    }

    // MARK: Steps

    /// The check itself, on a thread that leaves dataless files in the cloud.
    private func assess(itemStatus: any CloudItemStatusProviding) -> Outcome {
        if isDefaultLocation {
            // Today's first-run behavior: created when missing, never refused.
            return .available(try? LibraryIdentity.read(in: root), relocatedTo: nil)
        }
        switch FolderState(of: root) {
        case .folder:
            return assessLibrary(in: root, itemStatus: itemStatus)
        case .missing:
            if let relocated = libraryFoundByBookmark() {
                return .available(relocated.identity, relocatedTo: relocated.folder)
            }
            return .unavailable(.missingFolder(
                root.path,
                home: home,
                isMountedVolume: FolderState.isMountPoint,
                exists: { FileManager.default.fileExists(atPath: $0) }
            ))
        case .notAFolder:
            return .unavailable(.notAFolder(folder: root.path))
        case .unreadable(let reason):
            return .unavailable(.unreadable(folder: root.path, reason: reason))
        case .onlyInCloud:
            return notDownloaded([Self.libraryIndex(in: root)], in: root, itemStatus: itemStatus)
        }
    }

    /// Whether the readable folder at `folder` holds this library, and its
    /// identity when it does.
    private func assessLibrary(in folder: URL, itemStatus: any CloudItemStatusProviding) -> Outcome {
        let marker = LibraryIdentity.markerURL(in: folder)
        let index = Self.libraryIndex(in: folder)
        let inCloud = [marker, index].filter { Self.isOnlyInCloud($0, itemStatus: itemStatus) }
        guard inCloud.isEmpty else {
            return notDownloaded(inCloud, in: folder, itemStatus: itemStatus)
        }
        let identity: LibraryIdentity?
        do {
            identity = try LibraryIdentity.read(in: folder)
        } catch where DatalessFiles.isDownloadRefusal(error) {
            return notDownloaded([marker], in: folder, itemStatus: itemStatus)
        } catch {
            return .unavailable(.identityUnreadable(folder: folder.path, reason: error.localizedDescription))
        }
        if let identity {
            if let expectedIdentity, identity.id != expectedIdentity {
                return .unavailable(.differentLibrary(folder: folder.path))
            }
            return .available(identity, relocatedTo: nil)
        }
        // A library from before identities is known by its index.
        guard FileManager.default.fileExists(atPath: index.path) else {
            return .unavailable(.libraryMissing(folder: folder.path))
        }
        return .available(nil, relocatedTo: nil)
    }

    /// The library this Mac expects, found through the bookmark in a folder
    /// at another path; nil when the bookmark leads nowhere, back to the
    /// missing path, into a Trash, or to a folder holding another library.
    /// With no identity expected yet, a folder holding any library counts:
    /// the bookmark follows the very folder that was chosen.
    private func libraryFoundByBookmark() -> (folder: URL, identity: LibraryIdentity?)? {
        guard let bookmark else { return nil }
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        let folder = resolved.standardizedFileURL
        guard folder.path != root.standardizedFileURL.path,
              !DataDirectoryPaths.isInTrash(folder.path),
              case .folder = FolderState(of: folder) else { return nil }
        let identity = try? LibraryIdentity.read(in: folder)
        if let expectedIdentity {
            guard identity?.id == expectedIdentity else { return nil }
        } else {
            guard identity != nil || FileManager.default.fileExists(atPath: Self.libraryIndex(in: folder).path) else {
                return nil
            }
        }
        return (folder, identity)
    }

    /// Asks the sync service to download `files`, the library's index or
    /// identity marker, and reports the library as waiting for them.
    private func notDownloaded(_ files: [URL], in folder: URL, itemStatus: any CloudItemStatusProviding) -> Outcome {
        for file in files {
            try? itemStatus.requestDownload(of: file)
        }
        return .unavailable(.notDownloaded(itemStatus.location(of: folder).provider, folder: folder.path))
    }

    /// library.json in the data directory at `folder`.
    private static func libraryIndex(in folder: URL) -> URL {
        folder.appendingPathComponent("library.json", isDirectory: false)
    }

    /// Whether the file at `file` exists with its content only in the
    /// cloud: as the sync service reports it, or as the file system marks
    /// it (`SF_DATALESS`).
    private static func isOnlyInCloud(_ file: URL, itemStatus: any CloudItemStatusProviding) -> Bool {
        switch itemStatus.status(of: file).state {
        case .notDownloaded, .downloading:
            return true
        case .local, .downloaded, .missing:
            return DatalessFiles.isDataless(file)
        }
    }
}

/// What is at a data directory's location, from one stat(2) that follows
/// links, and an access(2) check of a folder found there.
private enum FolderState {
    /// A folder TextMouth can list and read.
    case folder
    /// Nothing, or a link leading nowhere.
    case missing
    /// A file, or anything else that is not a folder.
    case notAFolder
    /// Something TextMouth isn't allowed to examine or list, with why.
    case unreadable(String)
    /// A folder whose listing is only in the cloud, which looking inside
    /// would download.
    case onlyInCloud

    /// What is at `url` now.
    init(of url: URL) {
        var status = stat()
        let examined = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return stat(path, &status)
        }
        guard examined == 0 else {
            self = Self.failure(errno)
            return
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            self = .notAFolder
            return
        }
        let readable = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return access(path, R_OK | X_OK)
        }
        self = readable == 0 ? .folder : Self.failure(errno)
    }

    /// The state a failed stat(2) or access(2), with `code`, reveals.
    private static func failure(_ code: Int32) -> FolderState {
        switch code {
        case ENOENT, ENOTDIR:
            return .missing
        case EDEADLK:
            return .onlyInCloud
        case EACCES, EPERM:
            return .unreadable("permission denied")
        default:
            return .unreadable(String(cString: strerror(code)).lowercased())
        }
    }

    /// Whether a volume is mounted at `path`: something is there, on
    /// another device than the folder holding it.
    static func isMountPoint(_ path: String) -> Bool {
        var point = stat()
        var parent = stat()
        guard stat(path, &point) == 0,
              stat((path as NSString).deletingLastPathComponent, &parent) == 0 else { return false }
        return point.st_dev != parent.st_dev
    }
}
