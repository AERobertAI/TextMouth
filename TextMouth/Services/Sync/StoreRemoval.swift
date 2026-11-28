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
    /// The book became busy (opened, played, kept, listed, edited, exported) or the setting changed, or sync stopped,
    /// between the proof and the removal: nothing was removed.
    case busy
    /// Reading the copy back needs room on this device for one more copy of the book, and there is none.
    case needsRoom
    /// The book has no file of its own on this device to remove: it is away already.
    case nothingToRemove

    /// The reason in a few English words for a debug log line, which stays English. It names no file: a path in a
    /// package holds the book's title, which a sync's lines never carry.
    var logReason: String {
        switch self {
        case .notBackedUp: return "the book has no copy in the sync folder" // l10n: no (debug log text)
        case .missingFromFolder: return "the sync folder lacks a file of the copy" // l10n: no (debug log text)
        case .notUploaded: return "a file of the copy is not reported uploaded" // l10n: no (debug log text)
        case .uploadFailed: return "an upload of the copy failed" // l10n: no (debug log text)
        case .changedHere: return "a file here is not the backed-up one" // l10n: no (debug log text)
        case .doesNotMatch: return "a file read back does not match" // l10n: no (debug log text)
        case .offline: return "offline" // l10n: no (debug log text)
        case .needsDownload: return "reading it back would download over a costly connection" // l10n: no (debug log text)
        case .folderUnreachable: return "the sync folder did not answer" // l10n: no (debug log text)
        case .couldNotRemove: return "a file could not be removed" // l10n: no (debug log text)
        case .busy: return "the book became busy before its files went" // l10n: no (debug log text)
        case .needsRoom: return "no room to read the copy back" // l10n: no (debug log text)
        case .nothingToRemove: return "the book has no file of its own here" // l10n: no (debug log text)
        }
    }
}

// MARK: - The Last Look Before Files Go (FR46)

/// What the library checks again, on the main actor, right before a removal writes its pointer: the book's rows,
/// its protections, the setting, whether sync is on and the library may change, and that the package about to change
/// is still the book's. A command or sweep sets it around its call into the storage (a task-local value, so it reaches
/// the removal however deep the call goes); with none set, nothing more is asked.
///
/// It is asked inside the removal's storage work (`StorageWork.removingSyncedDownloads`), in one step with what
/// follows a yes: the library marks the book busy then (`BooksBeingFreed`), so nothing it asked about can begin
/// between its answer and the files' going.
enum FreeingCheck {
    /// Answers whether the book whose package is at the URL, where the data directory is now, may still be freed.
    @TaskLocal static var current: (@MainActor @Sendable (URL) -> Bool)?
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
/// Steps 4 and 5, with the last look before them, are storage work
/// (`StorageBoundary.perform`): a data-directory move waits for them, and while
/// one holds the work they wait, then look at the package where the move left it.
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
    /// Asked on the main actor right before the pointer is written, after the files have been looked at again, with
    /// the package where it is then: false stops the removal (`.busy`). The library's last word (`FreeingCheck`).
    var finalCheck: (@MainActor @Sendable (URL) -> Bool)? = nil
    /// The boundary between data-directory moves and the work that writes into the data directory, which the last
    /// look and the removal run inside: the app's, unless a test holds one of its own.
    var boundary: StorageBoundary = .shared
    /// Told when the last look and the removal must wait because an operation holds the storage work (a data-directory
    /// move): the debug log says so, and a test learns the removal is waiting.
    var whileHeld: @Sendable () -> Void = {
        DiagnosticLog.event(.storage, "SYNC_REMOVAL_WAITING: storage work is held, so a removal waits") // l10n: no (debug log text)
    }
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
        guard !ownFiles.isEmpty else { throw SyncRemovalRefusal.nothingToRemove }

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
        // A costly connection reads back only what is already on this device: said before anything is hashed.
        if !mayDownload, blobs.contains(where: { listing[$0.blob]?.isOnThisDevice != true }) { throw SyncRemovalRefusal.needsDownload }
        // The names of the copy's every file in the folder: its blobs, and the manifest that lists them.
        let copyNames = blobs.map(\.blob) + [pointer.manifest]
        for blob in blobs {
            guard listing[blob.blob] != nil else { throw SyncRemovalRefusal.missingFromFolder(blob.blob) }
        }
        for name in copyNames {
            try Self.requireUploaded(folder.access.uploadState(of: bookFolder.appendingPathComponent(name)), name: name)
        }
        try Self.requireFilesHereAreTheStores(ownFiles, manifest: manifest)

        // Step 3: each blob read back, and its size and SHA-256 are the manifest's.
        for blob in blobs {
            try Task.checkCancellation()
            try await readBack(blob, in: bookFolder)
        }
        try checkpoint(.proven)

        // The last look and steps 4 and 5, as storage work.
        let freed = try await commit(ownFiles, manifest: manifest, pointer: pointer, package: package)

        // Last, the folder's own copies of the blobs stop taking room here; a refusal is a wait, not a failure.
        for name in copyNames {
            try? folder.access.evictLocalCopy(of: bookFolder.appendingPathComponent(name))
        }
        return Outcome(freedBytes: freed)
    }

    /// The last look, then step 4 (the pointer says the book's own files are away, before the first goes), then
    /// step 5 (the files go, one entry of the package at a time): one piece of storage work, off the main thread, so a
    /// data-directory move never copies the package while it changes (`StorageBoundary.perform`).
    ///
    /// The last look comes first, since the read-back can take minutes: the book's own files are listed again, in the
    /// package as it is now (where a move published meanwhile put it), and must be the very files that were hashed;
    /// then the library must agree the book may go (`finalCheck`, on the main actor). An edit rendered, a track added
    /// or taken away, a package moved, a book opened or kept meanwhile each stop it.
    /// - Returns: The bytes of the book's own files that went.
    private func commit(_ hashed: [OwnFile], manifest: StoreManifest, pointer: StorePointer, package: URL) async throws -> Int64 {
        let removal = self
        return try await OffMainWork.runThrowing {
            try removal.boundary.perform(.removingSyncedDownloads, whileHeld: removal.whileHeld) { _ in
                // The package where the data directory is now: a move that held this work back has published another.
                let here = URL(fileURLWithPath: removal.boundary.rebasedToCurrent(package.path), isDirectory: true)
                try Self.requireUnchanged(hashed, then: try removal.ownFilesHere(in: here))
                if let finalCheck = removal.finalCheck, !Self.answerOnTheMainActor({ finalCheck(here) }) {
                    throw SyncRemovalRefusal.busy
                }
                try removal.writePointer(for: manifest, manifestName: pointer.manifest, in: here, previous: pointer)
                try removal.checkpoint(.pointerWritten)
                try removal.removeEntries(of: hashed, in: here)
                try removal.checkpoint(.allRemoved)
                return hashed.reduce(Int64(0)) { $0 + $1.size }
            }
        }
    }

    /// Asks `question` on the main actor from inside the removal's storage work, and waits for its answer, as an
    /// import's step asks the library there (`openTMBPackage`). The main queue is free to answer: whoever runs a
    /// removal awaits it rather than blocking, and no operation on the main thread waits for storage work under way
    /// without suspending. A call made on the main thread, which only a test's own thread can be, asks at once.
    private static func answerOnTheMainActor(_ question: @escaping @MainActor @Sendable () -> Bool) -> Bool {
        if Thread.isMainThread { return MainActor.assumeIsolated { question() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { question() } }
    }

    // MARK: The book's files here

    /// A file of the book's own, here: where it is, its path in the package, and its size.
    struct OwnFile: Equatable, Sendable {
        var path: String
        var url: URL
        var size: Int64
        /// When the file was last changed, and which file it is on the volume: with its size, what tells the file
        /// that was hashed from one an editor wrote over, or replaced, while the copy was read back.
        var modified: Date?
        var fileNumber: UInt64?
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
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path)
            return OwnFile(
                path: file.path, url: file.url, size: size,
                modified: attributes?[.modificationDate] as? Date,
                fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
            )
        }
    }

    /// The files are the ones that were hashed: none was changed, replaced, added, or taken away; `current` is what is
    /// there now. A file gone is a change too: an edit that took a track away, or a package moved or removed
    /// meanwhile, which holds none of them, so nothing is ever reported freed that this removal did not free.
    private static func requireUnchanged(_ hashed: [OwnFile], then current: [OwnFile]) throws {
        let before = Dictionary(hashed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Set(current.map(\.path))
        if let gone = hashed.first(where: { !now.contains($0.path) }) { throw SyncRemovalRefusal.changedHere(gone.path) }
        for file in current {
            guard let was = before[file.path], was.size == file.size, was.modified == file.modified, was.fileNumber == file.fileNumber else {
                throw SyncRemovalRefusal.changedHere(file.path)
            }
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
        // A copy staged for the read-back that finds the disk full is a need for room, not a damaged copy.
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return SyncRemovalRefusal.needsRoom }
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
