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
        guard let data = try? Data(contentsOf: package.appendingPathComponent(StorePointer.fileName)) else { return nil }
        return try? SyncFormats.decodePointer(data)
    }

    /// Writes `pointer` atomically in the package at `package`.
    static func write(_ pointer: StorePointer, in package: URL) throws {
        try SyncFormats.encode(pointer).write(to: package.appendingPathComponent(StorePointer.fileName), options: .atomic)
    }

    /// Whether the package at `package` is a placeholder or partly one: some file of its pointer isn't here.
    static func isMissingFiles(_ package: URL) -> Bool {
        pointer(in: package)?.files.contains { !$0.onThisDevice } ?? false
    }

    /// The bytes of the files not on this device, from the pointer's sizes: what a fetch needs room for.
    static func bytesToFetch(_ package: URL) -> Int64? {
        pointer(in: package).map { $0.files.filter { !$0.onThisDevice }.reduce(Int64(0)) { $0 + $1.size } }
    }

    // MARK: Fetching

    /// Fetches the files of the package at `package` that aren't here yet.
    ///
    /// `progress` is told, after each file, how many bytes and files are here. Throws a
    /// `SyncProblem`: `.offline`, `.notDownloaded` at the limit, `.damaged` for a blob that doesn't
    /// match its name (it stays in staging, never in the package), `.anotherStore` for a
    /// pointer of another store. A cancelled task stops between files; what was moved in stays, and
    /// the pointer says so, so the next fetch goes on from there.
    ///
    /// Every file is written at its manifest `path`, so the book's content has the name it had where it was
    /// backed up. Returns that content file's path (the first `content` file of the manifest, by path), which
    /// the host sets as the row's `filePath` (`SyncLibraryHost.syncDidFetch`).
    @discardableResult
    func fetch(package: URL, progress: @Sendable (_ completedFiles: Int, _ completedBytes: Int64) -> Void = { _, _ in }) async throws -> String? {
        guard var pointer = Self.pointer(in: package) else { throw SyncProblem.notASyncFolder }
        if pointer.storeID != storeID { throw SyncProblem.anotherStore }
        let bookFolder = folder.bookFolder(pointer.bookID)
        let manifestData = try await folder.access.read(bookFolder.appendingPathComponent(pointer.manifest), within: perFile)
        guard let manifest = try? SyncFormats.decodeManifest(manifestData, named: pointer.manifest), manifest.bookID == pointer.bookID else {
            throw SyncProblem.damaged(file: pointer.manifest)
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var completedFiles = manifest.files.count - pointer.files.filter { !$0.onThisDevice }.count
        var completedBytes = pointer.files.filter(\.onThisDevice).reduce(Int64(0)) { $0 + $1.size }
        for file in manifest.files {
            try Task.checkCancellation()
            let existing = pointer.files.firstIndex { $0.path == file.path }
            if let existing, pointer.files[existing].onThisDevice { continue }
            let destination = package.appendingPathComponent(file.path)
            // The device's own record, and anything already there, stays as it is.
            if !FileManager.default.fileExists(atPath: destination.path) {
                let staged = staging.appendingPathComponent(UUID().uuidString.lowercased())
                try await folder.access.fetch(bookFolder.appendingPathComponent(file.blob), to: staged, within: perFile)
                let size = (try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
                guard size == file.size, try FileDigest.sha256(of: staged) == file.sha256 else {
                    throw SyncProblem.damaged(file: file.blob)
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: staged, to: destination)
            }
            let entry = StorePointer.File(path: file.path, sha256: file.sha256, size: file.size, modified: Self.modified(destination), onThisDevice: true)
            if let existing { pointer.files[existing] = entry } else { pointer.files.append(entry) }
            // The pointer follows each file, so a stop leaves the next fetch where this one was.
            try Self.write(pointer, in: package)
            completedFiles += 1
            completedBytes += file.size
            progress(completedFiles, completedBytes)
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
