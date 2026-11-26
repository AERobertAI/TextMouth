import Foundation

// MARK: - Why a Download Stays (FR46)

/// Why the removal of a book's download did not happen: the proof that the sync
/// folder holds every file of the book fell short somewhere, or the files could
/// not be taken away. In each case the book stays whole on this device; the
/// words are `SyncWording.removalRefusal`.
///
/// The detail a case holds is for the debug log (a blob's name, a path): a
/// digest or a file's name, never read aloud.
enum SyncRemovalRefusal: Error, Equatable, Sendable {
    /// The book has no copy in the store: no pointer names a manifest, or it names another store's.
    case notBackedUp
    /// The folder lacks a file the manifest names.
    case missingFromFolder(String)
    /// iCloud Drive does not report a file of the copy uploaded: still uploading, or it says nothing.
    case notUploaded(String)
    /// iCloud Drive reports an upload that failed (its room, or an error).
    case uploadFailed(String)
    /// A file of the book here is not the one the store holds: the book was changed here since it was backed up.
    case changedHere(String)
    /// What was read back from the folder is not what the manifest says, or the manifest itself is damaged.
    case doesNotMatch(String)
    /// The copy cannot be read: this device is offline.
    case offline
    /// Reading the copy back would download files over a connection that costs (cellular, Low Data Mode).
    case needsDownload
    /// The folder, or a file in it, did not arrive in time or is not there.
    case folderUnreachable
    /// A file of the book could not be taken off this device.
    case couldNotRemove(String)

    /// The reason in a few English words for a debug log line, which stays English.
    var logReason: String {
        switch self {
        case .notBackedUp: return "the book has no copy in the sync folder" // l10n: no (debug log text)
        case .missingFromFolder(let file): return "the sync folder lacks \(file)" // l10n: no (debug log text)
        case .notUploaded(let file): return "\(file) is not reported uploaded" // l10n: no (debug log text)
        case .uploadFailed(let file): return "the upload of \(file) failed" // l10n: no (debug log text)
        case .changedHere(let file): return "\(file) here is not the backed-up one" // l10n: no (debug log text)
        case .doesNotMatch(let file): return "\(file) read back does not match" // l10n: no (debug log text)
        case .offline: return "offline" // l10n: no (debug log text)
        case .needsDownload: return "reading it back would download over a costly connection" // l10n: no (debug log text)
        case .folderUnreachable: return "the sync folder did not answer" // l10n: no (debug log text)
        case .couldNotRemove(let file): return "\(file) could not be removed" // l10n: no (debug log text)
        }
    }
}

// MARK: - Removing a Synced Book's Download (FR46)

/// Frees a book's files on this device while the book stays in the library as a
/// placeholder that says In Cloud (`SyncPlaceholder`): its record, place,
/// bookmarks, and details stay, and `StoreFetch` brings the files back.
///
/// The rule above every other: a device never removes the last copy of a book.
/// A file goes only when the TextMouth Sync folder holds every file of the book,
/// proven in this order, each step before the next:
/// 1. the pointer names a manifest, and the manifest in the folder is what its name says;
/// 2. every blob the manifest names, and the manifest, is in the folder and iCloud
///    Drive reports it uploaded, and each file here that would go is the manifest's
///    file (size and SHA-256);
/// 3. each blob is read back from the folder and its size and SHA-256 are the manifest's;
/// 4. only then the pointer is written, with every file about to go marked away;
/// 5. only then are the files removed.
///
/// A stop at any step leaves the book whole, or a placeholder whose blobs are
/// proven; never neither. Anything short of the proof (offline, still uploading,
/// a blob missing, a read that fails, a digest that differs) throws a
/// `SyncRemovalRefusal` and changes nothing here.
///
/// Only the book's own files go (`StoreBackup.role` "content": its file or tracks);
/// the record, the text, and every other file stay, so a text book still reads.
struct StoreRemoval: Sendable {
    /// The folder the proof reads.
    let folder: SyncFolder
    /// The store's ID, which the book's pointer must name.
    let storeID: UUID
    /// This device's `Staging/`, where a blob read back waits to be hashed.
    let staging: URL
    /// How long one file may take to arrive (section 7).
    var perFile: Duration = .seconds(60)
    /// Called after each step; a test throws from it to stop the run there, as a crash would.
    var checkpoint: @Sendable (Step) throws -> Void = { _ in }

    /// The steps of a removal, in order.
    enum Step: Equatable, Sendable {
        /// Every proof passed; nothing here has changed.
        case proven
        /// The pointer says the book's own files are away; they are all still here.
        case pointerWritten
        /// One of the book's own entries was removed (its name in the package).
        case removed(String)
        /// Every one of the book's own entries is gone.
        case allRemoved
    }

    /// What a removal did.
    struct Outcome: Equatable, Sendable {
        /// The bytes of the book's own files that were taken off this device; 0 when none were here.
        var freedBytes: Int64
    }

    // MARK: Removing

    /// Removes the book's own files from the package at `package` once the folder is proven to hold them.
    /// - Parameters:
    ///   - package: The book's package on this device.
    ///   - bookID: The book, which the pointer must name.
    ///   - mayDownload: Whether files of the copy that are away in iCloud Drive may be downloaded to read them back:
    ///     a person's command says yes on any connection; a removal nobody asked for says no on a costly one.
    /// - Returns: What was freed; 0 bytes for a book already away.
    /// - Throws: `SyncRemovalRefusal`, with this device unchanged, or `CancellationError`.
    func removeDownload(of package: URL, bookID: UUID, mayDownload: Bool) async throws -> Outcome {
        // The book's pointer must name this store and a manifest: a book never backed up is not removed.
        guard let pointer = StoreFetch.pointer(in: package), pointer.bookID == bookID, pointer.storeID == storeID,
              !pointer.manifest.isEmpty else { throw SyncRemovalRefusal.notBackedUp }

        // The book's own files here. A package with none is already away.
        let ownFiles = try ownFilesHere(in: package)
        guard !ownFiles.isEmpty else { return Outcome(freedBytes: 0) }

        // Step 1: the manifest the pointer names, read and checked.
        let bookFolder = folder.bookFolder(bookID)
        let listing = Dictionary(
            ((try? folder.access.list(bookFolder)) ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let manifest = try await readManifest(named: pointer.manifest, bookID: bookID, in: bookFolder, listing: listing, mayDownload: mayDownload)

        // Step 2: every file of the copy is in the folder and reported uploaded. These are the cheap looks: they
        // come before the files here are hashed and before anything is read back, so a book that is not backed up
        // yet costs nothing to refuse.
        let blobs = Self.uniqueBlobs(of: manifest)
        // The names of the copy's every file in the folder: its blobs, and the manifest that lists them.
        let copyNames = blobs.map(\.blob) + [pointer.manifest]
        for blob in blobs {
            guard listing[blob.blob] != nil else { throw SyncRemovalRefusal.missingFromFolder(blob.blob) }
        }
        for name in copyNames {
            try Self.requireUploaded(folder.access.uploadState(of: bookFolder.appendingPathComponent(name)), name: name)
        }
        try Self.requireFilesHereAreTheStores(ownFiles, manifest: manifest)

        // Step 3: each blob read back, and its size and SHA-256 are the manifest's. A costly connection reads
        // back only what is already on this device.
        if !mayDownload, blobs.contains(where: { listing[$0.blob]?.isOnThisDevice != true }) { throw SyncRemovalRefusal.needsDownload }
        for blob in blobs {
            try Task.checkCancellation()
            try await readBack(blob, in: bookFolder)
        }
        try checkpoint(.proven)

        // Step 4: the pointer says the book's own files are away, before the first goes.
        try writePointer(for: manifest, manifestName: pointer.manifest, in: package, previous: pointer)
        try checkpoint(.pointerWritten)

        // Step 5: the files go, one entry of the package at a time.
        try removeEntries(of: ownFiles, in: package)
        try checkpoint(.allRemoved)

        // Last, the folder's own copies of the blobs stop taking room here; a refusal is a wait, not a failure.
        for name in copyNames {
            try? folder.access.evictLocalCopy(of: bookFolder.appendingPathComponent(name))
        }
        return Outcome(freedBytes: ownFiles.reduce(Int64(0)) { $0 + $1.size })
    }

    // MARK: The book's files here

    /// A file of the book's own, here: where it is, its path in the package, and its size.
    struct OwnFile: Equatable, Sendable {
        var path: String
        var url: URL
        var size: Int64
    }

    /// The files of the package that are the book's own (its file or tracks), found without following a link.
    /// A package holding a symbolic link has no proof to give: it is `changedHere`.
    private func ownFilesHere(in package: URL) throws -> [OwnFile] {
        let files: [StoreBackup.PackageFile]
        do {
            files = try StoreBackup.files(of: package)
        } catch SyncProblem.damaged(let path) {
            throw SyncRemovalRefusal.changedHere(path)
        }
        return files.filter { StoreBackup.role(of: $0.path) == "content" }.map { file in
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return OwnFile(path: file.path, url: file.url, size: size)
        }
    }

    /// The package's entries (its top-level names) that hold the book's own files, in a fixed order.
    private static func entryNames(of files: [OwnFile]) -> [String] {
        Set(files.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path }).sorted()
    }

    /// Takes each entry that holds the book's own files off this device.
    private func removeEntries(of files: [OwnFile], in package: URL) throws {
        for name in Self.entryNames(of: files) {
            let entry = package.appendingPathComponent(name)
            do {
                if FileManager.default.fileExists(atPath: entry.path) { try FileManager.default.removeItem(at: entry) }
            } catch {
                throw SyncRemovalRefusal.couldNotRemove(name)
            }
            try checkpoint(.removed(name))
        }
    }

    // MARK: The proof

    /// Reads the manifest the pointer names and checks it is what its name says, for this book, with safe paths.
    private func readManifest(
        named name: String, bookID: UUID, in bookFolder: URL, listing: [String: SyncFolderItem], mayDownload: Bool
    ) async throws -> StoreManifest {
        guard let item = listing[name] else { throw SyncRemovalRefusal.missingFromFolder(name) }
        if !mayDownload, !item.isOnThisDevice { throw SyncRemovalRefusal.needsDownload }
        let data: Data
        do {
            data = try await folder.access.read(bookFolder.appendingPathComponent(name), within: perFile)
        } catch {
            throw Self.refusal(for: error, file: name)
        }
        // The manifest's name is the digest of its bytes: a damaged or swapped file is refused, as a fetch refuses it.
        guard StoreBackup.manifestName(for: data) == name,
              let manifest = try? SyncFormats.decodeManifest(data, named: name),
              manifest.bookID == bookID,
              manifest.files.allSatisfy(StoreFetch.isSafe) else { throw SyncRemovalRefusal.doesNotMatch(name) }
        return manifest
    }

    /// Each file here that would go is the manifest's file at its path: the same size and the same SHA-256, so the
    /// blob proven below is exactly what leaves this device. Anything else is a change not backed up.
    private static func requireFilesHereAreTheStores(_ files: [OwnFile], manifest: StoreManifest) throws {
        let byPath = Dictionary(manifest.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for file in files {
            guard let entry = byPath[file.path], entry.size == file.size,
                  (try? FileDigest.sha256(of: file.url)) == entry.sha256 else { throw SyncRemovalRefusal.changedHere(file.path) }
        }
    }

    /// The manifest's blobs, each once, in a fixed order: two files of one content share a blob.
    private static func uniqueBlobs(of manifest: StoreManifest) -> [StoreManifest.File] {
        var seen = Set<String>()
        return manifest.files.sorted { $0.blob < $1.blob }.filter { seen.insert($0.blob).inserted }
    }

    /// Only an upload iCloud Drive reports done is proof: still uploading and "no report" both mean not yet.
    private static func requireUploaded(_ state: SyncUploadState, name: String) throws {
        switch state {
        case .uploaded: return
        case .uploading, .notReported: throw SyncRemovalRefusal.notUploaded(name)
        case .failed: throw SyncRemovalRefusal.uploadFailed(name)
        }
    }

    /// Reads `blob` back from the folder into staging, compares its size and SHA-256 with the manifest's, and
    /// leaves nothing in staging whichever way it goes.
    private func readBack(_ blob: StoreManifest.File, in bookFolder: URL) async throws {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent(UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            try await folder.access.fetch(bookFolder.appendingPathComponent(blob.blob), to: staged, within: perFile)
        } catch {
            throw Self.refusal(for: error, file: blob.blob)
        }
        let size = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        guard size == blob.size, (try? FileDigest.sha256(of: staged)) == blob.sha256 else {
            throw SyncRemovalRefusal.doesNotMatch(blob.blob)
        }
    }

    /// The refusal for an error a read of the folder threw.
    private static func refusal(for error: Error, file: String) -> Error {
        if error is CancellationError { return error }
        switch error as? SyncProblem {
        case .offline: return SyncRemovalRefusal.offline
        case .damaged: return SyncRemovalRefusal.doesNotMatch(file)
        case .some: return SyncRemovalRefusal.folderUnreachable
        case nil: return SyncRemovalRefusal.doesNotMatch(file)
        }
    }

    // MARK: The pointer

    /// Writes the pointer so every file of the book's own is away and the rest are as they are here. Written
    /// atomically, after the proof and before any file goes.
    private func writePointer(for manifest: StoreManifest, manifestName: String, in package: URL, previous: StorePointer) throws {
        let files = manifest.files.map { file -> StorePointer.File in
            let isOwn = StoreBackup.role(of: file.path) == "content"
            let here = !isOwn && FileManager.default.fileExists(atPath: package.appendingPathComponent(file.path).path)
            let modified = previous.files.first { $0.path == file.path }?.modified ?? 0
            return StorePointer.File(path: file.path, sha256: file.sha256, size: file.size, modified: modified, onThisDevice: here)
        }
        let pointer = StorePointer(
            formatVersion: SyncFormats.currentVersion, storeID: storeID, bookID: manifest.bookID,
            manifest: manifestName, uploaded: manifestName, files: files
        )
        try StoreFetch.write(pointer, in: package)
    }
}
