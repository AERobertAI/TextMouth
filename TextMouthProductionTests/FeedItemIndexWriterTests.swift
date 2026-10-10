import XCTest
@testable import TextMouth

/// The writers of library.json beyond the library's saves (FR11, branch A1):
/// the data-directory move writes its copy's library.json without a feed's
/// items and each feed's index with them, and Rebuild Library Index saves
/// the provisional library, with the feed items it joined, the same way.
final class FeedItemIndexWriterTests: FeedItemIndexTestCase {

    // MARK: - The Data-Directory Move

    /// The copy's library.json holds the library's own books; each feed's
    /// index in the copy holds the feed's items, those whose files are here
    /// and those on the shelf, each placed in the new data directory, and
    /// each feed item's record is written in its feed's folder of the copy.
    func testTheDataDirectoryMoveWritesFeedItemsToTheirIndexes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        let book = try makeBook(titled: "Moved Book", in: source, feedID: nil)
        let item = try makeBook(titled: "Moved Episode", in: source, feedID: feedID)
        var kept = try makeBook(titled: "Kept Episode", in: source, feedID: feedID)
        try FileManager.default.removeItem(at: kept.bookFileURL)
        kept.readingPosition = Self.position(42, at: 10)
        let library = Library(books: [book, item], feedShelf: FeedShelf(rows: [kept]))

        let migrated = try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)

        let libraryJSON = try String(contentsOf: destination.appendingPathComponent("library.json"), encoding: .utf8)
        XCTAssertTrue(libraryJSON.contains(book.id.uuidString))
        XCTAssertFalse(libraryJSON.contains(item.id.uuidString), "the copy's library.json holds a feed item")
        XCTAssertFalse(libraryJSON.contains(kept.id.uuidString), "the copy's library.json holds a kept feed item")
        XCTAssertFalse(libraryJSON.contains("feedLink"))

        let index = try FeedIndexFiles.decoded(Data(contentsOf: FeedPaths.indexFile(of: feedID, in: destination)))
        XCTAssertEqual(Set(index.books.map(\.id)), [item.id, kept.id])
        let destinationPath = destination.resolvingSymlinksInPath().path
        for row in index.books {
            XCTAssertTrue(
                URL(fileURLWithPath: row.filePath).resolvingSymlinksInPath().path.hasPrefix(destinationPath + "/Feeds/"),
                row.filePath
            )
        }
        XCTAssertEqual(index.books.first { $0.id == kept.id }?.readingPosition, kept.readingPosition)

        let movedItem = try XCTUnwrap(migrated.books.first { $0.id == item.id })
        XCTAssertEqual(movedItem.feedLink, item.feedLink)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedItem.filePath))
        let record = try BookInfo.load(from: movedItem.packageDirectory(inDataDirectory: destination))
        XCTAssertEqual(record.metadata.bookID, item.id)
        XCTAssertEqual(record.metadata.feedLink, item.feedLink)
        XCTAssertTrue(migrated.feedShelf.rows.first?.filePath.hasPrefix(destination.path + "/") ?? false)
    }

    // MARK: - Rebuild Library Index

    /// While library.json cannot be read, the provisional library holds the
    /// feed items read from their packages, and Rebuild Library Index saves
    /// it as every save does: the feed items to their feed's index, the
    /// library's own books to library.json, and its outcome counts books only.
    @MainActor
    func testRebuildLibraryIndexWritesFeedItemsToTheirIndexes() throws {
        let item = try makeFeedItem(title: "Kept Through Recovery", lastOpened: Self.date(30), position: Self.position(7, at: 30))
        let book = try makePackagedBook(title: "Adopted In Recovery")
        try book.saveBookInfoThrowing()
        saveNow(Library(books: [book, item]))
        try Data("{ damaged".utf8).write(to: TextMouthPaths.libraryIndexFile)
        let model = launchedModel()
        XCTAssertNotNil(model.indexRecovery)
        XCTAssertNotNil(model.bookByID(book.id))
        XCTAssertEqual(model.bookByID(item.id)?.feedLink, item.feedLink)

        let outcome = model.rebuildLibraryIndex()

        guard case .rebuilt(let bookCount, _, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(bookCount, model.library.libraryBookCount)
        XCTAssertLessThan(bookCount, model.library.books.count, "the outcome counts the feed item")
        try assertLibraryJSONHoldsNoFeedItem([item])
        XCTAssertTrue(try libraryJSONBookIDs().contains(book.id))
        XCTAssertEqual(try indexedRows().map(\.id), [item.id])
    }

    // MARK: - Helpers

    /// A book in a package of its own in the data directory at `root`, with
    /// its file and its record: in the Library folder's top level, or, with
    /// `feedID`, a feed item's in that feed's folder.
    private func makeBook(titled title: String, in root: URL, feedID: UUID?) throws -> Book {
        let bookID = UUID()
        let name = TextMouthPaths.tmbName(title: title, author: "Fixture", dateAdded: Self.date(), bookID: bookID)
        var book = Book(
            id: bookID,
            title: title,
            author: "Fixture",
            format: .txt,
            filePath: "",
            md5Hash: UUID().uuidString,
            dateAdded: Self.date(),
            tmbDirectoryName: name,
            feedLink: feedID.map { FeedBookLink(feedID: $0, itemID: "item-\(title)") }
        )
        let package = book.packageDirectory(inDataDirectory: root)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("\(title).txt")
        try "Words of \(title).".write(to: file, atomically: true, encoding: .utf8)
        book.filePath = file.path
        try book.makeBookInfo().save(to: package)
        return book
    }
}
