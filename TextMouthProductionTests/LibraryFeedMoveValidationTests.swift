import XCTest
@testable import TextMouth

/// The first launch of FR11's build moves each download made before it into
/// its feed's folder in one rename (`LibraryViewModel+FeedItemMove.swift`).
/// A row whose package name is missing (a row without that key reads as "")
/// or whose folder path holds ".." would make that rename's source the
/// row's whole folder, or all of the Library folder, carrying every other
/// book into the feed's folder (REV10, item 1). Such a row is never moved:
/// it is left out of the downloads to move, and the move itself refuses it
/// before touching the disk, with the check the deletion guard makes
/// (`FileImportService.namesManagedPackage(_:)`).
final class LibraryFeedMoveValidationTests: FeedItemIndexTestCase {

    // MARK: - The Shared Check

    /// The check refuses a row with no package name, a package name that is
    /// a path, one that is no package, and a folder path holding "..", an
    /// absolute path, or an empty component, and accepts an ordinary row;
    /// the deletion guard refuses exactly the rows the check refuses.
    func testTheCheckRefusesEveryShapeTheDeletionGuardRefuses() {
        let refused: [(name: String, folder: String)] = [
            ("", ""),
            ("", "Fiction"),
            ("../Outside.tmb", ""),
            ("Fiction/Inside.tmb", ""),
            ("Notes.txt", ""),
            ("Book.tmb", ".."),
            ("Book.tmb", "Fiction/.."),
            ("Book.tmb", "Fiction/../.."),
            ("Book.tmb", "/Fiction"),
            ("Book.tmb", "Fiction//Sci-Fi"),
        ]
        for shape in refused {
            let row = Self.row(packageName: shape.name, folderPath: shape.folder)
            XCTAssertFalse(FileImportService.namesManagedPackage(row), "accepted \(shape)")
            XCTAssertThrowsError(try FileImportService.managedPackageURLForDeletion(row), "the deletion guard accepted \(shape)")
        }
        XCTAssertTrue(FileImportService.namesManagedPackage(Self.row(packageName: "Book.tmb", folderPath: "")))
        XCTAssertTrue(FileImportService.namesManagedPackage(Self.row(packageName: "Book.TMB", folderPath: "Fiction/Sci-Fi")))
    }

    // MARK: - The List of Downloads to Move

    /// Of three downloads a feed's record names, the one whose row names its
    /// package is listed to move; the one with no package name and the one
    /// whose folder path holds ".." are not.
    @MainActor
    func testRowsNamingNoManagedPackageAreNotListedToMove() throws {
        let fixture = try makeDownloads()
        let model = makeModel(with: fixture.rows)

        let listed = model.downloadsToMoveIntoTheirFeeds(records: fixture.records)

        XCTAssertEqual(listed.map(\.book.id), [fixture.movable.id])
    }

    /// The move takes only the download whose row names its package. The
    /// row with no package name, whose "package" would be this test's whole
    /// folder, and the row whose folder path climbs out of this test's folder
    /// and back into it, stay books of the library's own, untouched: every
    /// package in the folder stays, the other book's included, and one
    /// FEED_DOWNLOAD_MOVE_REFUSED line names each of the two.
    @MainActor
    func testTheMoveLeavesRowsNamingNoManagedPackageWhereTheyAre() async throws {
        let fixture = try makeDownloads()
        let model = makeModel(with: fixture.rows)
        let refusals = [fixture.unnamed, fixture.climbing].map { "FEED_DOWNLOAD_MOVE_REFUSED: \"\($0.title)\"" }
        let linesBefore = refusals.map { debugLogLines(containing: $0).count }

        let moved = await model.moveDownloadsIntoTheirFeeds(records: fixture.records)

        XCTAssertEqual(moved, 1)
        XCTAssertEqual(model.bookByID(fixture.movable.id)?.feedLink, fixture.links[fixture.movable.id])
        for row in [fixture.unnamed, fixture.climbing] {
            XCTAssertEqual(model.bookByID(row.id), row, "\(row.title) changed")
        }
        XCTAssertEqual(refusals.map { debugLogLines(containing: $0).count }, linesBefore.map { $0 + 1 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.neighbour.filePath), "the other book left its folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.climbing.filePath), "the climbing row's package moved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path), "this test's folder moved")
        let feedFolder = try FileManager.default.contentsOfDirectory(atPath: feedFolderURL.path)
        XCTAssertEqual(
            Set(feedFolder.filter { $0.hasSuffix(".tmb") }),
            [fixture.movable.tmbDirectoryName],
            "the feed's folder holds a package it should not"
        )
    }

    // MARK: - The Rename Refuses Them Too

    /// Whoever calls it, the move of one download refuses a row naming no
    /// managed package before it makes any folder or renames anything, in a
    /// data directory of the test's own: neither the row's folder nor the
    /// Library folder moves, and no Feeds folder is made.
    func testTheRenameRefusesARowNamingNoManagedPackageBeforeTouchingTheDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFeedMoveValidation-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let shelf = root.appendingPathComponent("Library/Shelf", isDirectory: true)
        let other = shelf.appendingPathComponent("Other.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("Another book".utf8).write(to: other.appendingPathComponent("book.txt"))
        let link = FeedBookLink(feedID: feedID, itemID: "guid:refused")

        for (name, folder) in [("", "Shelf"), ("", "Shelf/.."), ("Other.tmb", "Shelf/../Shelf"), ("", "")] {
            let row = Self.row(packageName: name, folderPath: folder, file: other.appendingPathComponent("book.txt"))
            XCTAssertThrowsError(try LibraryViewModel.moveIntoItsFeed(row, link: link, root: root), "moved \(name) in \(folder)") { error in
                XCTAssertEqual(error as? FeedItemMoveError, .packageNotManaged)
            }
        }

        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("book.txt"), encoding: .utf8), "Another book")
        XCTAssertFalse(FileManager.default.fileExists(atPath: FeedPaths.recordsFolder(in: root).path), "a Feeds folder was made")
    }

    // MARK: - Fixtures

    /// The downloads of `makeDownloads()`, with what the feed's record says
    /// of them.
    private struct Downloads {
        /// A download whose row names its package in this test's folder.
        var movable: Book
        /// A download whose row has no package name.
        var unnamed: Book
        /// A download whose folder path leaves this test's folder by ".."
        /// and comes back to it, naming its real package.
        var climbing: Book
        /// A book of the library's own beside them, in this test's folder.
        var neighbour: Book
        /// The feed and item each download's row would take.
        var links: [UUID: FeedBookLink]
        /// This test's feed's record, naming the three downloads.
        var records: [UUID: FeedRecord]

        /// Every row, as the library holds them.
        var rows: [Book] {
            [neighbour, movable, unnamed, climbing]
        }
    }

    /// Three downloads made before FR11, each a package in this test's
    /// folder as a download then left one, beside a book of the library's
    /// own, and the record of this test's feed naming the three as its
    /// items' downloads. Only the first row names its package as the move
    /// can take it.
    private func makeDownloads() throws -> Downloads {
        let neighbour = try makePackagedBook(title: "Middlemarch")
        let movable = try makePackagedBook(title: "Movable Episode")
        var unnamed = try makePackagedBook(title: "Unnamed Episode")
        unnamed.tmbDirectoryName = ""
        var climbing = try makePackagedBook(title: "Climbing Episode")
        climbing.folderPath = "\(folderPath)/../\(folderPath)"
        let downloads = [movable, unnamed, climbing]
        let links = Dictionary(uniqueKeysWithValues: downloads.map {
            ($0.id, FeedBookLink(feedID: feedID, itemID: "guid:\($0.title)"))
        })
        let feed = Feed(
            id: feedID,
            feedURL: try XCTUnwrap(URL(string: "https://validation.example/feed.xml")),
            folderID: UUID(),
            subscribedDate: Self.date()
        )
        let items = downloads.map {
            FeedItem(id: "guid:\($0.title)", title: $0.title, firstSeen: Self.date(), state: .downloaded(bookID: $0.id))
        }
        return Downloads(
            movable: movable,
            unnamed: unnamed,
            climbing: climbing,
            neighbour: neighbour,
            links: links,
            records: [feedID: FeedRecord(feed: feed, items: items)]
        )
    }

    /// A row naming the package `packageName` in the library folder
    /// `folderPath`, its file at `file`.
    private static func row(
        packageName: String,
        folderPath: String,
        file: URL = URL(fileURLWithPath: "/nonexistent/book.txt")
    ) -> Book {
        Book(
            title: "Shape",
            format: .txt,
            filePath: file.path,
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            tmbDirectoryName: packageName
        )
    }
}
