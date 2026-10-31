import XCTest
@testable import TextMouth

final class LegacyLibraryModelTests: XCTestCase {
    private func book(_ title: String, hash: String, folder: String = "") -> Book {
        Book(title: title, format: .txt, filePath: "/tmp/\(hash).txt", md5Hash: hash, folderPath: folder)
    }

    func testBookFolderDepthAndFullPath() {
        XCTAssertEqual(BookFolder(name: "Fiction").depth, 1)
        XCTAssertEqual(BookFolder(name: "SciFi", parentPath: "Fiction").fullPath, "Fiction/SciFi")
        XCTAssertEqual(BookFolder(name: "Hard", parentPath: "Fiction/SciFi").depth, 3)
        XCTAssertEqual(BookFolder(name: "Space", parentPath: "Fiction/SciFi/Hard").depth, 4)
        XCTAssertEqual(BookFolder.maxDepth, 4)
    }

    /// A saved bookmark at a place no bookmark can have (a negative chapter
    /// or offset, or one too large for an `Int`, as a hand edit of
    /// library.json can leave) decodes with that number repaired to 0,
    /// rather than failing its book, and keeps its identity, number, note,
    /// and date (`Bookmark.init(from:)`, `LenientFields.position`).
    func testADecodedBookmarkWithAnImpossibleLocationIsRepaired() throws {
        let id = try XCTUnwrap(UUID(uuidString: "6F1C2A4E-0B7D-4C11-9E55-3A2B1C0D9E8F"))
        let created = "2026-10-09T14:30:00Z"
        // Read as library.json is read: its dates are ISO 8601.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        /// The bookmark saved with `chapterIndex` and `characterOffset`, each
        /// written into the JSON as given.
        func decoded(chapterIndex: String, characterOffset: String) throws -> Bookmark {
            let json = """
                {"id": "\(id.uuidString)", "number": 7, "chapterIndex": \(chapterIndex), \
                "characterOffset": \(characterOffset), "label": "Margin note", "dateCreated": "\(created)"}
                """
            return try decoder.decode(Bookmark.self, from: Data(json.utf8))
        }

        let negativeOffset = try decoded(chapterIndex: "3", characterOffset: "-5")
        XCTAssertEqual(negativeOffset.chapterIndex, 3)
        XCTAssertEqual(negativeOffset.characterOffset, 0)

        let negativeChapter = try decoded(chapterIndex: "-1", characterOffset: "500")
        XCTAssertEqual(negativeChapter.chapterIndex, 0)
        XCTAssertEqual(negativeChapter.characterOffset, 500)

        let tooLarge = try decoded(chapterIndex: "2", characterOffset: "99999999999999999999")
        XCTAssertEqual(tooLarge.chapterIndex, 2)
        XCTAssertEqual(tooLarge.characterOffset, 0)

        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: created))
        for bookmark in [negativeOffset, negativeChapter, tooLarge] {
            XCTAssertEqual(bookmark.id, id)
            XCTAssertEqual(bookmark.number, 7)
            XCTAssertEqual(bookmark.label, "Margin note")
            XCTAssertEqual(bookmark.dateCreated, date)
        }
    }

    func testTimeBasedSkipUnitsCalculateWordCounts() {
        XCTAssertEqual(SkipUnit.seconds10.wordCount(wpm: 300), 50)
        XCTAssertEqual(SkipUnit.seconds15.wordCount(wpm: 300), 75)
        XCTAssertEqual(SkipUnit.seconds30.wordCount(wpm: 300), 150)
        XCTAssertEqual(SkipUnit.seconds60.wordCount(wpm: 300), 300)
    }

    func testSkipWordCountsScaleAndClamp() {
        XCTAssertEqual(SkipUnit.seconds15.wordCount(wpm: 150), 37)
        XCTAssertEqual(SkipUnit.seconds15.wordCount(wpm: 500), 125)
        XCTAssertEqual(SkipUnit.seconds10.wordCount(wpm: 1), 1)
    }

    func testMaximumWPMProducesValidSkipCounts() {
        XCTAssertEqual(SkipUnit.seconds15.wordCount(wpm: 650), 162)
        XCTAssertEqual(SkipUnit.seconds60.wordCount(wpm: 650), 650)
        XCTAssertNil(SkipUnit.heading.wordCount(wpm: 650))
    }

    func testLibraryCategoryCasesAndRecentDefaults() {
        XCTAssertEqual(LibraryCategory.allCases.count, 5)
        XCTAssertTrue(LibraryCategory.allCases.contains(.recent))
        XCTAssertEqual(LibraryCategory.recent.rawValue, "Recently Opened")
        XCTAssertEqual(LibraryCategory.recent.sortSettingsKey, "__recent__")
        XCTAssertEqual(LibraryCategory.recent.defaultSortSetting, .recentDefault)
    }

    func testAddBookPreventsDuplicateHash() {
        var library = Library()
        library.addBook(book("A", hash: "same"))
        library.addBook(book("Copy", hash: "same"))
        library.addBook(book("B", hash: "different"))
        XCTAssertEqual(library.books.map(\.title), ["A", "B"])
    }

    func testRemoveBookUsesIdentity() {
        var library = Library()
        let first = book("First", hash: "one")
        let second = book("Second", hash: "two")
        library.addBook(first)
        library.addBook(second)
        library.removeBook(id: first.id)
        XCTAssertEqual(library.books.map(\.title), ["Second"])
    }

    func testFolderCreationEnforcesDepthAndDuplicates() {
        var library = Library()
        XCTAssertNotNil(library.createFolder(name: "A"))
        XCTAssertNotNil(library.createFolder(name: "B", parentPath: "A"))
        XCTAssertNotNil(library.createFolder(name: "C", parentPath: "A/B"))
        XCTAssertNotNil(library.createFolder(name: "D", parentPath: "A/B/C"))
        XCTAssertNil(library.createFolder(name: "E", parentPath: "A/B/C/D"))
        XCTAssertNil(library.createFolder(name: "A"))
    }

    func testBookmarkAdditionAndRemovalRenumbersRemainingBookmarks() throws {
        var library = Library()
        let item = book("Book", hash: "book")
        library.addBook(item)
        library.addBookmark(bookID: item.id, chapterIndex: 0, characterOffset: 100)
        library.addBookmark(bookID: item.id, chapterIndex: 1, characterOffset: 200)
        library.addBookmark(bookID: item.id, chapterIndex: 2, characterOffset: 300)
        // Stop here, rather than trap, if the book or its second bookmark is missing.
        let storedBook = try XCTUnwrap(library.books[safe: 0], "the library has no first book")
        let middleID = try XCTUnwrap(storedBook.bookmarks[safe: 1], "the book has no second bookmark").id
        library.removeBookmark(bookID: item.id, bookmarkID: middleID)
        XCTAssertEqual(library.books[safe: 0]?.bookmarks.map(\.number), [1, 2])
        XCTAssertEqual(library.books[safe: 0]?.bookmarks[safe: 1]?.characterOffset, 300)
    }

    func testMoveBookUpdatesFolderPath() {
        var library = Library()
        let item = book("Book", hash: "book")
        library.addBook(item)
        library.moveBook(id: item.id, toFolder: "Fiction/SciFi")
        XCTAssertEqual(library.books[safe: 0]?.folderPath, "Fiction/SciFi")
    }

    func testBooksInFolderAndNoFolderQueries() {
        var library = Library()
        library.addBook(book("A", hash: "a", folder: "Fiction"))
        library.addBook(book("B", hash: "b", folder: "Fiction"))
        library.addBook(book("C", hash: "c"))
        XCTAssertEqual(library.booksInFolder("Fiction").count, 2)
        XCTAssertEqual(library.booksInFolder("").map(\.title), ["C"])
    }

    func testRemovingMultipleBooksLeavesUnselectedBook() {
        var library = Library()
        let books = [book("First", hash: "1"), book("Second", hash: "2"), book("Third", hash: "3")]
        books.forEach { library.addBook($0) }
        library.removeBook(id: books[0].id)
        library.removeBook(id: books[2].id)
        XCTAssertEqual(library.books.map(\.title), ["Second"])
    }

    func testMovingMultipleBooksPreservesUnselectedFolders() {
        var library = Library()
        let a = book("A", hash: "a", folder: "Old")
        let b = book("B", hash: "b", folder: "Old")
        let c = book("C", hash: "c", folder: "Old")
        [a, b, c].forEach { library.addBook($0) }
        library.moveBook(id: a.id, toFolder: "New")
        library.moveBook(id: c.id, toFolder: "New")
        XCTAssertEqual(library.booksInFolder("New").count, 2)
        XCTAssertEqual(library.booksInFolder("Old").map(\.title), ["B"])
    }

    func testMoveFolderChangesParentAndBookPaths() throws {
        var library = Library()
        _ = library.createFolder(name: "Fiction")
        _ = library.createFolder(name: "NonFiction")
        let folder = try XCTUnwrap(library.createFolder(name: "SciFi", parentPath: "Fiction"), "the library made no folder named SciFi")
        library.addBook(book("Dune", hash: "d", folder: "Fiction/SciFi"))
        XCTAssertTrue(library.moveFolder(id: folder.id, toParentPath: "NonFiction"))
        XCTAssertEqual(library.folders.first { $0.id == folder.id }?.fullPath, "NonFiction/SciFi")
        XCTAssertEqual(library.books[safe: 0]?.folderPath, "NonFiction/SciFi")
    }

    func testMoveFolderToRoot() throws {
        var library = Library()
        _ = library.createFolder(name: "Parent")
        let child = try XCTUnwrap(library.createFolder(name: "Child", parentPath: "Parent"), "the library made no folder named Child")
        library.addBook(book("A", hash: "a", folder: "Parent/Child"))
        XCTAssertTrue(library.moveFolder(id: child.id, toParentPath: ""))
        XCTAssertEqual(library.books[safe: 0]?.folderPath, "Child")
    }

    func testMoveFolderPreventsCycle() throws {
        var library = Library()
        let parent = try XCTUnwrap(library.createFolder(name: "Parent"), "the library made no folder named Parent")
        _ = library.createFolder(name: "Child", parentPath: "Parent")
        XCTAssertFalse(library.moveFolder(id: parent.id, toParentPath: "Parent/Child"))
    }

    func testMoveFolderPreventsDescendantsExceedingMaximumDepth() throws {
        var library = Library()
        _ = library.createFolder(name: "A")
        let b = try XCTUnwrap(library.createFolder(name: "B", parentPath: "A"), "the library made no folder named B")
        _ = library.createFolder(name: "C", parentPath: "A/B")
        _ = library.createFolder(name: "X")
        _ = library.createFolder(name: "Y", parentPath: "X")
        _ = library.createFolder(name: "Z", parentPath: "X/Y")
        XCTAssertFalse(library.moveFolder(id: b.id, toParentPath: "X/Y/Z"))
    }

    func testMoveFolderUpdatesDescendantPaths() throws {
        var library = Library()
        _ = library.createFolder(name: "Old")
        let sub = try XCTUnwrap(library.createFolder(name: "Sub", parentPath: "Old"), "the library made no folder named Sub")
        _ = library.createFolder(name: "Deep", parentPath: "Old/Sub")
        _ = library.createFolder(name: "New")
        library.addBook(book("B", hash: "b", folder: "Old/Sub/Deep"))
        XCTAssertTrue(library.moveFolder(id: sub.id, toParentPath: "New"))
        XCTAssertEqual(library.folders.first { $0.name == "Deep" }?.fullPath, "New/Sub/Deep")
        XCTAssertEqual(library.books[safe: 0]?.folderPath, "New/Sub/Deep")
    }

    func testMoveFolderRejectsDestinationCollision() throws {
        var library = Library()
        _ = library.createFolder(name: "A")
        _ = library.createFolder(name: "B")
        let duplicate = try XCTUnwrap(library.createFolder(name: "A", parentPath: "B"), "the library made no folder named A")
        XCTAssertFalse(library.moveFolder(id: duplicate.id, toParentPath: ""))
    }

    func testRemoveFolderAndContentsRemovesEntireTree() throws {
        var library = Library()
        let folder = try XCTUnwrap(library.createFolder(name: "Delete"), "the library made no folder named Delete")
        _ = library.createFolder(name: "Sub", parentPath: "Delete")
        library.addBook(book("A", hash: "a", folder: "Delete"))
        library.addBook(book("B", hash: "b", folder: "Delete/Sub"))
        library.addBook(book("C", hash: "c"))
        XCTAssertEqual(library.removeFolderAndContents(id: folder.id).count, 2)
        XCTAssertEqual(library.books.map(\.title), ["C"])
        XCTAssertTrue(library.folders.isEmpty)
    }

    func testRemoveFolderCanReparentContentsToDestination() throws {
        var library = Library()
        let old = try XCTUnwrap(library.createFolder(name: "Old"), "the library made no folder named Old")
        _ = library.createFolder(name: "Sub", parentPath: "Old")
        _ = library.createFolder(name: "Target")
        library.addBook(book("A", hash: "a", folder: "Old"))
        library.addBook(book("B", hash: "b", folder: "Old/Sub"))
        library.removeFolder(id: old.id, movingContentsTo: "Target")
        XCTAssertEqual(library.books.first { $0.title == "A" }?.folderPath, "Target")
        XCTAssertEqual(library.books.first { $0.title == "B" }?.folderPath, "Target/Sub")
        XCTAssertEqual(library.folders.first { $0.name == "Sub" }?.parentPath, "Target")
    }

    func testRemoveFolderCanReparentContentsToRoot() throws {
        var library = Library()
        let parent = try XCTUnwrap(library.createFolder(name: "Parent"), "the library made no folder named Parent")
        _ = library.createFolder(name: "Child", parentPath: "Parent")
        library.addBook(book("A", hash: "a", folder: "Parent"))
        library.addBook(book("B", hash: "b", folder: "Parent/Child"))
        library.removeFolder(id: parent.id)
        XCTAssertEqual(library.books.first { $0.title == "A" }?.folderPath, "")
        XCTAssertEqual(library.books.first { $0.title == "B" }?.folderPath, "Child")
        XCTAssertEqual(library.folders.first?.parentPath, "")
    }

    func testFolderHasContentsDetectsBooksAndChildren() throws {
        var library = Library()
        let empty = try XCTUnwrap(library.createFolder(name: "Empty"), "the library made no folder named Empty")
        let withBook = try XCTUnwrap(library.createFolder(name: "WithBook"), "the library made no folder named WithBook")
        let withChild = try XCTUnwrap(library.createFolder(name: "WithChild"), "the library made no folder named WithChild")
        _ = library.createFolder(name: "Sub", parentPath: "WithChild")
        library.addBook(book("A", hash: "a", folder: "WithBook"))
        XCTAssertFalse(library.folderHasContents(empty))
        XCTAssertTrue(library.folderHasContents(withBook))
        XCTAssertTrue(library.folderHasContents(withChild))
    }

    func testRecursiveBookCounts() {
        var library = Library()
        library.addBook(book("A", hash: "a", folder: "Root"))
        library.addBook(book("B", hash: "b", folder: "Root/Sub"))
        library.addBook(book("C", hash: "c", folder: "Root/Sub/Deep"))
        XCTAssertEqual(library.totalBooksInFolderTree("Root"), 3)
        XCTAssertEqual(library.totalBooksInFolderTree("Root/Sub"), 2)
        XCTAssertEqual(library.totalBooksInFolderTree("Root/Sub/Deep"), 1)
    }

    func testRenameFolderUpdatesBooksAndDescendants() throws {
        var library = Library()
        let parent = try XCTUnwrap(library.createFolder(name: "Parent"), "the library made no folder named Parent")
        _ = library.createFolder(name: "Child", parentPath: "Parent")
        library.addBook(book("B", hash: "b", folder: "Parent/Child"))
        XCTAssertTrue(library.renameFolder(id: parent.id, to: "Renamed"))
        XCTAssertEqual(library.folders.first { $0.name == "Child" }?.fullPath, "Renamed/Child")
        XCTAssertEqual(library.books[safe: 0]?.folderPath, "Renamed/Child")
    }

    func testRenameFolderRejectsInvalidNamesAndCollisions() throws {
        var library = Library()
        _ = library.createFolder(name: "Existing")
        let folder = try XCTUnwrap(library.createFolder(name: "Original"), "the library made no folder named Original")
        XCTAssertFalse(library.renameFolder(id: folder.id, to: "   "))
        XCTAssertFalse(library.renameFolder(id: folder.id, to: "Original"))
        XCTAssertFalse(library.renameFolder(id: folder.id, to: "Existing"))
        XCTAssertEqual(library.folders.first { $0.id == folder.id }?.name, "Original")
    }

    func testRenameFolderSanitizesSlashes() throws {
        var library = Library()
        let folder = try XCTUnwrap(library.createFolder(name: "Original"), "the library made no folder named Original")
        XCTAssertTrue(library.renameFolder(id: folder.id, to: "New/Name"))
        XCTAssertEqual(library.folders.first { $0.id == folder.id }?.name, "New-Name")
    }

    func testTreeOrderKeepsChildrenImmediatelyAfterParent() {
        let folders = [
            BookFolder(name: "Misc SciFi"),
            BookFolder(name: "Sub", parentPath: "Misc SciFi"),
            BookFolder(name: "Misc SciFi anthologies"),
        ]
        XCTAssertEqual(folders.sortedTreeOrder().map(\.fullPath), [
            "Misc SciFi", "Misc SciFi/Sub", "Misc SciFi anthologies",
        ])
    }

    func testTreeOrderHandlesDeepNesting() {
        let folders = [
            BookFolder(name: "Z"), BookFolder(name: "A"),
            BookFolder(name: "B", parentPath: "A"),
            BookFolder(name: "C", parentPath: "A/B"), BookFolder(name: "A extra"),
        ]
        XCTAssertEqual(folders.sortedTreeOrder().map(\.fullPath), ["A", "A/B", "A/B/C", "A extra", "Z"])
    }

    func testTreeOrderSortsSiblingsAlphabetically() {
        let folders = [
            BookFolder(name: "Parent"), BookFolder(name: "Zebra", parentPath: "Parent"),
            BookFolder(name: "Alpha", parentPath: "Parent"),
            BookFolder(name: "Middle", parentPath: "Parent"),
        ]
        XCTAssertEqual(folders.sortedTreeOrder().map(\.fullPath), [
            "Parent", "Parent/Alpha", "Parent/Middle", "Parent/Zebra",
        ])
    }
}
