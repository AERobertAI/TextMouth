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
    case destinationNotEmpty
    case missingSource
    case missingBook(String)
    case invalidLibrary

    var errorDescription: String? {
        switch self {
        case .invalidRelationship(let overlap, let source, let destination):
            return overlap.explanation(source: source, destination: destination)
        case .destinationNotEmpty: return "The selected data directory is not empty. Choose an empty location."
        case .missingSource: return "The current data directory does not exist."
        case .missingBook(let title): return "The migrated copy is missing the content for \(title)."
        case .invalidLibrary: return "The migrated library index could not be validated."
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
/// `init(_:fileManager:)` resolves a name against the file system.
struct DataDirectoryLocation: Equatable {
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

// MARK: - Migration

/// Copy-and-validate migration primitive. It does not mutate global path state,
/// which makes failure behavior deterministic and independently testable.
enum DataDirectoryMigrator {
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
        // Compare real folders before copying: a selected symlink can
        // otherwise disguise a child directory and stage a copy inside itself.
        if let overlap = DataDirectoryOverlap(source: source, destination: destination) {
            throw DataDirectoryMigrationError.invalidRelationship(overlap, source: source, destination: destination)
        }
        let destinationPath = destination.named.path
        guard fileManager.fileExists(atPath: source.real.path) else {
            throw DataDirectoryMigrationError.missingSource
        }
        if fileManager.fileExists(atPath: destinationPath) {
            let contents = try fileManager.contentsOfDirectory(atPath: destinationPath)
            guard contents.isEmpty else { throw DataDirectoryMigrationError.destinationNotEmpty }
        }

        let staging = destination.named.deletingLastPathComponent()
            .appendingPathComponent(".TextMouth-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        // Copy the folder the data directory leads to. Copying a link copies
        // only the link, so the package records and library.json written
        // below would land in the data directory itself, and publication
        // would leave a second name for it instead of a copy (TODO S10).
        try fileManager.copyItem(at: source.real, to: staging)

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

        if fileManager.fileExists(atPath: destinationPath) {
            try fileManager.removeItem(at: destination.named)
        }
        try fileManager.moveItem(at: staging, to: destination.named)
        return migratedLibrary
    }
}
