import Foundation

// MARK: - A Feed's Own Index (FR11)

/// A feed's own index of its items' packages (FR11, branch A1): the file
/// `Feeds/<feed ID>/library.json`, beside the packages it lists, with one row
/// per package, as library.json would hold the row, its feed link included.
///
/// The library model holds a feed's rows while TextMouth runs: those whose
/// files are here among its books, and the rest on its feed shelf
/// (`Library.feedShelf`). Every save of the library writes each feed's index
/// from them before library.json, and only an index whose bytes changed
/// (`LibraryPersistenceService`); library.json never holds a feed item's row
/// (`Library.encode(to:)`).
///
/// A row's paths are worked out again from where its package is whenever
/// the index is read (`FeedIndexFiles.placed(_:in:of:)`), so moving the data
/// directory, or opening the library on another Mac, needs no index
/// rewritten first.
struct FeedIndex: Equatable {
    /// The version of the index's layout this TextMouth writes.
    static let currentFormatVersion = 1

    /// The feed whose items the index lists.
    var feedID: UUID
    /// One row per package, each a feed item's (`Book.feedLink`).
    var books: [Book]
}

extension FeedIndex: Codable {
    /// The index's keys: its layout's version, its feed, and its rows.
    private enum CodingKeys: String, CodingKey {
        case formatVersion, feedID, books
    }

    /// Reads an index. The feed ID it names is read for completeness; the
    /// folder it is found in decides which feed it lists, as a record's
    /// file name does (`FeedIndexFiles.read(feedID:in:fromPackages:)`). Each
    /// row reads as a library.json row does, leniently.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feedID = try container.decode(UUID.self, forKey: .feedID)
        books = try container.decode([Book].self, forKey: .books)
    }

    /// Writes the index with its layout's version first.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
        try container.encode(feedID, forKey: .feedID)
        try container.encode(books, forKey: .books)
    }
}

// MARK: - Reading and Writing Feed Indexes

/// How each feed's index is read from disk and encoded for it (FR11). The
/// library's persistence writes the indexes (`LibraryPersistenceService`).
enum FeedIndexFiles {
    /// `index` as its file holds it: compact JSON with ISO 8601 dates, as
    /// library.json is written, with sorted keys and its rows in the order
    /// they were added, so one index is always written as the same bytes and
    /// a save that changed nothing of a feed writes nothing for it.
    static func encoded(_ index: FeedIndex) throws -> Data {
        var ordered = index
        ordered.books.sort(by: isInIndexOrder)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ordered)
    }

    /// The order an index lists its rows in: by the date each was added,
    /// then by ID, which no two rows share.
    private static func isInIndexOrder(_ first: Book, _ second: Book) -> Bool {
        if first.dateAdded != second.dateAdded {
            return first.dateAdded < second.dateAdded
        }
        return first.id.uuidString < second.id.uuidString
    }

    /// The index `data` holds. Throws when it holds none.
    static func decoded(_ data: Data) throws -> FeedIndex {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FeedIndex.self, from: data)
    }

    // MARK: Reading

    /// What reading one feed's folder found.
    struct Contents: Equatable {
        /// The feed's rows, each placed where its package is now.
        var rows: [Book]
        /// The index file's bytes as they were read, which a save writing
        /// the same bytes leaves in place; nil when no usable index was
        /// read.
        var indexBytes: Data?
    }

    /// Every feed's rows in the data directory at `root`: each folder of its
    /// Feeds folder named by a feed's ID (`FeedPaths.feedID(ofItemsFolderNamed:)`),
    /// read as `read(feedID:in:fromPackages:)` reads one. A feed without a
    /// folder has downloaded nothing, and has no rows.
    static func readAll(in root: URL, fromPackages: Bool = false) -> [UUID: Contents] {
        let feedsFolder = FeedPaths.recordsFolder(in: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: feedsFolder.path)) ?? []
        var contents: [UUID: Contents] = [:]
        for name in names.sorted() {
            guard let feedID = FeedPaths.feedID(ofItemsFolderNamed: name),
                  isFolder(feedsFolder.appendingPathComponent(name, isDirectory: true)) else { continue }
            contents[feedID] = read(feedID: feedID, in: root, fromPackages: fromPackages)
        }
        return contents
    }

    /// The rows of the feed `feedID` in the data directory at `root`, each
    /// placed where its package is (`placed(_:in:of:)`):
    ///
    /// - the rows of its index, which is read as library.json is, waiting
    ///   for a file only in the cloud; unless `fromPackages`, as while the
    ///   library index is recovered, when the packages' records, which hold
    ///   the latest state, are read instead, as the provisional library's
    ///   books are;
    /// - and a row for every package in its folder the index does not list,
    ///   read from the package's record, as a download whose save a crash cut
    ///   short leaves one.
    ///
    /// An index that cannot be read or decoded is preserved beside itself
    /// (`SavedFile.preserveUnusable`), with one FEED_INDEX_UNREADABLE line,
    /// and the rows come from the packages, each of which names its feed and
    /// item in its record.
    static func read(feedID: UUID, in root: URL, fromPackages: Bool = false) -> Contents {
        let indexURL = FeedPaths.indexFile(of: feedID, in: root)
        var rows: [Book] = []
        var indexBytes: Data?
        if !fromPackages {
            switch SavedFile.read(indexURL, using: { try Data(contentsOf: $0) }) {
            case .missing:
                break
            case .contents(let data):
                do {
                    rows = try decoded(data).books
                    indexBytes = data
                } catch {
                    preserveUnusable(indexURL, of: feedID, bytes: data, because: error.localizedDescription)
                }
            case .inCloud:
                preserveUnusable(indexURL, of: feedID, bytes: nil, because: "it is only in the cloud")
            case .unreadable(let reason):
                preserveUnusable(indexURL, of: feedID, bytes: nil, because: reason)
            }
        }
        let listed = Set(rows.map(\.tmbDirectoryName))
        let unlisted = rowsFromPackages(of: feedID, in: root, excluding: listed)
        if indexBytes != nil, !unlisted.isEmpty {
            DiagnosticLog.event(
                .feeds,
                "FEED_INDEX: \(feedID.uuidString.prefix(8)): took \(CountWording.phrase(unlisted.count, singular: "package", plural: "packages")) "
                    + "its index did not list from their records"
            )
        }
        return Contents(rows: (rows + unlisted).map { placed($0, in: root, of: feedID) }, indexBytes: indexBytes)
    }

    /// A row for every package in the feed `feedID`'s folder whose name is
    /// not in `listed`, read from the package's record, read with dataless
    /// files left in the cloud: every package holding a readable record and
    /// no removal marker. A staged package, whose name is hidden, is never
    /// one; a record only in the cloud is left for a launch that finds it
    /// here, which takes it then.
    private static func rowsFromPackages(of feedID: UUID, in root: URL, excluding listed: Set<String>) -> [Book] {
        let folder = FeedPaths.itemsFolder(of: feedID, in: root)
        let names = DatalessFiles.withoutDownloading {
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        }
        var rows: [Book] = []
        for name in names.sorted() where name.hasSuffix(".tmb") && !name.hasPrefix(".") && !listed.contains(name) {
            let package = folder.appendingPathComponent(name, isDirectory: true)
            let marker = TextMouthPaths.removedFromLibraryMarkerPath(in: package)
            guard !FileManager.default.fileExists(atPath: marker.path),
                  let record = try? DatalessFiles.withoutDownloading({ try StoredBookRecord.read(from: package) }).info else {
                continue
            }
            rows.append(Book(
                record: record,
                filePath: package.appendingPathComponent(record.metadata.originalFileName).path,
                folderPath: "",
                tmbDirectoryName: name
            ))
        }
        return rows
    }

    /// Keeps a copy of the feed `feedID`'s index at `url`, which can't be
    /// used, beside it, and says so in one FEED_INDEX_UNREADABLE line naming
    /// the feed.
    private static func preserveUnusable(_ url: URL, of feedID: UUID, bytes: Data?, because reason: String) {
        SavedFile.preserveUnusable(
            url,
            bytes: bytes,
            because: reason,
            logging: "FEED_INDEX_UNREADABLE",
            in: .feeds,
            standIn: "the rows of feed \(feedID.uuidString) are read from its packages"
        )
    }

    /// Whether a folder is at `url`.
    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Placing Rows

    /// `row` as a row of the feed `feedID`, placed where its package is in
    /// that feed's folder in the data directory at `root`: a feed item of
    /// that feed, whatever feed its row named (the folder decides), with no
    /// library folder, and its file at its place in the package.
    static func placed(_ row: Book, in root: URL, of feedID: UUID) -> Book {
        var placed = row
        placed.feedLink = FeedBookLink(feedID: feedID, itemID: row.feedLink?.itemID ?? "")
        placed.folderPath = ""
        placed.filePath = path(row.filePath, inPackageNamed: row.tmbDirectoryName, at: placed.packageDirectory(inDataDirectory: root))
        return placed
    }

    /// `filePath`, a path inside a package named `packageName` wherever that
    /// package was, at the same place inside `package`: the part after the
    /// package's name, or the file's own name when the path passes through
    /// no package of that name.
    static func path(_ filePath: String, inPackageNamed packageName: String, at package: URL) -> String {
        let marker = "/" + packageName + "/"
        if !packageName.isEmpty, let range = filePath.range(of: marker, options: .backwards) {
            return package.appendingPathComponent(String(filePath[range.upperBound...])).path
        }
        return package.appendingPathComponent(URL(fileURLWithPath: filePath).lastPathComponent).path
    }
}
