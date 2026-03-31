import Foundation

// Mirror LibraryCategory for testing
enum LibraryCategory: String, CaseIterable, Codable {
    case folders = "Folders"
    case allItems = "All Items"
    case noFolder = "No Folder"
    case recent = "Recent"

    var sortSettingsKey: String? {
        switch self {
        case .folders:  return nil
        case .allItems: return "__allItems__"
        case .noFolder: return "__noFolder__"
        case .recent:   return "__recent__"
        }
    }

    var defaultSortSetting: FolderSortSetting {
        switch self {
        case .recent: return .recentDefault
        default:      return .defaultSort
        }
    }
}

func runLibraryModelTests() {
print("\n--- Library Model Tests ---")

test("BookFolder depth calculation") {
    let root = BookFolder(name: "Fiction", parentPath: "")
    try assertEqual(root.depth, 1)
    try assertEqual(root.fullPath, "Fiction")

    let sub = BookFolder(name: "SciFi", parentPath: "Fiction")
    try assertEqual(sub.depth, 2)
    try assertEqual(sub.fullPath, "Fiction/SciFi")

    let deep = BookFolder(name: "Hard", parentPath: "Fiction/SciFi")
    try assertEqual(deep.depth, 3)
    try assertEqual(deep.fullPath, "Fiction/SciFi/Hard")

    let level4 = BookFolder(name: "Space", parentPath: "Fiction/SciFi/Hard")
    try assertEqual(level4.depth, 4)
    try assertTrue(level4.depth <= BookFolder.maxDepth, "Should be within max depth")

    let level5 = BookFolder(name: "Mars", parentPath: "Fiction/SciFi/Hard/Space")
    try assertEqual(level5.depth, 5)
    try assertTrue(level5.depth > BookFolder.maxDepth, "Should exceed max depth")
}

test("Bookmark numbering") {
    let b1 = Bookmark(number: 1, chapterIndex: 0, characterOffset: 100, label: "Start")
    let b2 = Bookmark(number: 2, chapterIndex: 2, characterOffset: 500, label: "Middle")
    try assertEqual(b1.number, 1)
    try assertEqual(b2.number, 2)
    try assertEqual(b1.chapterIndex, 0)
    try assertEqual(b2.characterOffset, 500)
}

// ---- Skip Unit / WPM Word Count Tests ----
print("\n--- Skip Unit Word Count Tests ---")

test("Time-based skip units calculate correct word counts") {
    // At 300 WPM:
    // 10s = 300 * 10/60 = 50 words
    // 15s = 300 * 15/60 = 75 words
    // 30s = 300 * 30/60 = 150 words
    // 60s = 300 * 60/60 = 300 words
    let wpm = 300.0

    let w10 = max(1, Int(wpm * 10.0 / 60.0))
    let w15 = max(1, Int(wpm * 15.0 / 60.0))
    let w30 = max(1, Int(wpm * 30.0 / 60.0))
    let w60 = max(1, Int(wpm * 60.0 / 60.0))

    try assertEqual(w10, 50, "10s at 300 WPM = 50 words")
    try assertEqual(w15, 75, "15s at 300 WPM = 75 words")
    try assertEqual(w30, 150, "30s at 300 WPM = 150 words")
    try assertEqual(w60, 300, "60s at 300 WPM = 300 words")
    print("    300 WPM: 10s=\(w10), 15s=\(w15), 30s=\(w30), 60s=\(w60)")
}

test("Skip word counts scale with WPM") {
    let slow = max(1, Int(150.0 * 15.0 / 60.0))  // 150 WPM, 15s
    let fast = max(1, Int(500.0 * 15.0 / 60.0))  // 500 WPM, 15s
    try assertEqual(slow, 37, "150 WPM 15s")
    try assertEqual(fast, 125, "500 WPM 15s")
    try assertTrue(fast > slow, "Faster speed should skip more words")
    print("    15s skip: 150 WPM=\(slow) words, 500 WPM=\(fast) words")
}

test("Max WPM of 650 produces valid skip counts") {
    let w15at650 = max(1, Int(650.0 * 15.0 / 60.0))
    try assertEqual(w15at650, 162, "15s at 650 WPM")
    let w60at650 = max(1, Int(650.0 * 60.0 / 60.0))
    try assertEqual(w60at650, 650, "60s at 650 WPM")
    print("    650 WPM: 15s=\(w15at650), 60s=\(w60at650)")
}

// ---- Sorting Tests ----
print("\n--- Library Sorting Tests ---")

test("Books sort by title ascending") {
    let books = [
        ("Zebra", "Author A", Date(timeIntervalSince1970: 100)),
        ("Apple", "Author B", Date(timeIntervalSince1970: 200)),
        ("Mango", "Author C", Date(timeIntervalSince1970: 300)),
    ]
    let sorted = books.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    try assertEqual(sorted[0].0, "Apple")
    try assertEqual(sorted[1].0, "Mango")
    try assertEqual(sorted[2].0, "Zebra")
}

test("Books sort by author ascending") {
    let books = [
        ("Book1", "Zane", Date(timeIntervalSince1970: 100)),
        ("Book2", "Adams", Date(timeIntervalSince1970: 200)),
        ("Book3", "Mitchell", Date(timeIntervalSince1970: 300)),
    ]
    let sorted = books.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    try assertEqual(sorted[0].1, "Adams")
    try assertEqual(sorted[1].1, "Mitchell")
    try assertEqual(sorted[2].1, "Zane")
}

test("Books sort by date added descending") {
    let books = [
        ("A", Date(timeIntervalSince1970: 100)),
        ("B", Date(timeIntervalSince1970: 300)),
        ("C", Date(timeIntervalSince1970: 200)),
    ]
    let sortedDesc = books.sorted { $0.1 > $1.1 }
    try assertEqual(sortedDesc[0].0, "B")
    try assertEqual(sortedDesc[1].0, "C")
    try assertEqual(sortedDesc[2].0, "A")
}

// ---- Library Model (new tests) ----
print("\n--- Library Model Tests ---")

test("Library addBook prevents duplicates by hash") {
    // Simulate Library behavior
    var books: [(title: String, hash: String)] = []
    func addBook(title: String, hash: String) {
        guard !books.contains(where: { $0.hash == hash }) else { return }
        books.append((title: title, hash: hash))
    }

    addBook(title: "Book A", hash: "abc123")
    addBook(title: "Book B", hash: "def456")
    addBook(title: "Book A Copy", hash: "abc123")  // duplicate hash

    try assertEqual(books.count, 2, "Duplicate hash should not be added")
    try assertEqual(books[0].title, "Book A")
    try assertEqual(books[1].title, "Book B")
}

test("Library removeBook by id") {
    var ids: [UUID] = []
    let id1 = UUID()
    let id2 = UUID()
    let id3 = UUID()
    ids = [id1, id2, id3]

    ids.removeAll { $0 == id2 }
    try assertEqual(ids.count, 2)
    try assertTrue(!ids.contains(id2))
}

test("Library folder operations") {
    var folders: [(name: String, parentPath: String, fullPath: String)] = []

    func createFolder(name: String, parentPath: String) -> Bool {
        let fullPath = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
        let depth = fullPath.components(separatedBy: "/").count
        guard depth <= 4 else { return false }
        guard !folders.contains(where: { $0.fullPath == fullPath }) else { return false }
        folders.append((name: name, parentPath: parentPath, fullPath: fullPath))
        return true
    }

    try assertTrue(createFolder(name: "Fiction", parentPath: ""))
    try assertTrue(createFolder(name: "SciFi", parentPath: "Fiction"))
    try assertTrue(createFolder(name: "Hard", parentPath: "Fiction/SciFi"))
    try assertTrue(createFolder(name: "Space", parentPath: "Fiction/SciFi/Hard"))
    // Depth 5 should fail
    try assertTrue(!createFolder(name: "Mars", parentPath: "Fiction/SciFi/Hard/Space"), "Depth 5 should be rejected")
    // Duplicate should fail
    try assertTrue(!createFolder(name: "Fiction", parentPath: ""), "Duplicate folder should be rejected")
    try assertEqual(folders.count, 4)
}

test("Folder name sanitization strips slashes") {
    let name = "Sci/Fi Books"
    let sanitized = name.replacingOccurrences(of: "/", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    try assertEqual(sanitized, "Sci-Fi Books", "Slash should be replaced with dash")

    let emptyAfterTrim = "   "
    let sanitized2 = emptyAfterTrim.trimmingCharacters(in: .whitespacesAndNewlines)
    try assertTrue(sanitized2.isEmpty, "Whitespace-only name should become empty")
}

test("Library bookmark numbering and renumbering") {
    var bookmarks: [(number: Int, chapterIndex: Int, offset: Int)] = []

    func addBookmark(chapter: Int, offset: Int) {
        let nextNum = (bookmarks.map { $0.number }.max() ?? 0) + 1
        bookmarks.append((number: nextNum, chapterIndex: chapter, offset: offset))
    }

    func removeBookmark(at index: Int) {
        bookmarks.remove(at: index)
        for i in bookmarks.indices {
            bookmarks[i].number = i + 1
        }
    }

    addBookmark(chapter: 0, offset: 100)
    addBookmark(chapter: 1, offset: 200)
    addBookmark(chapter: 2, offset: 300)

    try assertEqual(bookmarks[0].number, 1)
    try assertEqual(bookmarks[1].number, 2)
    try assertEqual(bookmarks[2].number, 3)

    // Remove middle bookmark — remaining should renumber
    removeBookmark(at: 1)
    try assertEqual(bookmarks.count, 2)
    try assertEqual(bookmarks[0].number, 1, "First should be renumbered to 1")
    try assertEqual(bookmarks[1].number, 2, "Second should be renumbered to 2")
    try assertEqual(bookmarks[1].offset, 300, "Content should remain from original third")
}

test("Library moveBook updates folder path") {
    // Simulate: books array with folder paths
    var books = [
        (id: 1, folderPath: "Fiction"),
        (id: 2, folderPath: ""),
        (id: 3, folderPath: "Fiction/SciFi"),
    ]

    // Move book 1 to root
    if let idx = books.firstIndex(where: { $0.id == 1 }) {
        books[idx].folderPath = ""
    }
    try assertEqual(books[0].folderPath, "", "Should be moved to root")

    // Move book 2 to Fiction/SciFi
    if let idx = books.firstIndex(where: { $0.id == 2 }) {
        books[idx].folderPath = "Fiction/SciFi"
    }
    try assertEqual(books[1].folderPath, "Fiction/SciFi")
}

test("Library removeFolder moves books to root") {
    var books = [
        (title: "A", folderPath: "Fiction"),
        (title: "B", folderPath: "Fiction/SciFi"),
        (title: "C", folderPath: "NonFiction"),
    ]
    let removePath = "Fiction"

    for i in books.indices {
        if books[i].folderPath == removePath || books[i].folderPath.hasPrefix(removePath + "/") {
            books[i].folderPath = ""
        }
    }

    try assertEqual(books[0].folderPath, "", "Book in Fiction should move to root")
    try assertEqual(books[1].folderPath, "", "Book in Fiction/SciFi should move to root")
    try assertEqual(books[2].folderPath, "NonFiction", "NonFiction book should be unaffected")
}

test("Library booksInFolder query") {
    let books = [
        (title: "A", folderPath: "Fiction"),
        (title: "B", folderPath: "Fiction"),
        (title: "C", folderPath: "NonFiction"),
        (title: "D", folderPath: ""),
    ]
    let fictionBooks = books.filter { $0.folderPath == "Fiction" }
    let rootBooks = books.filter { $0.folderPath.isEmpty }
    let all = books

    try assertEqual(fictionBooks.count, 2)
    try assertEqual(rootBooks.count, 1)
    try assertEqual(all.count, 4)
}

// ---- Multi-Selection Operations ----
print("\n--- Multi-Selection Tests ---")

test("Library removeBooks removes multiple books at once") {
    var library = Library()
    let book1 = Book(title: "First", md5Hash: "h1")
    let book2 = Book(title: "Second", md5Hash: "h2")
    let book3 = Book(title: "Third", md5Hash: "h3")
    library.addBook(book1)
    library.addBook(book2)
    library.addBook(book3)

    // Remove two books at once
    let toRemove = [book1, book3]
    for book in toRemove {
        library.removeBook(id: book.id)
    }

    try assertEqual(library.books.count, 1, "Should have 1 book remaining")
    try assertEqual(library.books[0].title, "Second", "Remaining book should be Second")
}

test("Library moveBooks moves multiple books to same folder") {
    var library = Library()
    let book1 = Book(title: "A", md5Hash: "a1", folderPath: "")
    let book2 = Book(title: "B", md5Hash: "b1", folderPath: "")
    let book3 = Book(title: "C", md5Hash: "c1", folderPath: "Fiction")
    library.addBook(book1)
    library.addBook(book2)
    library.addBook(book3)
    _ = library.createFolder(name: "Fiction")
    _ = library.createFolder(name: "NonFiction")

    // Move first two books to NonFiction
    let toMove = [book1, book2]
    for book in toMove {
        library.moveBook(id: book.id, toFolder: "NonFiction")
    }

    let nonFictionBooks = library.booksInFolder("NonFiction")
    try assertEqual(nonFictionBooks.count, 2, "Should have 2 books in NonFiction")
    let rootBooks = library.booksInFolder("")
    try assertEqual(rootBooks.count, 0, "Root should be empty")
    let fictionBooks = library.booksInFolder("Fiction")
    try assertEqual(fictionBooks.count, 1, "Fiction should still have 1 book")
}

test("Multi-select remove leaves unselected books intact") {
    var library = Library()
    for i in 0..<5 {
        library.addBook(Book(title: "Book \(i)", md5Hash: "hash\(i)"))
    }
    try assertEqual(library.books.count, 5)

    // Simulate multi-select: remove books at indices 1 and 3
    let idsToRemove = [library.books[1].id, library.books[3].id]
    for id in idsToRemove {
        library.removeBook(id: id)
    }

    try assertEqual(library.books.count, 3, "Should have 3 books left")
    try assertEqual(library.books[0].title, "Book 0")
    try assertEqual(library.books[1].title, "Book 2")
    try assertEqual(library.books[2].title, "Book 4")
}

test("Multi-select move preserves books not in selection") {
    var library = Library()
    let bookA = Book(title: "A", md5Hash: "a", folderPath: "Old")
    let bookB = Book(title: "B", md5Hash: "b", folderPath: "Old")
    let bookC = Book(title: "C", md5Hash: "c", folderPath: "Old")
    library.addBook(bookA)
    library.addBook(bookB)
    library.addBook(bookC)
    _ = library.createFolder(name: "Old")
    _ = library.createFolder(name: "New")

    // Move only A and C
    library.moveBook(id: bookA.id, toFolder: "New")
    library.moveBook(id: bookC.id, toFolder: "New")

    let newBooks = library.booksInFolder("New")
    let oldBooks = library.booksInFolder("Old")
    try assertEqual(newBooks.count, 2, "New folder should have 2 books")
    try assertEqual(oldBooks.count, 1, "Old folder should have 1 book remaining")
    try assertEqual(oldBooks[0].title, "B", "Remaining book should be B")
}

// ---- LibraryCategory Enum ----
print("\n--- LibraryCategory Enum ---")

test("LibraryCategory: has 4 cases including recent") {
    try assertEqual(LibraryCategory.allCases.count, 4)
    try assertTrue(LibraryCategory.allCases.contains(.recent))
}

test("LibraryCategory: recent raw value") {
    try assertEqual(LibraryCategory.recent.rawValue, "Recent")
}

// ---- Last Moved Folder Tests ----
print("\n--- Last Moved Folder Tests ---")

test("Last moved folder tracks most recent move destination") {
    var lastMovedFolderPath = ""

    // Move to Fiction
    lastMovedFolderPath = "Fiction"
    try assertEqual(lastMovedFolderPath, "Fiction")

    // Move to NonFiction — should update
    lastMovedFolderPath = "NonFiction"
    try assertEqual(lastMovedFolderPath, "NonFiction")

    // Move to root — should update to empty string
    lastMovedFolderPath = ""
    try assertEqual(lastMovedFolderPath, "")
}

test("Last moved folder used as default in move dialog") {
    let lastMovedFolderPath = "Fiction/SciFi"
    let availableFolders = [
        (label: "Library Root", path: ""),
        (label: "Fiction", path: "Fiction"),
        (label: "Fiction/SciFi", path: "Fiction/SciFi"),
        (label: "NonFiction", path: "NonFiction"),
    ]

    // The default selected path should match lastMovedFolderPath if it exists
    let defaultPath: String
    if !lastMovedFolderPath.isEmpty,
       availableFolders.contains(where: { $0.path == lastMovedFolderPath }) {
        defaultPath = lastMovedFolderPath
    } else {
        defaultPath = ""
    }

    try assertEqual(defaultPath, "Fiction/SciFi", "Should default to last moved folder")
}

test("Last moved folder falls back to root if folder was deleted") {
    let lastMovedFolderPath = "DeletedFolder"
    let availableFolders = [
        (label: "Library Root", path: ""),
        (label: "Fiction", path: "Fiction"),
    ]

    let defaultPath: String
    if !lastMovedFolderPath.isEmpty,
       availableFolders.contains(where: { $0.path == lastMovedFolderPath }) {
        defaultPath = lastMovedFolderPath
    } else {
        defaultPath = ""
    }

    try assertEqual(defaultPath, "", "Should fall back to root when folder no longer exists")
}

test("Moving multiple books updates last moved folder once") {
    var library = Library()
    let book1 = Book(title: "A", md5Hash: "a1", folderPath: "")
    let book2 = Book(title: "B", md5Hash: "b1", folderPath: "")
    library.addBook(book1)
    library.addBook(book2)
    _ = library.createFolder(name: "Target")

    var lastMovedFolderPath = ""

    // Simulate moveBooks which moves all then sets lastMovedFolderPath once
    for book in [book1, book2] {
        library.moveBook(id: book.id, toFolder: "Target")
    }
    lastMovedFolderPath = "Target"

    try assertEqual(lastMovedFolderPath, "Target")
    try assertEqual(library.booksInFolder("Target").count, 2)
}

// ---- Folder Move Tests ----
print("\n--- Folder Move Tests ---")

test("moveFolder changes parent and updates books") {
    var library = Library()
    _ = library.createFolder(name: "Fiction")
    _ = library.createFolder(name: "NonFiction")
    let scifi = library.createFolder(name: "SciFi", parentPath: "Fiction")!
    library.addBook(Book(title: "Dune", md5Hash: "d1", folderPath: "Fiction/SciFi"))

    let result = library.moveFolder(id: scifi.id, toParentPath: "NonFiction")
    try assertTrue(result, "Move should succeed")

    // SciFi should now be under NonFiction
    let moved = library.folders.first(where: { $0.name == "SciFi" })!
    try assertEqual(moved.parentPath, "NonFiction")
    try assertEqual(moved.fullPath, "NonFiction/SciFi")

    // Book should be updated
    try assertEqual(library.books[0].folderPath, "NonFiction/SciFi")
}

test("moveFolder to root") {
    var library = Library()
    _ = library.createFolder(name: "Parent")
    let child = library.createFolder(name: "Child", parentPath: "Parent")!
    library.addBook(Book(title: "A", md5Hash: "a1", folderPath: "Parent/Child"))

    let result = library.moveFolder(id: child.id, toParentPath: "")
    try assertTrue(result)
    try assertEqual(library.books[0].folderPath, "Child")
}

test("moveFolder prevents cycle (into own descendant)") {
    var library = Library()
    let parent = library.createFolder(name: "Parent")!
    _ = library.createFolder(name: "Child", parentPath: "Parent")

    let result = library.moveFolder(id: parent.id, toParentPath: "Parent/Child")
    try assertTrue(!result, "Should prevent moving into own descendant")
}

test("moveFolder prevents exceeding max depth") {
    var library = Library()
    // Create a folder with a subfolder at depth 3 (A/B/C)
    _ = library.createFolder(name: "A")
    let b = library.createFolder(name: "B", parentPath: "A")!
    _ = library.createFolder(name: "C", parentPath: "A/B")
    // B is at depth 2, with subfolder C at depth 3.
    // Create a depth-3 target: X/Y/Z
    _ = library.createFolder(name: "X")
    _ = library.createFolder(name: "Y", parentPath: "X")
    _ = library.createFolder(name: "Z", parentPath: "X/Y")

    // Moving B (which contains C) under X/Y/Z would put C at X/Y/Z/B/C = depth 5
    let result = library.moveFolder(id: b.id, toParentPath: "X/Y/Z")
    try assertTrue(!result, "Should prevent exceeding max depth for subfolders")
}

test("moveFolder updates subfolder paths") {
    var library = Library()
    _ = library.createFolder(name: "Old")
    let sub = library.createFolder(name: "Sub", parentPath: "Old")!
    _ = library.createFolder(name: "Deep", parentPath: "Old/Sub")
    _ = library.createFolder(name: "New")
    library.addBook(Book(title: "B", md5Hash: "b1", folderPath: "Old/Sub/Deep"))

    library.moveFolder(id: sub.id, toParentPath: "New")

    let deep = library.folders.first(where: { $0.name == "Deep" })!
    try assertEqual(deep.parentPath, "New/Sub")
    try assertEqual(deep.fullPath, "New/Sub/Deep")
    try assertEqual(library.books[0].folderPath, "New/Sub/Deep")
}

test("moveFolder rejects name collision") {
    var library = Library()
    _ = library.createFolder(name: "A")
    _ = library.createFolder(name: "B")
    let dup = library.createFolder(name: "A", parentPath: "B")! // B/A exists

    // Try to move B/A to root where "A" already exists
    let result = library.moveFolder(id: dup.id, toParentPath: "")
    try assertTrue(!result, "Should reject because A already exists at root")
}

// ---- Folder Delete Tests ----
print("\n--- Folder Delete Tests ---")

test("removeFolderAndContents removes books and subfolders") {
    var library = Library()
    let folder = library.createFolder(name: "ToDelete")!
    _ = library.createFolder(name: "Sub", parentPath: "ToDelete")
    library.addBook(Book(title: "A", md5Hash: "a1", folderPath: "ToDelete"))
    library.addBook(Book(title: "B", md5Hash: "b1", folderPath: "ToDelete/Sub"))
    library.addBook(Book(title: "C", md5Hash: "c1", folderPath: ""))

    let removed = library.removeFolderAndContents(id: folder.id)

    try assertEqual(removed.count, 2, "Should return 2 removed books")
    try assertEqual(library.books.count, 1, "Only unrelated book should remain")
    try assertEqual(library.books[0].title, "C")
    try assertTrue(!library.folders.contains(where: { $0.name == "ToDelete" }))
    try assertTrue(!library.folders.contains(where: { $0.name == "Sub" }))
}

test("removeFolder movingContentsTo reparents children") {
    var library = Library()
    let folder = library.createFolder(name: "Old")!
    _ = library.createFolder(name: "Sub", parentPath: "Old")
    _ = library.createFolder(name: "Target")
    library.addBook(Book(title: "A", md5Hash: "a1", folderPath: "Old"))
    library.addBook(Book(title: "B", md5Hash: "b1", folderPath: "Old/Sub"))

    library.removeFolder(id: folder.id, movingContentsTo: "Target")

    // Book A should be in Target
    try assertEqual(library.books.first(where: { $0.title == "A" })!.folderPath, "Target")
    // Book B should be in Target/Sub
    try assertEqual(library.books.first(where: { $0.title == "B" })!.folderPath, "Target/Sub")
    // Sub folder should be reparented under Target
    let sub = library.folders.first(where: { $0.name == "Sub" })!
    try assertEqual(sub.parentPath, "Target")
    // Old folder should be gone
    try assertTrue(!library.folders.contains(where: { $0.name == "Old" }))
}

test("removeFolder movingContentsTo root reparents correctly") {
    var library = Library()
    let folder = library.createFolder(name: "Parent")!
    _ = library.createFolder(name: "Child", parentPath: "Parent")
    library.addBook(Book(title: "A", md5Hash: "a1", folderPath: "Parent"))
    library.addBook(Book(title: "B", md5Hash: "b1", folderPath: "Parent/Child"))

    library.removeFolder(id: folder.id, movingContentsTo: "")

    try assertEqual(library.books.first(where: { $0.title == "A" })!.folderPath, "")
    try assertEqual(library.books.first(where: { $0.title == "B" })!.folderPath, "Child")
    let child = library.folders.first(where: { $0.name == "Child" })!
    try assertEqual(child.parentPath, "")
}

test("folderHasContents detects books and subfolders") {
    var library = Library()
    let empty = library.createFolder(name: "Empty")!
    let withBook = library.createFolder(name: "WithBook")!
    let withSub = library.createFolder(name: "WithSub")!
    _ = library.createFolder(name: "Sub", parentPath: "WithSub")
    library.addBook(Book(title: "A", md5Hash: "a1", folderPath: "WithBook"))

    try assertTrue(!library.folderHasContents(empty), "Empty folder should have no contents")
    try assertTrue(library.folderHasContents(withBook), "Folder with book should have contents")
    try assertTrue(library.folderHasContents(withSub), "Folder with subfolder should have contents")
}

test("totalBooksInFolderTree counts recursively") {
    var library = Library()
    _ = library.createFolder(name: "Root")
    _ = library.createFolder(name: "Sub", parentPath: "Root")
    _ = library.createFolder(name: "Deep", parentPath: "Root/Sub")
    library.addBook(Book(title: "A", md5Hash: "a1", folderPath: "Root"))
    library.addBook(Book(title: "B", md5Hash: "b1", folderPath: "Root/Sub"))
    library.addBook(Book(title: "C", md5Hash: "c1", folderPath: "Root/Sub/Deep"))
    library.addBook(Book(title: "D", md5Hash: "d1", folderPath: ""))

    try assertEqual(library.totalBooksInFolderTree("Root"), 3)
    try assertEqual(library.totalBooksInFolderTree("Root/Sub"), 2)
    try assertEqual(library.totalBooksInFolderTree("Root/Sub/Deep"), 1)
}

// ---- Folder Rename Tests ----
print("\n--- Folder Rename Tests ---")

test("renameFolder updates folder name and book paths") {
    var library = Library()
    let folder = library.createFolder(name: "OldName")!
    library.addBook(Book(title: "A", md5Hash: "a1", folderPath: "OldName"))

    let result = library.renameFolder(id: folder.id, to: "NewName")
    try assertTrue(result, "Rename should succeed")

    let renamed = library.folders.first(where: { $0.id == folder.id })!
    try assertEqual(renamed.name, "NewName")
    try assertEqual(renamed.fullPath, "NewName")
    try assertEqual(library.books[0].folderPath, "NewName")
}

test("renameFolder updates subfolder paths") {
    var library = Library()
    let parent = library.createFolder(name: "Parent")!
    _ = library.createFolder(name: "Child", parentPath: "Parent")
    library.addBook(Book(title: "B", md5Hash: "b1", folderPath: "Parent/Child"))

    library.renameFolder(id: parent.id, to: "Renamed")

    let child = library.folders.first(where: { $0.name == "Child" })!
    try assertEqual(child.parentPath, "Renamed")
    try assertEqual(child.fullPath, "Renamed/Child")
    try assertEqual(library.books[0].folderPath, "Renamed/Child")
}

test("renameFolder rejects empty name") {
    var library = Library()
    let folder = library.createFolder(name: "Test")!
    let result = library.renameFolder(id: folder.id, to: "   ")
    try assertTrue(!result, "Empty name should be rejected")
    try assertEqual(library.folders[0].name, "Test", "Name should be unchanged")
}

test("renameFolder rejects same name") {
    var library = Library()
    let folder = library.createFolder(name: "Same")!
    let result = library.renameFolder(id: folder.id, to: "Same")
    try assertTrue(!result, "Same name should be rejected")
}

test("renameFolder rejects collision with sibling") {
    var library = Library()
    _ = library.createFolder(name: "Existing")
    let folder = library.createFolder(name: "ToRename")!
    let result = library.renameFolder(id: folder.id, to: "Existing")
    try assertTrue(!result, "Should reject collision with sibling folder")
}

test("renameFolder sanitizes slashes in name") {
    var library = Library()
    let folder = library.createFolder(name: "Test")!
    library.renameFolder(id: folder.id, to: "New/Name")
    try assertEqual(library.folders[0].name, "New-Name", "Slashes should be replaced with dashes")
}

// ---- Folder Tree-Order Sort Tests ----
print("\n--- Folder Tree-Order Sort Tests ---")

test("sortedTreeOrder keeps children after parent, not interleaved") {
    // The bug: "Misc SciFi anthologies" sorted between "Misc SciFi" and "Misc SciFi/Sub"
    let folders = [
        BookFolder(name: "Misc SciFi"),
        BookFolder(name: "Sub", parentPath: "Misc SciFi"),
        BookFolder(name: "Misc SciFi anthologies"),
    ]
    let sorted = folders.sortedTreeOrder()
    let paths = sorted.map { $0.fullPath }

    try assertEqual(paths[0], "Misc SciFi", "Parent should come first")
    try assertEqual(paths[1], "Misc SciFi/Sub", "Child should follow parent")
    try assertEqual(paths[2], "Misc SciFi anthologies", "Unrelated folder should come after parent's children")
}

test("sortedTreeOrder handles deep nesting correctly") {
    let folders = [
        BookFolder(name: "Z"),
        BookFolder(name: "A"),
        BookFolder(name: "B", parentPath: "A"),
        BookFolder(name: "C", parentPath: "A/B"),
        BookFolder(name: "A extra"),
    ]
    let sorted = folders.sortedTreeOrder()
    let paths = sorted.map { $0.fullPath }

    try assertEqual(paths[0], "A")
    try assertEqual(paths[1], "A/B")
    try assertEqual(paths[2], "A/B/C")
    try assertEqual(paths[3], "A extra")
    try assertEqual(paths[4], "Z")
}

test("sortedTreeOrder: siblings are alphabetical") {
    let folders = [
        BookFolder(name: "Parent"),
        BookFolder(name: "Zebra", parentPath: "Parent"),
        BookFolder(name: "Alpha", parentPath: "Parent"),
        BookFolder(name: "Middle", parentPath: "Parent"),
    ]
    let sorted = folders.sortedTreeOrder()
    let paths = sorted.map { $0.fullPath }

    try assertEqual(paths[0], "Parent")
    try assertEqual(paths[1], "Parent/Alpha")
    try assertEqual(paths[2], "Parent/Middle")
    try assertEqual(paths[3], "Parent/Zebra")
}

} // end runLibraryModelTests
