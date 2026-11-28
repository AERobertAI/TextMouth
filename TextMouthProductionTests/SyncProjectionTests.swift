import XCTest
@testable import TextMouth

/// The library as sync values, and what changed (FR43).
final class SyncProjectionTests: XCTestCase {
    private typealias Fixtures = SyncTestFixtures

    /// A book's presence, details, folder, and bookmarks are in its projection.
    func testProjectionOfABook() throws {
        var book = Fixtures.book(title: "Moby-Dick", author: "Melville")
        book.localWPM = 200
        book.localPitch = 1.25
        book.readingPosition = ReadingPosition(chapterIndex: 2, characterOffset: 40)
        book.lastOpened = Date(timeIntervalSince1970: 5_000)
        let bookmark = Bookmark(number: 1, chapterIndex: 1, characterOffset: 9, label: "Here")
        book.bookmarks = [bookmark]
        let projection = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])

        XCTAssertEqual(projection.values[.book(book.id, .presence)], .bool(true))
        XCTAssertEqual(projection.values[.book(book.id, .title)], .string("Moby-Dick"))
        XCTAssertEqual(projection.values[.book(book.id, .rate)], .integer(200))
        XCTAssertEqual(projection.values[.book(book.id, .pitch)], .number(1.25))
        XCTAssertEqual(projection.values[.book(book.id, .voice)], .null)
        XCTAssertEqual(projection.values[.book(book.id, .folder)], .null)
        XCTAssertEqual(projection.values[.book(book.id, .position)]?["chapterIndex"], .integer(2))
        XCTAssertEqual(projection.values[.book(book.id, .lastOpened)], .string("1970-01-01T01:23:20Z"))
        XCTAssertEqual(projection.values[.bookmark(book: book.id, id: bookmark.id)]?["label"], .string("Here"))
        XCTAssertNil(projection.values[.book(book.id, .content)], "no content until a manifest is uploaded")
        XCTAssertNil(projection.values[.book(book.id, .keep)], "keep is never projected")
        XCTAssertTrue(projection.byHand.isEmpty)
    }

    /// Content is projected for the books that have it.
    func testProjectionHoldsTheContentGiven() {
        let book = Fixtures.book()
        let content = Fixtures.content(of: book)
        let projection = SyncProjection.of(Fixtures.library(books: [book]), contents: [book.id: content])
        XCTAssertEqual(projection.values[.book(book.id, .content)]?["manifest"], .string("m1"))
    }

    /// A detail edited by hand is marked, and only that detail.
    func testHandEditedDetailsAreMarked() {
        var book = Fixtures.book()
        book.markEditedByHand([.author])
        let projection = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        XCTAssertEqual(projection.byHand, [.book(book.id, .author)])
    }

    /// Folders are keyed by ID, with their parent by ID, and a book names its folder by ID.
    func testFoldersAreProjectedByID() {
        let top = BookFolder(name: "Fiction")
        let inner = BookFolder(name: "Old", parentPath: "Fiction")
        let book = Fixtures.book(folderPath: "Fiction/Old")
        let projection = SyncProjection.of(Fixtures.library(books: [book], folders: [top, inner]), contents: [:])
        XCTAssertEqual(projection.values[.folder(top.id, .parent)], .null)
        XCTAssertEqual(projection.values[.folder(inner.id, .parent)], SyncValueCoding.id(top.id))
        XCTAssertEqual(projection.values[.folder(inner.id, .name)], .string("Old"))
        XCTAssertEqual(projection.values[.book(book.id, .folder)], SyncValueCoding.id(inner.id))
    }

    /// The reading list gives each book its place, and the options.
    func testReadingListIsProjectedByOrder() {
        let first = Fixtures.book(), second = Fixtures.book()
        var library = Fixtures.library(books: [first, second])
        library.readingList = ReadingList(bookIDs: [second.id, first.id], continuation: .stop, skipsFinished: false, removesFinished: true)
        let projection = SyncProjection.of(library, contents: [:])
        XCTAssertEqual(projection.values[.readingList(book: second.id)], .integer(0))
        XCTAssertEqual(projection.values[.readingList(book: first.id)], .integer(1))
        XCTAssertEqual(projection.values[.readingListOption(.continuation)], .string("stop"))
        XCTAssertEqual(projection.values[.readingListOption(.skipsFinished)], .bool(false))
        XCTAssertEqual(projection.values[.readingListOption(.removesFinished)], .bool(true))
    }

    /// A library with nothing changed has no changes.
    func testNoChangeWhenNothingChanged() {
        let book = Fixtures.book()
        let projection = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        XCTAssertTrue(SyncMerge.changes(from: projection, to: projection, atLaunch: false).isEmpty)
    }

    /// Everything is a change against an empty baseline: the first run records the library.
    func testFirstRunRecordsEverything() {
        let book = Fixtures.book()
        let now = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        let changes = SyncMerge.changes(from: SyncProjection(), to: now, atLaunch: true)
        XCTAssertEqual(changes[.book(book.id, .presence)], .bool(true))
        XCTAssertEqual(changes[.book(book.id, .title)], .string("A Book"))
    }

    /// Only the value that changed is reported.
    func testOnlyAChangedValueIsReported() {
        var book = Fixtures.book()
        let baseline = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        book.title = "Renamed"
        let now = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        XCTAssertEqual(SyncMerge.changes(from: baseline, to: now, atLaunch: false), [.book(book.id, .title): .string("Renamed")])
    }

    /// A detail newly edited by hand is reported even when its value is as it was.
    func testNewHandEditIsReportedWithTheSameValue() {
        var book = Fixtures.book()
        let baseline = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        book.markEditedByHand([.title])
        let now = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        XCTAssertEqual(SyncMerge.changes(from: baseline, to: now, atLaunch: false).keys.map(\.self), [.book(book.id, .title)])
    }

    /// A removed book is a removal mark of its presence, and nothing else of it.
    func testRemovedBookIsOneRemovalMark() {
        var book = Fixtures.book()
        book.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: 0)]
        let baseline = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        let now = SyncProjection.of(Fixtures.library(), contents: [:])
        XCTAssertEqual(SyncMerge.changes(from: baseline, to: now, atLaunch: false), [.book(book.id, .presence): .null])
    }

    /// At launch a missing book is put back, not removed; a missing bookmark still counts.
    func testMissingBookAtLaunchIsNotARemoval() {
        var book = Fixtures.book()
        let bookmark = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0)
        book.bookmarks = [bookmark]
        let baseline = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        XCTAssertTrue(SyncMerge.changes(from: baseline, to: SyncProjection.of(Fixtures.library(), contents: [:]), atLaunch: true).isEmpty)
        var without = book
        without.bookmarks = []
        let now = SyncProjection.of(Fixtures.library(books: [without]), contents: [:])
        XCTAssertEqual(SyncMerge.changes(from: baseline, to: now, atLaunch: true), [.bookmark(book: book.id, id: bookmark.id): .null])
    }

    /// A removed folder is a removal mark too, except at launch.
    func testRemovedFolder() {
        let folder = BookFolder(name: "Fiction")
        let baseline = SyncProjection.of(Fixtures.library(folders: [folder]), contents: [:])
        let now = SyncProjection.of(Fixtures.library(), contents: [:])
        XCTAssertEqual(SyncMerge.changes(from: baseline, to: now, atLaunch: false), [.folder(folder.id, .presence): .null])
        XCTAssertTrue(SyncMerge.changes(from: baseline, to: now, atLaunch: true).isEmpty)
    }

    /// A baseline holds the order keys the changes made, and then a list in the same order changes nothing.
    func testReadingListChangesOnlyForMovedBooks() {
        let books = (0..<4).map { _ in Fixtures.book() }
        var library = Fixtures.library(books: books)
        library.readingList = ReadingList(bookIDs: books.map(\.id))
        var baseline = SyncProjection()
        let first = SyncMerge.changes(from: baseline, to: SyncProjection.of(library, contents: [:]), atLaunch: true)
        XCTAssertEqual(first.keys.filter { if case .readingList = $0 { return true } else { return false } }.count, 4)
        baseline.absorb(first.map { Fixtures.entry($0.key, $0.value, wall: 1) })

        // Unchanged: no list changes. Moved to the front: one change.
        XCTAssertTrue(SyncMerge.changes(from: baseline, to: SyncProjection.of(library, contents: [:]), atLaunch: false).isEmpty)
        library.readingList = ReadingList(bookIDs: [books[3].id] + books[0..<3].map(\.id))
        let moved = SyncMerge.changes(from: baseline, to: SyncProjection.of(library, contents: [:]), atLaunch: false)
        XCTAssertEqual(Array(moved.keys), [.readingList(book: books[3].id)])
    }

    /// A book that left the list is a removal mark, while a book removed from the library is not reported there.
    func testReadingListRemovals() {
        let books = (0..<2).map { _ in Fixtures.book() }
        var library = Fixtures.library(books: books)
        library.readingList = ReadingList(bookIDs: books.map(\.id))
        var baseline = SyncProjection()
        baseline.absorb(SyncMerge.changes(from: baseline, to: SyncProjection.of(library, contents: [:]), atLaunch: true).map { Fixtures.entry($0.key, $0.value, wall: 1) })
        library.readingList = ReadingList(bookIDs: [books[0].id])
        let now = SyncProjection.of(library, contents: [:])
        XCTAssertEqual(SyncMerge.changes(from: baseline, to: now, atLaunch: false)[.readingList(book: books[1].id)], .null)
    }

    /// A removal mark takes a book's keys out of a baseline.
    func testAbsorbingARemovalForgetsTheBook() {
        let book = Fixtures.book()
        var baseline = SyncProjection.of(Fixtures.library(books: [book]), contents: [:])
        baseline.absorb([Fixtures.entry(.book(book.id, .presence), .null, wall: 9)])
        XCTAssertTrue(baseline.values.keys.filter { $0.bookID == book.id }.isEmpty)
    }

    /// A value absorbed with its hand-edit mark is remembered.
    func testAbsorbKeepsTheHandEditMark() {
        let key = SyncKey.book(UUID(), .title)
        var baseline = SyncProjection()
        baseline.absorb([Fixtures.entry(key, .string("x"), wall: 1, byHand: true)])
        XCTAssertEqual(baseline.values[key], .string("x"))
        XCTAssertTrue(baseline.byHand.contains(key))
        baseline.absorb([Fixtures.entry(key, .string("y"), wall: 2)])
        XCTAssertFalse(baseline.byHand.contains(key))
    }

    /// A feed item's row is not part of the library that syncs.
    func testFeedItemsAreLeftOut() {
        var item = Fixtures.book()
        item.feedLink = FeedBookLink(feedID: UUID(), itemID: "g")
        let projection = SyncProjection.of(Fixtures.library(books: [item]), contents: [:])
        XCTAssertNil(projection.values[.book(item.id, .presence)])
    }
}
