import CryptoKit
import Foundation

// MARK: - Backing a Book Up Into the Store (FR43, section 8)

/// What a book's backup found or made.
struct StoreBackupResult: Equatable, Sendable {
    /// The manifest's file name in `Books/<id>/`.
    var manifestName: String
    /// The manifest as written.
    var manifest: StoreManifest
    /// How many bytes of blobs this run copied into the folder (blobs already there aren't copied again).
    var bytesCopied: Int64
    /// The blobs' and manifest's names in `Books/<id>/`, which the upload check reads.
    var uploadNames: [String]
}

/// A book candidate for the backup's order.
struct StoreBackupCandidate: Equatable, Sendable {
    var bookID: UUID
    /// Whether the book is a text book (an audiobook is large and goes after).
    var isText: Bool
    /// The size of the book's files in bytes.
    var bytes: Int64
}

/// How much the backup may hold copied but not yet evicted, so a first
/// backup of a large library doesn't fill the disk (section 8): 2 GB, or the
/// free space less 1 GB if that is smaller. The spike may raise it.
struct StoreBackupBudget: Equatable, Sendable {
    static let ceiling: Int64 = 2_000_000_000
    static let reserve: Int64 = 1_000_000_000

    /// The most bytes not yet evicted, for `freeSpace` bytes free on this device.
    static func limit(freeSpace: Int64) -> Int64 {
        max(0, min(ceiling, freeSpace - reserve))
    }
}

/// Copies a book's files into the store as blobs named by their SHA-256,
/// and writes the manifest and the pointer (section 3). A blob already
/// there isn't copied again, a file is hashed once, and nothing is ever
/// written over a file (R4). A package holding a symbolic link isn't backed up.
struct StoreBackup: Sendable {
    /// The folder backed up into.
    let folder: SyncFolder
    /// The store's ID, for the pointer.
    let storeID: UUID
    /// This device's `Staging/`, where each file is cloned and hashed before it is moved in.
    let staging: URL

    /// Names that never belong to a manifest: the pointer and Finder's debris. The
    /// cachedAudio folder is left out too, as a cache that is made again.
    static func isLeftOut(_ relativePath: String) -> Bool {
        let top = relativePath.split(separator: "/").first.map(String.init) ?? relativePath
        let name = (relativePath as NSString).lastPathComponent
        // The plain copy a password removal is writing (or a crash left) holds the book
        // without its password: it never goes to the sync folder (FR41).
        return name == StorePointer.fileName || name == ".DS_Store"
            || top.hasPrefix(ProtectionRemoval.temporaryPrefix) || name.hasPrefix(ProtectionRemoval.temporaryPrefix)
            || top == TextMouthPaths.cachedAudioFolderName
            || top == TextMouthPaths.removedFromLibraryMarkerName
    }

    /// A file's role in the manifest: the book's own files are content,
    /// bookInfo.json the record, and the rest other.
    static func role(of relativePath: String) -> String {
        let top = relativePath.split(separator: "/").first.map(String.init) ?? relativePath
        if relativePath == TextMouthPaths.bookInfoFileName { return "record" }
        return FileImportService.isPackageContentName(top) ? "content" : "other"
    }

    /// The order books are backed up in: text books first, then smaller first
    /// (ties by ID, so the order is the same every run).
    static func order(_ candidates: [StoreBackupCandidate]) -> [StoreBackupCandidate] {
        candidates.sorted {
            if $0.isText != $1.isText { return $0.isText }
            if $0.bytes != $1.bytes { return $0.bytes < $1.bytes }
            return $0.bookID.uuidString < $1.bookID.uuidString
        }
    }

    /// The name a manifest has in the store: the SHA-256 of its bytes, so a reader can check it.
    static func manifestName(for data: Data) -> String {
        SyncNames.manifestName(sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    /// The backup would copy more than the local budget allows: a result of its own, not the drive's "full".
    enum BudgetError: Error, Equatable {
        case overBudget
    }

    /// The package's pointer says some of the book's files are not on this device, so it is not backed up from here.
    struct FilesAreAway: Error, Equatable {}

    // MARK: Listing a package

    /// One file of a package: its path from the package, and its URL.
    struct PackageFile: Equatable, Sendable {
        var path: String
        var url: URL
    }

    /// Every file of the package at `package` that the manifest holds, by path. Throws
    /// `SyncProblem.damaged` when it holds a symbolic link, so such a book isn't backed up.
    static func files(of package: URL) throws -> [PackageFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: package, includingPropertiesForKeys: keys) else { return [] }
        let base = package.standardizedFileURL.path
        var found: [PackageFile] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if values.isSymbolicLink == true { throw SyncProblem.damaged(file: path) }
            if isLeftOut(path) {
                if values.isDirectory == true { walker.skipDescendants() }
                continue
            }
            if values.isRegularFile == true { found.append(PackageFile(path: path, url: url)) }
        }
        return withoutDerivedText(ofProtectedBookIn: found).sorted { $0.path < $1.path }
    }

    /// The names of a package's files that hold a book's words in plain text.
    private static let derivedTextNames: Set<String> = [TextMouthPaths.contentIndexFileName, "content.md"]

    /// `files`, less the derived files that would copy the words of a book
    /// protected by a password (its headings, a text cache) out of the
    /// library (FR41). A package whose own file has no password is whole.
    private static func withoutDerivedText(ofProtectedBookIn files: [PackageFile]) -> [PackageFile] {
        let isProtected = files.contains { file in
            guard !file.path.contains("/"), !derivedTextNames.contains(file.path),
                  let format = BookFormat.detect(from: file.url) else { return false }
            return ProtectionDetector.isProtected(fileAt: file.url, format: format)
        }
        guard isProtected else { return files }
        return files.filter { !derivedTextNames.contains($0.path) && !$0.path.hasPrefix("content.md.") }
    }

    /// The bytes of the files of the package at `package`, for the backup's order; 0 when it can't be read.
    static func bytes(of package: URL) -> Int64 {
        ((try? files(of: package)) ?? []).reduce(Int64(0)) { total, file in
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            return total + Int64(size ?? 0)
        }
    }

    // MARK: Backing up

    /// Backs the book at `package` up into `Books/<bookID>/`, and writes its
    /// pointer, with every file `onThisDevice`. A book whose files are all
    /// there already copies nothing new, and writes the manifest only if it
    /// is not there. `budget` is how many blob bytes may be copied this call;
    /// a book that doesn't fit throws `.outOfSpace` before copying anything.
    func back(up package: URL, bookID: UUID, budget: Int64 = .max) throws -> StoreBackupResult {
        // A book whose pointer says a file is away has a copy already, and what is here is not the whole book: a
        // manifest made from it would leave out the file that is away, and be taken for the book's copy everywhere.
        if StoreFetch.isMissingFiles(package) { throw FilesAreAway() }
        let files = try Self.files(of: package)
        let bookFolder = folder.bookFolder(bookID)
        let present = Set(((try? folder.access.list(bookFolder)) ?? []).map(\.name))
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        // Clone each file into staging first and hash that copy, so the digest is of exactly the bytes copied
        // even if the book changes meanwhile.
        var entries: [StoreManifest.File] = []
        var staged: [(blob: String, url: URL, size: Int64)] = []
        for file in files {
            let copy = staging.appendingPathComponent(UUID().uuidString.lowercased())
            try FileManager.default.copyItem(at: file.url, to: copy)
            let digest = try FileDigest.sha256(of: copy)
            let size = (try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let blob = SyncNames.blobName(sha256: digest, pathExtension: (file.path as NSString).pathExtension)
            entries.append(StoreManifest.File(path: file.path, sha256: digest, blob: blob, role: Self.role(of: file.path), size: size))
            if present.contains(blob) || staged.contains(where: { $0.blob == blob }) {
                try? FileManager.default.removeItem(at: copy)
            } else {
                staged.append((blob, copy, size))
            }
        }

        let needed = staged.reduce(Int64(0)) { $0 + $1.size }
        if needed > budget {
            for item in staged { try? FileManager.default.removeItem(at: item.url) }
            throw BudgetError.overBudget
        }
        for item in staged {
            // `copyIn` never writes over a file; one that appeared meanwhile is the same blob.
            do { try folder.access.copyIn(item.url, to: bookFolder.appendingPathComponent(item.blob)) } catch SyncProblem.exists {}
            try? FileManager.default.removeItem(at: item.url)
        }

        let manifest = StoreManifest(formatVersion: SyncFormats.currentVersion, bookID: bookID, files: entries)
        let manifestData = try SyncFormats.encode(manifest)
        let manifestName = Self.manifestName(for: manifestData)
        if !present.contains(manifestName) {
            do { try folder.access.write(manifestData, to: bookFolder.appendingPathComponent(manifestName), replacing: false) } catch SyncProblem.exists {}
        }
        try writePointer(in: package, bookID: bookID, manifest: manifestName, entries: entries, files: files, uploaded: nil)
        return StoreBackupResult(
            manifestName: manifestName, manifest: manifest, bytesCopied: needed,
            uploadNames: Array(Set(entries.map(\.blob))).sorted() + [manifestName]
        )
    }

    /// Whether a new manifest is needed: the files' digests differ from `existing`'s, ignoring
    /// the record, so a bookInfo.json change alone makes none.
    static func needsNewManifest(existing: StoreManifest?, files: [StoreManifest.File]) -> Bool {
        guard let existing else { return true }
        func comparable(_ files: [StoreManifest.File]) -> [String] {
            files.filter { $0.role != "record" }.map { "\($0.path)\u{0}\($0.sha256)" }.sorted()
        }
        return comparable(existing.files) != comparable(files)
    }

    // MARK: The pointer

    /// Writes `.storeCopy.json` in the package, atomically: the manifest it
    /// names and which files are on this device (those in `files`).
    private func writePointer(
        in package: URL, bookID: UUID, manifest: String, entries: [StoreManifest.File],
        files: [PackageFile], uploaded: String?
    ) throws {
        // Each file's modification time in milliseconds, which tells a later edit from the copy made.
        var modified: [String: Int64] = [:]
        for file in files {
            let date = try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            modified[file.path] = date.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        }
        let pointer = StorePointer(
            formatVersion: SyncFormats.currentVersion, storeID: storeID, bookID: bookID,
            manifest: manifest, uploaded: uploaded,
            files: entries.map {
                // A file is on this device when it was found there, not because the manifest names it: a book whose own
                // file was freed has its record and text here and the file away.
                StorePointer.File(path: $0.path, sha256: $0.sha256, size: $0.size, modified: modified[$0.path] ?? 0, onThisDevice: modified[$0.path] != nil)
            }
        )
        try SyncFormats.encode(pointer).write(to: package.appendingPathComponent(StorePointer.fileName), options: .atomic)
    }

    // MARK: Uploads and eviction

    /// Whether the drive reports every blob and the manifest of `result` uploaded, or, where it
    /// reports nothing, whether they are all copied (they are, once `back(up:)` returned). A
    /// failure is returned as the problem, so the status can say the drive is full.
    func uploadState(of result: StoreBackupResult, bookID: UUID) -> SyncUploadState {
        var anyUploading = false
        var anyReported = false
        for name in result.uploadNames {
            switch folder.access.uploadState(of: folder.bookFolder(bookID).appendingPathComponent(name)) {
            case .uploaded: anyReported = true
            case .uploading: anyUploading = true; anyReported = true
            case .failed(let problem): return .failed(problem)
            case .notReported: break
            }
        }
        if anyUploading { return .uploading }
        return anyReported ? .uploaded : .notReported
    }

    /// Records that the book's copy has uploaded: the pointer names the manifest in `uploaded`.
    func markUploaded(package: URL, bookID: UUID, result: StoreBackupResult) throws {
        let files = try Self.files(of: package)
        try writePointer(in: package, bookID: bookID, manifest: result.manifestName, entries: result.manifest.files, files: files, uploaded: result.manifestName)
    }

    /// Evicts the local copies of an uploaded book's blobs, so the folder
    /// doesn't keep a second copy on this device; a refusal is a wait, not a
    /// failure. Returns how many it evicted.
    @discardableResult
    func evictBlobs(of result: StoreBackupResult, bookID: UUID) -> Int {
        var evicted = 0
        for name in result.uploadNames {
            if (try? folder.access.evictLocalCopy(of: folder.bookFolder(bookID).appendingPathComponent(name))) != nil { evicted += 1 }
        }
        return evicted
    }
}
