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

// MARK: - Nothing Written Where the Library Isn't

/// The data directories the library model found unavailable (FR02), which
/// nothing may create or write into until a check finds the library there
/// again.
///
/// The library model closes the gate of a data directory its check finds
/// unavailable and opens it when a check finds the library. While the data
/// directory in use is closed, `TextMouthPaths.ensureDirectoryStructure()`,
/// which every writer of the data directory's own files calls first,
/// refuses, and library index writes are skipped. Gates are kept by path,
/// so one closed for a data directory no longer in use, such as one a test
/// published and put back, closes no other.
enum DataDirectoryGate {
    /// Guards `closedRoots`: writers ask from their own queues.
    private static let lock = NSLock()
    /// The standardized paths of the closed data directories, read and
    /// changed only under `lock`.
    nonisolated(unsafe) private static var closedRoots: Set<String> = []

    /// Closes the gate of the data directory at `root`.
    static func close(_ root: URL) {
        lock.withLock { _ = closedRoots.insert(key(root)) }
    }

    /// Opens the gate of the data directory at `root` again.
    static func open(_ root: URL) {
        lock.withLock { _ = closedRoots.remove(key(root)) }
    }

    /// Whether the gate of the data directory at `root` is closed.
    static func isClosed(_ root: URL) -> Bool {
        lock.withLock { closedRoots.contains(key(root)) }
    }

    /// How a data directory is known here: its standardized path.
    private static func key(_ root: URL) -> String {
        root.standardizedFileURL.path
    }
}

/// How the library learns that its data directory came and went (FR02).
enum DataDirectoryEvents {
    /// The `userInfo` key of the data directory's path in a
    /// `.dataDirectoryWriteFoundFolderMissing` notification.
    static let rootKey = "root"

    /// Tells the library model, on the main thread, that a write found the
    /// folder of the data directory at `root` missing, as when its drive was
    /// unplugged or its cloud service signed out. Writers call this from
    /// their own queues.
    static func reportMissingFolder(_ root: URL) {
        let path = root.path
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .dataDirectoryWriteFoundFolderMissing,
                object: nil,
                userInfo: [rootKey: path]
            )
        }
    }
}

extension Notification.Name {
    /// Posted on the main thread when a write found the data directory's
    /// folder missing, with its path under `DataDirectoryEvents.rootKey`:
    /// the library model checks the data directory again (FR02).
    static let dataDirectoryWriteFoundFolderMissing = Notification.Name("dataDirectoryWriteFoundFolderMissing")

    /// Posted on the main thread when the library model finds the data
    /// directory available again after it was not (FR02): services that
    /// left their files unread while it was missing read them now.
    static let dataDirectoryDidBecomeAvailable = Notification.Name("dataDirectoryDidBecomeAvailable")
}

/// Thrown in place of creating a data directory that is missing, or of
/// writing into one the library model found unavailable (FR02). Its
/// description follows what failed, as in "Listening statistics could not
/// be saved: The library at /Volumes/Backup/TextMouth isn't available."
struct DataDirectoryUnavailableError: LocalizedError, Equatable {
    /// The data directory, as the current storage generation names it.
    let root: URL

    var errorDescription: String? {
        "The library at \(root.path) isn't available."
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
    /// The identity marker, library.json, or a feed's folder or index is only
    /// in the cloud, and TextMouth asked the sync service for it. `provider`
    /// is nil when the service is unknown.
    case notDownloaded(CloudProvider?, folder: String)
    /// Those files are only in the cloud, and TextMouth is reading them now
    /// to bring them to this Mac; the library opens by itself when they
    /// arrive. `files` are the first pass's, by name in the data directory.
    case gettingFromCloud(CloudProvider?, folder: String, files: [String])
    /// TextMouth tried to bring those files from the cloud and could not;
    /// Try Again starts over. `ending` says in a few words how the fetch
    /// ended, for the debug log (never an absolute path).
    case cloudFetchFailed(CloudProvider?, folder: String, files: [String], ending: String)

    /// The data directory's full path, as the screen shows it.
    var folder: String {
        switch self {
        case .driveNotConnected(_, let folder), .cloudFolderMissing(_, _, let folder), .folderMissing(let folder),
             .notAFolder(let folder), .unreadable(let folder, _), .libraryMissing(let folder),
             .differentLibrary(let folder), .identityUnreadable(let folder, _), .notDownloaded(_, let folder),
             .gettingFromCloud(_, let folder, _), .cloudFetchFailed(_, let folder, _, _):
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
            return Self.notOnThisMac(provider)
        case .gettingFromCloud(let provider, _, _):
            return Self.notOnThisMac(provider) + " TextMouth is getting them now, and the library opens when they arrive."
        case .cloudFetchFailed(let provider, _, _, _):
            return "TextMouth couldn't get the library's files from \(Self.service(provider)). "
                + Self.whatToCheck(provider)
        }
    }

    /// The first sentence of both download reasons.
    private static func notOnThisMac(_ provider: CloudProvider?) -> String {
        "Some of the library's files are in \(service(provider)) and aren't on this Mac yet."
    }

    /// What `provider` is called in a sentence: its name, or "the cloud"
    /// when the service is unknown.
    private static func service(_ provider: CloudProvider?) -> String {
        provider?.displayName ?? "the cloud"
    }

    /// What to check when the files couldn't be fetched from `provider`,
    /// ending in the way out. iCloud Drive is not something that "runs", so
    /// it is asked about as `likelyCause(in:serviceFolderMissing:)` asks.
    private static func whatToCheck(_ provider: CloudProvider?) -> String {
        if provider == .iCloudDrive {
            return "iCloud Drive may be turned off or signed out, or this Mac may be offline. Check that, then choose Try Again."
        }
        return "Check that \(provider?.displayName ?? "the cloud service") is running and that this Mac is online, "
            + "then choose Try Again."
    }

    /// Whether TextMouth is bringing the library's files to this Mac now,
    /// which the screen's heading says (`DataDirectoryUnavailableText.title(for:)`).
    var isGettingFromCloud: Bool {
        if case .gettingFromCloud = self {
            return true
        }
        return false
    }

    /// `files` as a log line lists them: at most eight, then how many more.
    static func listed(_ files: [String]) -> String {
        let shown = files.prefix(8).joined(separator: ", ")
        return files.count > 8 ? "\(shown) and \(files.count - 8) more" : shown
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

    /// The reason as a debug log line gives it: the folder by its short
    /// name (`DataDirectoryPaths.shortName(of:)`), never its absolute path.
    var logDescription: String {
        // A folder, named as one: this runs on the main thread, where a stat(2)
        // of a path under a dataless folder would wait on the network.
        let name = DataDirectoryPaths.shortName(of: URL(fileURLWithPath: folder, isDirectory: true))
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
            return "some of the library's files in \(name) are only in \(Self.service(provider)); asked to download them"
        case .gettingFromCloud(let provider, _, let files):
            return "getting \(Self.listed(files)) in \(name) from \(Self.service(provider))"
        case .cloudFetchFailed(let provider, _, let files, let ending):
            return "could not get \(Self.listed(files)) in \(name) from \(Self.service(provider)): \(ending)"
        }
    }

    /// Why the folder at `folder`, which doesn't exist, can't be found: its
    /// drive isn't connected, its cloud service's folder is missing, or it
    /// is simply gone. Decided from the path, with the two questions that
    /// need the file system passed in, so tests never look in /Volumes.
    /// - Parameters:
    ///   - isMountedVolume: Whether a volume is mounted at a /Volumes path.
    ///   - exists: Whether anything exists at a path.
    static func missingFolder(
        _ folder: String,
        isMountedVolume: (String) -> Bool,
        exists: (String) -> Bool
    ) -> DataDirectoryUnavailability {
        if let volume = DataDirectoryPaths.volume(holding: folder), !isMountedVolume(volume.mountPoint) {
            return .driveNotConnected(volume: volume.name, folder: folder)
        }
        if let cloud = DataDirectoryPaths.cloudFolder(holding: folder) {
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

    /// The cloud service whose folder holds `path`, as the cloud services
    /// read paths (`UbiquitousItemStatusProvider.provider(forPath:)`), and
    /// that service's own folder: iCloud Drive's container in a Library's
    /// Mobile Documents, or a File Provider drive's folder in its
    /// CloudStorage. Nil for a path in no such folder.
    static func cloudFolder(holding path: String) -> (provider: CloudProvider, serviceFolder: String)? {
        var folder = URL(fileURLWithPath: path).standardizedFileURL
        guard let provider = UbiquitousItemStatusProvider.provider(forPath: folder) else { return nil }
        // The service's own folder is the shortest path still read as the
        // service's: one level up from it is the place that holds them all.
        var parent = folder.deletingLastPathComponent()
        while parent.path != folder.path, UbiquitousItemStatusProvider.provider(forPath: parent) != nil {
            folder = parent
            parent = folder.deletingLastPathComponent()
        }
        return (provider, folder.path)
    }

    /// How a debug log line names a data directory: its folder's name and
    /// the name of the folder or drive holding it ("Backup/TextMouth"),
    /// never its absolute path (`DiagnosticLog`'s content policy).
    static func shortName(of folder: URL) -> String {
        folder.standardizedFileURL.pathComponents.filter { $0 != "/" }.suffix(2).joined(separator: "/")
    }

    /// How a debug log line names `item` inside the data directory at
    /// `root`: by its path relative to `root` (`library.json`, `Feeds`),
    /// never an absolute path.
    static func relativeName(of item: URL, in root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = item.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { return item.lastPathComponent }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Whether `path` lies inside a Trash folder: a home's .Trash or a
    /// volume's .Trashes. A bookmark follows a folder moved to the Trash, and
    /// a library there must not be opened as if it had only been renamed.
    static func isInTrash(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }
}

// MARK: - A Location Named From Outside

/// Whether a data directory that config.json names, from an edit made
/// outside TextMouth, may start a move here (FR02). config.json travels
/// with a library in the cloud, so it can name another Mac's location: a
/// path missing on this Mac, as another user name makes it, or a folder that
/// holds a library already, this one or another. Neither starts a move;
/// Storage settings remain the way to move the library on purpose. Any
/// other location keeps today's request, which the move itself checks.
enum DataDirectoryRequest {
    /// Why the edit naming `target` is ignored, for the debug log, or nil
    /// when it may ask for a move. Reads metadata only.
    static func reasonToIgnore(_ target: URL) -> String? {
        DatalessFiles.withoutDownloading {
            let fileManager = FileManager.default
            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: target.path, isDirectory: &isFolder) else {
                return "it doesn't exist on this Mac"
            }
            let holdsLibrary = isFolder.boolValue
                && (fileManager.fileExists(atPath: LibraryIdentity.markerURL(in: target).path)
                    || fileManager.fileExists(atPath: target.appendingPathComponent("library.json").path))
            return holdsLibrary ? "it holds a TextMouth library already" : nil
        }
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
            bookmark: DataDirectoryPreferences.bookmark.read(from: preferences)
        )
    }

    /// Runs the check, asking `itemStatus` where files are and for the
    /// downloads it needs. Never waits on the network.
    func run(itemStatus: any CloudItemStatusProviding) -> Outcome {
        runNamingPending(itemStatus: itemStatus).outcome
    }

    /// Runs the check as `run(itemStatus:)` does, and also names the files
    /// it is waiting for: the identity marker, library.json, and the Feeds
    /// folder and each feed's folder and index that are only in the cloud
    /// (`pending`, empty unless the outcome is `.notDownloaded`). Those are
    /// the only files the library fetches (`LibraryFileFetch`).
    func runNamingPending(itemStatus: any CloudItemStatusProviding) -> (outcome: Outcome, pending: [URL]) {
        var pending: [URL] = []
        let outcome = DatalessFiles.withoutDownloading {
            assess(itemStatus: itemStatus, pending: &pending)
        }
        return (outcome, pending)
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
    private func assess(itemStatus: any CloudItemStatusProviding, pending: inout [URL]) -> Outcome {
        if isDefaultLocation {
            // Today's first-run behavior: created when missing, never refused.
            return .available(try? LibraryIdentity.read(in: root), relocatedTo: nil)
        }
        switch FolderState(of: root) {
        case .folder:
            return assessLibrary(in: root, itemStatus: itemStatus, pending: &pending)
        case .missing:
            if let relocated = libraryFoundByBookmark() {
                return .available(relocated.identity, relocatedTo: relocated.folder)
            }
            return .unavailable(.missingFolder(
                root.path,
                isMountedVolume: FolderState.isMountPoint,
                exists: { FileManager.default.fileExists(atPath: $0) }
            ))
        case .notAFolder:
            return .unavailable(.notAFolder(folder: root.path))
        case .unreadable(let reason):
            return .unavailable(.unreadable(folder: root.path, reason: reason))
        case .onlyInCloud:
            return notDownloaded([Self.libraryIndex(in: root)], in: root, itemStatus: itemStatus, pending: &pending)
        }
    }

    /// Whether the readable folder at `folder` holds this library, and its
    /// identity when it does.
    ///
    /// The library index is read whole at launch, on the main thread, and
    /// so is each feed's own index (FR11), so every one of them must be on
    /// this Mac first: one only in the cloud, or a folder holding them whose
    /// listing is (`feedIndexFiles(in:)`), is asked of the sync service, and
    /// the library waits for it as it waits for library.json.
    private func assessLibrary(
        in folder: URL,
        itemStatus: any CloudItemStatusProviding,
        pending: inout [URL]
    ) -> Outcome {
        let marker = LibraryIdentity.markerURL(in: folder)
        let index = Self.libraryIndex(in: folder)
        let inCloud = ([marker, index] + Self.feedIndexFiles(in: folder))
            .filter { Self.isOnlyInCloud($0, itemStatus: itemStatus) }
        guard inCloud.isEmpty else {
            return notDownloaded(inCloud, in: folder, itemStatus: itemStatus, pending: &pending)
        }
        let identity: LibraryIdentity?
        do {
            identity = try LibraryIdentity.read(in: folder)
        } catch where DatalessFiles.isDownloadRefusal(error) {
            return notDownloaded([marker], in: folder, itemStatus: itemStatus, pending: &pending)
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

    /// Asks the sync service to download `files`, the identity marker,
    /// library.json, or a feed's folder or index, and reports the library as
    /// waiting for them. `pending` receives the files, for the caller to fetch.
    private func notDownloaded(
        _ files: [URL],
        in folder: URL,
        itemStatus: any CloudItemStatusProviding,
        pending: inout [URL]
    ) -> Outcome {
        pending = files
        for file in files {
            try? itemStatus.requestDownload(of: file)
        }
        return .unavailable(.notDownloaded(itemStatus.location(of: folder).provider, folder: folder.path))
    }

    /// library.json in the data directory at `folder`.
    private static func libraryIndex(in folder: URL) -> URL {
        folder.appendingPathComponent("library.json", isDirectory: false)
    }

    /// What the library's launch reads of its feeds (FR11) in the data
    /// directory at `folder`, which must be on this Mac before it opens:
    /// the Feeds folder, and, for each feed's folder in it
    /// (`FeedPaths.feedID(ofItemsFolderNamed:)`), that folder and its index
    /// (`FeedPaths.indexFile(of:in:)`). The Feeds folder is listed as the
    /// rest of the check runs, with dataless files left in the cloud: a
    /// listing only in the cloud lists nothing, and the Feeds folder itself
    /// then answers for what it holds. Items that are not there are no
    /// concern of the caller's, which asks only which are in the cloud.
    private static func feedIndexFiles(in folder: URL) -> [URL] {
        let feeds = FeedPaths.recordsFolder(in: folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: feeds.path)) ?? []
        return [feeds] + names.sortedStably().flatMap { name -> [URL] in
            guard let feedID = FeedPaths.feedID(ofItemsFolderNamed: name) else { return [] }
            return [FeedPaths.itemsFolder(of: feedID, in: folder), FeedPaths.indexFile(of: feedID, in: folder)]
        }
    }

    /// Whether the file at `file` exists with its content only in the
    /// cloud: as the sync service reports it, or as the file system marks
    /// it (`SF_DATALESS`).
    static func isOnlyInCloud(_ file: URL, itemStatus: any CloudItemStatusProviding) -> Bool {
        switch itemStatus.status(of: file).state {
        case .notDownloaded, .downloading:
            return true
        case .local, .downloaded, .missing:
            return DatalessFiles.isDataless(file)
        }
    }
}

/// What is at a data directory's location, or at its Logs folder's
/// (`TextMouthPaths.logDestination`), from one stat(2) that follows links,
/// and an access(2) check of a folder found there. Run it with dataless
/// files left in the cloud (`DatalessFiles.withoutDownloading`), so a folder
/// only in the cloud is reported as such instead of being downloaded.
enum FolderState {
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

    /// Whether a folder TextMouth can list and read is there.
    var isFolder: Bool {
        if case .folder = self {
            return true
        }
        return false
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
