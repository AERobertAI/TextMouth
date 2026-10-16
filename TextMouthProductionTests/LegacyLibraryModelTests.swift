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

    func testBookmarkStoresNumberAndPosition() {
        let bookmark = Bookmark(number: 2, chapterIndex: 3, characterOffset: 500, label: "Middle")
        XCTAssertEqual(bookmark.number, 2)
        XCTAssertEqual(bookmark.chapterIndex, 3)
        XCTAssertEqual(bookmark.characterOffset, 500)
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

    func testMoveFolderChangesParentAndBookPaths() {
        var library = Library()
        _ = library.createFolder(name: "Fiction")
        _ = library.createFolder(name: "NonFiction")
        let folder = library.createFolder(name: "SciFi", parentPath: "Fiction")!
        library.addBook(book("Dune", hash: "d", folder: "Fiction/SciFi"))
        XCTAssertTrue(library.moveFolder(id: folder.id, toParentPath: "NonFiction"))
        XCTAssertEqual(library.folders.first { $0.id == folder.id }?.fullPath, "NonFiction/SciFi")
        XCTAssertEqual(library.books[safe: 0]?.folderPath, "NonFiction/SciFi")
    }

    func testMoveFolderToRoot() {
        var library = Library()
        _ = library.createFolder(name: "Parent")
        let child = library.createFolder(name: "Child", parentPath: "Parent")!
        library.addBook(book("A", hash: "a", folder: "Parent/Child"))
        XCTAssertTrue(library.moveFolder(id: child.id, toParentPath: ""))
        XCTAssertEqual(library.books[safe: 0]?.folderPath, "Child")
    }

    func testMoveFolderPreventsCycle() {
        var library = Library()
        let parent = library.createFolder(name: "Parent")!
        _ = library.createFolder(name: "Child", parentPath: "Parent")
        XCTAssertFalse(library.moveFolder(id: parent.id, toParentPath: "Parent/Child"))
    }

    func testMoveFolderPreventsDescendantsExceedingMaximumDepth() {
        var library = Library()
        _ = library.createFolder(name: "A")
        let b = library.createFolder(name: "B", parentPath: "A")!
        _ = library.createFolder(name: "C", parentPath: "A/B")
        _ = library.createFolder(name: "X")
        _ = library.createFolder(name: "Y", parentPath: "X")
        _ = library.createFolder(name: "Z", parentPath: "X/Y")
        XCTAssertFalse(library.moveFolder(id: b.id, toParentPath: "X/Y/Z"))
    }

    func testMoveFolderUpdatesDescendantPaths() {
        var library = Library()
        _ = library.createFolder(name: "Old")
        let sub = library.createFolder(name: "Sub", parentPath: "Old")!
        _ = library.createFolder(name: "Deep", parentPath: "Old/Sub")
        _ = library.createFolder(name: "New")
        library.addBook(book("B", hash: "b", folder: "Old/Sub/Deep"))
        XCTAssertTrue(library.moveFolder(id: sub.id, toParentPath: "New"))
        XCTAssertEqual(library.folders.first { $0.name == "Deep" }?.fullPath, "New/Sub/Deep")
        XCTAssertEqual(library.books[safe: 0]?.folderPath, "New/Sub/Deep")
    }

    func testMoveFolderRejectsDestinationCollision() {
        var library = Library()
        _ = library.createFolder(name: "A")
        _ = library.createFolder(name: "B")
        let duplicate = library.createFolder(name: "A", parentPath: "B")!
        XCTAssertFalse(library.moveFolder(id: duplicate.id, toParentPath: ""))
    }

    func testRemoveFolderAndContentsRemovesEntireTree() {
        var library = Library()
        let folder = library.createFolder(name: "Delete")!
        _ = library.createFolder(name: "Sub", parentPath: "Delete")
        library.addBook(book("A", hash: "a", folder: "Delete"))
        library.addBook(book("B", hash: "b", folder: "Delete/Sub"))
        library.addBook(book("C", hash: "c"))
        XCTAssertEqual(library.removeFolderAndContents(id: folder.id).count, 2)
        XCTAssertEqual(library.books.map(\.title), ["C"])
        XCTAssertTrue(library.folders.isEmpty)
    }

    func testRemoveFolderCanReparentContentsToDestination() {
        var library = Library()
        let old = library.createFolder(name: "Old")!
        _ = library.createFolder(name: "Sub", parentPath: "Old")
        _ = library.createFolder(name: "Target")
        library.addBook(book("A", hash: "a", folder: "Old"))
        library.addBook(book("B", hash: "b", folder: "Old/Sub"))
        library.removeFolder(id: old.id, movingContentsTo: "Target")
        XCTAssertEqual(library.books.first { $0.title == "A" }?.folderPath, "Target")
        XCTAssertEqual(library.books.first { $0.title == "B" }?.folderPath, "Target/Sub")
        XCTAssertEqual(library.folders.first { $0.name == "Sub" }?.parentPath, "Target")
    }

    func testRemoveFolderCanReparentContentsToRoot() {
        var library = Library()
        let parent = library.createFolder(name: "Parent")!
        _ = library.createFolder(name: "Child", parentPath: "Parent")
        library.addBook(book("A", hash: "a", folder: "Parent"))
        library.addBook(book("B", hash: "b", folder: "Parent/Child"))
        library.removeFolder(id: parent.id)
        XCTAssertEqual(library.books.first { $0.title == "A" }?.folderPath, "")
        XCTAssertEqual(library.books.first { $0.title == "B" }?.folderPath, "Child")
        XCTAssertEqual(library.folders.first?.parentPath, "")
    }

    func testFolderHasContentsDetectsBooksAndChildren() {
        var library = Library()
        let empty = library.createFolder(name: "Empty")!
        let withBook = library.createFolder(name: "WithBook")!
        let withChild = library.createFolder(name: "WithChild")!
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

    func testRenameFolderUpdatesBooksAndDescendants() {
        var library = Library()
        let parent = library.createFolder(name: "Parent")!
        _ = library.createFolder(name: "Child", parentPath: "Parent")
        library.addBook(book("B", hash: "b", folder: "Parent/Child"))
        XCTAssertTrue(library.renameFolder(id: parent.id, to: "Renamed"))
        XCTAssertEqual(library.folders.first { $0.name == "Child" }?.fullPath, "Renamed/Child")
        XCTAssertEqual(library.books[safe: 0]?.folderPath, "Renamed/Child")
    }

    func testRenameFolderRejectsInvalidNamesAndCollisions() {
        var library = Library()
        _ = library.createFolder(name: "Existing")
        let folder = library.createFolder(name: "Original")!
        XCTAssertFalse(library.renameFolder(id: folder.id, to: "   "))
        XCTAssertFalse(library.renameFolder(id: folder.id, to: "Original"))
        XCTAssertFalse(library.renameFolder(id: folder.id, to: "Existing"))
        XCTAssertEqual(library.folders.first { $0.id == folder.id }?.name, "Original")
    }

    func testRenameFolderSanitizesSlashes() {
        var library = Library()
        let folder = library.createFolder(name: "Original")!
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
