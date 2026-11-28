import Foundation

// MARK: - Fetching a Book From the Store (FR43, section 6)

/// Brings a book's files from the store into its package on this device:
/// the placeholder a device makes for a book it lacks (its record and a
/// pointer naming a manifest) becomes the whole book. Each blob is fetched
/// into `Staging/`, checked against its SHA-256 and size, and only then
/// moved in, so a package never holds a half file; the device's own record
/// stays as it is.
struct StoreFetch: Sendable {
    /// The folder fetched from.
    let folder: SyncFolder
    /// The store's ID, for pointers this device writes.
    let storeID: UUID
    /// This device's `Staging/`.
    let staging: URL
    /// How long one blob may take to arrive (section 7).
    var perFile: Duration = .seconds(60)

    // MARK: Placeholders

    /// A pointer for a book none of whose files are on this device: what a
    /// placeholder holds, with every file `onThisDevice: false`.
    static func placeholderPointer(storeID: UUID, manifestName: String, manifest: StoreManifest) -> StorePointer {
        StorePointer(
            formatVersion: SyncFormats.currentVersion, storeID: storeID, bookID: manifest.bookID,
            manifest: manifestName, uploaded: manifestName,
            files: manifest.files.map { StorePointer.File(path: $0.path, sha256: $0.sha256, size: $0.size, modified: 0, onThisDevice: false) }
        )
    }

    /// The pointer in the package at `package`, or nil for a book that has none.
    static func pointer(in package: URL) -> StorePointer? {
        // A folder that is dataless is not downloaded to look for the pointer.
        let data = DatalessFiles.withoutDownloading { try? Data(contentsOf: package.appendingPathComponent(StorePointer.fileName)) }
        guard let data else { return nil }
        return try? SyncFormats.decodePointer(data)
    }

    /// Writes `pointer` atomically in the package at `package`.
    static func write(_ pointer: StorePointer, in package: URL) throws {
        try SyncFormats.encode(pointer).write(to: package.appendingPathComponent(StorePointer.fileName), options: .atomic)
    }

    /// Whether the package at `package` is a placeholder or partly one: its pointer lists no files yet (a
    /// placeholder made from a row alone, whose files the manifest names), or some file of it isn't here.
    static func isMissingFiles(_ package: URL) -> Bool {
        guard let pointer = pointer(in: package) else { return false }
        return pointer.files.isEmpty || pointer.files.contains { !$0.onThisDevice }
    }

    /// How many of `packages` are missing files (`isMissingFiles(_:)`): the books whose files are only in the sync
    /// folder, in whole or in part, which Stop Syncing's question counts (FR46). Reads each pointer, and nothing more.
    static func countMissingFiles(in packages: [URL]) -> Int {
        packages.reduce(0) { count, package in isMissingFiles(package) ? count + 1 : count }
    }

    /// The bytes of the files not on this device, from the pointer's sizes: what a fetch needs room for. Nil
    /// when the pointer lists no files yet, since only the manifest knows them.
    static func bytesToFetch(_ package: URL) -> Int64? {
        guard let pointer = pointer(in: package), !pointer.files.isEmpty else { return nil }
        return pointer.files.filter { !$0.onThisDevice }.reduce(Int64(0)) { $0 + $1.size }
    }

    /// Whether a manifest's file may be fetched: a relative path of plain names (no `..`, no empty name, not
    /// absolute), a digest, and a blob named `<digest>.<ext>` in the form the backup makes.
    static func isSafe(_ file: StoreManifest.File) -> Bool {
        let parts = file.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !file.path.isEmpty, !file.path.hasPrefix("/"), !parts.contains(""), !parts.contains("."), !parts.contains("..") else { return false }
        // The pointer is the device's own record of the book: no manifest may write over it.
        guard file.path != StorePointer.fileName, parts.last != StorePointer.fileName else { return false }
        guard SyncNames.isDigest(file.sha256), file.blob.hasPrefix(file.sha256 + "."), file.size >= 0 else { return false }
        let ext = String(file.blob.dropFirst(file.sha256.count + 1))
        return SyncNames.blobName(sha256: file.sha256, pathExtension: ext) == file.blob
    }

    // MARK: Fetching

    /// Fetches the files of the package at `package` that aren't here yet.
    ///
    /// `progress` is told, after each file, how many files and bytes are here, and the totals, which the
    /// manifest gives even for a placeholder whose pointer lists no files. Throws a
    /// `SyncProblem`: `.offline`, `.notDownloaded` at the limit, `.damaged` for a blob that doesn't
    /// match its name (it stays in staging, never in the package), `.anotherStore` for a
    /// pointer of another store. A cancelled task stops between files; what was moved in stays, and
    /// the pointer says so, so the next fetch goes on from there.
    ///
    /// Every file is written at its manifest `path`, so the book's content has the name it had where it was
    /// backed up. Returns that content file's path (the first `content` file of the manifest, by path), which
    /// the host sets as the row's `filePath` (`SyncLibraryHost.syncDidFetch`).
    @discardableResult
    func fetch(
        package: URL,
        progress: @Sendable (_ completedFiles: Int, _ completedBytes: Int64, _ totalFiles: Int, _ totalBytes: Int64) -> Void = { _, _, _, _ in }
    ) async throws -> String? {
        guard var pointer = Self.pointer(in: package) else { throw SyncProblem.notASyncFolder }
        if pointer.storeID != storeID { throw SyncProblem.anotherStore }
        let bookFolder = folder.bookFolder(pointer.bookID)
        let manifestData = try await folder.access.read(bookFolder.appendingPathComponent(pointer.manifest), within: perFile)
        // The manifest's name is the digest of its bytes: a damaged or swapped file is refused. Every path and
        // blob name in it is checked before anything is written or read.
        guard StoreBackup.manifestName(for: manifestData) == pointer.manifest,
              let manifest = try? SyncFormats.decodeManifest(manifestData, named: pointer.manifest),
              manifest.bookID == pointer.bookID else {
            throw SyncProblem.damaged(file: pointer.manifest)
        }
        if let unsafe = manifest.files.first(where: { !Self.isSafe($0) }) { throw SyncProblem.damaged(file: unsafe.path) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        // The pointer lists every file of the manifest before the first is fetched, each `onThisDevice: false` until it
        // lands, so a fetch that stops part way (Stop, Cancel, offline, a damaged file) always reads as missing files:
        // the book is not taken for whole, and the next fetch goes on from there.
        // A file counts as here only when what the pointer recorded for it is the manifest's own digest: a book edited on
        // another device (the same path, new bytes) is not taken for whole because the old text is there.
        let hereAlready = Set(pointer.files.filter { entry in
            entry.onThisDevice && manifest.files.contains { $0.path == entry.path && $0.sha256 == entry.sha256 }
        }.map(\.path))
        pointer.files = manifest.files.map { file in
            let here = hereAlready.contains(file.path)
            let known = pointer.files.first { $0.path == file.path }
            return StorePointer.File(path: file.path, sha256: file.sha256, size: file.size, modified: known?.modified ?? 0, onThisDevice: here)
        }
        try Self.write(pointer, in: package)

        let totalBytes = manifest.files.reduce(Int64(0)) { $0 + $1.size }
        var completedFiles = pointer.files.filter(\.onThisDevice).count
        var completedBytes = pointer.files.filter(\.onThisDevice).reduce(Int64(0)) { $0 + $1.size }
        for file in manifest.files {
            try Task.checkCancellation()
            let existing = pointer.files.firstIndex { $0.path == file.path }
            if let existing, pointer.files[existing].onThisDevice { continue }
            let destination = package.appendingPathComponent(file.path)
            // The device's own record stays as it is. Any other file already there is present only if its digest is the
            // manifest's; otherwise it is the old version, and the new one is fetched over it.
            let there = FileManager.default.fileExists(atPath: destination.path)
            let isWhole = there && (file.role == "record" || (try? FileDigest.sha256(of: destination)) == file.sha256)
            if !isWhole {
                let staged = staging.appendingPathComponent(UUID().uuidString.lowercased())
                try await folder.access.fetch(bookFolder.appendingPathComponent(file.blob), to: staged, within: perFile)
                let size = (try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
                guard size == file.size, try FileDigest.sha256(of: staged) == file.sha256 else {
                    throw SyncProblem.damaged(file: file.blob)
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if there {
                    // Over the old version, in one step: the book never has a half file under its name.
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
                } else {
                    try FileManager.default.moveItem(at: staged, to: destination)
                }
            }
            let entry = StorePointer.File(path: file.path, sha256: file.sha256, size: file.size, modified: Self.modified(destination), onThisDevice: true)
            if let existing { pointer.files[existing] = entry } else { pointer.files.append(entry) }
            // The pointer follows each file, so a stop leaves the next fetch where this one was.
            try Self.write(pointer, in: package)
            completedFiles += 1
            completedBytes += file.size
            progress(completedFiles, completedBytes, manifest.files.count, totalBytes)
        }
        Self.excludeFromBackup(package)
        return manifest.files.filter { $0.role == "content" }.map(\.path).min()
    }

    /// A file's modification time in milliseconds.
    private static func modified(_ url: URL) -> Int64 {
        let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return date.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
    }

    /// Leaves a fetched package out of iCloud Backup on the iPhone, as `ImportScratchSpace`
    /// does for its folder: the books are in the sync folder, and a device backup of them
    /// would hold them twice. Does nothing on the Mac.
    private static func excludeFromBackup(_ package: URL) {
        #if os(iOS)
        var url = package
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #endif
    }
}
