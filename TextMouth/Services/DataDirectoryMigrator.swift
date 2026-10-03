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
    case missingSource
    case missingBook(String)
    case invalidLibrary
    /// The new location changed while the data was being copied, so the
    /// copy was not published and the data directory in use did not change
    /// (TODO S10). The description names what changed and where.
    case destinationChanged(DataDirectoryDestinationChange)

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
        case .invalidLibrary: return "The migrated library index could not be validated."
        case .destinationChanged(let change): return change.explanation
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
        defer { try? fileManager.removeItem(at: staging) }
        // Copy the folder the data directory leads to. Copying a link copies
        // only the link, so the package records and library.json written
        // below would land in the data directory itself, and publication
        // would leave a second name for it instead of a copy (TODO S10).
        try fileManager.copyItem(at: source.real, to: staging)

        let migratedLibrary = try stage(library, from: source, to: destination, in: staging, fileManager: fileManager)
        try publish(staging, at: destination, keeping: source, fileManager: fileManager)
        return migratedLibrary
    }

    // MARK: Steps

    /// Refuses, before anything is copied, a migration that could not be
    /// published safely: overlapping real folders (TODO F20), a data
    /// directory that does not exist, and a new location that is a link
    /// leading nowhere or that already holds something.
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
        guard fileManager.fileExists(atPath: source.real.path) else {
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

    /// Points every book in the data directory at its place in the new
    /// location, under the name the preferences will hold, writes the result
    /// as the staged copy's package records and library.json, and checks it
    /// against the copy in `staging`.
    /// - Returns: The library the staged library.json holds.
    private static func stage(
        _ library: Library,
        from source: DataDirectoryLocation,
        to destination: DataDirectoryLocation,
        in staging: URL,
        fileManager: FileManager
    ) throws -> Library {
        let destinationPath = destination.named.path
        // A book's path spells the data directory as the preferences name
        // it, or, when that name is a link, perhaps as the folder it leads to.
        let sourcePaths = source.named.path == source.real.path
            ? [source.named.path]
            : [source.named.path, source.real.path]
        var migratedLibrary = library
        for index in migratedLibrary.books.indices {
            let oldPath = migratedLibrary.books[index].filePath
            if let sourcePath = sourcePaths.first(where: { oldPath == $0 || oldPath.hasPrefix($0 + "/") }) {
                migratedLibrary.books[index].filePath = destinationPath + String(oldPath.dropFirst(sourcePath.count))
            }

            let stagedBookPath = staging.path + String(
                migratedLibrary.books[index].filePath.dropFirst(destinationPath.count)
            )
            guard fileManager.fileExists(atPath: stagedBookPath) else {
                throw DataDirectoryMigrationError.missingBook(migratedLibrary.books[index].title)
            }

            if !migratedLibrary.books[index].tmbDirectoryName.isEmpty {
                let stagedPackage = staging
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent(migratedLibrary.books[index].folderPath, isDirectory: true)
                    .appendingPathComponent(migratedLibrary.books[index].tmbDirectoryName, isDirectory: true)
                var info = migratedLibrary.books[index].makeBookInfo()
                info.contentIndex = (try? BookInfo.load(from: stagedPackage))?.contentIndex
                try info.save(to: stagedPackage)
            }
        }

        let libraryURL = staging.appendingPathComponent("library.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(migratedLibrary).write(to: libraryURL, options: .atomic)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let validated = try? decoder.decode(Library.self, from: Data(contentsOf: libraryURL)),
              validated.books.count == migratedLibrary.books.count else {
            throw DataDirectoryMigrationError.invalidLibrary
        }
        return migratedLibrary
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
        self = .folder(try fileManager.contentsOfDirectory(atPath: url.path).sorted())
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
