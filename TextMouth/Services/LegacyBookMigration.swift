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

// MARK: - File Identity

/// The device and inode of the file a URL leads to once symbolic links are
/// followed. Two URLs with the same identity name one file, however they
/// spell it: through a link, a hard link, or a difference in case on a
/// case-insensitive volume. A file must not be removed while another
/// record still reads it, or when it is the copy that replaces it.
struct FileIdentity: Hashable {
    /// The device holding the file.
    let device: UInt64
    /// The file's inode number on that device.
    let inode: UInt64

    /// The identity of the file at `url`, or nil when nothing is there.
    init?(of url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(
                  atPath: url.resolvingSymlinksInPath().path
              ),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        self.device = device.uint64Value
        self.inode = inode.uint64Value
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

/// What one pass over the library's legacy books did, for the log and for
/// the user.
struct LegacyMigrationReport: Equatable {
    /// One book that needs the user's attention: its title, and plain
    /// sentences saying what happened to it.
    struct Issue: Equatable {
        let title: String
        let reason: String
    }

    /// How many books moved into packages, with or without warnings.
    var migratedCount = 0
    /// Books that could not move; their records and originals are unchanged.
    var failures: [Issue] = []
    /// Books that moved with something to look at, such as a kept original.
    var warnings: [Issue] = []

    /// Counts a book that moved, and lists it when it has warnings.
    mutating func record(_ migration: LegacyBookMigration) {
        migratedCount += 1
        if !migration.warnings.isEmpty {
            warnings.append(Issue(
                title: migration.book.title,
                reason: migration.warnings.joined(separator: " ")
            ))
        }
    }

    /// Lists a book that could not move, with the reason.
    mutating func recordFailure(of book: Book, error: Error) {
        failures.append(Issue(title: book.title, reason: error.localizedDescription))
    }

    /// The message for the library's error alert, or nil when no book needs
    /// attention. Failures come first, since those books did not move, and
    /// each book has a line of its own: its title, then what happened.
    var userSummary: String? {
        var sections: [String] = []
        if !failures.isEmpty {
            sections.append(
                "TextMouth could not move \(Self.describe(failures.count)) to the current library format. "
                    + (failures.count == 1
                        ? "Its original file was not changed."
                        : "Their original files were not changed.")
                    + "\n" + Self.lines(failures)
            )
        }
        if !warnings.isEmpty {
            sections.append(
                "TextMouth moved \(Self.describe(warnings.count)) to the current library format, "
                    + (warnings.count == 1 ? "but with a problem:" : "but with problems:")
                    + "\n" + Self.lines(warnings)
            )
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// One line for the debug log, or nil when the pass found nothing to move.
    var logSummary: String? {
        guard migratedCount > 0 || !failures.isEmpty else { return nil }
        var parts = ["moved \(Self.describe(migratedCount)) into packages"]
        if !failures.isEmpty {
            parts.append("could not move \(Self.describe(failures.count)): \(Self.inline(failures))")
        }
        if !warnings.isEmpty {
            parts.append("\(Self.describe(warnings.count)) moved with problems: \(Self.inline(warnings))")
        }
        return "LEGACY_MIGRATION: " + parts.joined(separator: "; ")
    }

    /// The most books either part of the alert names. A book that could not
    /// move is reported again at every launch until it is dealt with, and
    /// the alert is heard or read line by line, so a long list is cut short;
    /// the debug log names every book.
    static let booksNamedInAlert = 10

    /// "1 book" or "3 books".
    private static func describe(_ count: Int) -> String {
        count == 1 ? "1 book" : "\(count) books"
    }

    /// One "Title: what happened" line per book, up to `booksNamedInAlert`,
    /// then a line that counts the rest and says where they are listed.
    private static func lines(_ issues: [Issue]) -> String {
        var lines = issues.prefix(booksNamedInAlert).map { "\($0.title): \($0.reason)" }
        let unnamed = issues.count - booksNamedInAlert
        if unnamed > 0 {
            lines.append(
                "Plus \(unnamed) more \(unnamed == 1 ? "book" : "books"), "
                    + "all named in the debug log at \(TextMouthPaths.debugLogFile.path)."
            )
        }
        return lines.joined(separator: "\n")
    }

    /// Every issue on a single line: each title quoted, its reason in
    /// parentheses, and any line break in either flattened to a space.
    private static func inline(_ issues: [Issue]) -> String {
        issues.map { "\"\($0.title)\" (\($0.reason))" }
            .joined(separator: ", ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Migration

extension FileImportService {

    // MARK: Migrating the Library

    /// Moves every book the library still records in the layout that
    /// predates packages into a package of its own. A book that cannot move
    /// keeps its record and original, and the pass carries on with the next
    /// book. The summary goes to the debug log; a caller with a window shows
    /// the report's `userSummary` once its whole repair is done.
    ///
    /// Nothing guarantees that each stored file belongs to one record, so an
    /// original is removed only once no other record reads it: each record
    /// that moves gets its own verified copy first, and a record that could
    /// not move keeps reading the original.
    @discardableResult
    static func migrateLegacyBooks(in library: inout Library) -> LegacyMigrationReport {
        var report = LegacyMigrationReport()
        let legacyIndices = library.books.indices.filter { library.books[$0].tmbDirectoryName.isEmpty }
        guard !legacyIndices.isEmpty else { return report }

        // How many records, moved or not, read each file.
        var readers: [FileIdentity: Int] = [:]
        for book in library.books {
            if let identity = FileIdentity(of: book.bookFileURL) {
                readers[identity, default: 0] += 1
            }
        }

        for index in legacyIndices {
            let book = library.books[index]
            let original = FileIdentity(of: book.bookFileURL)
            let otherReaders = original.map { (readers[$0] ?? 1) - 1 } ?? 0
            do {
                let migration = try migrateBookToTMB(
                    book,
                    removingOriginalWith: otherReaders > 0 ? nil : removeMigratedOriginal(at:)
                )
                library.books[index] = migration.book
                // A moved record reads its package copy from now on.
                if let original, FileIdentity(of: migration.book.bookFileURL) != original {
                    readers[original] = otherReaders
                }
                report.record(migration)
            } catch {
                report.recordFailure(of: book, error: error)
            }
        }
        if let line = report.logSummary {
            print(line)
            TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: line)
        }
        return report
    }

    // MARK: Migrating One Book

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
    ///    honors the user's Trash preference. It is kept without comment
    ///    when `removeOriginal` is nil, because other records still read
    ///    it, and when the record already named the file in its usual
    ///    package, so that the copy is the original itself. It is kept, with
    ///    a warning, when the removal fails, and when the usual package held
    ///    other content: that is unexpected, so the original stays as a
    ///    recovery copy.
    /// 6. The text cache is built last. A failure there is a warning; the
    ///    library's cache pass builds the cache later.
    ///
    /// A missing original is reported unless an earlier, interrupted run
    /// provably finished the move (see `finishedMigration(of:)`).
    ///
    /// Whatever this throws, the original and the library record are as
    /// they were; the reasons are `LegacyMigrationError`s, apart from a
    /// failure to create the library's own folders. `copyItem` lets tests
    /// simulate a copy that goes wrong.
    static func migrateBookToTMB(
        _ book: Book,
        removingOriginalWith removeOriginal: ((URL) throws -> Void)? = FileImportService.removeMigratedOriginal(at:),
        copyingWith copyItem: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) throws -> LegacyBookMigration {
        try TextMouthPaths.ensureDirectoryStructure()
        if !book.folderPath.isEmpty {
            try TextMouthPaths.ensureLibrarySubfolder(book.folderPath)
        }

        let original = URL(fileURLWithPath: book.filePath)
        guard FileManager.default.fileExists(atPath: original.path) else {
            // The original's removal may have been the last thing a run did
            // before it was interrupted, ahead of the library index save.
            if let finished = finishedMigration(of: book) { return finished }
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
        if copy.isOriginal {
            // The record already named the file in its package, so there is
            // no separate original: removing it would remove the only copy.
        } else if let occupiedPackage = copy.occupiedPackage {
            warnings.append(
                "The library already had different content under its package name, "
                    + "\(occupiedPackage.lastPathComponent), so it was stored in a new package, "
                    + "\(copy.packageName), and its original file was kept at \(original.path)."
            )
        } else if let removeOriginal {
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

    // MARK: Finishing an Interrupted Migration

    /// The move of `book` that an earlier run completed, when that run was
    /// interrupted after removing the original but before the library index
    /// recorded the package. Only the usual package can hold such a move,
    /// because a move into a new package keeps its original. The package is
    /// accepted only on proof: its bookInfo.json names this book, and its
    /// copy has the hash the library recorded for the original. Nil
    /// otherwise.
    private static func finishedMigration(of book: Book) -> LegacyBookMigration? {
        let name = packageName(for: book, identifier: book.id)
        let package = TextMouthPaths.tmbPath(folderPath: book.folderPath, tmbName: name)
        let content = package.appendingPathComponent(book.bookFileURL.lastPathComponent)
        guard !book.md5Hash.isEmpty,
              (try? BookInfo.load(from: package))?.metadata.bookID == book.id,
              (try? ContentFingerprint(of: content))?.md5Hash == book.md5Hash else {
            return nil
        }
        var migrated = book
        migrated.filePath = content.path
        migrated.tmbDirectoryName = name
        return LegacyBookMigration(book: migrated, removedOriginal: false, warnings: [])
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
        /// Whether the copy found in the usual package is the original file
        /// itself, because the record already named a file in that package.
        let isOriginal: Bool
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
                createdPackage: false, createdContent: true, isOriginal: false, occupiedPackage: nil
            )
        case .ownWithIdenticalCopy:
            let content = usualPackage.appendingPathComponent(contentName)
            return PlacedCopy(
                packageName: usualName, package: usualPackage, content: content,
                createdPackage: false, createdContent: false,
                isOriginal: FileIdentity(of: content) == FileIdentity(of: original),
                occupiedPackage: nil
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
            createdPackage: true, createdContent: true, isOriginal: false, occupiedPackage: occupiedPackage
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
