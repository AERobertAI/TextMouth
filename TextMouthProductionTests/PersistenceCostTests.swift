import XCTest
@testable import TextMouth

/// Measures what the library's persistence costs at the moments the
/// performance review of October 3 named (PERF13 to PERF17): a reading
/// checkpoint, a folder rename, a launch, a config save, and a cloud
/// refresh. Every figure is printed on one line beginning
/// `PERSISTENCE_COST:`, so a test log can be searched for them. Assertions
/// check the shape of a cost (which files are written, how many bytes, how
/// many file-system calls), never a time, so a busy machine cannot fail
/// them.
final class PersistenceCostTests: XCTestCase {
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

    // MARK: - PERF15: A Reading Checkpoint

    /// What one reading checkpoint writes, as the reader makes one every 30
    /// seconds of playback: the library holds as many books as the user's
    /// (643, about 690 KB of index), and the book being read has a record as
    /// large as the user's largest (about 690 KB, most of it the content
    /// index). Each checkpoint's line names every file it rewrote and its
    /// size.
    ///
    /// Before PERF15 every checkpoint rewrote library.json and the whole
    /// record, index included: 1,305,075 bytes. Now it writes the record
    /// alone, under 4 KB, and the journal the first time; library.json takes
    /// the checkpoints at their deadline, or when TextMouth quits.
    @MainActor
    func testReadingCheckpointCost() throws {
        let book = try makePackagedBook(headingCount: 2_700)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Self.library(holding: book, besides: 642)
        model.save()
        LibraryPersistenceService.flushPendingSave()
        let files = Self.checkpointFiles(of: book)
        Self.report("PERF15 library.json holds \(model.library.books.count) books in \(Self.size(of: sandbox.indexURL)) bytes")

        var bytesPerCheckpoint: [Int] = []
        var rewroteIndex = false
        for checkpoint in 1...3 {
            let before = files.map(Self.identity(of:))
            model.persistReadingPosition(
                bookID: book.id,
                position: ReadingPosition(chapterIndex: 1, characterOffset: 100 * checkpoint)
            )
            waitPastLibrarySaveDebounce()
            let rewritten = zip(files, before).filter { Self.identity(of: $0.0) != $0.1 }.map(\.0)
            let bytes = rewritten.map(Self.size(of:)).reduce(0, +)
            bytesPerCheckpoint.append(bytes)
            let names = rewritten.map { "\($0.lastPathComponent) (\(Self.size(of: $0)) bytes)" }
            Self.report("PERF15 checkpoint \(checkpoint) rewrote \(names.joined(separator: ", ")): \(bytes) bytes")
            XCTAssertFalse(rewritten.contains(TextMouthPaths.contentIndexPath(in: book.tmbDirectory)), "checkpoint \(checkpoint)")
            rewroteIndex = rewroteIndex || rewritten.contains(TextMouthPaths.libraryIndexFile)
        }
        // A listening hour holds 120 checkpoints, one every 30 seconds, and
        // library.json takes them once per checkpoint deadline.
        let indexWritesPerHour = rewroteIndex ? 120 : 3_600 / LibraryPersistenceService.readingCheckpointDelay
        let perHour = (Double(bytesPerCheckpoint.max() ?? 0) * 120
            + (rewroteIndex ? 0 : indexWritesPerHour * Double(Self.size(of: sandbox.indexURL)))) / 1_000_000
        Self.report(
            "PERF15 checkpoints write about \(String(format: "%.1f", perHour)) MB per listening hour "
                + "(library.json \(Int(indexWritesPerHour)) times)"
        )
        XCTAssertFalse(rewroteIndex, "a checkpoint rewrote library.json")
        XCTAssertLessThan(bytesPerCheckpoint.max() ?? 0, 4_096, "a checkpoint wrote more than its record")

        // Quitting writes the last checkpoint into library.json.
        LibraryPersistenceService.flushPendingSave()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(Library.self, from: Data(contentsOf: sandbox.indexURL))
        XCTAssertEqual(saved.books.first { $0.id == book.id }?.readingPosition?.characterOffset, 300)
    }

    // MARK: - Fixtures

    /// A Markdown book in a package of its own, in a folder this test
    /// removes, whose record holds a content index of `headingCount`
    /// headings: about 690 KB of record for 2,700, as large as the user's
    /// largest.
    private func makePackagedBook(headingCount: Int) throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        let folder = "Persistence Cost \(UUID().uuidString.prefix(8))"
        createdDirectories.append(TextMouthPaths.libraryDir.appendingPathComponent(folder, isDirectory: true))
        let packageName = "PersistenceCost-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folder, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let source = package.appendingPathComponent("book.md")
        try "# Opening\n\nThe words of a long collection.".write(to: source, atomically: true, encoding: .utf8)
        let index = Self.contentIndex(headingCount: headingCount)
        var book = Book(
            title: "The Collected Works",
            author: "Cost Fixture",
            format: .markdown,
            filePath: source.path,
            md5Hash: try FileImportService.md5Hash(of: source),
            folderPath: folder,
            tmbDirectoryName: packageName,
            cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        )
        book.applyContentAnalysis(index, cacheFormatVersion: MarkdownCacheService.currentCacheVersion)
        try book.saveBookInfoThrowing(contentIndex: index)
        return book
    }

    /// A text book's content index with `headingCount` headings spread over
    /// chapters of twenty headings each, labeled as a long collection's are.
    static func contentIndex(headingCount: Int) -> BookContentIndex {
        let headingsPerChapter = 20
        let chapterCount = max(1, (headingCount + headingsPerChapter - 1) / headingsPerChapter)
        let charactersPerHeading = 2_000
        var chapters: [BookContentChapterIndex] = []
        var globalOffset = 0
        for chapterIndex in 0..<chapterCount {
            let start = globalOffset
            let headings = (0..<headingsPerChapter).map { headingIndex -> BookContentHeadingIndex in
                let local = headingIndex * charactersPerHeading
                return BookContentHeadingIndex(
                    id: "heading-\(chapterIndex)-\(headingIndex)",
                    level: headingIndex == 0 ? 1 : 2,
                    text: "Part \(chapterIndex + 1), Section \(headingIndex + 1): A Heading of Ordinary Length",
                    characterOffset: local,
                    globalCharacterOffset: start + local
                )
            }
            let characterCount = headingsPerChapter * charactersPerHeading
            chapters.append(BookContentChapterIndex(
                chapterIndex: chapterIndex,
                title: "Part \(chapterIndex + 1)",
                startCharacterOffset: start,
                characterCount: characterCount,
                wordCount: characterCount / 6,
                headings: headings,
                audio: nil
            ))
            globalOffset += characterCount
        }
        return BookContentIndex(
            version: BookContentIndex.currentVersion,
            kind: .text,
            format: .markdown,
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            totalWordCount: globalOffset / 6,
            totalCharacterCount: globalOffset,
            totalAudioDuration: nil,
            audioLayout: nil,
            chapters: chapters
        )
    }

    /// A library of `book` and `others` more rows, each filled in as most of
    /// the user's rows are (an imported, analyzed EPUB with a title of about
    /// 20 characters, a path of about 180, and, for one book in seven, a
    /// reading position), so the index is about as large as the user's:
    /// about 1,080 bytes per book. The other rows have no package on disk;
    /// only `book` is ever written to.
    static func library(holding book: Book, besides others: Int) -> Library {
        let root = TextMouthPaths.libraryDir.path
        let rows = (0..<others).map { number -> Book in
            let folder = "Synthetic Shelf \(number % 38)"
            let title = "Synthetic Title \(number)"
            let packageName = "Synthetic_Title_\(number)-Synthetic_Author-1774073441.tmb"
            let isBeingRead = number % 7 == 0
            return Book(
                title: title,
                author: "Synthetic Author \(number % 50)",
                format: .epub,
                filePath: "\(root)/\(folder)/\(packageName)/Synthetic_Title_\(number)-Synthetic_Author_Name.epub",
                md5Hash: String(repeating: "0123456789abcdef", count: 2),
                folderPath: folder,
                dateAdded: Date(timeIntervalSince1970: 1_774_073_441),
                lastOpened: isBeingRead ? Date(timeIntervalSince1970: 1_790_000_000) : nil,
                readingPosition: isBeingRead
                    ? ReadingPosition(chapterIndex: 3, characterOffset: 1_200, globalCharacterOffset: 45_000)
                    : nil,
                totalWordCount: 98_000,
                totalCharacterCount: 560_000,
                tmbDirectoryName: packageName,
                sourceFilePath: "/Users/reader/Documents/Books To Import/\(title) - Synthetic Author.epub",
                cacheFormatVersion: MarkdownCacheService.currentCacheVersion,
                contentIndexVersion: BookContentIndex.currentVersion
            )
        }
        return Library(books: [book] + rows)
    }

    // MARK: - Files

    /// The files a reading checkpoint of `book` can rewrite: library.json,
    /// the checkpoint journal beside it, and the book's package record, with
    /// every file beside the record that holds part of it.
    private static func checkpointFiles(of book: Book) -> [URL] {
        let package = book.tmbDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: package.path)) ?? []
        let recordFiles = names.filter { $0.hasSuffix(".json") }.sorted().map { package.appendingPathComponent($0) }
        return [TextMouthPaths.libraryIndexFile, TextMouthPaths.readingCheckpointsFile] + recordFiles
    }

    /// Which file is at `url` now: its inode, which an atomic write replaces,
    /// with its size and modification time; nil when nothing is there.
    private static func identity(of url: URL) -> [String]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return [
            "\(attributes[.systemFileNumber] ?? "")",
            "\(attributes[.size] ?? "")",
            "\(attributes[.modificationDate] ?? "")",
        ]
    }

    /// The size of the file at `url` in bytes, or 0 when nothing is there.
    private static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Prints one measurement on a line of its own.
    private static func report(_ line: String) {
        print("PERSISTENCE_COST: \(line)")
    }
}
