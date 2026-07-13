import XCTest
import AppKit
@testable import TextMouth

/// Regression coverage for the production library sort comparator.
final class LibraryBookSorterTests: XCTestCase {
    func testDescendingTitleSortUsesExplicitReverseComparison() {
        let alpha = makeBook(title: "Alpha")
        let zulu = makeBook(title: "Zulu")

        let result = LibraryBookSorter.sorted([alpha, zulu], by: .title, ascending: false)

        XCTAssertEqual(result.map(\.title), ["Zulu", "Alpha"])
    }

    /// Equal primary values must not compare as less-than in both directions.
    func testEqualPrimaryValuesMaintainStrictOrdering() {
        let first = makeBook(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Same", author: "Author")
        let second = makeBook(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Same", author: "Author")

        let firstBeforeSecond = LibraryBookSorter.areInIncreasingOrder(
            first, second, by: .author, ascending: false
        )
        let secondBeforeFirst = LibraryBookSorter.areInIncreasingOrder(
            second, first, by: .author, ascending: false
        )

        XCTAssertNotEqual(firstBeforeSecond, secondBeforeFirst)
    }

    func testDescendingDateSortUsesTitleAsDeterministicTieBreaker() {
        let date = Date(timeIntervalSince1970: 100)
        let beta = makeBook(title: "Beta", dateAdded: date)
        let alpha = makeBook(title: "Alpha", dateAdded: date)

        let result = LibraryBookSorter.sorted([beta, alpha], by: .dateAdded, ascending: false)

        XCTAssertEqual(result.map(\.title), ["Alpha", "Beta"])
    }

    func testRecursiveFileSizeIncludesNestedPackageContents() throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = package.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }

        try Data(repeating: 1, count: 12).write(to: package.appendingPathComponent("cover.jpg"))
        try Data(repeating: 2, count: 30).write(to: nested.appendingPathComponent("chapter.mp3"))

        XCTAssertEqual(LibraryBookSorter.recursiveFileSize(at: package), 42)
    }

    func testRecursiveFileSizeStillHandlesOrdinaryFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0, count: 17).write(to: file)

        XCTAssertEqual(LibraryBookSorter.recursiveFileSize(at: file), 17)
    }

    func testLibraryPersistenceFlushWritesNewestPendingSnapshot() throws {
        let first = makeBook(title: "Older Snapshot")
        let newest = makeBook(title: "Newest Snapshot")

        LibraryPersistenceService.save(Library(books: [first]))
        LibraryPersistenceService.save(Library(books: [newest]))
        LibraryPersistenceService.flushPendingSave()

        let data = try Data(contentsOf: TextMouthPaths.libraryIndexFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(Library.self, from: data)
        XCTAssertEqual(persisted.books.map(\.title), ["Newest Snapshot"])
    }

    func testApplicationTerminationFlushesPendingLibrarySave() throws {
        let book = makeBook(title: "Saved at Termination")
        LibraryPersistenceService.save(Library(books: [book]))

        AppDelegate().applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        let data = try Data(contentsOf: TextMouthPaths.libraryIndexFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(Library.self, from: data)
        XCTAssertEqual(persisted.books.map(\.title), ["Saved at Termination"])
    }

    private func makeBook(
        id: UUID = UUID(),
        title: String,
        author: String = "Unknown",
        dateAdded: Date = Date()
    ) -> Book {
        Book(
            id: id,
            title: title,
            author: author,
            format: .txt,
            filePath: "/tmp/\(id.uuidString).txt",
            md5Hash: id.uuidString,
            dateAdded: dateAdded
        )
    }
}
