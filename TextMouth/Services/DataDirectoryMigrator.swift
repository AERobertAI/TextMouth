import Foundation

/// Why a data-directory migration was refused or failed. Each description is
/// what the Storage settings status line and the library's error alert show,
/// and what VoiceOver reads, after the operation's own words, such as
/// "Failed to move directory: ".
enum DataDirectoryMigrationError: LocalizedError {
    /// The real folders of the two locations overlap (TODO F20), so the copy
    /// would land inside its own source or replace the data it copies. The
    /// description names both real folders, and any link that leads to one.
    case invalidRelationship(
        DataDirectoryOverlap,
        source: DataDirectoryLocation,
        destination: DataDirectoryLocation
    )
    /// The new location is a symbolic link that leads to no folder: what it
    /// points to, `target` as written in the link, is missing, or leads back
    /// to the link (TODO S10).
    case unreachableLink(DataDirectoryLocation, target: String)
    case destinationNotEmpty
    /// A file, or anything else that is not a folder, stands at the new
    /// location, or at the end of the link the new location is.
    case destinationNotAFolder(DataDirectoryLocation)
    /// The data directory to copy is gone, or is no folder: a file, or
    /// anything else, stands where it was.
    case missingSource
    /// The copy lacks the content of the book with this title: its file is
    /// not where the library says, inside the data directory.
    case missingBook(String)
    /// The book with this title is stored at this path, outside the data
    /// directory, so the move copies nothing of it and cannot point the
    /// library at a copy. Refused before anything is published, rather than
    /// reported as missing from the copy, which it never was in.
    case bookOutsideDataDirectory(title: String, path: String)
    case invalidLibrary
    /// The new location changed while the data was being copied, so the
    /// copy was not published and the data directory in use did not change
    /// (TODO S10). The description names what changed and where.
    case destinationChanged(DataDirectoryDestinationChange)
    /// The move was cancelled before its copy was published (FR02): the
    /// partial copy is deleted, and the data directory in use, its setting,
    /// and the library stay as they were.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidRelationship(let overlap, let source, let destination):
            return overlap.explanation(source: source, destination: destination)
        case .unreachableLink(let link, let target):
            return "The new location, \(link.named.path), is a link to \(target), which cannot be found. "
                + "Choose another location."
        case .destinationNotEmpty: return "The selected data directory is not empty. Choose an empty location."
        case .destinationNotAFolder(let location):
            return "The new location, \(location.namedDescription), is a file, not a folder. Choose another location."
        case .missingSource: return "The current data directory does not exist."
        case .missingBook(let title): return "The migrated copy is missing the content for \(title)."
        case .bookOutsideDataDirectory(let title, let path):
            return "The book \(title) is stored at \(path), outside the data directory, so the move cannot carry it. "
                + "Import it again, which asks about the duplicate, and choose Replace Existing so that the copy "
                + "stored in the data directory takes its place, or remove it from the library, "
                + "then move the data directory again."
        case .invalidLibrary: return "The migrated library index could not be validated."
        case .destinationChanged(let change): return change.explanation
        case .cancelled:
            return "The move was cancelled, so nothing changed."
        }
    }
}

// MARK: - Locations

/// A data-directory location as it is named and as the file system resolves
/// it (TODO S10). The two differ only where a symbolic link stands in the
/// path: `named` is the spelling the user chose or the preferences hold, and
/// `real` is the folder the data lives in.
///
/// The memberwise initializer takes both as given, for describing locations;
/// `init(_:fileManager:)` resolves a name against the file system. Compare
/// locations by their paths: URLs for one folder can differ in whether
/// they are marked as directories.
struct DataDirectoryLocation {
    /// The location as named: standardized, with every link left in place.
    let named: URL
    /// The folder `named` leads to: every link in the part of the path that
    /// exists resolved, followed by the part that does not exist yet. The
    /// system's own links, such as /var and /tmp, resolve without the
    /// /private they lead to, as Foundation spells them.
    let real: URL

    /// Whether a symbolic link makes the name lead to another folder. A
    /// name spelled through /private is the same folder, not a link to one.
    var isAlias: Bool {
        Self.withoutPrivatePrefix(named.path) != Self.withoutPrivatePrefix(real.path)
    }

    /// The real folder as a message names it, followed by the name that
    /// leads there when that name is a link: "/Volumes/Archive/.TextMouth,
    /// where /Users/me/.TextMouth leads".
    var realDescription: String {
        isAlias ? "\(real.path), where \(named.path) leads" : real.path
    }

    /// The name as a message gives it, followed by the real folder when the
    /// name is a link: "/Users/me/.TextMouth, which leads to
    /// /Volumes/Archive/.TextMouth".
    var namedDescription: String {
        isAlias ? "\(named.path), which leads to \(real.path)" : named.path
    }

    /// `path` without the /private that /var, /tmp, and /etc lead to.
    private static func withoutPrivatePrefix(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}

extension DataDirectoryLocation {
    /// `url` as the file system resolves it now. Declared in an extension
    /// so the memberwise initializer stays available.
    init(_ url: URL, fileManager: FileManager = .default) {
        let named = url.standardizedFileURL
        self.init(named: named, real: Self.resolve(named, fileManager: fileManager))
    }

    /// Whether `path` is this location's folder or inside it, spelled under
    /// its name or, when that name is a link, under the folder it leads to.
    func contains(_ path: String) -> Bool {
        spelling(of: path) != nil
    }

    /// `path` at the same place inside `destination`, when it is inside this
    /// location (see `contains(_:)`); nil for a path anywhere else. A data
    /// directory move gives each book this path in the copy, and work that
    /// captured a path before a move publishes moves it the same way
    /// (TODO S04).
    func relocating(_ path: String, to destination: URL) -> String? {
        guard let spelling = spelling(of: path) else { return nil }
        return destination.path + String(path.dropFirst(spelling.count))
    }

    /// The spelling of this location that `path` starts with: its name, or
    /// the real folder that name leads to. A book's path spells the data
    /// directory as the preferences name it, or, when that name is a link,
    /// perhaps as the folder it leads to.
    private func spelling(of path: String) -> String? {
        let spellings = named.path == real.path ? [named.path] : [named.path, real.path]
        return spellings.first { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Foundation does not reliably resolve a symlink ancestor when the final
    /// destination does not exist yet. Resolve its closest existing ancestor,
    /// then reattach the missing path components (TODO F20).
    private static func resolve(_ url: URL, fileManager: FileManager) -> URL {
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !fileManager.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missingComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component, isDirectory: true)
        }
        return resolved.standardizedFileURL
    }
}

/// How the real folders of a migration's two locations overlap (TODO F20).
/// A migration between overlapping folders would copy the data into itself,
/// or publish over the data it copies, so it is refused before anything is
/// copied, naming both real folders (TODO S10).
enum DataDirectoryOverlap: Equatable {
    /// Both locations lead to one folder.
    case sameFolder
    /// The new location is inside the current data directory.
    case destinationInsideSource
    /// The new location contains the current data directory.
    case sourceInsideDestination

    /// How the real folder of `destination` overlaps that of `source`, or
    /// nil when the two are apart.
    init?(source: DataDirectoryLocation, destination: DataDirectoryLocation) {
        let sourcePath = source.real.path
        let destinationPath = destination.real.path
        if sourcePath == destinationPath {
            self = .sameFolder
        } else if destinationPath.hasPrefix(sourcePath + "/") {
            self = .destinationInsideSource
        } else if sourcePath.hasPrefix(destinationPath + "/") {
            self = .sourceInsideDestination
        } else {
            return nil
        }
    }

    /// Why a migration from `source` to `destination` is refused, naming
    /// both real folders, and each link that leads to one, as in "The new
    /// location, /Users/me/Link, leads to /Users/me/.TextMouth/Backup, which
    /// is inside the current data directory, /Users/me/.TextMouth. Choose a
    /// location outside it."
    func explanation(source: DataDirectoryLocation, destination: DataDirectoryLocation) -> String {
        // The subject ends where the verb follows: "The new location, /a,"
        // or, through a link, "The new location, /link, leads to /a, which".
        let newLocation = destination.isAlias
            ? "The new location, \(destination.named.path), leads to \(destination.real.path), which"
            : "The new location, \(destination.real.path),"
        switch self {
        case .sameFolder:
            // One folder: its real path was just named, so only a link to
            // the current data directory is added.
            let currentLink = source.isAlias ? ", where \(source.named.path) leads" : ""
            return "\(newLocation) is the current data directory\(currentLink). Choose another location."
        case .destinationInsideSource:
            return "\(newLocation) is inside the current data directory, \(source.realDescription). "
                + "Choose a location outside it."
        case .sourceInsideDestination:
            return "\(newLocation) contains the current data directory, \(source.realDescription). "
                + "Choose a location that does not contain it."
        }
    }
}

// MARK: - Publication

/// What publication found at the new location in place of the empty
/// folder, or nothing, that the migration began with (TODO S10). The copy
/// is then not published: whatever was found stays where it is, and the
/// current data directory stays in use.
struct DataDirectoryDestinationChange {
    /// What changed at the new location.
    enum Finding: Equatable {
        /// Items appeared inside the new location's folder: their names,
        /// sorted.
        case items([String])
        /// Something else was put where the new location's folder belongs:
        /// a file, a link, or a folder publication did not find there.
        case replaced
        /// The new location's name now leads to another folder: this real
        /// path.
        case redirected(to: String)
    }

    /// What changed.
    let finding: Finding
    /// The new location, as named and as it led when the copy began.
    let destination: DataDirectoryLocation
    /// The current data directory, which stays in use.
    let source: DataDirectoryLocation

    /// What happened, where, and what TextMouth did, as in "While TextMouth
    /// was copying its data, 2 items appeared in /Volumes/Archive/.TextMouth:
    /// Library and library.json. TextMouth left them there and is still
    /// using /Users/me/.TextMouth. Choose an empty location and try again."
    var explanation: String {
        let prefix = "While TextMouth was copying its data,"
        let inUse = "is still using \(source.namedDescription)."
        switch finding {
        case .items(let names):
            let count = CountWording.phrase(names.count, singular: "item", plural: "items")
            let them = names.count == 1 ? "it" : "them"
            return "\(prefix) \(count) appeared in \(destination.realDescription): \(Self.listing(names)). "
                + "TextMouth left \(them) there and \(inUse) Choose an empty location and try again."
        case .replaced:
            return "\(prefix) something else was put at \(destination.realDescription). "
                + "TextMouth left it there and \(inUse) Choose an empty location and try again."
        case .redirected(let path):
            return "\(prefix) \(destination.named.path) was changed to lead to \(path) instead of "
                + "\(destination.real.path). TextMouth \(inUse) Try again."
        }
    }

    /// At most three names, then how many more, so a folder that filled up
    /// does not flood the status line or a braille display: "a", "a and b",
    /// "a, b, and c", or "a, b, c, and 2 more".
    static func listing(_ names: [String]) -> String {
        var parts = Array(names.prefix(3))
        if names.count > parts.count {
            parts.append("\(names.count - parts.count) more")
        }
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
        }
    }
}

// MARK: - Migration

/// Copy-and-validate migration primitive. It does not mutate global path state,
/// which makes failure behavior deterministic and independently testable.
///
/// Links are explicit (TODO S10). Each location is taken as the folder it
/// leads to: a data directory that is a link is copied from its folder, and
/// a new location that is a link to an empty folder receives the data in
/// that folder. Locations whose real folders overlap (TODO F20), and a new
/// location that is a link leading nowhere, are refused before anything is
/// copied, in words that name the real folders.
///
/// Publication checks the new location again (TODO S10). The copy can take
/// several minutes, and anything that arrives at the new location meanwhile,
/// from another app, a sync service, or another Mac, stops publication and
/// is never deleted. The data directory in use, its setting, and the
/// library index change only after a published copy, and only the caller
/// changes them.
enum DataDirectoryMigrator {
    /// The start of the hidden name a migration stages its copy under,
    /// beside the destination's real folder, followed by a UUID.
    static let stagingNamePrefix = ".TextMouth-migration-"

    /// Copies the data directory at `oldRoot` to `newRoot`, points the
    /// library's books at the copy, checks it, and publishes it.
    /// - Returns: The library the published copy's library.json holds.
    static func prepareMigration(
        from oldRoot: URL,
        to newRoot: URL,
        library: Library,
        fileManager: FileManager = .default
    ) throws -> Library {
        // The copy's library.json is written from `library`. While the index
        // cannot be read, that library is only the provisional one rebuilt
        // from disk, and publishing it would bypass the index write
        // suspension, so migration waits until the index is recovered.
        guard !LibraryPersistenceService.areIndexWritesSuspended else {
            throw LibraryIndexRecoveryError.indexUnreadable
        }
        let source = DataDirectoryLocation(oldRoot, fileManager: fileManager)
        let destination = DataDirectoryLocation(newRoot, fileManager: fileManager)
        try refuseUnsafeLocations(source: source, destination: destination, fileManager: fileManager)

        // The copy is staged and published in the folder that holds the
        // destination's real folder, so a new location that is a link to an
        // empty folder receives the data in that folder, the link staying
        // as it is, and the final rename never crosses volumes (TODO S10).
        let staging = destination.real.deletingLastPathComponent()
            .appendingPathComponent(stagingNamePrefix + UUID().uuidString, isDirectory: true)
        // Noted before anything is created, so a folder that exists is always
        // on this Mac's journal. Removed when the move ends, however it ends;
        // if the removal fails (the volume was unplugged), the note stays and
        // the launch sweep removes the folder once the volume is back.
        MigrationStagingLeftovers.note(staging)
        defer { MigrationStagingLeftovers.discard(staging, fileManager: fileManager) }
        // Copy the folder the data directory leads to. Copying a link copies
        // only the link, so the package records and library.json written
        // below would land in the data directory itself, and publication
        // would leave a second name for it instead of a copy (TODO S10).
        // The copy goes item by item, telling the move that runs it how far
        // it has got and stopping at its Cancel (FR02); a cancelled copy is
        // deleted by the line above, like any copy that is not published.
        try copyItems(of: source.real, into: staging, fileManager: fileManager)

        let migratedLibrary = try stage(library, from: source, to: destination, in: staging, fileManager: fileManager)
        try publish(staging, at: destination, keeping: source, fileManager: fileManager)
        // Renamed into place: nothing is left to clean up.
        MigrationStagingLeftovers.forget(staging)
        return migratedLibrary
    }

    /// What Storage settings say once the data directory is at `destination`
    /// after a run that began with it at `source`: "Done. Data is now at
    /// <path>." Wherever a link stands in either location, the folder it
    /// leads to is named too, so the user hears where the data really is
    /// (TODO S10), as in "Done. Data is now at /Users/me/Archive, which leads
    /// to /Volumes/Archive/.TextMouth."
    static func doneMessage(dataAt destination: DataDirectoryLocation, copiedFrom source: DataDirectoryLocation) -> String {
        var message = "Done. Data is now at \(destination.namedDescription)."
        // A data directory reached through a link was copied from the folder
        // the link leads to; nothing was copied when the data stayed put.
        if source.isAlias, source.real.path != destination.real.path {
            message += " It was copied from \(source.realDescription)."
        }
        return message
    }

    // MARK: Steps

    /// Refuses, before anything is copied, a migration that could not be
    /// published safely: overlapping real folders (TODO F20), a data
    /// directory that does not exist or is no folder, and a new location
    /// that is a link leading nowhere or that already holds something.
    private static func refuseUnsafeLocations(
        source: DataDirectoryLocation,
        destination: DataDirectoryLocation,
        fileManager: FileManager
    ) throws {
        // Compare real folders before copying: a selected symlink can
        // otherwise disguise a child directory and stage a copy inside itself.
        if let overlap = DataDirectoryOverlap(source: source, destination: destination) {
            throw DataDirectoryMigrationError.invalidRelationship(overlap, source: source, destination: destination)
        }
        // Only a folder is a data directory. A file where it was is refused
        // as nothing there is: listing it for the copy would fail in the
        // file system's own words, which say nothing of the data directory.
        var sourceIsFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: source.real.path, isDirectory: &sourceIsFolder),
              sourceIsFolder.boolValue else {
            throw DataDirectoryMigrationError.missingSource
        }
        // A new location that is a link leading nowhere has no folder to
        // receive the data; publishing at its name would replace the link
        // with the data instead. `fileExists` follows links, so it is false
        // for a link whose target is missing or leads back to itself.
        let destinationPath = destination.named.path
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: destinationPath),
           !fileManager.fileExists(atPath: destinationPath) {
            throw DataDirectoryMigrationError.unreachableLink(destination, target: target)
        }
        // Publication can only make way for an empty folder, or for nothing.
        switch try DestinationContents(at: destination.real, fileManager: fileManager) {
        case .nothing:
            break
        case .folder(let names):
            guard names.isEmpty else { throw DataDirectoryMigrationError.destinationNotEmpty }
        case .notAFolder:
            throw DataDirectoryMigrationError.destinationNotAFolder(destination)
        }
    }

    /// Copies the data directory in the folder `source` into a new folder at
    /// `staging`, one item at a time (FR02), in the order of its
    /// `DataDirectoryCopyPlan`: each ordinary folder is made, and each file,
    /// link, and package is copied whole with `copyItem`, which clones it
    /// when both folders are on one APFS volume.
    ///
    /// The observer bound for this copy (`copyObserver`), when there is one,
    /// hears how far it has got before the first item and after each one,
    /// on this thread, and is asked before each item, and once more after
    /// the last, whether the move was cancelled, which stops the copy with
    /// `DataDirectoryMigrationError.cancelled`. The caller deletes whatever
    /// was copied by then, as it deletes any copy it does not publish.
    ///
    /// Once every item is in, each folder made here takes its original's
    /// permissions, extended attributes, and dates, as copying the whole
    /// folder at once did.
    private static func copyItems(of source: URL, into staging: URL, fileManager: FileManager) throws {
        let observer = copyObserver
        let plan = try DataDirectoryCopyPlan(of: source, fileManager: fileManager)
        var progress = DataDirectoryCopyProgress(
            copiedBytes: 0,
            totalBytes: plan.totalBytes,
            copiedItems: 0,
            totalItems: plan.items.count
        )
        observer?.report(progress)
        try stopIfCancelled(observer)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)

        for item in plan.items {
            try stopIfCancelled(observer)
            let copy = staging.appendingPathComponent(item.relativePath)
            switch item.kind {
            case .folder:
                try fileManager.createDirectory(at: copy, withIntermediateDirectories: false)
            case .whole:
                try fileManager.copyItem(at: source.appendingPathComponent(item.relativePath), to: copy)
            }
            progress.copiedBytes += item.byteCount
            progress.copiedItems += 1
            observer?.report(progress)
        }
        // A Cancel pressed while the last item was copied, which can be a
        // large book, still stops the move before anything is published.
        try stopIfCancelled(observer)

        // Deepest first, and the data directory's own folder last: a folder's
        // dates are set once nothing more goes into it.
        let foldersMadeHere = plan.items.filter { $0.kind == .folder }.map(\.relativePath)
        for relativePath in foldersMadeHere.reversed() {
            copyFolderMetadata(
                from: source.appendingPathComponent(relativePath),
                to: staging.appendingPathComponent(relativePath)
            )
        }
        copyFolderMetadata(from: source, to: staging)
    }

    /// Throws `DataDirectoryMigrationError.cancelled` when `observer` says
    /// the move was cancelled.
    private static func stopIfCancelled(_ observer: DataDirectoryCopyObserver?) throws {
        if observer?.isCancelled() == true {
            throw DataDirectoryMigrationError.cancelled
        }
    }

    /// Gives the folder at `copy` the permissions, access control list,
    /// extended attributes, flags, and dates of the folder at `original`
    /// (copyfile(3) with `COPYFILE_METADATA`), as `copyItem` gives a folder
    /// it copies whole. Best effort, as a folder's metadata is no part of
    /// the library: a volume that cannot hold some of it, such as an exFAT
    /// drive's missing extended attributes, keeps the copy as it is.
    private static func copyFolderMetadata(from original: URL, to copy: URL) {
        _ = original.withUnsafeFileSystemRepresentation { from -> Int32 in
            copy.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { return -1 }
                return copyfile(from, to, nil, copyfile_flags_t(COPYFILE_METADATA))
            }
        }
    }

    /// Points every book in the data directory at its place in the new
    /// location, under the name the preferences will hold, writes the result
    /// as the staged copy's package records, each feed's index, and
    /// library.json, and checks it against the copy in `staging`. Each record
    /// is written as a save of its book writes one, so each package's content
    /// index stays as it was copied.
    ///
    /// A feed item's row (FR11) is staged in its feed's folder of the copy,
    /// its record written there, and goes to its feed's index, never to the
    /// staged library.json (`Library.encode(to:)`); a row of the feed shelf,
    /// whose file is not here, moves with the rest and goes to its feed's
    /// index too.
    /// - Returns: The library the staged library.json and feed indexes hold.
    private static func stage(
        _ library: Library,
        from source: DataDirectoryLocation,
        to destination: DataDirectoryLocation,
        in staging: URL,
        fileManager: FileManager
    ) throws -> Library {
        let destinationPath = destination.named.path
        var migratedLibrary = library
        for index in migratedLibrary.books.indices {
            if let moved = source.relocating(migratedLibrary.books[index].filePath, to: destination.named) {
                migratedLibrary.books[index].filePath = moved
            } else if !migratedLibrary.books[index].filePath.hasPrefix(destinationPath + "/") {
                // Neither in the data directory nor already in the new
                // location: the copy never held this book, so it is not
                // "missing from the copy" (`missingBook`) but stored apart.
                throw DataDirectoryMigrationError.bookOutsideDataDirectory(
                    title: migratedLibrary.books[index].title, path: migratedLibrary.books[index].filePath
                )
            }

            let stagedBookPath = staging.path + String(
                migratedLibrary.books[index].filePath.dropFirst(destinationPath.count)
            )
            guard fileManager.fileExists(atPath: stagedBookPath) else {
                throw DataDirectoryMigrationError.missingBook(migratedLibrary.books[index].title)
            }

            if !migratedLibrary.books[index].tmbDirectoryName.isEmpty {
                // In its library folder of the copy, or, for a feed item, in
                // its feed's folder (`Book.packageDirectory(inDataDirectory:)`).
                let stagedPackage = migratedLibrary.books[index].packageDirectory(inDataDirectory: staging)
                // Written as every save of the book writes its record
                // (PERF15), over the record copied with the package, reading
                // bookInfo.json alone. The copied contentIndex.json stays as
                // it is, byte for byte, beside the analysis fields that
                // describe it: only analysis writes that file. An index an
                // older version kept inside bookInfo.json moves into a file
                // of its own, as the book's first save would move it.
                try migratedLibrary.books[index].saveBookInfoThrowing(inPackageAt: stagedPackage)
            }
        }
        migratedLibrary.feedShelf.changeRows { row in
            if let moved = source.relocating(row.filePath, to: destination.named) {
                row.filePath = moved
            }
        }
        try stageFeedIndexes(of: migratedLibrary, at: destination, in: staging, fileManager: fileManager)

        let libraryURL = staging.appendingPathComponent("library.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(migratedLibrary).write(to: libraryURL, options: .atomic)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // library.json holds the library's own books, never a feed item's
        // row (FR11, `Library.encode(to:)`).
        guard let validated = try? decoder.decode(Library.self, from: Data(contentsOf: libraryURL)),
              validated.books.count == migratedLibrary.libraryBookCount else {
            throw DataDirectoryMigrationError.invalidLibrary
        }
        return migratedLibrary
    }

    /// Writes each feed's index in the staged copy from `library`'s feed
    /// items (FR11, `Library.feedIndexRows`), each row placed where its
    /// package is in the data directory at `destination`, exactly as a save
    /// there writes it (`FeedIndexFiles.encodedIndexes(of:placedIn:)` and
    /// `write(_:in:fileManager:)`, which the save uses too). A feed the
    /// library keeps no row of keeps the index copied with its folder; one
    /// whose folder is gone has nothing to keep; and an index left alone
    /// (`FeedShelf.indexesLeftAlone`) is left out, keeping its copy.
    private static func stageFeedIndexes(
        of library: Library,
        at destination: DataDirectoryLocation,
        in staging: URL,
        fileManager: FileManager
    ) throws {
        for index in try FeedIndexFiles.encodedIndexes(of: library, placedIn: destination.named) where index.rowCount > 0 {
            try FeedIndexFiles.write(index, in: staging, fileManager: fileManager)
        }
    }

    /// Renames the checked copy in `staging` to the destination's real
    /// folder, which makes it the new data directory, once it is sure the
    /// new location did not change while the data was copied (TODO S10).
    ///
    /// Whatever arrives there, at any moment, is never deleted or replaced.
    /// The only item removed to make way is the empty folder found there,
    /// with rmdir(2), which the kernel refuses once anything is inside, and
    /// `moveItem` never replaces an item. A change stops publication
    /// instead, with the error naming it; the caller then deletes the copy,
    /// which holds only what this migration copied and wrote.
    private static func publish(
        _ staging: URL,
        at destination: DataDirectoryLocation,
        keeping source: DataDirectoryLocation,
        fileManager: FileManager
    ) throws {
        /// The error that stops publication over `finding`.
        func stopped(_ finding: DataDirectoryDestinationChange.Finding) -> DataDirectoryMigrationError {
            .destinationChanged(DataDirectoryDestinationChange(finding: finding, destination: destination, source: source))
        }

        // The name must still lead to the folder the copy was staged beside.
        // Paths are compared, not URLs: a URL built for a folder that did not
        // exist yet is marked as a directory, and one resolved later may not be.
        let current = DataDirectoryLocation(destination.named, fileManager: fileManager)
        guard current.real.path == destination.real.path else {
            throw stopped(.redirected(to: current.real.path))
        }

        // Look again: anything that arrived since the first look stops here.
        let contents = try DestinationContents(at: destination.real, fileManager: fileManager)
        if let arrival = contents.arrival {
            throw stopped(arrival)
        }
        if contents == .folder([]) {
            try removeEmptyFolder(destination.real, fileManager: fileManager, stopped: stopped)
        }

        do {
            try fileManager.moveItem(at: staging, to: destination.real)
        } catch {
            // moveItem never replaces an item, so whatever stands at the
            // destination now arrived after the look above.
            if let now = try? DestinationContents(at: destination.real, fileManager: fileManager), now != .nothing {
                throw stopped(now.arrival ?? .replaced)
            }
            throw error
        }
    }

    /// Removes the empty folder at `folder` to make way for the copy, with
    /// rmdir(2), which the kernel refuses once anything is inside: whatever
    /// arrived after the caller looked then stops publication through
    /// `stopped`, and is never deleted. A folder already gone needs nothing.
    /// Any other failure, such as a volume mounted on the folder, is thrown
    /// as it is.
    private static func removeEmptyFolder(
        _ folder: URL,
        fileManager: FileManager,
        stopped: (DataDirectoryDestinationChange.Finding) -> DataDirectoryMigrationError
    ) throws {
        guard rmdir(folder.path) != 0 else { return }
        let code = errno
        if code == ENOENT { return }
        if let now = try? DestinationContents(at: folder, fileManager: fileManager), let arrival = now.arrival {
            throw stopped(arrival)
        }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

/// What stands at a migration's destination, looked at without following a
/// link there, so a link is seen as the link it is (TODO S10).
private enum DestinationContents: Equatable {
    /// Nothing: no folder or anything else exists there yet.
    case nothing
    /// A folder, with the names of the items inside it, hidden ones
    /// included, sorted.
    case folder([String])
    /// A file, a link, or anything else that is not a folder.
    case notAFolder

    /// What stands at `url` now.
    init(at url: URL, fileManager: FileManager) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            // The attributes of the item itself, never of a link's target.
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch CocoaError.fileReadNoSuchFile {
            self = .nothing
            return
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            self = .notAFolder
            return
        }
        self = .folder(try fileManager.contentsOfDirectory(atPath: url.path).sortedStably())
    }

    /// What makes this more than the empty folder, or nothing, that a copy
    /// can be published over: the items inside a folder, or an item that is
    /// not a folder. Nil for an empty folder or nothing.
    var arrival: DataDirectoryDestinationChange.Finding? {
        switch self {
        case .nothing: return nil
        case .folder(let names): return names.isEmpty ? nil : .items(names)
        case .notAFolder: return .replaced
        }
    }
}

// MARK: - Copying One Item at a Time (FR02)

/// How far a migration's copy has got: the bytes and items copied so far,
/// of all the copy's. Sizes are the lengths the file system reports for the
/// files, so they count the bytes the copy reads.
struct DataDirectoryCopyProgress: Equatable, Sendable {
    /// Bytes of the items copied so far.
    var copiedBytes: Int64
    /// Bytes of every item the copy copies.
    let totalBytes: Int64
    /// Items copied so far: folders made, and files, links, and packages
    /// copied.
    var copiedItems: Int
    /// Every item the copy copies.
    let totalItems: Int

    /// Whether every item has been copied.
    var isComplete: Bool {
        copiedItems >= totalItems
    }

    /// Whole percent copied, from 0 to 100, rounded down: by bytes when the
    /// items hold any, otherwise by items. It is 100 exactly when every item
    /// has been copied, so a file the file system sizes at 0 never makes a
    /// copy look finished early.
    var percent: Int {
        guard !isComplete else { return 100 }
        let fraction = totalBytes > 0
            ? Double(copiedBytes) / Double(totalBytes)
            : Double(copiedItems) / Double(totalItems)
        let whole = Int((min(1, max(0, fraction)) * 100).rounded(.down))
        return min(whole, 99)
    }
}

/// What a migration's copy tells the move that runs it, and asks it (FR02).
/// The copy calls both on its own thread, so they must be quick: a move
/// hands the progress to the main actor and answers from a locked flag.
struct DataDirectoryCopyObserver: Sendable {
    /// Hears how far the copy has got: once before its first item, then
    /// after each item.
    let report: @Sendable (DataDirectoryCopyProgress) -> Void
    /// Whether the move was cancelled, asked before each item and once more
    /// after the last.
    let isCancelled: @Sendable () -> Bool
}

extension DataDirectoryMigrator {
    /// The observer of the copies made where it is bound (FR02): a move binds
    /// one around `TextMouthPaths.moveDataDirectory`, which calls
    /// `prepareMigration` with no room for one, on the thread or in the task
    /// that copies (`$copyObserver.withValue(_:operation:)`). Unbound, a copy
    /// reports to no one and is never cancelled.
    @TaskLocal static var copyObserver: DataDirectoryCopyObserver?
}

/// The items a migration copies, in the order it copies them, with their
/// sizes (FR02): every item in the data directory's folder, hidden ones
/// included, as a folder to make or an item to copy whole.
///
/// A book's package (a .tmb folder, or any folder the system treats as a
/// package) is one item, copied whole, so each book arrives in one piece
/// and a copy on one APFS volume clones it. Other folders are made and
/// filled one item at a time. Within each folder, folders and packages come
/// before files, each in order of name: the books, the bulk of the copy,
/// are copied first, and the small files at the top, such as config.json,
/// which a setting changed during the copy rewrites, last.
struct DataDirectoryCopyPlan: Equatable {
    /// One item of the copy.
    struct Item: Equatable {
        /// How the copy makes an item.
        enum Kind: Equatable {
            /// An ordinary folder: made empty, and filled by the items after
            /// it whose paths lie inside it.
            case folder
            /// A file, a link, or a package, copied whole.
            case whole
        }

        /// The item's path inside the data directory, such as
        /// "Library/Fiction/Book.tmb".
        let relativePath: String
        /// How the copy makes it.
        let kind: Kind
        /// Its size in bytes: the lengths of every file inside a package,
        /// and 0 for a folder, whose items count for themselves.
        let byteCount: Int64
    }

    /// Every item, in the order the copy makes them: each folder before
    /// the items inside it.
    let items: [Item]

    /// The bytes of every item.
    var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.byteCount }
    }

    /// The plan for the data directory in the folder at `root`, read
    /// through `fileManager` without following any link inside it.
    /// - Throws: The file system's error for anything that cannot be listed
    ///   or looked at, such as a folder that is only in the cloud while
    ///   dataless files are left there (`DatalessFiles.withoutDownloading`).
    init(of root: URL, fileManager: FileManager = .default) throws {
        items = try Self.items(in: root, at: "", fileManager: fileManager)
    }

    /// The items inside the folder `folder`, whose path inside the data
    /// directory is `relativePath` (empty for the data directory itself),
    /// with the items inside each ordinary folder after it.
    private static func items(in folder: URL, at relativePath: String, fileManager: FileManager) throws -> [Item] {
        var folders: [(item: Item, url: URL)] = []
        var others: [Item] = []
        for name in try fileManager.contentsOfDirectory(atPath: folder.path).sortedStably() {
            let url = folder.appendingPathComponent(name)
            let path = relativePath.isEmpty ? name : relativePath + "/" + name
            // The item itself, never a link's target.
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                if isPackage(url) {
                    let item = Item(relativePath: path, kind: .whole, byteCount: try byteCount(ofFolder: url))
                    folders.append((item, url))
                } else {
                    folders.append((Item(relativePath: path, kind: .folder, byteCount: 0), url))
                }
            } else {
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                others.append(Item(relativePath: path, kind: .whole, byteCount: size))
            }
        }
        var ordered: [Item] = []
        for (item, url) in folders {
            ordered.append(item)
            if item.kind == .folder {
                ordered += try items(in: url, at: item.relativePath, fileManager: fileManager)
            }
        }
        return ordered + others
    }

    /// Whether the folder at `url` is copied whole: a book's .tmb package,
    /// or any folder the system treats as a package.
    private static func isPackage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "tmb"
            || (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    /// The lengths of every file inside the folder at `url`, at any depth,
    /// links not followed.
    /// - Throws: The first error met listing the folder.
    private static func byteCount(ofFolder url: URL) throws -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let listingFailure = FolderListingFailure()
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                // Stop at the first folder that cannot be listed.
                listingFailure.note(error)
                return false
            }
        )
        var total: Int64 = 0
        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        if let error = listingFailure.error {
            throw error
        }
        return total
    }
}

/// The first error a folder enumeration met, noted by its error handler,
/// which runs while the enumeration does.
private final class FolderListingFailure {
    /// The first error noted, if any.
    private(set) var error: Error?

    /// Notes `error`, unless one was noted already.
    func note(_ error: Error) {
        if self.error == nil {
            self.error = error
        }
    }
}
