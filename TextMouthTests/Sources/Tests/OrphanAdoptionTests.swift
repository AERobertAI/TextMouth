import Foundation
@testable import TextMouth

/// Tests for the orphaned .tmb package adoption feature.
/// Verifies that .tmb directories on disk but not in library.json
/// are discovered, reconstructed from their bookInfo.json, and added
/// to the library.
@MainActor
func runOrphanAdoptionTests() {
    print("\n--- Orphan Adoption Tests ---")

    let fm = FileManager.default
    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Create a temporary directory to act as a library root
    func createTempLibrary() -> URL {
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("TextMouthOrphanTest-\(UUID().uuidString)")
            .appendingPathComponent("Library")
        try! fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Write a bookInfo.json into a .tmb directory with the given metadata
    func writeBookInfo(
        in tmbDir: URL,
        title: String,
        author: String,
        format: BookFormat = .epub,
        md5Hash: String,
        tmbName: String,
        folderPath: String = "",
        bookID: UUID = UUID()
    ) {
        let info = BookInfo(
            metadata: BookMetadata(
                title: title,
                author: author,
                format: format,
                md5Hash: md5Hash,
                dateAdded: Date(),
                originalFileName: "\(title).epub",
                folderPath: folderPath,
                bookID: bookID
            ),
            state: BookState(
                isNew: true,
                tmbDirectoryName: tmbName
            ),
            bookmarks: []
        )
        let data = try! encoder.encode(info)
        try! data.write(to: tmbDir.appendingPathComponent("bookInfo.json"))
    }

    /// Create a .tmb package with a dummy book file and bookInfo.json
    func createOrphanTMB(
        in libraryDir: URL,
        folderPath: String = "",
        tmbName: String,
        title: String,
        author: String,
        md5Hash: String,
        bookID: UUID = UUID()
    ) -> URL {
        let base: URL
        if folderPath.isEmpty {
            base = libraryDir
        } else {
            base = libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        }
        let tmbDir = base.appendingPathComponent(tmbName, isDirectory: true)
        try! fm.createDirectory(at: tmbDir, withIntermediateDirectories: true)

        // Create a dummy book file
        let bookFile = tmbDir.appendingPathComponent("\(title).epub")
        fm.createFile(atPath: bookFile.path, contents: Data("dummy epub data".utf8))

        // Write bookInfo.json
        writeBookInfo(
            in: tmbDir,
            title: title,
            author: author,
            md5Hash: md5Hash,
            tmbName: tmbName,
            folderPath: folderPath,
            bookID: bookID
        )

        return tmbDir
    }

    // ---- Tests ----

    test("Adopts single orphaned .tmb at library root") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        let tmbName = "Orphan_Book-Some_Writer-12345.tmb"
        _ = createOrphanTMB(
            in: libraryDir,
            tmbName: tmbName,
            title: "Orphan Book",
            author: "Some Writer",
            md5Hash: "abc123"
        )

        // Start with an empty library
        var library = Library()
        try assertEqual(library.books.count, 0, "Library starts empty")

        // Run adoption using the standalone function
        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: libraryDir)

        try assertEqual(adopted, 1, "Should adopt 1 orphan")
        try assertEqual(library.books.count, 1, "Library should have 1 book")
        try assertEqual(library.books[0].title, "Orphan Book", "Title matches")
        try assertEqual(library.books[0].author, "Some Writer", "Author matches")
        try assertEqual(library.books[0].tmbDirectoryName, tmbName, "TMB name matches")
    }

    test("Skips .tmb already tracked in library") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        let tmbName = "Known_Book-Known_Author-12345.tmb"
        _ = createOrphanTMB(
            in: libraryDir,
            tmbName: tmbName,
            title: "Known Book",
            author: "Known Author",
            md5Hash: "known123"
        )

        // Library already has this book
        var library = Library(books: [
            Book(
                title: "Known Book",
                author: "Known Author",
                format: .epub,
                filePath: "/some/path.epub",
                md5Hash: "known123",
                tmbDirectoryName: tmbName
            )
        ])

        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: libraryDir)

        try assertEqual(adopted, 0, "Should not adopt already-known book")
        try assertEqual(library.books.count, 1, "Library still has 1 book")
    }

    test("Adopts orphan in subfolder with correct folderPath") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        let tmbName = "Nested_Book-Nested_Author-12345.tmb"
        _ = createOrphanTMB(
            in: libraryDir,
            folderPath: "Science Fiction/Space Opera",
            tmbName: tmbName,
            title: "Nested Book",
            author: "Nested Author",
            md5Hash: "nested123"
        )

        var library = Library()
        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: libraryDir)

        try assertEqual(adopted, 1, "Should adopt nested orphan")
        try assertEqual(library.books[0].folderPath, "Science Fiction/Space Opera",
                       "Folder path derived from disk location")
    }

    test("Adopts multiple orphans across different folders") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        _ = createOrphanTMB(
            in: libraryDir,
            tmbName: "Book_A-Writer_A-11111.tmb",
            title: "Book A",
            author: "Writer A",
            md5Hash: "hashA"
        )
        _ = createOrphanTMB(
            in: libraryDir,
            folderPath: "Fantasy",
            tmbName: "Book_B-Writer_B-22222.tmb",
            title: "Book B",
            author: "Writer B",
            md5Hash: "hashB"
        )
        _ = createOrphanTMB(
            in: libraryDir,
            folderPath: "Fantasy/Epic",
            tmbName: "Book_C-Writer_C-33333.tmb",
            title: "Book C",
            author: "Writer C",
            md5Hash: "hashC"
        )

        var library = Library()
        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: libraryDir)

        try assertEqual(adopted, 3, "Should adopt all 3 orphans")
        try assertEqual(library.books.count, 3, "Library has 3 books")

        // Verify each book's folder path
        let titles = Set(library.books.map { $0.title })
        try assertTrue(titles.contains("Book A"), "Book A adopted")
        try assertTrue(titles.contains("Book B"), "Book B adopted")
        try assertTrue(titles.contains("Book C"), "Book C adopted")
    }

    test("Skips .tmb without bookInfo.json") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        // Create a .tmb with only a book file, no bookInfo.json
        let tmbDir = libraryDir.appendingPathComponent("No_Info-Unknown-12345.tmb", isDirectory: true)
        try! fm.createDirectory(at: tmbDir, withIntermediateDirectories: true)
        let bookFile = tmbDir.appendingPathComponent("book.epub")
        fm.createFile(atPath: bookFile.path, contents: Data("dummy".utf8))

        var library = Library()
        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: libraryDir)

        try assertEqual(adopted, 0, "Should skip .tmb without bookInfo.json")
        try assertEqual(library.books.count, 0, "Library still empty")
    }

    test("Skips .tmb without any book file") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        // Create a .tmb with only bookInfo.json, no actual book file
        let tmbDir = libraryDir.appendingPathComponent("Empty_Book-Unknown-12345.tmb", isDirectory: true)
        try! fm.createDirectory(at: tmbDir, withIntermediateDirectories: true)
        writeBookInfo(
            in: tmbDir,
            title: "Empty Book",
            author: "Unknown",
            md5Hash: "empty123",
            tmbName: "Empty_Book-Unknown-12345.tmb"
        )

        var library = Library()
        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: libraryDir)

        try assertEqual(adopted, 0, "Should skip .tmb with no book file")
    }

    test("Deduplicates by md5Hash during adoption") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        // Create an orphan with a hash that already exists in the library
        _ = createOrphanTMB(
            in: libraryDir,
            tmbName: "Dupe_Book-Dupe_Author-12345.tmb",
            title: "Dupe Book",
            author: "Dupe Author",
            md5Hash: "existingHash"
        )

        // Library already has a different book with the same hash
        var library = Library(books: [
            Book(
                title: "Original Book",
                author: "Original Author",
                format: .epub,
                filePath: "/path/to/original.epub",
                md5Hash: "existingHash",
                tmbDirectoryName: "Original_Book-Original_Author-99999.tmb"
            )
        ])

        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: libraryDir)

        try assertEqual(adopted, 0, "Should not adopt duplicate hash")
        try assertEqual(library.books.count, 1, "Library still has 1 book")
        try assertEqual(library.books[0].title, "Original Book", "Original book unchanged")
    }

    test("Preserves reading state from bookInfo.json") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        let tmbName = "Stateful_Book-Author-12345.tmb"
        let tmbDir = libraryDir.appendingPathComponent(tmbName, isDirectory: true)
        try! fm.createDirectory(at: tmbDir, withIntermediateDirectories: true)

        // Create book file
        let bookFile = tmbDir.appendingPathComponent("Stateful Book.epub")
        fm.createFile(atPath: bookFile.path, contents: Data("book data".utf8))

        // Write bookInfo with reading state data
        let bookID = UUID()
        let info = BookInfo(
            metadata: BookMetadata(
                title: "Stateful Book",
                author: "Author",
                format: .epub,
                md5Hash: "stateful123",
                dateAdded: Date(),
                originalFileName: "Stateful Book.epub",
                bookID: bookID
            ),
            state: BookState(
                totalWordCount: 50000,
                totalCharacterCount: 250000,
                isNew: false,
                tmbDirectoryName: tmbName,
                localVoiceID: "com.apple.voice.samantha"
            ),
            bookmarks: [
                Bookmark(number: 1, chapterIndex: 3, characterOffset: 1500, label: "Good part")
            ]
        )
        let data = try! encoder.encode(info)
        try! data.write(to: tmbDir.appendingPathComponent("bookInfo.json"))

        var library = Library()
        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: libraryDir)

        try assertEqual(adopted, 1, "Should adopt stateful orphan")
        let book = library.books[0]
        try assertEqual(book.totalWordCount, 50000, "Word count preserved")
        try assertEqual(book.totalCharacterCount, 250000, "Char count preserved")
        try assertEqual(book.localVoiceID, "com.apple.voice.samantha", "Voice ID preserved")
        try assertEqual(book.bookmarks.count, 1, "Bookmark preserved")
        try assertEqual(book.bookmarks[0].label, "Good part", "Bookmark label preserved")
    }

    test("Mixed scenario: known books, orphans, and duplicates") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        let knownTMB = "Known-Author-11111.tmb"
        let orphanTMB = "Orphan-Author-22222.tmb"
        let dupeTMB = "Dupe-Author-33333.tmb"

        // Create all three on disk
        _ = createOrphanTMB(in: libraryDir, tmbName: knownTMB, title: "Known",
                           author: "Author", md5Hash: "hash1")
        _ = createOrphanTMB(in: libraryDir, tmbName: orphanTMB, title: "Orphan",
                           author: "Author", md5Hash: "hash2")
        _ = createOrphanTMB(in: libraryDir, tmbName: dupeTMB, title: "Dupe",
                           author: "Author", md5Hash: "hash1") // same hash as Known

        // Library knows about the first one
        var library = Library(books: [
            Book(title: "Known", author: "Author", format: .epub,
                 filePath: libraryDir.appendingPathComponent(knownTMB)
                    .appendingPathComponent("Known.epub").path,
                 md5Hash: "hash1", tmbDirectoryName: knownTMB)
        ])

        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: libraryDir)

        // Only the truly new orphan should be adopted; Known is tracked, Dupe has same hash
        try assertEqual(adopted, 1, "Should adopt only the unique orphan")
        try assertEqual(library.books.count, 2, "Library now has 2 books")
        try assertTrue(library.books.contains(where: { $0.title == "Orphan" }),
                      "Orphan was adopted")
    }
}

// MARK: - Misplaced .tmb Relocation Tests

@MainActor
func runRelocationTests() {
    print("\n--- TMB Relocation Tests ---")

    let fm = FileManager.default

    /// Create a temporary directory to act as a library root
    func createTempLibrary() -> URL {
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("TextMouthRelocationTest-\(UUID().uuidString)")
            .appendingPathComponent("Library")
        try! fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Create a .tmb at a given location with a dummy book file
    func createTMB(in base: URL, tmbName: String, fileName: String) -> URL {
        let tmbDir = base.appendingPathComponent(tmbName, isDirectory: true)
        try! fm.createDirectory(at: tmbDir, withIntermediateDirectories: true)
        let bookFile = tmbDir.appendingPathComponent(fileName)
        fm.createFile(atPath: bookFile.path, contents: Data("dummy book data".utf8))
        return tmbDir
    }

    test("Moves .tmb from root to assigned folder") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        let tmbName = "Misplaced-Author-12345.tmb"
        let fileName = "Misplaced.epub"
        let rootTmb = createTMB(in: libraryDir, tmbName: tmbName, fileName: fileName)

        // Book says it belongs in "Science Fiction" but .tmb is at root
        var library = Library(books: [
            Book(title: "Misplaced", author: "Author", format: .epub,
                 filePath: rootTmb.appendingPathComponent(fileName).path,
                 md5Hash: "hash1", folderPath: "Science Fiction",
                 tmbDirectoryName: tmbName)
        ])

        let relocated = FileImportService.relocateMisplacedTMBPackages(library: &library, libraryDirectory: libraryDir)

        try assertEqual(relocated, 1, "Should relocate 1 book")

        // .tmb should now be in the subfolder
        let expectedDir = libraryDir
            .appendingPathComponent("Science Fiction", isDirectory: true)
            .appendingPathComponent(tmbName, isDirectory: true)
        try assertTrue(fm.fileExists(atPath: expectedDir.path), "TMB moved to subfolder")
        try assertTrue(!fm.fileExists(atPath: rootTmb.path), "TMB gone from root")

        // filePath should be updated
        let expectedFile = expectedDir.appendingPathComponent(fileName).path
        try assertEqual(library.books[0].filePath, expectedFile, "filePath updated")
    }

    test("Skips .tmb already in correct folder") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        let tmbName = "Correct-Author-12345.tmb"
        let fileName = "Correct.epub"
        let subDir = libraryDir.appendingPathComponent("Fantasy", isDirectory: true)
        try! fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        let tmbDir = createTMB(in: subDir, tmbName: tmbName, fileName: fileName)

        var library = Library(books: [
            Book(title: "Correct", author: "Author", format: .epub,
                 filePath: tmbDir.appendingPathComponent(fileName).path,
                 md5Hash: "hash1", folderPath: "Fantasy",
                 tmbDirectoryName: tmbName)
        ])

        let relocated = FileImportService.relocateMisplacedTMBPackages(library: &library, libraryDirectory: libraryDir)
        try assertEqual(relocated, 0, "Should not relocate already-correct book")
    }

    test("Skips books with no folder assignment") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        let tmbName = "RootBook-Author-12345.tmb"
        let fileName = "RootBook.epub"
        let tmbDir = createTMB(in: libraryDir, tmbName: tmbName, fileName: fileName)

        // folderPath is empty — book belongs at root
        var library = Library(books: [
            Book(title: "RootBook", author: "Author", format: .epub,
                 filePath: tmbDir.appendingPathComponent(fileName).path,
                 md5Hash: "hash1", folderPath: "",
                 tmbDirectoryName: tmbName)
        ])

        let relocated = FileImportService.relocateMisplacedTMBPackages(library: &library, libraryDirectory: libraryDir)
        try assertEqual(relocated, 0, "Should not move root-assigned book")
    }

    test("Relocates multiple books to different folders") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        let tmb1 = "Book_A-Author-11111.tmb"
        let tmb2 = "Book_B-Author-22222.tmb"
        let tmb3 = "Book_C-Author-33333.tmb"
        let rootA = createTMB(in: libraryDir, tmbName: tmb1, fileName: "A.epub")
        let rootB = createTMB(in: libraryDir, tmbName: tmb2, fileName: "B.epub")
        let rootC = createTMB(in: libraryDir, tmbName: tmb3, fileName: "C.epub")

        var library = Library(books: [
            Book(title: "A", author: "Author", format: .epub,
                 filePath: rootA.appendingPathComponent("A.epub").path,
                 md5Hash: "h1", folderPath: "SciFi",
                 tmbDirectoryName: tmb1),
            Book(title: "B", author: "Author", format: .epub,
                 filePath: rootB.appendingPathComponent("B.epub").path,
                 md5Hash: "h2", folderPath: "Fantasy",
                 tmbDirectoryName: tmb2),
            Book(title: "C", author: "Author", format: .epub,
                 filePath: rootC.appendingPathComponent("C.epub").path,
                 md5Hash: "h3", folderPath: "SciFi/Space Opera",
                 tmbDirectoryName: tmb3),
        ])

        let relocated = FileImportService.relocateMisplacedTMBPackages(library: &library, libraryDirectory: libraryDir)
        try assertEqual(relocated, 3, "Should relocate all 3")

        // Verify they all ended up in the right places
        for book in library.books {
            let expectedDir = libraryDir
                .appendingPathComponent(book.folderPath, isDirectory: true)
                .appendingPathComponent(book.tmbDirectoryName, isDirectory: true)
            try assertTrue(fm.fileExists(atPath: expectedDir.path),
                          "\(book.title) moved to \(book.folderPath)")
        }
    }
}

// MARK: - Empty Directory Cleanup Tests

@MainActor
func runEmptyDirectoryCleanupTests() {
    print("\n--- Empty Directory Cleanup Tests ---")

    let fm = FileManager.default

    func createTempLibrary() -> URL {
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("TextMouthCleanupTest-\(UUID().uuidString)")
            .appendingPathComponent("Library")
        try! fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    test("Removes empty directories not tracked as folders") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        // Create some empty directories (as if folders were removed from model but not disk)
        let emptyDir1 = libraryDir.appendingPathComponent("OldFolder", isDirectory: true)
        let emptyDir2 = libraryDir.appendingPathComponent("AnotherEmpty", isDirectory: true)
        try! fm.createDirectory(at: emptyDir1, withIntermediateDirectories: true)
        try! fm.createDirectory(at: emptyDir2, withIntermediateDirectories: true)

        // Library has no folders
        let library = Library()
        FileImportService.removeEmptyLibrarySubdirectories(library: library, libraryDirectory: libraryDir)

        try assertTrue(!fm.fileExists(atPath: emptyDir1.path), "Empty dir 1 removed")
        try assertTrue(!fm.fileExists(atPath: emptyDir2.path), "Empty dir 2 removed")
    }

    test("Keeps directories that are tracked as folders") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        let keepDir = libraryDir.appendingPathComponent("ActiveFolder", isDirectory: true)
        try! fm.createDirectory(at: keepDir, withIntermediateDirectories: true)

        // This folder IS tracked in the library
        let library = Library(folders: [BookFolder(name: "ActiveFolder")])
        FileImportService.removeEmptyLibrarySubdirectories(library: library, libraryDirectory: libraryDir)

        try assertTrue(fm.fileExists(atPath: keepDir.path), "Tracked folder preserved")
    }

    test("Keeps non-empty directories even if untracked") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        // Directory with a .tmb inside (not empty)
        let dirWithContent = libraryDir.appendingPathComponent("HasBooks", isDirectory: true)
        let tmbDir = dirWithContent.appendingPathComponent("Book-Author-12345.tmb", isDirectory: true)
        try! fm.createDirectory(at: tmbDir, withIntermediateDirectories: true)

        let library = Library()
        FileImportService.removeEmptyLibrarySubdirectories(library: library, libraryDirectory: libraryDir)

        try assertTrue(fm.fileExists(atPath: dirWithContent.path), "Non-empty dir preserved")
    }

    test("Does not remove .tmb directories") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        // An empty .tmb directory (unusual but should not be removed by cleanup)
        let emptyTmb = libraryDir.appendingPathComponent("Empty-Book-12345.tmb", isDirectory: true)
        try! fm.createDirectory(at: emptyTmb, withIntermediateDirectories: true)

        let library = Library()
        FileImportService.removeEmptyLibrarySubdirectories(library: library, libraryDirectory: libraryDir)

        try assertTrue(fm.fileExists(atPath: emptyTmb.path), "Empty .tmb not removed by cleanup")
    }

    test("Removes nested empty directories deepest-first") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        // Create nested empty dirs
        let nested = libraryDir.appendingPathComponent("A/B/C", isDirectory: true)
        try! fm.createDirectory(at: nested, withIntermediateDirectories: true)

        let library = Library()
        FileImportService.removeEmptyLibrarySubdirectories(library: library, libraryDirectory: libraryDir)

        // All should be removed since they're all empty (deepest first makes parents empty)
        try assertTrue(!fm.fileExists(atPath: nested.path), "Deepest dir removed")
        try assertTrue(!fm.fileExists(
            atPath: libraryDir.appendingPathComponent("A/B").path), "Middle dir removed")
        try assertTrue(!fm.fileExists(
            atPath: libraryDir.appendingPathComponent("A").path), "Top dir removed")
    }
}

// MARK: - Orphan Non-Re-Adoption Tests

@MainActor
func runOrphanNonReAdoptionTests() {
    print("\n--- Orphan Non-Re-Adoption Tests ---")

    let fm = FileManager.default

    func createTempLibrary() -> URL {
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("TextMouthNonReAdoptTest-\(UUID().uuidString)")
            .appendingPathComponent("Library")
        try! fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    test("Does not adopt .tmb without bookInfo.json (simulates library-only removal)") {
        let libraryDir = createTempLibrary()
        defer { try? fm.removeItem(at: libraryDir.deletingLastPathComponent()) }

        // Create a .tmb with a book file but NO bookInfo.json
        // (this is what happens when removeBooksFromLibraryOnly deletes bookInfo.json)
        let tmbDir = libraryDir.appendingPathComponent("Removed_Book-Author-12345.tmb", isDirectory: true)
        try! fm.createDirectory(at: tmbDir, withIntermediateDirectories: true)
        let bookFile = tmbDir.appendingPathComponent("Removed Book.epub")
        fm.createFile(atPath: bookFile.path, contents: Data("book data".utf8))

        var library = Library()
        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: libraryDir)

        try assertEqual(adopted, 0, "Should not adopt .tmb without bookInfo.json")
        try assertEqual(library.books.count, 0, "Library still empty")
        // But the .tmb itself should still be on disk
        try assertTrue(fm.fileExists(atPath: tmbDir.path), "TMB preserved on disk")
        try assertTrue(fm.fileExists(atPath: bookFile.path), "Book file preserved on disk")
    }
}
