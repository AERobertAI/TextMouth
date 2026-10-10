import XCTest
@testable import TextMouth

// MARK: - FR11 Feed Item Test Support

/// The test cases of FR11's branch A1: a feed of the test's own whose items'
/// packages and index are in its folder under the hosted test root's Feeds
/// folder, removed when the test ends, beside the cloud maintenance
/// fixtures' library folder of the test's own, with the library index put
/// back as it was.
class FeedItemIndexTestCase: CloudMaintenanceTestCase {
    /// The feed this test's items belong to.
    private(set) var feedID = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        feedID = UUID()
    }

    override func tearDownWithError() throws {
        // The library index is put back first, which writes any save still
        // waiting; only then is the feed's folder removed, so no late save
        // makes it again.
        try super.tearDownWithError()
        try? FileManager.default.removeItem(at: feedFolderURL)
    }

    /// This test's feed's folder.
    var feedFolderURL: URL {
        FeedPaths.itemsFolder(of: feedID, in: TextMouthPaths.root)
    }

    /// This test's feed's index.
    var feedIndexURL: URL {
        FeedPaths.indexFile(of: feedID, in: TextMouthPaths.root)
    }

    /// A whole second, which ISO 8601 dates keep exactly, `seconds` after a
    /// fixed start, so rows read back compare equal.
    static func date(_ seconds: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_790_000_000 + seconds)
    }

    /// A downloaded article of this test's feed, as a download publishes
    /// one: a package in the feed's folder holding its HTML and its record,
    /// which names the feed and item, and the row the library holds for it.
    func makeFeedItem(
        title: String = "Lamentable Lemmings",
        itemID: String = UUID().uuidString,
        dateAdded: Date = FeedItemIndexTestCase.date(),
        lastOpened: Date? = nil,
        position: ReadingPosition? = nil
    ) throws -> Book {
        let bookID = UUID()
        let name = TextMouthPaths.tmbName(title: title, author: "Antiquarian", dateAdded: dateAdded, bookID: bookID)
        let package = FeedPaths.packageDirectory(named: name, of: feedID, in: TextMouthPaths.root)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("\(title).html")
        try "<html><body><h1>\(title)</h1><p>Words.</p></body></html>".write(to: file, atomically: true, encoding: .utf8)
        let book = Book(
            id: bookID,
            title: title,
            author: "Antiquarian",
            format: .html,
            filePath: file.path,
            md5Hash: UUID().uuidString,
            folderPath: "",
            dateAdded: dateAdded,
            lastOpened: lastOpened,
            readingPosition: position,
            tmbDirectoryName: name,
            feedLink: FeedBookLink(feedID: feedID, itemID: itemID)
        )
        try book.makeBookInfo().save(to: package)
        return book
    }

    /// The rows this test's feed's index holds on disk.
    func indexedRows() throws -> [Book] {
        try FeedIndexFiles.decoded(Data(contentsOf: feedIndexURL)).books
    }

    /// The rows library.json holds on disk, as written.
    func libraryJSONRows() throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: TextMouthPaths.libraryIndexFile))
        let index = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(index["books"] as? [[String: Any]])
    }

    /// Fails unless library.json holds no row with a feed link and none of
    /// `items`.
    func assertLibraryJSONHoldsNoFeedItem(
        _ items: [Book] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let rows = try libraryJSONRows()
        XCTAssertFalse(rows.contains { $0["feedLink"] != nil }, "library.json holds a row with a feed link", file: file, line: line)
        let ids = Set(rows.compactMap { $0["id"] as? String })
        for item in items {
            XCTAssertFalse(ids.contains(item.id.uuidString), "library.json holds \(item.title)", file: file, line: line)
        }
    }

    /// The IDs of the books library.json holds on disk.
    func libraryJSONBookIDs() throws -> Set<UUID> {
        Set(try libraryJSONRows().compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) })
    }
}
