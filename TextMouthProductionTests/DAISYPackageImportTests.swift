import XCTest
@testable import TextMouth

/// A DAISY book kept as loose files imports with every file it needs, laid
/// out in its package as in its folder, so it reads in full after its
/// folder is gone (TODO I02). It is known by its package's checksum, so a
/// second import of it is a duplicate, and its folder is never deleted.
/// Each test imports into a library folder of its own and puts the library
/// index back afterwards.
final class DAISYPackageImportTests: XCTestCase {
    private typealias Fixtures = DAISYPackageFixtures

    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox!
    /// The library folder this test imports into.
    private var folderPath: String!
    /// Where this test's DAISY books are written, outside the library.
    private var sources: URL!

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        folderPath = "DAISY Package Import \(UUID().uuidString.prefix(8))"
        sources = try makeSandboxDirectory("daisy-package-sources")
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
        if let folderPath {
            try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
        }
    }

    // MARK: - Loose Books

    /// A DAISY 3 book chosen by its package file imports with every file
    /// its manifest lists, laid out as in its folder, and nothing else from
    /// beside it. With its folder deleted, it reads every section from the
    /// copied files, as the reader reads it.
    func testLoosePackageFileReadsInFullAfterItsFolderIsGone() throws {
        let folder = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.packageBook, changing: Fixtures.unrelatedFiles),
            named: "Ferry Timetables",
            in: sources
        )
        let source = folder.appendingPathComponent("book.opf")

        let imported = try FileImportService.importFileWithReport(from: source, toFolder: folderPath)
        try FileManager.default.removeItem(at: folder)

        let book = imported.book
        XCTAssertEqual(book.title, "Ferry Timetables of the Outer Sound")
        XCTAssertEqual(book.author, "Ottilie Vandermeer")
        XCTAssertEqual(book.format, .daisy)
        XCTAssertEqual(book.filePath, book.tmbDirectory.appendingPathComponent("book.opf").path)
        XCTAssertEqual(book.sourceFilePath, source.path)
        XCTAssertTrue(imported.isFromPackageFolder)
        XCTAssertFalse(imported.mayDeleteOriginal)
        XCTAssertEqual(try bookFiles(of: book), Fixtures.packageBookFiles)
        try assertReadsInFull(book, sentences: Fixtures.packageBookSentences, headings: Fixtures.packageBookHeadings)
    }

    /// A DAISY 2.02 book chosen by its folder imports with its navigation
    /// file, the SMIL, text, and audio files it leads to, and the style
    /// sheets and images those use, laid out as in its folder. With the
    /// folder deleted, it reads every section.
    func testNavigationFolderReadsInFullAfterItIsGone() throws {
        let folder = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.navigationBook, changing: Fixtures.unrelatedFiles),
            named: "Rope Splicing",
            in: sources
        )

        let imported = try FileImportService.importFileWithReport(from: folder, toFolder: folderPath)
        try FileManager.default.removeItem(at: folder)

        let book = imported.book
        XCTAssertEqual(book.title, "Notes on Rope Splicing")
        XCTAssertEqual(book.author, "Casimir Oyelaran")
        XCTAssertEqual(book.format, .daisy)
        XCTAssertEqual(book.filePath, book.tmbDirectory.appendingPathComponent("ncc.html").path)
        XCTAssertEqual(book.sourceFilePath, folder.path)
        XCTAssertTrue(imported.isFromPackageFolder)
        XCTAssertEqual(try bookFiles(of: book), Fixtures.navigationBookFiles)
        try assertReadsInFull(book, sentences: Fixtures.navigationBookSentences, headings: Fixtures.navigationBookHeadings)
    }

    /// The same kind of book chosen by its ncc.html imports the same files.
    /// When its navigation names no title, it is listed under its folder's
    /// name, since every navigation file is called ncc.
    func testNavigationFileImportsItsBookUnderTheFoldersNameWhenUntitled() throws {
        let untitled = Fixtures.navigationBook["ncc.html", default: ""]
            .replacingOccurrences(of: "<title>Notes on Rope Splicing</title>", with: "")
            .replacingOccurrences(of: "<meta name=\"dc:title\" content=\"Notes on Rope Splicing\"/>", with: "")
        let folder = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.navigationBook, changing: ["ncc.html": untitled]),
            named: "Splicing Lessons",
            in: sources
        )

        let book = try FileImportService.importFileWithReport(
            from: folder.appendingPathComponent("ncc.html"),
            toFolder: folderPath
        ).book

        XCTAssertEqual(book.title, "Splicing Lessons")
        XCTAssertEqual(book.author, "Casimir Oyelaran")
        XCTAssertEqual(try bookFiles(of: book), Fixtures.navigationBookFiles)
    }

    // MARK: - Failures

    /// A manifest entry leading out of the book's folder fails the import
    /// while the file is read, naming the entry and the file making it.
    /// Nothing is left in the library folder, and the file outside is
    /// neither copied nor changed.
    func testReferenceLeavingTheFolderFailsTheImportByName() throws {
        let shared = sources.appendingPathComponent("shared.xml")
        try Data("a file outside the book".utf8).write(to: shared)
        let opf = Fixtures.packageBook["book.opf", default: ""]
            .replacingOccurrences(of: "images/harbor%20map.png", with: "../shared.xml")
        let folder = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.packageBook, changing: ["book.opf": opf]),
            named: "Ferry Timetables",
            in: sources
        )

        XCTAssertThrowsError(
            try FileImportService.importFileWithReport(from: folder.appendingPathComponent("book.opf"), toFolder: folderPath)
        ) { error in
            let failure = error as? ImportFailure
            XCTAssertEqual(failure?.step, .readingSource)
            XCTAssertEqual(
                failure?.underlying as? DAISYPackageError,
                .referenceOutsidePackage(reference: "../shared.xml", file: "book.opf")
            )
            XCTAssertEqual(
                failure?.localizedDescription,
                "Could not import “book.opf”. Reading the file failed: The file “book.opf” in this DAISY book "
                    + "refers to “../shared.xml”, which is outside the book's folder. Only files inside the folder can be imported."
            )
        }
        XCTAssertEqual(try folderEntries(), [])
        XCTAssertEqual(try String(contentsOf: shared, encoding: .utf8), "a file outside the book")
    }

    /// A folder that holds no DAISY book fails while its format is checked,
    /// saying in words what is wrong, and leaves nothing behind.
    func testFolderWithoutABookFailsSayingSo() throws {
        let folder = try Fixtures.writeFolder(["notes.txt": "Nothing to read here."], named: "Harbor Notes", in: sources)

        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: folder, toFolder: folderPath)) { error in
            XCTAssertEqual((error as? ImportFailure)?.step, .checkingFormat)
            XCTAssertEqual(
                error.localizedDescription,
                "Could not import “Harbor Notes”. Checking its format failed: The folder is not a DAISY book: "
                    + "it has no ncc.html or .opf file at its top level."
            )
        }
        XCTAssertEqual(try folderEntries(), [])
    }

    // MARK: - Duplicates

    /// The same book imported again, here from a copy of its folder
    /// elsewhere, has the same checksum: its package's, which
    /// `importHash(of:)` computes before anything is copied. The library
    /// recognizes it as a duplicate and asks, and never offers to delete
    /// the book's folder.
    @MainActor
    func testReimportingThePackageIsRecognizedAsADuplicate() throws {
        let folder = try Fixtures.writeFolder(Fixtures.navigationBook, named: "Rope Splicing", in: sources)
        let copy = try Fixtures.writeFolder(
            Fixtures.navigationBook,
            named: "Rope Splicing",
            in: sources.appendingPathComponent("Downloads", isDirectory: true)
        )

        let first = try FileImportService.importFileWithReport(from: folder, toFolder: folderPath)
        let second = try FileImportService.importFileWithReport(
            from: copy.appendingPathComponent("ncc.html"),
            toFolder: folderPath
        )

        XCTAssertEqual(first.book.md5Hash, try DAISYPackageInventory.make(for: folder).contentHash())
        XCTAssertEqual(try FileImportService.importHash(of: folder), first.book.md5Hash)
        XCTAssertEqual(second.book.md5Hash, first.book.md5Hash)
        XCTAssertNotEqual(second.book.sourceFilePath, first.book.sourceFilePath)

        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [first.book])
        model.completeSingleImportedBook(second, originalURL: copy.appendingPathComponent("ncc.html"))

        XCTAssertTrue(model.showDuplicateDialog)
        XCTAssertEqual(model.pendingDuplicateExisting?.id, first.book.id)
        XCTAssertEqual(model.pendingDuplicateBook?.id, second.book.id)
        XCTAssertNil(model.pendingDuplicateOriginalURL)
    }

    /// Any other source's import checksum is the MD5 of its file, as before.
    func testImportHashOfASingleFileIsItsMD5() throws {
        let epub = try requireFile("alice.epub")

        XCTAssertEqual(try FileImportService.importHash(of: epub), try FileImportService.md5Hash(of: epub))
    }

    // MARK: - The Original

    /// A DAISY book's folder is never deleted after its import, nor offered
    /// for deletion, whatever the "After Importing a Book" preference says:
    /// it holds files that are not the book's.
    @MainActor
    func testPackageImportNeverDeletesOrOffersToDeleteItsFolder() throws {
        let packageFolder = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.packageBook, changing: Fixtures.unrelatedFiles),
            named: "Ferry Timetables",
            in: sources
        )
        let navigationFolder = try Fixtures.writeFolder(Fixtures.navigationBook, named: "Rope Splicing", in: sources)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()

        for (folder, original, behavior) in [
            (packageFolder, packageFolder.appendingPathComponent("book.opf"), ImportDeleteBehavior.deleteAfterImport),
            (navigationFolder, navigationFolder, ImportDeleteBehavior.askEachTime)
        ] {
            let imported = try FileImportService.importFileWithReport(from: original, toFolder: folderPath)
            withImportDeleteBehavior(behavior) {
                model.completeSingleImportedBook(imported, originalURL: original)
            }

            XCTAssertTrue(model.library.books.contains { $0.id == imported.book.id }, folder.lastPathComponent)
            XCTAssertFalse(model.showDeleteOriginalDialog, folder.lastPathComponent)
            XCTAssertNil(model.pendingOriginalURL, folder.lastPathComponent)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), folder.lastPathComponent)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageFolder.appendingPathComponent("notes.txt").path))
    }

    // MARK: - What Is Copied Instead

    /// A DAISY 3 book whose manifest names no DTBook is copied whole, since
    /// the reader searches its folder for one, and it still reads in full;
    /// the debug log says the whole folder was copied, and why.
    func testBookCopiedWholeReadsInFullAndIsLogged() throws {
        let opf = Fixtures.packageBook["book.opf", default: ""]
            .replacingOccurrences(of: "application/x-dtbook+xml", with: "text/xml")
        let files = Fixtures.files(Fixtures.packageBook, changing: Fixtures.unrelatedFiles.merging(["book.opf": opf]) { _, new in new })
        let folder = try Fixtures.writeFolder(files, named: "Ferry Timetables Whole", in: sources)

        let book = try FileImportService.importFileWithReport(from: folder, toFolder: folderPath).book

        XCTAssertEqual(try bookFiles(of: book), files.keys.filter { !$0.hasPrefix(".") }.sorted())
        try assertReadsInFull(book, sentences: Fixtures.packageBookSentences, headings: Fixtures.packageBookHeadings)
        let logged = debugLogLines(containing: "DAISY_PACKAGE_WHOLE_FOLDER: \(folder.path): ")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged.first?.contains("lists no DTBook content file") == true, logged.first ?? "")
    }

    /// A book referring to a file that does not exist still imports, as it
    /// read before, and the debug log names the missing file.
    func testMissingFileIsLoggedByNameAndTheBookStillImports() throws {
        let folder = try Fixtures.writeFolder(
            Fixtures.files(Fixtures.navigationBook, removing: ["images/eye splice.png"]),
            named: "Rope Splicing Without Pictures",
            in: sources
        )

        let book = try FileImportService.importFileWithReport(from: folder, toFolder: folderPath).book

        XCTAssertEqual(try bookFiles(of: book), Fixtures.navigationBookFiles.filter { $0 != "images/eye splice.png" })
        XCTAssertEqual(
            debugLogLines(containing: "DAISY_PACKAGE_MISSING: \(folder.appendingPathComponent("ncc.html").path): ").last
                .map { $0.hasSuffix("refers to 1 file(s) that do not exist: images/eye splice.png") },
            true
        )
    }

    // MARK: - Helpers

    /// Asserts that `book` reads each of `sentences` and `headings` from
    /// its own package: as the reader rebuilds its text cache from the
    /// copied files (the import's cache is removed first, so it cannot
    /// stand in for them), and straight from the files.
    private func assertReadsInFull(
        _ book: Book,
        sentences: [String],
        headings: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try FileManager.default.removeItem(at: TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory))
        let loaded = try BookContentAnalysisService.load(book: book).content
        let text = loaded.chapters.map(\.text).joined(separator: "\n\n")
        let loadedHeadings = loaded.chapters.flatMap(\.headings).map(\.text)
        let direct = try Fixtures.spokenText(of: DAISYParser.extractMarkdown(from: book.bookFileURL))

        for sentence in sentences {
            XCTAssertTrue(text.contains(sentence), "missing “\(sentence)” in:\n\(text)", file: file, line: line)
            XCTAssertTrue(direct.contains(sentence), "missing “\(sentence)” in:\n\(direct)", file: file, line: line)
        }
        for heading in headings {
            XCTAssertTrue(loadedHeadings.contains(heading), "missing heading “\(heading)” in \(loadedHeadings)", file: file, line: line)
        }
    }

    /// The paths of the book's own files in its package, in order, leaving
    /// out the files TextMouth keeps beside them; the record and the text
    /// cache must be among those.
    private func bookFiles(of book: Book) throws -> [String] {
        let package = book.tmbDirectory
        let entries = try XCTUnwrap(FileManager.default.enumerator(atPath: package.path))
        var files: [String] = []
        while let path = entries.nextObject() as? String {
            guard (entries.fileAttributes?[.type] as? FileAttributeType) != .typeDirectory else { continue }
            files.append(path)
        }
        XCTAssertTrue(files.contains("bookInfo.json"))
        XCTAssertTrue(files.contains("content.md"))
        return files.filter(DAISYPackageInventory.isBookPath).sorted()
    }

    /// Every name in this test's library folder, hidden ones included; none
    /// when the folder does not exist.
    private func folderEntries() throws -> Set<String> {
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// Runs `body` with the "After Importing a Book" preference set to
    /// `behavior`, restoring the previous preference afterwards.
    @MainActor
    private func withImportDeleteBehavior(_ behavior: ImportDeleteBehavior, _ body: () throws -> Void) rethrows {
        let config = ConfigService.shared
        let previous = config.config.importDeleteBehavior
        config.config.importDeleteBehavior = behavior
        defer { config.config.importDeleteBehavior = previous }
        try body()
    }
}
