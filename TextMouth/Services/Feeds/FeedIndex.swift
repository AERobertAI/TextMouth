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
    /// The rows this TextMouth could not read (V03): a feed item a later
    /// TextMouth wrote, in a format or with fields this one does not know.
    /// Each is kept exactly as read and written back after `books`, as
    /// library.json keeps its own (`Library.unreadableRows`), never shown or
    /// counted as a feed item. Its package, in this feed's folder, is its
    /// own.
    var unreadableRows: [UnreadableLibraryRow] = []
}

/// Why an index was not read: a newer TextMouth wrote it, in a layout of a
/// later version than this one writes (`FeedIndex.currentFormatVersion`),
/// whose rows may be laid out otherwise. Such a file is left as it is,
/// never read as this layout nor written over (`FeedIndexFiles.read`).
struct FeedIndexNewerLayout: Error, Equatable {
    /// The layout's version the file names.
    let formatVersion: Int
}

extension FeedIndex: Codable {
    /// The index's keys: its layout's version, its feed, and its rows.
    private enum CodingKeys: String, CodingKey {
        case formatVersion, feedID, books
    }

    /// Reads an index: its layout's version first, so one a newer TextMouth
    /// wrote is never read as this layout (`FeedIndexNewerLayout`); an index
    /// naming no version is of the first. The feed ID it names is read for
    /// completeness; the folder it is found in decides which feed it lists,
    /// as a record's file name does
    /// (`FeedIndexFiles.read(feedID:in:fromPackages:reader:)`). Each row
    /// reads as a library.json row does, leniently, and a row that cannot be
    /// read is kept, not fatal (V03, `UnreadableLibraryRow.decodeRows(from:)`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        guard version <= Self.currentFormatVersion else {
            throw FeedIndexNewerLayout(formatVersion: version)
        }
        feedID = try container.decode(UUID.self, forKey: .feedID)
        var rows = try container.nestedUnkeyedContainer(forKey: .books)
        let decoded = try UnreadableLibraryRow.decodeRows(from: &rows)
        books = decoded.books
        unreadableRows = decoded.unreadable
    }

    /// Writes the index with its layout's version first, its rows, and then
    /// the rows it keeps as they were read (V03). An index without kept rows
    /// is written exactly as it was before they could be kept.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
        try container.encode(feedID, forKey: .feedID)
        var rows = container.nestedUnkeyedContainer(forKey: .books)
        for book in books {
            try rows.encode(book)
        }
        for row in unreadableRows {
            try rows.encode(row.json)
        }
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
        // The standard sort, specialized, as LibraryBookSorter keeps it: this
        // sorts every row of a feed's index at each library save, a list of
        // whole books large enough that the shared helper's unspecialized
        // comparison would cost more than its share of the app's size.
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

    /// The index `data` holds. Throws when it holds none, or
    /// `FeedIndexNewerLayout` for one a newer TextMouth wrote.
    static func decoded(_ data: Data) throws -> FeedIndex {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FeedIndex.self, from: data)
    }

    // MARK: Writing

    /// One feed's index as it is written: the feed, how many rows it holds,
    /// and its file's bytes.
    struct EncodedIndex: Equatable {
        /// The feed whose index this is.
        let feedID: UUID
        /// How many rows the index holds.
        let rowCount: Int
        /// The file's bytes (`encoded(_:)`).
        let data: Data
    }

    /// Each feed's index `library` keeps (`Library.feedIndexRows`), in the
    /// order of the feeds' IDs, its rows placed where their packages are in
    /// the data directory at `root` (`placed(_:in:of:)`), as its file holds
    /// it: what every writer of the feeds' indexes writes, a save in the
    /// data directory in use (`LibraryPersistenceService`) and a
    /// data-directory move's staged copy, whose rows are placed in the new
    /// location (`DataDirectoryMigrator`).
    static func encodedIndexes(of library: Library, placedIn root: URL) throws -> [EncodedIndex] {
        try library.feedIndexRows.sortedStably { $0.key.uuidString < $1.key.uuidString }.map { feedID, rows in
            let placedRows = rows.map { placed($0, in: root, of: feedID) }
            // The rows this version cannot read are written back as they
            // were read, and count as rows: an index holding only them is
            // not empty (V03).
            let kept = library.feedShelf.unreadableRows[feedID] ?? []
            let index = FeedIndex(feedID: feedID, books: placedRows, unreadableRows: kept)
            return EncodedIndex(feedID: feedID, rowCount: rows.count + kept.count, data: try encoded(index))
        }
    }

    /// Writes `index` as its feed's index in the data directory at `root`,
    /// making the feed's folder when missing and replacing the file
    /// atomically, so no reader ever finds half an index.
    static func write(_ index: EncodedIndex, in root: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: FeedPaths.itemsFolder(of: index.feedID, in: root), withIntermediateDirectories: true)
        try index.data.write(to: FeedPaths.indexFile(of: index.feedID, in: root), options: .atomic)
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
        /// Whether the index file is left as it is, neither read nor ever
        /// written over (`FeedShelf.indexesLeftAlone`): it is only in the
        /// cloud (FR02), so reading it would have downloaded it first, or a
        /// newer TextMouth wrote it, in a layout this one does not read
        /// (`FeedIndexNewerLayout`). The rows stand in for its own, read from
        /// the packages' records.
        var isLeftAlone = false
        /// The rows of the index this TextMouth could not read (V03), kept
        /// as they were read for the next save of the index to write back.
        /// None is among `rows`, and none of their packages is.
        var unreadableRows: [UnreadableLibraryRow] = []
    }

    /// Every feed's rows in the data directory at `root`: each folder of its
    /// Feeds folder named by a feed's ID (`FeedPaths.feedID(ofItemsFolderNamed:)`),
    /// read as `read(feedID:in:fromPackages:reader:)` reads one. The Feeds
    /// folder is listed with dataless files left in the cloud, so a listing
    /// only in the cloud reads as no feed's folder rather than waiting on
    /// the network. A feed without a folder has downloaded nothing, and has
    /// no rows.
    static func readAll(
        in root: URL,
        fromPackages: Bool = false,
        reader: SavedFile.Reader = SavedFile.readWithoutDownloading
    ) -> [UUID: Contents] {
        let feedsFolder = FeedPaths.recordsFolder(in: root)
        let names = DatalessFiles.withoutDownloading {
            (try? FileManager.default.contentsOfDirectory(atPath: feedsFolder.path)) ?? []
        }
        var contents: [UUID: Contents] = [:]
        for name in names.sortedStably() {
            guard let feedID = FeedPaths.feedID(ofItemsFolderNamed: name),
                  isFolder(feedsFolder.appendingPathComponent(name, isDirectory: true)) else { continue }
            contents[feedID] = read(feedID: feedID, in: root, fromPackages: fromPackages, reader: reader)
        }
        return contents
    }

    /// The rows of the feed `feedID` in the data directory at `root`, each
    /// placed where its package is (`placed(_:in:of:)`):
    ///
    /// - the rows of its index, read through `reader`, which the app's
    ///   leaves a file only in the cloud there (`SavedFile.readWithoutDownloading`,
    ///   as a feed's record is read); unless `fromPackages`, as while the
    ///   library index is recovered, when the packages' records, which hold
    ///   the latest state, are read instead, as the provisional library's
    ///   books are;
    /// - and a row for every package in its folder the index does not list,
    ///   read from the package's record, as a download whose save a crash cut
    ///   short leaves one.
    ///
    /// A row of the index this TextMouth cannot read (a feed item a later
    /// TextMouth wrote) does not make the index unusable: it is kept in
    /// `Contents.unreadableRows`, and its package is not read again as a row
    /// of the folder (V03).
    ///
    /// An index that cannot be read or decoded is preserved beside itself
    /// (`SavedFile.preserveUnusable`), with one FEED_INDEX_UNREADABLE line,
    /// and the rows come from the packages, each of which names its feed and
    /// item in its record.
    ///
    /// An index only in the cloud is no damage, and is not preserved: its
    /// download is asked of the sync service, one FEED_INDEX_IN_CLOUD line
    /// says so, the rows come from the packages whose records are here, and
    /// the index is left alone (`Contents.isLeftAlone`), so no save writes
    /// those rows over what the cloud holds until a launch reads it. A
    /// launch in a cloud data directory waits for every feed's index to be
    /// on this Mac (`DataDirectoryCheck`), so this happens only when one
    /// leaves between that check and this read. An index a newer TextMouth
    /// wrote, in a later layout (`FeedIndexNewerLayout`), is left alone the
    /// same way, with one FEED_INDEX_NEWER line, rather than taken for
    /// damage and written over in this one's layout.
    static func read(
        feedID: UUID,
        in root: URL,
        fromPackages: Bool = false,
        reader: SavedFile.Reader = SavedFile.readWithoutDownloading
    ) -> Contents {
        let indexURL = FeedPaths.indexFile(of: feedID, in: root)
        var rows: [Book] = []
        var kept: [UnreadableLibraryRow] = []
        var indexBytes: Data?
        var isLeftAlone = false
        if !fromPackages {
            switch SavedFile.read(indexURL, using: reader) {
            case .missing:
                break
            case .contents(let data):
                do {
                    let index = try decoded(data)
                    rows = index.books
                    kept = index.unreadableRows
                    indexBytes = data
                } catch let newer as FeedIndexNewerLayout {
                    isLeftAlone = true
                    DiagnosticLog.event(
                        .feeds,
                        "FEED_INDEX_NEWER: \(feedID.uuidString.prefix(8)): \(indexURL.lastPathComponent) is of layout "
                            + "\(newer.formatVersion), which a newer TextMouth wrote; it is left as it is, and the feed's rows "
                            + "are read from its packages"
                    )
                } catch {
                    preserveUnusable(indexURL, of: feedID, bytes: data, because: error.localizedDescription)
                }
            case .inCloud:
                isLeftAlone = true
                Task { @MainActor in SavedFile.requestDownload(of: indexURL) }
                DiagnosticLog.event(
                    .feeds,
                    "FEED_INDEX_IN_CLOUD: \(feedID.uuidString.prefix(8)): \(indexURL.lastPathComponent) is only in the cloud, "
                        + "so it was not read; asked the sync service for it, and until a launch reads it the feed's rows "
                        + "are read from its packages and its index is not written"
                )
            case .unreadable(let reason):
                preserveUnusable(indexURL, of: feedID, bytes: nil, because: reason)
            }
        }
        let listed = Set(rows.map(\.tmbDirectoryName))
        let unlisted = rowsFromPackages(of: feedID, in: root, excluding: listed, keptRows: KeptRowPackages(kept))
        if indexBytes != nil, !unlisted.isEmpty {
            DiagnosticLog.event(
                .feeds,
                "FEED_INDEX: \(feedID.uuidString.prefix(8)): took \(CountWording.phrase(unlisted.count, singular: "package", plural: "packages")) "
                    + "its index did not list from their records"
            )
        }
        return Contents(
            rows: (rows + unlisted).map { placed($0, in: root, of: feedID) },
            indexBytes: indexBytes,
            isLeftAlone: isLeftAlone,
            unreadableRows: kept
        )
    }

    /// A row for every package in the feed `feedID`'s folder whose name is
    /// not in `listed` and which no row in `keptRows` owns (a row of the
    /// index this TextMouth cannot read, V03), read from the package's
    /// record, read with dataless files left in the cloud: every package
    /// holding a readable record and no removal marker. A staged package,
    /// whose name is hidden, is never one; a record only in the cloud is
    /// left for a launch that finds it here, which takes it then.
    private static func rowsFromPackages(
        of feedID: UUID,
        in root: URL,
        excluding listed: Set<String>,
        keptRows: KeptRowPackages
    ) -> [Book] {
        let folder = FeedPaths.itemsFolder(of: feedID, in: root)
        let names = DatalessFiles.withoutDownloading {
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        }
        var rows: [Book] = []
        for name in names.sortedStably() where name.hasSuffix(".tmb") && !name.hasPrefix(".") && !listed.contains(name)
            && !keptRows.owns(tmbDirectoryName: name) {
            let package = folder.appendingPathComponent(name, isDirectory: true)
            let marker = TextMouthPaths.removedFromLibraryMarkerPath(in: package)
            // The marker is looked up with downloads refused, since a package
            // only in the cloud would be downloaded on the main thread; the
            // record read below is refused too, and skips the package.
            guard !DatalessFiles.withoutDownloading({ FileManager.default.fileExists(atPath: marker.path) }),
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
