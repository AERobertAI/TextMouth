import Foundation

/// Tests for the orphaned .tmb package adoption feature.
/// Verifies that .tmb directories on disk but not in library.json
/// are discovered, reconstructed from their bookInfo.json, and added
/// to the library.
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
        let adopted = adoptOrphanedTMBs(libraryDir: libraryDir, library: &library)

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

        let adopted = adoptOrphanedTMBs(libraryDir: libraryDir, library: &library)

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
        let adopted = adoptOrphanedTMBs(libraryDir: libraryDir, library: &library)

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
        let adopted = adoptOrphanedTMBs(libraryDir: libraryDir, library: &library)

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
        let adopted = adoptOrphanedTMBs(libraryDir: libraryDir, library: &library)

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
        let adopted = adoptOrphanedTMBs(libraryDir: libraryDir, library: &library)

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

        let adopted = adoptOrphanedTMBs(libraryDir: libraryDir, library: &library)

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
        let adopted = adoptOrphanedTMBs(libraryDir: libraryDir, library: &library)

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

        let adopted = adoptOrphanedTMBs(libraryDir: libraryDir, library: &library)

        // Only the truly new orphan should be adopted; Known is tracked, Dupe has same hash
        try assertEqual(adopted, 1, "Should adopt only the unique orphan")
        try assertEqual(library.books.count, 2, "Library now has 2 books")
        try assertTrue(library.books.contains(where: { $0.title == "Orphan" }),
                      "Orphan was adopted")
    }
}

// MARK: - Standalone adoption function (mirrors FileImportService.adoptOrphanedTMBPackages)
// This function duplicates the core logic for testing without depending on
// TextMouthPaths or other app-specific singletons.

/// Scan a library directory for .tmb packages not tracked in the library,
/// reconstruct Book objects from their bookInfo.json, and add them.
/// Returns the number of books adopted.
func adoptOrphanedTMBs(libraryDir: URL, library: inout Library) -> Int {
    let fm = FileManager.default
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    let knownTMBNames = Set(library.books.map { $0.tmbDirectoryName })

    var adopted = 0
    guard let enumerator = fm.enumerator(
        at: libraryDir,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return 0 }

    while let url = enumerator.nextObject() as? URL {
        guard url.pathExtension == "tmb",
              (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { continue }

        enumerator.skipDescendants()

        let tmbName = url.lastPathComponent
        if knownTMBNames.contains(tmbName) { continue }

        // Load bookInfo.json
        let infoPath = url.appendingPathComponent("bookInfo.json")
        guard let data = try? Data(contentsOf: infoPath),
              let info = try? decoder.decode(BookInfo.self, from: data)
        else { continue }

        // Find book file
        let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        let bookFileName = contents.first { name in
            !name.hasPrefix(".")
            && name != "bookInfo.json"
            && name != "content.md"
            && name != "cachedAudio"
        }
        guard let fileName = bookFileName else { continue }
        let bookFilePath = url.appendingPathComponent(fileName).path
        guard fm.fileExists(atPath: bookFilePath) else { continue }

        // Derive folder path from disk location.
        // Resolve symlinks so /tmp and /private/tmp match consistently.
        let resolvedLibrary = libraryDir.resolvingSymlinksInPath().path
        let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let relativePath = resolvedParent
            .replacingOccurrences(of: resolvedLibrary, with: "")
        let folderPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let book = Book(
            id: info.metadata.bookID,
            title: info.metadata.title,
            author: info.metadata.author,
            format: info.metadata.format,
            filePath: bookFilePath,
            md5Hash: info.metadata.md5Hash,
            folderPath: folderPath,
            dateAdded: info.metadata.dateAdded,
            lastOpened: info.metadata.lastOpened,
            bookmarks: info.bookmarks,
            totalWordCount: info.state.totalWordCount,
            totalCharacterCount: info.state.totalCharacterCount,
            tmbDirectoryName: tmbName,
            sourceFilePath: info.metadata.sourceFilePath,
            localVoiceID: info.state.localVoiceID,
            localWPM: info.state.localWPM,
            localPitch: info.state.localPitch,
            skippedHeadingIDs: info.state.skippedHeadingIDs,
            localEndOfBookBehavior: info.state.localEndOfBookBehavior,
            manualSortOrder: info.state.manualSortOrder,
            audioDuration: info.state.audioDuration,
            audioAlbum: info.metadata.audioAlbum,
            audioGenre: info.metadata.audioGenre,
            audioYear: info.metadata.audioYear
        )

        let countBefore = library.books.count
        library.addBook(book)
        if library.books.count > countBefore {
            adopted += 1
        }
    }

    return adopted
}
