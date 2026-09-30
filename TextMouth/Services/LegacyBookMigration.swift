import Foundation

// Moving books recorded in the layout that predates `.tmb` packages into
// packages, and the fingerprint that proves a copy matches its original
// before that original may be removed.

// MARK: - Content Fingerprint

/// The size and MD5 hash of a regular file. Two files with equal
/// fingerprints hold the same bytes for every purpose TextMouth has, so a
/// copy whose fingerprint matches its original's can stand in for it.
struct ContentFingerprint: Equatable {
    /// The file's size in bytes.
    let byteCount: UInt64
    /// The hex MD5 digest from `FileImportService.md5Hash(of:)`, the same
    /// hash duplicate detection uses.
    let md5Hash: String

    /// Reads the fingerprint of the regular file at `url`. A folder, a
    /// symbolic link, or any other kind of item throws
    /// `ContentFingerprintError.notARegularFile` instead of being hashed.
    init(of url: URL) throws {
        byteCount = try Self.regularFileSize(at: url)
        md5Hash = try FileImportService.md5Hash(of: url)
    }

    /// Whether the item at `url` is a regular file holding exactly these
    /// bytes. Sizes are compared first, so a partial copy is rejected
    /// without being hashed. Anything that cannot be read counts as
    /// different, never as a match.
    func matchesFile(at url: URL) -> Bool {
        guard (try? Self.regularFileSize(at: url)) == byteCount else { return false }
        return (try? FileImportService.md5Hash(of: url)) == md5Hash
    }

    /// The size of the regular file at `url`. The attributes come from
    /// lstat, so a symbolic link is never followed, and a folder is refused
    /// before it can reach `FileHandle`, whose legacy read raises an
    /// Objective-C exception on one.
    private static func regularFileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw ContentFingerprintError.notARegularFile
        }
        return size.uint64Value
    }
}

/// Why an item has no content fingerprint.
enum ContentFingerprintError: LocalizedError, Equatable {
    /// The item is a folder, a symbolic link, or something else that is not
    /// a regular file.
    case notARegularFile

    var errorDescription: String? {
        switch self {
        case .notARegularFile:
            return "The item is a folder or link rather than a file."
        }
    }
}

// MARK: - Migration Outcomes

/// Why a book recorded in the layout that predates packages could not be
/// moved into one. In every case its original file is where it was and its
/// library record is unchanged. The descriptions are sentences about the
/// book, written to follow its title in a list.
enum LegacyMigrationError: LocalizedError, Equatable {
    /// Nothing is at the path the library records for the original.
    case originalMissing(path: String)
    /// The original is a folder or a link, so a copy of it cannot be checked.
    case originalNotAFile(path: String)
    /// The original's size or content hash could not be read.
    case originalUnreadable(path: String, reason: String)
    /// Copying the original into its package failed.
    case copyFailed(reason: String)
    /// The copy's size or content hash differed from the original's, so the
    /// copy was discarded.
    case copyDiffers
    /// The book's usual package held other content, and no unused name
    /// could be found for a new package.
    case noUnusedPackageName
    /// The package's bookInfo.json could not be saved.
    case metadataNotSaved(reason: String)
    /// The Trash preference, which belongs to the main actor, could not be
    /// read, so the original was kept rather than removed.
    case trashPreferenceUnavailable

    var errorDescription: String? {
        switch self {
        case .originalMissing(let path):
            return "The original file is missing from \(path)."
        case .originalNotAFile(let path):
            return "The original at \(path) is a folder or link, so a copy of it cannot be checked."
        case .originalUnreadable(let path, let reason):
            return "The original file at \(path) could not be read to check a copy of it. \(reason)"
        case .copyFailed(let reason):
            return "It could not be copied into the library. \(reason)"
        case .copyDiffers:
            return "The copy made in the library did not match the original, so the copy was discarded."
        case .noUnusedPackageName:
            return "Its package name was taken by other content, and no unused name could be found."
        case .metadataNotSaved(let reason):
            return "Its book information file, bookInfo.json, could not be saved. \(reason)"
        case .trashPreferenceUnavailable:
            return "TextMouth could not check whether to move it to the Trash."
        }
    }
}

/// A legacy book that now lives in its own package. Its copy was verified
/// and its bookInfo.json saved; the warnings say what did not go as planned
/// after that.
struct LegacyBookMigration {
    /// The book's record, now pointing at its package.
    let book: Book
    /// Whether this migration removed the original: moved it to the Trash or
    /// deleted it, as the user prefers. Whenever there is doubt it is kept.
    let removedOriginal: Bool
    /// Plain sentences about problems that did not stop the move.
    let warnings: [String]
}

// MARK: - Migrating One Book

extension FileImportService {

    /// Moves a book recorded in the layout that predates packages (its
    /// `tmbDirectoryName` is empty) into its own `.tmb` package. Nothing
    /// already in the library is overwritten or trusted unchecked, and the
    /// original is removed only once its copy is proven identical and the
    /// package's metadata is saved:
    ///
    /// 1. The original's size and MD5 hash are read first. A book whose
    ///    original cannot be read this way stays where it is.
    /// 2. The copy goes into the book's usual package. A package already at
    ///    that name is used only when it is this book's own and holds either
    ///    no file under the original's name or an identical copy. Anything
    ///    else there (another book's package, a different or partial file)
    ///    is left untouched, and the book moves into a new package named by
    ///    the same scheme with a fresh identifier.
    /// 3. A copy is written under a hidden name and renamed into place only
    ///    once it matches the original, so an interruption never leaves a
    ///    partial file where a copy is expected.
    /// 4. bookInfo.json is saved. When that fails, whatever this call
    ///    created is removed again and the error is thrown.
    /// 5. The original is removed with `removeOriginal`, which by default
    ///    honors the user's Trash preference. It is kept, with a warning,
    ///    when the removal fails, and when the usual package held other
    ///    content: that is unexpected, so the original stays as a recovery
    ///    copy.
    /// 6. The text cache is built last. A failure there is a warning; the
    ///    library's cache pass builds the cache later.
    ///
    /// Whatever this throws, the original and the library record are as
    /// they were; the reasons are `LegacyMigrationError`s, apart from a
    /// failure to create the library's own folders. `copyItem` lets tests
    /// simulate a copy that goes wrong.
    static func migrateBookToTMB(
        _ book: Book,
        removingOriginalWith removeOriginal: (URL) throws -> Void = FileImportService.removeMigratedOriginal(at:),
        copyingWith copyItem: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) throws -> LegacyBookMigration {
        try TextMouthPaths.ensureDirectoryStructure()
        if !book.folderPath.isEmpty {
            try TextMouthPaths.ensureLibrarySubfolder(book.folderPath)
        }

        let original = URL(fileURLWithPath: book.filePath)
        guard FileManager.default.fileExists(atPath: original.path) else {
            throw LegacyMigrationError.originalMissing(path: original.path)
        }
        let fingerprint = try originalFingerprint(of: original)
        let copy = try placeVerifiedCopy(of: original, matching: fingerprint, for: book, copyItem: copyItem)

        // Commit the metadata while the original still exists: a failure
        // here must leave the book exactly as it was.
        var migrated = book
        migrated.filePath = copy.content.path
        migrated.tmbDirectoryName = copy.packageName
        do {
            try migrated.saveBookInfoThrowing()
        } catch {
            copy.discardCreatedItems()
            throw LegacyMigrationError.metadataNotSaved(reason: error.localizedDescription)
        }

        var warnings: [String] = []
        var removedOriginal = false
        if let occupiedPackage = copy.occupiedPackage {
            warnings.append(
                "The library already had different content under its package name, "
                    + "\(occupiedPackage.lastPathComponent), so it was stored in a new package, "
                    + "\(copy.packageName), and its original file was kept at \(original.path)."
            )
        } else {
            do {
                try removeOriginal(original)
                removedOriginal = true
            } catch {
                warnings.append(
                    "Its original file could not be removed, so it was kept at \(original.path). "
                        + error.localizedDescription
                )
            }
        }

        if !migrated.format.isAudio, let cacheWarning = buildTextCache(for: &migrated) {
            warnings.append(cacheWarning)
        }
        return LegacyBookMigration(book: migrated, removedOriginal: removedOriginal, warnings: warnings)
    }

    /// Removes a migrated book's original with
    /// `removeItemRespectingTrashSetting`: it goes to the Trash or is
    /// deleted as the user prefers, and a Trash failure keeps it rather than
    /// deleting it.
    ///
    /// That preference belongs to the main actor. Every migration TextMouth
    /// runs is on the main thread: the startup repair, the Storage settings
    /// rebuilds, and the library index load that comes before the startup
    /// repair. Anywhere else the original is kept, and the reason given,
    /// rather than removed without knowing what the user wants.
    static func removeMigratedOriginal(at url: URL) throws {
        guard Thread.isMainThread else {
            throw LegacyMigrationError.trashPreferenceUnavailable
        }
        try MainActor.assumeIsolated {
            try removeItemRespectingTrashSetting(at: url)
        }
    }

    // MARK: Verifying the Original

    /// The original's fingerprint, or the reason the book cannot be moved.
    private static func originalFingerprint(of original: URL) throws -> ContentFingerprint {
        do {
            return try ContentFingerprint(of: original)
        } catch ContentFingerprintError.notARegularFile {
            throw LegacyMigrationError.originalNotAFile(path: original.path)
        } catch {
            throw LegacyMigrationError.originalUnreadable(path: original.path, reason: error.localizedDescription)
        }
    }

    // MARK: Placing the Copy

    /// Where a migration put its verified copy, and what it created to do so.
    private struct PlacedCopy {
        /// The package's directory name, which becomes the book's `tmbDirectoryName`.
        let packageName: String
        /// The package directory.
        let package: URL
        /// The verified copy inside the package.
        let content: URL
        /// Whether this migration created the package directory.
        let createdPackage: Bool
        /// Whether this migration created the copy, in a package that may
        /// already have existed.
        let createdContent: Bool
        /// The book's usual package, when it held other content and the
        /// copy went into a new package instead.
        let occupiedPackage: URL?

        /// Removes what this migration created, and nothing that was there
        /// before, after a later step failed.
        func discardCreatedItems() {
            if createdPackage {
                try? FileManager.default.removeItem(at: package)
            } else if createdContent {
                try? FileManager.default.removeItem(at: content)
            }
        }
    }

    /// What the book's usual package location holds.
    private enum UsualPackageState {
        /// Nothing: the package can be created there.
        case absent
        /// The book's own package, without a file under the original's name.
        case ownWithoutCopy
        /// The book's own package, holding an identical copy.
        case ownWithIdenticalCopy
        /// Anything else: another book's package, metadata that cannot be
        /// read, something other than a directory, or a different or partial
        /// file under the original's name. It is left untouched.
        case occupied
    }

    /// Puts a verified copy of `original` into a package for `book` and says
    /// what it created. Existing files are never replaced.
    private static func placeVerifiedCopy(
        of original: URL,
        matching fingerprint: ContentFingerprint,
        for book: Book,
        copyItem: (URL, URL) throws -> Void
    ) throws -> PlacedCopy {
        let contentName = original.lastPathComponent
        let usualName = packageName(for: book, identifier: book.id)
        let usualPackage = TextMouthPaths.tmbPath(folderPath: book.folderPath, tmbName: usualName)

        switch stateOfUsualPackage(usualPackage, contentName: contentName, bookID: book.id, fingerprint: fingerprint) {
        case .absent:
            return try copyIntoNewPackage(
                named: usualName, in: book.folderPath, original: original, matching: fingerprint,
                occupiedPackage: nil, copyItem: copyItem
            )
        case .ownWithoutCopy:
            let content = usualPackage.appendingPathComponent(contentName)
            try copyVerified(original, matching: fingerprint, to: content, copyItem: copyItem)
            return PlacedCopy(
                packageName: usualName, package: usualPackage, content: content,
                createdPackage: false, createdContent: true, occupiedPackage: nil
            )
        case .ownWithIdenticalCopy:
            return PlacedCopy(
                packageName: usualName, package: usualPackage,
                content: usualPackage.appendingPathComponent(contentName),
                createdPackage: false, createdContent: false, occupiedPackage: nil
            )
        case .occupied:
            // A fresh identifier keeps the naming scheme and makes the name
            // unique; the retries only guard against the practically impossible.
            for _ in 0..<3 {
                let name = packageName(for: book, identifier: UUID())
                guard !itemExists(at: TextMouthPaths.tmbPath(folderPath: book.folderPath, tmbName: name)) else {
                    continue
                }
                return try copyIntoNewPackage(
                    named: name, in: book.folderPath, original: original, matching: fingerprint,
                    occupiedPackage: usualPackage, copyItem: copyItem
                )
            }
            throw LegacyMigrationError.noUnusedPackageName
        }
    }

    /// Classifies the book's usual package location. A package counts as the
    /// book's own when it has no bookInfo.json or one that names this book,
    /// and a copy counts only when it matches the original's fingerprint.
    private static func stateOfUsualPackage(
        _ package: URL,
        contentName: String,
        bookID: UUID,
        fingerprint: ContentFingerprint
    ) -> UsualPackageState {
        // lstat attributes: a link in place of the package is not followed.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: package.path) else {
            return .absent
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { return .occupied }
        if itemExists(at: TextMouthPaths.bookInfoPath(in: package)),
           (try? BookInfo.load(from: package))?.metadata.bookID != bookID {
            return .occupied
        }
        let content = package.appendingPathComponent(contentName)
        guard itemExists(at: content) else { return .ownWithoutCopy }
        return fingerprint.matchesFile(at: content) ? .ownWithIdenticalCopy : .occupied
    }

    /// Creates the package `name` in `folderPath` and puts a verified copy
    /// of `original` in it. When the copy fails, the package is removed.
    private static func copyIntoNewPackage(
        named name: String,
        in folderPath: String,
        original: URL,
        matching fingerprint: ContentFingerprint,
        occupiedPackage: URL?,
        copyItem: (URL, URL) throws -> Void
    ) throws -> PlacedCopy {
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: name)
        let content = package.appendingPathComponent(original.lastPathComponent)
        do {
            // Without intermediate directories this refuses a package that
            // appeared since the name was checked, instead of writing into it.
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        } catch {
            throw LegacyMigrationError.copyFailed(reason: error.localizedDescription)
        }
        do {
            try copyVerified(original, matching: fingerprint, to: content, copyItem: copyItem)
        } catch {
            try? FileManager.default.removeItem(at: package)
            throw error
        }
        return PlacedCopy(
            packageName: name, package: package, content: content,
            createdPackage: true, createdContent: true, occupiedPackage: occupiedPackage
        )
    }

    /// Copies `original` to `destination` through a hidden name beside it,
    /// and gives the copy its real name only once it matches the original.
    /// The rename never replaces anything that appeared at `destination`.
    private static func copyVerified(
        _ original: URL,
        matching fingerprint: ContentFingerprint,
        to destination: URL,
        copyItem: (URL, URL) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let pending = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).migrating")
        // Only an interrupted run of this same step leaves this name behind.
        try? fileManager.removeItem(at: pending)
        // Whatever happens below, nothing may stay at the hidden name.
        defer { try? fileManager.removeItem(at: pending) }

        do {
            try copyItem(original, pending)
        } catch {
            throw LegacyMigrationError.copyFailed(reason: error.localizedDescription)
        }
        guard fingerprint.matchesFile(at: pending) else {
            throw LegacyMigrationError.copyDiffers
        }
        do {
            try fileManager.moveItem(at: pending, to: destination)
        } catch {
            throw LegacyMigrationError.copyFailed(reason: error.localizedDescription)
        }
    }

    /// The package name the usual scheme gives `book`, with `identifier` as
    /// its unique part: the book's own ID for its usual package.
    private static func packageName(for book: Book, identifier: UUID) -> String {
        TextMouthPaths.tmbName(
            title: book.title,
            author: book.author,
            dateAdded: book.dateAdded,
            bookID: identifier
        )
    }

    /// Whether anything, even a broken symbolic link, is at `url`.
    private static func itemExists(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    // MARK: Building the Text Cache

    /// Builds the migrated book's text cache and saves its reading index.
    /// The record takes the new cache version and statistics only once both
    /// are saved; otherwise it claims no new cache, so the library's cache
    /// pass builds one later. Returns a warning when that happens.
    private static func buildTextCache(for book: inout Book) -> String? {
        var cached = book
        guard let contentIndex = MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &cached) else {
            return "Its text could not be prepared for reading yet; TextMouth will try again later."
        }
        do {
            try cached.saveBookInfoThrowing(contentIndex: contentIndex)
        } catch {
            return "Its reading index could not be saved, so TextMouth will build it again later. "
                + error.localizedDescription
        }
        book = cached
        return nil
    }
}
