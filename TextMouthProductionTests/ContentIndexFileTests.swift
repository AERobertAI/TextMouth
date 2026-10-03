import XCTest
@testable import TextMouth

/// A package keeps its content index in a file of its own, contentIndex.json,
/// beside bookInfo.json (PERF15), so the save a reader makes every 30
/// seconds writes about a kilobyte instead of the whole index. Records that
/// older versions of TextMouth wrote, with the index inside bookInfo.json,
/// still load with their index, and their first save moves it out; an older
/// version reading a record written since finds no index and builds one, as
/// for any book without one.
final class ContentIndexFileTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox!
    /// Folders this test created in the test root's library, removed after
    /// it with every package inside.
    private var createdDirectories: [URL] = []

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        createdDirectories = []
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when capturing failed in set-up.
        // Restoring flushes pending saves, so none lands in a removed folder.
        sandbox?.restore()
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Records an Older Version Wrote

    /// A package an older version wrote, with the index inside bookInfo.json,
    /// loads with that index after it is copied, as a library moved or
    /// restored from a backup is, and still holds no contentIndex.json:
    /// reading changes nothing.
    func testCopiedPackageOfTheOldFormatLoadsWithItsIndex() throws {
        let original = try makeOldFormatPackage(title: "Copied Almanac")
        let copy = try copyPackage(of: original.book)

        let loaded = try BookInfo.load(from: copy.tmbDirectory)

        XCTAssertEqual(loaded.contentIndex, original.index)
        XCTAssertEqual(loaded.metadata.title, "Copied Almanac")
        XCTAssertEqual(loaded.bookmarks, original.book.bookmarks)
        XCTAssertFalse(exists(TextMouthPaths.contentIndexPath(in: copy.tmbDirectory)))
    }

    /// The first save of a copied old-format package's book, a reading
    /// checkpoint here, moves its index into contentIndex.json and leaves
    /// bookInfo.json without it, keeping every other field and the analysis
    /// fields that describe the index, and numbering the record one higher.
    func testFirstSaveMovesTheIndexOutOfACopiedOldFormatRecord() throws {
        let original = try makeOldFormatPackage(title: "Migrated Almanac")
        var book = try copyPackage(of: original.book)
        let recordBefore = try BookInfo.load(from: book.tmbDirectory)

        book.readingPosition = ReadingPosition(chapterIndex: 1, characterOffset: 17)
        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()

        let indexFile = TextMouthPaths.contentIndexPath(in: book.tmbDirectory)
        XCTAssertTrue(exists(indexFile), "the index was not moved into its own file")
        XCTAssertNil(try recordKeys(of: book)["contentIndex"], "bookInfo.json still holds the index")
        let loaded = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(loaded.contentIndex, original.index)
        XCTAssertEqual(loaded.state.readingPosition?.characterOffset, 17)
        XCTAssertEqual(loaded.bookmarks, original.book.bookmarks)
        XCTAssertEqual(loaded.metadata.title, recordBefore.metadata.title)
        XCTAssertEqual(loaded.state.contentAnalysisFields, recordBefore.state.contentAnalysisFields)
        XCTAssertEqual(loaded.state.revision, (recordBefore.state.revision ?? 0) + 1)
    }

    /// An older version reads a record written now as one without an index:
    /// it decodes with the same keys it always required, every field intact,
    /// and its loader finds no index, so it builds the book's index once.
    func testAnOlderVersionReadsTheNewRecordAsOneWithoutAnIndex() throws {
        let original = try makeOldFormatPackage(title: "Read By An Older Version")
        LibraryPersistenceService.saveBookInfo(for: original.book)
        LibraryPersistenceService.flushPendingSave()

        // An older version decodes bookInfo.json alone, exactly as it was.
        let bytes = try Data(contentsOf: TextMouthPaths.bookInfoPath(in: original.book.tmbDirectory))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let asAnOlderVersionReadsIt = try decoder.decode(BookInfo.self, from: bytes)

        XCTAssertNil(asAnOlderVersionReadsIt.contentIndex)
        XCTAssertEqual(asAnOlderVersionReadsIt.metadata.bookID, original.book.id)
        XCTAssertEqual(asAnOlderVersionReadsIt.bookmarks, original.book.bookmarks)
        XCTAssertEqual(Set(try recordKeys(of: original.book).keys), ["metadata", "state", "bookmarks"])
    }

    /// When an older version writes its index into bookInfo.json again, as
    /// it does after building one for a record written here, that index wins
    /// over contentIndex.json, which it never saw, until the next save here
    /// moves it out, replacing the file.
    func testAnIndexAnOlderVersionWritesAgainWinsUntilTheNextSaveMovesIt() throws {
        let original = try makeOldFormatPackage(title: "Read Back And Forth")
        LibraryPersistenceService.saveBookInfo(for: original.book)
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(try BookInfo.load(from: original.book.tmbDirectory).contentIndex, original.index)

        // The older version rebuilds the index and keeps it inside its record.
        let rebuilt = Self.index(of: "words an older version indexed again")
        var olderRecord = try BookInfo.load(from: original.book.tmbDirectory)
        olderRecord.contentIndex = nil
        try Self.olderVersionRecordBytes(olderRecord, index: rebuilt)
            .write(to: TextMouthPaths.bookInfoPath(in: original.book.tmbDirectory), options: .atomic)
        XCTAssertEqual(try BookInfo.load(from: original.book.tmbDirectory).contentIndex, rebuilt)

        LibraryPersistenceService.saveBookInfo(for: original.book)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertNil(try recordKeys(of: original.book)["contentIndex"])
        XCTAssertEqual(try BookInfo.load(from: original.book.tmbDirectory).contentIndex, rebuilt)
    }

    // MARK: - Saves

    /// A save without an index, as a reading checkpoint is, rewrites only
    /// bookInfo.json, about a kilobyte: the package's contentIndex.json is
    /// the same file afterwards, and the index loads as before.
    func testCheckpointLeavesTheIndexFileAsItIs() throws {
        var book = try makePackagedBook(title: "Untouched Index")
        let index = Self.index(of: "a long book with many headings")
        try book.saveBookInfoThrowing(contentIndex: index)
        let indexFile = TextMouthPaths.contentIndexPath(in: book.tmbDirectory)
        let indexFileBefore = try LibraryIndexSandbox.inode(of: indexFile)

        book.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 5)
        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try LibraryIndexSandbox.inode(of: indexFile), indexFileBefore, "contentIndex.json was rewritten")
        XCTAssertLessThan(Self.size(of: TextMouthPaths.bookInfoPath(in: book.tmbDirectory)), 4_096)
        let loaded = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(loaded.contentIndex, index)
        XCTAssertEqual(loaded.state.readingPosition?.characterOffset, 5)
    }

    /// An analysis committed through the metadata queue writes its index to
    /// contentIndex.json and its fields to bookInfo.json, and a later save
    /// without an index keeps both.
    func testAnalysisWritesItsIndexToItsOwnFile() throws {
        var book = try makePackagedBook(title: "Freshly Analyzed")
        try book.saveBookInfoThrowing()
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &book))

        let committed = try XCTUnwrap(try LibraryPersistenceService.saveContentAnalysis(
            for: book,
            index: index,
            cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        ))
        LibraryPersistenceService.saveBookInfo(for: committed)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertNil(try recordKeys(of: book)["contentIndex"])
        let loaded = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(loaded.contentIndex, index)
        XCTAssertEqual(loaded.state.contentIndexVersion, index.version)
        XCTAssertEqual(loaded.state.totalWordCount, index.totalWordCount)
    }

    /// A package's whole record written without an index, as separating a
    /// shared package writes one to have its index rebuilt, removes the
    /// index the package held; written with one, it replaces it.
    func testWholeRecordSaveRemovesOrReplacesThePackagesIndex() throws {
        let book = try makePackagedBook(title: "Written Whole")
        var info = book.makeBookInfo()
        info.contentIndex = Self.index(of: "the first index")
        try info.save(to: book.tmbDirectory)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).contentIndex, info.contentIndex)

        info.contentIndex = Self.index(of: "the second index")
        try info.save(to: book.tmbDirectory)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).contentIndex, info.contentIndex)

        info.contentIndex = nil
        try info.save(to: book.tmbDirectory)
        XCTAssertNil(try BookInfo.load(from: book.tmbDirectory).contentIndex)
        XCTAssertFalse(exists(TextMouthPaths.contentIndexPath(in: book.tmbDirectory)))
        // Removing an index that is not there is no failure.
        XCTAssertNoThrow(try info.save(to: book.tmbDirectory))
    }

    // MARK: - Reading

    /// A contentIndex.json that cannot be decoded counts as no index: the
    /// record still loads, and the book's next load builds a fresh index.
    func testDamagedIndexFileCountsAsNone() throws {
        let book = try makePackagedBook(title: "Damaged Index")
        try book.saveBookInfoThrowing(contentIndex: Self.index(of: "soon damaged"))
        try Data("{\"version\": ".utf8).write(to: TextMouthPaths.contentIndexPath(in: book.tmbDirectory))

        let loaded = try BookInfo.load(from: book.tmbDirectory)

        XCTAssertNil(loaded.contentIndex)
        XCTAssertEqual(loaded.metadata.bookID, book.id)
    }

    /// A save reads what it replaces without the index: whether the package
    /// keeps one, in its own file or inside an older record, and the
    /// record's own fields.
    func testStoredRecordTellsWhetherThePackageKeepsAnIndex() throws {
        let plain = try makePackagedBook(title: "No Index Yet")
        try plain.saveBookInfoThrowing()
        XCTAssertEqual(try StoredBookRecord.read(from: plain.tmbDirectory).keepsContentIndex, false)

        try plain.saveBookInfoThrowing(contentIndex: Self.index(of: "now indexed"))
        let indexed = try StoredBookRecord.read(from: plain.tmbDirectory)
        XCTAssertTrue(indexed.keepsContentIndex)
        XCTAssertNil(indexed.info.contentIndex, "the index file was read")

        let older = try makeOldFormatPackage(title: "Index Inside")
        let embedded = try StoredBookRecord.read(from: older.book.tmbDirectory)
        XCTAssertTrue(embedded.keepsContentIndex)
        XCTAssertEqual(embedded.info.contentIndex, older.index)
    }

    /// contentIndex.json is a file TextMouth keeps beside a book, never the
    /// book's own content, so a package holding one still holds one book.
    func testTheIndexFileIsNeverTakenForTheBook() {
        XCTAssertFalse(FileImportService.isPackageContentName(TextMouthPaths.contentIndexFileName))
        XCTAssertFalse(FileImportService.isPackageContentName("bookInfo.json"))
        XCTAssertTrue(FileImportService.isPackageContentName("Almanac.epub"))
    }

    // MARK: - Fixtures

    /// A Markdown book in a package of its own, in a folder this test
    /// removes, with no record written yet.
    private func makePackagedBook(title: String) throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        let folder = "Content Index File \(UUID().uuidString.prefix(8))"
        createdDirectories.append(TextMouthPaths.libraryDir.appendingPathComponent(folder, isDirectory: true))
        let packageName = "ContentIndexFile-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folder, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let source = package.appendingPathComponent("book.md")
        try "# Opening\n\nThe words of \(title).".write(to: source, atomically: true, encoding: .utf8)
        return Book(
            title: title,
            author: "Index Fixture",
            format: .markdown,
            filePath: source.path,
            md5Hash: try FileImportService.md5Hash(of: source),
            folderPath: folder,
            // A whole second, which bookInfo.json's ISO 8601 dates keep exactly.
            bookmarks: [Bookmark(
                number: 1,
                chapterIndex: 0,
                characterOffset: 3,
                label: "Kept",
                dateCreated: Date(timeIntervalSince1970: 1_790_000_000)
            )],
            tmbDirectoryName: packageName,
            cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        )
    }

    /// A packaged book whose bookInfo.json an older version of TextMouth
    /// wrote: the record with its analysis fields and its index inside,
    /// laid out as that version's encoder laid it out, and no
    /// contentIndex.json.
    private func makeOldFormatPackage(title: String) throws -> (book: Book, index: BookContentIndex) {
        var book = try makePackagedBook(title: title)
        let index = Self.index(of: "the words \(title) was indexed from")
        book.applyContentAnalysis(index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion)
        var info = book.makeBookInfo()
        info.state.revision = 4
        try Self.olderVersionRecordBytes(info, index: index)
            .write(to: TextMouthPaths.bookInfoPath(in: book.tmbDirectory), options: .atomic)
        XCTAssertNotNil(try recordKeys(of: book)["contentIndex"], "the fixture must hold its index inside")
        return (book, index)
    }

    /// A copy of `book`'s package, made whole as a library copied to another
    /// disk is, in a folder of its own; returns the book as it is there.
    private func copyPackage(of book: Book) throws -> Book {
        let folder = "Content Index Copy \(UUID().uuidString.prefix(8))"
        createdDirectories.append(TextMouthPaths.libraryDir.appendingPathComponent(folder, isDirectory: true))
        try TextMouthPaths.ensureLibrarySubfolder(folder)
        var copy = book
        copy.folderPath = folder
        try FileManager.default.copyItem(at: book.tmbDirectory, to: copy.tmbDirectory)
        copy.filePath = copy.tmbDirectory.appendingPathComponent(book.bookFileURL.lastPathComponent).path
        return copy
    }

    /// The bytes an older version of TextMouth wrote as bookInfo.json for
    /// `info`: the record with `index` inside it, pretty-printed with sorted
    /// keys and ISO 8601 dates, as that version's encoder wrote every record.
    static func olderVersionRecordBytes(_ info: BookInfo, index: BookContentIndex) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(info)) as? [String: Any])
        record["contentIndex"] = try JSONSerialization.jsonObject(with: encoder.encode(index))
        return try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    }

    /// A one-chapter text index of `text`.
    static func index(of text: String) -> BookContentIndex {
        BookContentIndex.build(fromChapters: [Chapter(title: "One", text: text)], format: .markdown)
    }

    /// The top-level keys of `book`'s bookInfo.json as written on disk.
    private func recordKeys(of book: Book) throws -> [String: Any] {
        let bytes = try Data(contentsOf: TextMouthPaths.bookInfoPath(in: book.tmbDirectory))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    /// Whether anything is at `url`.
    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The size of the file at `url` in bytes, or 0 when nothing is there.
    private static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
