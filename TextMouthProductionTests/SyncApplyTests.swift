import XCTest
@testable import TextMouth

/// What a merged state does to a library (FR43): details, places, bookmarks,
/// folders, removals, new books, and the reading list.
final class SyncApplyTests: XCTestCase {
    private typealias Fixtures = SyncTestFixtures

    /// Applies `entries` to `library` with every voice present.
    private func apply(_ entries: [SyncEntry], to library: Library, voices: Set<String>? = nil) -> SyncApplication {
        SyncMerge.apply(Fixtures.registers(entries), to: library, voices: voices)
    }

    /// No entries change nothing.
    func testNoEntriesChangeNothing() {
        let library = Fixtures.library(books: [Fixtures.book()], folders: [BookFolder(name: "F")])
        let application = apply([], to: library)
        XCTAssertEqual(application.library, library)
        XCTAssertTrue(application.booksToAdd.isEmpty)
        XCTAssertTrue(application.booksToRemove.isEmpty)
        XCTAssertFalse(application.movesPackages)
    }

    // MARK: Details and settings

    /// A detail, a setting, and a place are applied, and noted as applied.
    func testValuesAreApplied() throws {
        let book = Fixtures.book()
        let place = ReadingPosition(chapterIndex: 3, characterOffset: 77)
        let entries = [
            Fixtures.entry(.book(book.id, .title), .string("New Title"), wall: 5),
            Fixtures.entry(.book(book.id, .rate), .integer(250), wall: 5),
            Fixtures.entry(.book(book.id, .position), SyncValueCoding.json(place), wall: 5),
            Fixtures.entry(.book(book.id, .lastOpened), SyncValueCoding.json(date: Date(timeIntervalSince1970: 9_000)), wall: 5),
        ]
        let application = apply(entries, to: Fixtures.library(books: [book]))
        let changed = try XCTUnwrap(application.library.books.first)
        XCTAssertEqual(changed.title, "New Title")
        XCTAssertEqual(changed.localWPM, 250)
        XCTAssertEqual(changed.readingPosition?.chapterIndex, 3)
        XCTAssertEqual(changed.lastOpened, Date(timeIntervalSince1970: 9_000))
        XCTAssertTrue(entries.allSatisfy { application.appliedKeys.contains($0.key) })
    }

    /// A setting cleared on another device is cleared here.
    func testNullClearsASetting() throws {
        var book = Fixtures.book()
        book.localVoiceID = "com.example.voice"
        let application = apply([Fixtures.entry(.book(book.id, .voice), .null, wall: 2)], to: Fixtures.library(books: [book]))
        XCTAssertNil(application.library.books.first?.localVoiceID)
    }

    /// A voice this device lacks is not applied, and not noted as applied.
    func testVoiceTheDeviceLacksIsNotApplied() {
        var book = Fixtures.book()
        book.localVoiceID = "mine"
        let entry = Fixtures.entry(.book(book.id, .voice), .string("theirs"), wall: 2)
        let missing = apply([entry], to: Fixtures.library(books: [book]), voices: ["mine"])
        XCTAssertEqual(missing.library.books.first?.localVoiceID, "mine")
        XCTAssertFalse(missing.appliedKeys.contains(entry.key))
        let present = apply([entry], to: Fixtures.library(books: [book]), voices: ["mine", "theirs"])
        XCTAssertEqual(present.library.books.first?.localVoiceID, "theirs")
    }

    /// A detail that a person edited by hand elsewhere is marked as edited by hand here.
    func testHandEditedDetailIsMarked() {
        let book = Fixtures.book()
        let entry = Fixtures.entry(.book(book.id, .author), .string("By Hand"), wall: 2, byHand: true)
        let application = apply([entry], to: Fixtures.library(books: [book]))
        XCTAssertEqual(application.library.books.first?.author, "By Hand")
        XCTAssertEqual(application.library.books.first?.handEdits?.contains(.author), true)
    }

    /// A value of the wrong kind is left alone and not noted as applied.
    func testWrongKindOfValueIsIgnored() {
        let book = Fixtures.book()
        let entry = Fixtures.entry(.book(book.id, .rate), .string("fast"), wall: 2)
        let application = apply([entry], to: Fixtures.library(books: [book]))
        XCTAssertEqual(application.library, Fixtures.library(books: [book]))
        XCTAssertFalse(application.appliedKeys.contains(entry.key))
    }

    /// Skipped headings are applied as one value.
    func testSkippedHeadingsApply() {
        var source = Fixtures.book()
        source.setSkippedHeadings([SkippedHeading(level: 2, label: "Preface", chapterIndex: 0, characterOffset: 10)])
        let value = SyncValueCoding.json(SyncSkippedHeadingsValue(source))
        let target = Fixtures.book(id: source.id)
        let application = apply([Fixtures.entry(.book(source.id, .skippedHeadings), value, wall: 2)], to: Fixtures.library(books: [target]))
        XCTAssertEqual(application.library.books.first?.skippedHeadings?.first?.label, "Preface")
        XCTAssertEqual(application.library.books.first?.skippedHeadingIDs?.count, 1)
    }

    /// Applying the same entries to what they gave changes nothing more.
    func testApplyingAgainChangesNothing() {
        let book = Fixtures.book()
        let entries = [
            Fixtures.entry(.book(book.id, .title), .string("T"), wall: 5),
            Fixtures.entry(.book(book.id, .pitch), .number(1.5), wall: 5),
            Fixtures.entry(.bookmark(book: book.id, id: UUID()), SyncValueCoding.json(SyncBookmarkValue(Bookmark(number: 1, chapterIndex: 1, characterOffset: 1))), wall: 5),
        ]
        let once = apply(entries, to: Fixtures.library(books: [book]))
        let twice = apply(entries, to: once.library)
        XCTAssertEqual(twice.library, once.library)
    }

    // MARK: Removal

    /// A removal mark later than everything else removes the book, and takes it off the reading list.
    func testRemovalMarkRemovesTheBook() {
        let book = Fixtures.book(), kept = Fixtures.book()
        var library = Fixtures.library(books: [book, kept])
        library.readingList = ReadingList(bookIDs: [book.id, kept.id])
        let application = apply([
            Fixtures.entry(.book(book.id, .title), .string("T"), wall: 1),
            Fixtures.entry(.book(book.id, .presence), .null, wall: 5),
        ], to: library)
        XCTAssertEqual(application.booksToRemove, [book.id])
        XCTAssertEqual(application.library.books.map(\.id), [kept.id])
        XCTAssertEqual(application.library.readingList.bookIDs, [kept.id])
    }

    /// A change later than the removal brings the book back.
    func testLaterChangeBringsTheBookBack() {
        let book = Fixtures.book()
        let application = apply([
            Fixtures.entry(.book(book.id, .presence), .null, wall: 5),
            Fixtures.entry(.book(book.id, .position), SyncValueCoding.json(ReadingPosition(chapterIndex: 1)), wall: 9, device: "b"),
        ], to: Fixtures.library(books: [book]))
        XCTAssertTrue(application.booksToRemove.isEmpty)
        XCTAssertEqual(application.library.books.first?.readingPosition?.chapterIndex, 1)
    }

    /// A removed bookmark, or one taken off the list, does not bring a removed book back.
    func testRemovalsDoNotBringABookBack() {
        let book = Fixtures.book()
        let application = apply([
            Fixtures.entry(.book(book.id, .presence), .null, wall: 5),
            Fixtures.entry(.bookmark(book: book.id, id: UUID()), .null, wall: 9),
            Fixtures.entry(.readingList(book: book.id), .null, wall: 9),
        ], to: Fixtures.library(books: [book]))
        XCTAssertEqual(application.booksToRemove, [book.id])
    }

    /// A Keep on All Devices later than a removal brings the book back (the orchestrator's decision).
    func testKeepLaterThanARemovalBringsTheBookBack() {
        let book = Fixtures.book()
        let application = apply([
            Fixtures.entry(.book(book.id, .presence), .null, wall: 5),
            Fixtures.entry(.book(book.id, .keep), .bool(true), wall: 9),
        ], to: Fixtures.library(books: [book]))
        XCTAssertTrue(application.booksToRemove.isEmpty)
        XCTAssertEqual(application.entriesToRecord[.book(book.id, .presence)], .bool(true))
        XCTAssertFalse(application.appliedKeys.contains(.book(book.id, .presence)), "the removal mark is not what was applied")
    }

    // MARK: New books

    /// A book another device made is offered with its content, and its details applied.
    func testNewBookIsOffered() throws {
        let theirs = Fixtures.book(title: "Theirs")
        let application = apply(Fixtures.presence(of: theirs, wall: 5), to: Fixtures.library())
        let offered = try XCTUnwrap(application.booksToAdd.first)
        XCTAssertEqual(offered.book.id, theirs.id)
        XCTAssertEqual(offered.book.title, "Theirs")
        XCTAssertEqual(offered.book.md5Hash, theirs.md5Hash)
        XCTAssertEqual(offered.content.manifest, "m1")
        XCTAssertTrue(application.library.books.isEmpty, "the host adds the rows once it has made their packages")
    }

    /// A book with no uploaded content cannot be made, and a removed one is not offered.
    func testNewBookNeedsContentAndPresence() {
        let theirs = Fixtures.book()
        let noContent = apply([Fixtures.entry(.book(theirs.id, .presence), .bool(true), wall: 5)], to: Fixtures.library())
        XCTAssertTrue(noContent.booksToAdd.isEmpty)
        let removed = apply(Fixtures.presence(of: theirs, wall: 5) + [Fixtures.entry(.book(theirs.id, .presence), .null, wall: 9)], to: Fixtures.library())
        XCTAssertTrue(removed.booksToAdd.isEmpty)
    }

    /// A book this library has under another ID (imported on both) stays one book.
    func testBookImportedOnBothStaysOne() {
        let mine = Fixtures.book(md5: "same")
        let theirs = Fixtures.book(md5: "same")
        let application = apply(Fixtures.presence(of: theirs, wall: 5), to: Fixtures.library(books: [mine]))
        XCTAssertTrue(application.booksToAdd.isEmpty)
    }

    /// New books are offered oldest first.
    func testNewBooksAreOfferedInOneOrder() {
        var older = Fixtures.book(), newer = Fixtures.book()
        older.dateAdded = Date(timeIntervalSince1970: 10)
        newer.dateAdded = Date(timeIntervalSince1970: 20)
        let application = apply(Fixtures.presence(of: newer, wall: 5) + Fixtures.presence(of: older, wall: 5), to: Fixtures.library())
        XCTAssertEqual(application.booksToAdd.map(\.book.id), [older.id, newer.id])
    }

    // MARK: Bookmarks

    /// Bookmarks from another device join this device's, numbered by date, and a removed one goes.
    func testBookmarksMergeAndRenumber() throws {
        var book = Fixtures.book()
        let mine = Bookmark(number: 1, chapterIndex: 0, characterOffset: 5, label: "mine", dateCreated: Date(timeIntervalSince1970: 200))
        let gone = Bookmark(number: 2, chapterIndex: 0, characterOffset: 9, label: "gone", dateCreated: Date(timeIntervalSince1970: 300))
        book.bookmarks = [mine, gone]
        let theirs = Bookmark(number: 1, chapterIndex: 2, characterOffset: 1, label: "theirs", dateCreated: Date(timeIntervalSince1970: 100))
        let application = apply([
            Fixtures.entry(.bookmark(book: book.id, id: theirs.id), SyncValueCoding.json(SyncBookmarkValue(theirs)), wall: 5),
            Fixtures.entry(.bookmark(book: book.id, id: gone.id), .null, wall: 5),
        ], to: Fixtures.library(books: [book]))
        let result = try XCTUnwrap(application.library.books.first?.bookmarks)
        XCTAssertEqual(result.map(\.label), ["theirs", "mine"])
        XCTAssertEqual(result.map(\.number), [1, 2])
    }

    /// A relabeled bookmark is changed in place.
    func testBookmarkRelabeled() {
        var book = Fixtures.book()
        let bookmark = Bookmark(number: 1, chapterIndex: 0, characterOffset: 5, label: "old")
        book.bookmarks = [bookmark]
        var value = SyncBookmarkValue(bookmark)
        value.label = "new"
        let application = apply([Fixtures.entry(.bookmark(book: book.id, id: bookmark.id), SyncValueCoding.json(value), wall: 5)], to: Fixtures.library(books: [book]))
        XCTAssertEqual(application.library.books.first?.bookmarks.first?.label, "new")
    }

    // MARK: Folders

    /// A folder another device made is added under its parent, and a book is put in it.
    func testNewFolderAndABookInIt() {
        let book = Fixtures.book()
        let top = UUID(), inner = UUID()
        let application = apply([
            Fixtures.entry(.folder(top, .presence), .bool(true), wall: 2),
            Fixtures.entry(.folder(top, .name), .string("Fiction"), wall: 2),
            Fixtures.entry(.folder(inner, .presence), .bool(true), wall: 3),
            Fixtures.entry(.folder(inner, .name), .string("Old"), wall: 3),
            Fixtures.entry(.folder(inner, .parent), SyncValueCoding.id(top), wall: 3),
            Fixtures.entry(.book(book.id, .folder), SyncValueCoding.id(inner), wall: 4),
        ], to: Fixtures.library(books: [book]))
        XCTAssertEqual(Set(application.library.folders.map(\.fullPath)), ["Fiction", "Fiction/Old"])
        XCTAssertEqual(application.library.books.first?.folderPath, "Fiction/Old")
        XCTAssertTrue(application.movesPackages)
    }

    /// A renamed folder takes its books and its sort setting with it.
    func testRenamedFolderMovesItsBooks() {
        let folder = BookFolder(name: "Old")
        let book = Fixtures.book(folderPath: "Old")
        var library = Fixtures.library(books: [book], folders: [folder])
        library.folderSortSettings["Old"] = FolderSortSetting(sortField: .author, sortAscending: false)
        let application = apply([Fixtures.entry(.folder(folder.id, .name), .string("New"), wall: 5)], to: library)
        XCTAssertEqual(application.library.folders.first?.fullPath, "New")
        XCTAssertEqual(application.library.books.first?.folderPath, "New")
        XCTAssertNotNil(application.library.folderSortSettings["New"])
        XCTAssertNil(application.library.folderSortSettings["Old"])
        XCTAssertTrue(application.movesPackages)
    }

    /// A removed folder's books and children go to its nearest live ancestor.
    func testRemovedFolderGivesItsContentsToItsAncestor() {
        let top = BookFolder(name: "Top")
        let middle = BookFolder(name: "Middle", parentPath: "Top")
        let low = BookFolder(name: "Low", parentPath: "Top/Middle")
        let book = Fixtures.book(folderPath: "Top/Middle")
        let application = apply(
            [Fixtures.entry(.folder(middle.id, .presence), .null, wall: 5)],
            to: Fixtures.library(books: [book], folders: [top, middle, low])
        )
        XCTAssertEqual(Set(application.library.folders.map(\.fullPath)), ["Top", "Top/Low"])
        XCTAssertEqual(application.library.books.first?.folderPath, "Top")
    }

    /// A removed folder that was changed later lives.
    func testFolderChangedAfterItsRemovalLives() {
        let folder = BookFolder(name: "Old")
        let application = apply([
            Fixtures.entry(.folder(folder.id, .presence), .null, wall: 5),
            Fixtures.entry(.folder(folder.id, .name), .string("Renamed"), wall: 9, device: "b"),
        ], to: Fixtures.library(folders: [folder]))
        XCTAssertEqual(application.library.folders.map(\.fullPath), ["Renamed"])
    }

    /// Two folders that made each other's parent are cut at the later change, to the top.
    func testCycleIsCutAtTheLatestParentChange() {
        let one = UUID(), two = UUID()
        let application = apply([
            Fixtures.entry(.folder(one, .presence), .bool(true), wall: 1), Fixtures.entry(.folder(one, .name), .string("One"), wall: 1),
            Fixtures.entry(.folder(two, .presence), .bool(true), wall: 1), Fixtures.entry(.folder(two, .name), .string("Two"), wall: 1),
            Fixtures.entry(.folder(one, .parent), SyncValueCoding.id(two), wall: 5),
            Fixtures.entry(.folder(two, .parent), SyncValueCoding.id(one), wall: 9),
        ], to: Fixtures.library())
        // Two's parent changed last, so Two goes to the top and One stays below it.
        XCTAssertEqual(Set(application.library.folders.map(\.fullPath)), ["Two", "Two/One"])
    }

    /// A folder deeper than the limit rises to it.
    func testDeepFolderRisesToTheLimit() {
        let ids = (0..<6).map { _ in UUID() }
        var entries: [SyncEntry] = []
        for (depth, id) in ids.enumerated() {
            entries.append(Fixtures.entry(.folder(id, .presence), .bool(true), wall: Int64(depth + 1)))
            entries.append(Fixtures.entry(.folder(id, .name), .string("F\(depth)"), wall: Int64(depth + 1)))
            if depth > 0 { entries.append(Fixtures.entry(.folder(id, .parent), SyncValueCoding.id(ids[depth - 1]), wall: Int64(depth + 1))) }
        }
        let application = apply(entries, to: Fixtures.library())
        let depths = application.library.folders.map(\.depth)
        XCTAssertEqual(application.library.folders.count, 6)
        XCTAssertLessThanOrEqual(depths.max() ?? 0, BookFolder.maxDepth)
    }

    /// Two folders of one name under one parent fold into the older, and the moves are recorded.
    func testSameNamedFoldersFold() {
        let older = UUID(), younger = UUID(), child = UUID()
        let book = Fixtures.book()
        let application = apply([
            Fixtures.entry(.folder(older, .presence), .bool(true), wall: 1), Fixtures.entry(.folder(older, .name), .string("Fiction"), wall: 1),
            Fixtures.entry(.folder(younger, .presence), .bool(true), wall: 2, device: "b"),
            Fixtures.entry(.folder(younger, .name), .string("fiction"), wall: 2, device: "b"),
            Fixtures.entry(.folder(child, .presence), .bool(true), wall: 3, device: "b"),
            Fixtures.entry(.folder(child, .name), .string("Sub"), wall: 3, device: "b"),
            Fixtures.entry(.folder(child, .parent), SyncValueCoding.id(younger), wall: 3, device: "b"),
            Fixtures.entry(.book(book.id, .folder), SyncValueCoding.id(younger), wall: 4, device: "b"),
        ], to: Fixtures.library(books: [book]))
        XCTAssertEqual(Set(application.library.folders.map(\.fullPath)), ["Fiction", "Fiction/Sub"])
        XCTAssertEqual(application.library.books.first?.folderPath, "Fiction")
        // The removal mark names the folder it folded into, which is all that is recorded.
        XCTAssertEqual(application.entriesToRecord, [.folder(younger, .presence): SyncValueCoding.id(older)])
    }

    // MARK: The reading list

    /// The reading list is ordered by the keys, with the library's own unlisted books after them.
    func testReadingListOrderAndOptions() {
        let first = Fixtures.book(), second = Fixtures.book(), unkeyed = Fixtures.book(), dropped = Fixtures.book()
        var library = Fixtures.library(books: [first, second, unkeyed, dropped])
        library.readingList = ReadingList(bookIDs: [dropped.id, unkeyed.id, first.id])
        let application = apply([
            Fixtures.entry(.readingList(book: second.id), .string("B"), wall: 2),
            Fixtures.entry(.readingList(book: first.id), .string("C"), wall: 2),
            Fixtures.entry(.readingList(book: dropped.id), .null, wall: 2),
            Fixtures.entry(.readingListOption(.continuation), .string("stop"), wall: 2),
            Fixtures.entry(.readingListOption(.removesFinished), .bool(true), wall: 2),
        ], to: library)
        XCTAssertEqual(application.library.readingList.bookIDs, [second.id, first.id, unkeyed.id])
        XCTAssertEqual(application.library.readingList.continuation, .stop)
        XCTAssertTrue(application.library.readingList.removesFinished)
        XCTAssertTrue(application.library.readingList.skipsFinished, "an option no entry names stays")
    }

    /// A new book can be on the list before its row is added.
    func testReadingListNamesNewBooks() {
        let theirs = Fixtures.book()
        let application = apply(Fixtures.presence(of: theirs, wall: 5) + [Fixtures.entry(.readingList(book: theirs.id), .string("V"), wall: 5)], to: Fixtures.library())
        XCTAssertEqual(application.library.readingList.bookIDs, [theirs.id])
    }
}
