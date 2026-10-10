import XCTest
@testable import TextMouth

/// A feed item's row and its feed link (FR11, branch A1): a row names the
/// feed and item its book was downloaded from while the book belongs to its
/// feed, library.json's rows read and write exactly as before, and a package
/// found in the Library folder is always a book of the library's own.
///
/// Built on the cloud maintenance fixtures: each test's packages are in a
/// library folder of its own, removed afterwards, with the library index put
/// back as it was.
final class FeedItemIndexRowTests: CloudMaintenanceTestCase {

    // MARK: - The Row

    /// A row without a feed link, as every row of library.json is, is
    /// written without the key, so library.json's rows stay exactly as they
    /// were.
    func testARowWithoutAFeedLinkIsWrittenWithoutTheKey() throws {
        let book = Book(title: "Plain", format: .txt, filePath: "/library/plain.txt", md5Hash: "plain")

        let row = try Self.encodedRow(book)

        XCTAssertNil(row["feedLink"], "a row without a link names none")
        XCTAssertFalse(book.isFeedItem)
    }

    /// A row with a feed link writes it, reads it back, and counts as a
    /// feed item's.
    func testARowWithAFeedLinkReadsItBack() throws {
        let link = FeedBookLink(feedID: UUID(), itemID: "episode-1")
        // A whole second, which ISO 8601 dates keep exactly.
        let added = Date(timeIntervalSince1970: 1_790_000_000)
        let book = Book(
            title: "Episode", format: .audio, filePath: "/feeds/episode.mp3", md5Hash: "e", dateAdded: added, feedLink: link
        )

        let decoded = try Self.decoder.decode(Book.self, from: Self.encoder.encode(book))

        XCTAssertEqual(decoded.feedLink, link)
        XCTAssertTrue(decoded.isFeedItem)
        XCTAssertEqual(decoded, book)
    }

    /// A feed link that cannot be read counts as none, and the row, with
    /// everything else it holds, still loads.
    func testAFeedLinkThatCannotBeReadCountsAsNone() throws {
        let book = Book(title: "Damaged", format: .txt, filePath: "/library/damaged.txt", md5Hash: "d")
        for damaged in ["garbage", ["feedID": "not a UUID", "itemID": "x"]] as [Any] {
            var row = try Self.encodedRow(book)
            row["feedLink"] = damaged

            let decoded = try Self.decoder.decode(Book.self, from: JSONSerialization.data(withJSONObject: row))

            XCTAssertNil(decoded.feedLink, "\(damaged)")
            XCTAssertEqual(decoded.title, "Damaged")
        }
    }

    // MARK: - The Record

    /// A record takes the row's link; a row without one keeps the link the
    /// stored record holds, so clearing a row's link never erases where the
    /// book came from.
    func testARecordTakesTheRowsLinkOrKeepsTheStoredOne() {
        let stored = FeedBookLink(feedID: UUID(), itemID: "stored")
        let rowLink = FeedBookLink(feedID: UUID(), itemID: "row")
        let plain = Book(title: "Kept Link", format: .txt, filePath: "/library/kept.txt", md5Hash: "k")
        var storedInfo = plain.makeBookInfo()
        storedInfo.metadata.feedLink = stored
        let storedRecord = StoredBookRecord(info: storedInfo, keepsContentIndex: false)
        var linked = plain
        linked.feedLink = rowLink

        XCTAssertEqual(linked.makeBookInfo().metadata.feedLink, rowLink)
        XCTAssertEqual(linked.bookInfo(replacing: storedRecord, contentIndex: nil).metadata.feedLink, rowLink)
        XCTAssertEqual(plain.bookInfo(replacing: storedRecord, contentIndex: nil).metadata.feedLink, stored)
        XCTAssertNil(plain.bookInfo(replacing: nil, contentIndex: nil).metadata.feedLink)
    }

    /// A book rebuilt from its record takes the record's link.
    func testABookRebuiltFromItsRecordTakesItsLink() {
        let link = FeedBookLink(feedID: UUID(), itemID: "rebuilt")
        let book = Book(title: "Rebuilt", format: .html, filePath: "/feeds/rebuilt.html", md5Hash: "r", feedLink: link)

        let rebuilt = Book(record: book.makeBookInfo(), filePath: book.filePath, folderPath: "", tmbDirectoryName: "")

        XCTAssertEqual(rebuilt.feedLink, link)
        XCTAssertNil(rebuilt.placedInLibraryFolder().feedLink)
    }

    // MARK: - Packages in the Library Folder

    /// A package in the Library folder whose record names a feed, as a
    /// download made before FR11 does, is adopted as a book of the
    /// library's own: its row has no link, and its record keeps the one it
    /// had.
    func testAPackageInTheLibraryFolderIsALibraryBookWhateverItsRecordSays() throws {
        let book = try makePackagedBook(title: "Adopted Article")
        let package = book.tmbDirectory
        let link = FeedBookLink(feedID: UUID(), itemID: "article-1")
        var recorded = book
        recorded.feedLink = link
        try recorded.makeBookInfo().save(to: package)

        var library = Library()
        FileImportService.adoptOrphanedTMBPackages(library: &library)

        let adopted = try XCTUnwrap(library.books.first { $0.id == book.id })
        XCTAssertNil(adopted.feedLink)
        XCTAssertEqual(adopted.folderPath, folderPath)
        XCTAssertEqual(try BookInfo.load(from: package).metadata.feedLink, link)
    }

    /// A package's record read for the Library folder, as importing or
    /// taking back a package reads one, gives a book without a link.
    func testAPackageRecordPlacedInTheLibraryFolderHasNoLink() {
        let link = FeedBookLink(feedID: UUID(), itemID: "imported")
        let book = Book(title: "Imported", format: .txt, filePath: "/x/imported.txt", md5Hash: "i", feedLink: link)

        let placed = FileImportService.bookFromPackageInfo(
            book.makeBookInfo(),
            packageURL: URL(fileURLWithPath: "/library/Imported.tmb"),
            folderPath: "",
            tmbName: "Imported.tmb"
        )

        XCTAssertNil(placed.feedLink)
        XCTAssertEqual(placed.id, book.id)
    }

    // MARK: - Where the Package Is

    /// A feed item's package is in its feed's own folder, beside the feed's
    /// record and outside the Library folder, whatever folder its row names.
    func testAFeedItemsPackageIsInItsFeedsFolder() {
        let feedID = UUID()
        let root = TextMouthPaths.root
        let book = Book(
            title: "Episode", format: .audio, filePath: "/episode.mp3", md5Hash: "e",
            folderPath: "Podcasts", tmbDirectoryName: "Episode-1.tmb",
            feedLink: FeedBookLink(feedID: feedID, itemID: "1")
        )

        let expected = root.appendingPathComponent("Feeds/\(feedID.uuidString)/Episode-1.tmb", isDirectory: true)
        XCTAssertEqual(book.tmbDirectory.standardizedFileURL.path, expected.standardizedFileURL.path)
        XCTAssertEqual(book.tmbDirectory, FeedPaths.packageDirectory(named: "Episode-1.tmb", of: feedID, in: root))
        XCTAssertFalse(book.tmbDirectory.path.hasPrefix(TextMouthPaths.libraryDir.path + "/"))
    }

    /// Every other book's package is in its library folder, exactly where
    /// it always was, in the data directory in use and in any other.
    func testABooksPackageIsInItsLibraryFolder() {
        let other = URL(fileURLWithPath: "/Volumes/Elsewhere/.TextMouth", isDirectory: true)
        for folder in ["", "Fiction/Sci-Fi"] {
            let book = Book(
                title: "Book", format: .txt, filePath: "/book.txt", md5Hash: "b",
                folderPath: folder, tmbDirectoryName: "Book-1.tmb"
            )

            XCTAssertEqual(book.tmbDirectory, TextMouthPaths.tmbPath(folderPath: folder, tmbName: "Book-1.tmb"), folder)
            let inFolder = folder.isEmpty ? "" : folder + "/"
            XCTAssertEqual(
                book.packageDirectory(inDataDirectory: other).path,
                "/Volumes/Elsewhere/.TextMouth/Library/\(inFolder)Book-1.tmb",
                folder
            )
        }
    }

    /// A row's location carries its feed link, so a reader that takes a
    /// moved row's library fields finds the package in its feed's folder.
    func testTheLocationCarriesTheFeedLink() {
        let link = FeedBookLink(feedID: UUID(), itemID: "moved")
        var reader = Book(
            title: "Moved Article", format: .html, filePath: "/old/article.html", md5Hash: "m",
            folderPath: "The Digital Antiquarian", tmbDirectoryName: "Moved-1.tmb"
        )
        var row = reader
        row.fileLocation = Book.FileLocation(
            folderPath: "", filePath: "/new/article.html", tmbDirectoryName: "Moved-1.tmb", feedLink: link
        )

        reader.libraryFields = row.libraryFields

        XCTAssertEqual(reader.feedLink, link)
        XCTAssertEqual(reader.folderPath, "")
        XCTAssertEqual(reader.tmbDirectory, row.tmbDirectory)
    }

    /// A feed's folder is named by its ID alone, so it is never taken for a
    /// record, and a record's name or a conflict copy's never for a folder.
    func testAFeedsFolderIsNamedByItsIDAlone() {
        let id = UUID()
        let root = URL(fileURLWithPath: "/data", isDirectory: true)

        XCTAssertEqual(FeedPaths.feedID(ofItemsFolderNamed: id.uuidString), id)
        for name in [id.uuidString + ".json", id.uuidString.lowercased(), id.uuidString + " 2", "Feeds"] {
            XCTAssertNil(FeedPaths.feedID(ofItemsFolderNamed: name), name)
        }
        XCTAssertNil(FeedPaths.feedID(ofRecordNamed: id.uuidString), "the record reader reads only <ID>.json")
        XCTAssertEqual(FeedPaths.indexFile(of: id, in: root).path, "/data/Feeds/\(id.uuidString)/library.json")
    }

    // MARK: - Helpers

    /// Writes rows as library.json does.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Reads rows as library.json is read.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// `book` as library.json writes its row, as a dictionary.
    private static func encodedRow(_ book: Book) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(book)) as? [String: Any])
    }
}
