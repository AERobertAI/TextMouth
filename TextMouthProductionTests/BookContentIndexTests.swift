import XCTest
@testable import TextMouth

final class BookContentIndexTests: XCTestCase {
    func testTextIndexStoresChapterHeadingAndUTF16Breaks() {
        let chapters = [
            Chapter(
                title: "One",
                text: "🙂 one two",
                headings: [Heading(level: 1, text: "One", characterOffset: 0)]
            ),
            Chapter(
                title: "Two",
                text: "three four five",
                headings: [Heading(level: 2, text: "Two", characterOffset: 6)]
            ),
        ]

        let index = BookContentIndex.build(fromChapters: chapters, format: .epub)

        XCTAssertEqual(index.version, BookContentIndex.currentVersion)
        XCTAssertEqual(index.kind, .text)
        XCTAssertEqual(index.totalWordCount, 6)
        XCTAssertEqual(index.totalCharacterCount, 25)
        XCTAssertEqual(index.chapters.map(\.startCharacterOffset), [0, 10])
        XCTAssertEqual(index.chapters.map(\.wordCount), [3, 3])
        XCTAssertEqual(index.chapters[1].headings[0].globalCharacterOffset, 16)
        XCTAssertEqual(index.allHeadings.map(\.chapterIndex), [0, 1])
    }

    func testDocumentContentUsesPrecomputedIndexForDerivedValues() {
        let chapter = Chapter(title: "Actual", text: "one two", headings: [])
        var precomputed = BookContentIndex.build(fromChapters: [chapter], format: .txt)
        precomputed.totalWordCount = 123
        precomputed.totalCharacterCount = 456

        let content = DocumentContent(
            title: "Book",
            author: "Author",
            chapters: [chapter],
            contentIndex: precomputed
        )

        XCTAssertEqual(content.totalWordCount, 123)
        XCTAssertEqual(content.totalCharacterCount, 456)
    }

    func testBookInfoRoundTripsFullIndexAndVersionSummary() throws {
        let content = DocumentContent(
            title: "Book",
            author: "Author",
            chapters: [Chapter(
                title: "Chapter",
                text: "some persisted words",
                headings: [Heading(level: 1, text: "Chapter", characterOffset: 0)]
            )]
        )
        let index = content.contentIndex.replacingFormat(.markdown)
        let info = BookInfo(
            state: BookState(contentIndexVersion: index.version),
            contentIndex: index
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BookInfo.self, from: encoder.encode(info))

        XCTAssertEqual(decoded.state.contentIndexVersion, BookContentIndex.currentVersion)
        XCTAssertEqual(decoded.contentIndex, index)
        XCTAssertEqual(decoded.contentIndex?.chapters.first?.headings.first?.text, "Chapter")
    }

    func testLegacyBookInfoDecodesWithoutIndex() throws {
        let data = Data(#"""
        {
          "metadata": {
            "title":"Old", "author":"Unknown", "format":"txt", "md5Hash":"old",
            "dateAdded":"2024-01-01T00:00:00Z", "originalFileName":"old.txt",
            "folderPath":"", "bookID":"00000000-0000-0000-0000-000000000001"
          },
          "state": {"isNew":true,"tmbDirectoryName":"old.tmb"},
          "bookmarks": []
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(BookInfo.self, from: data)

        XCTAssertNil(decoded.contentIndex)
        XCTAssertNil(decoded.state.contentIndexVersion)
    }

    func testLibraryJSONStoresSummaryWithoutFullHeadingIndex() throws {
        var book = Book(
            title: "Compact",
            format: .epub,
            filePath: "/tmp/compact.epub",
            md5Hash: "compact"
        )
        book.contentIndexVersion = BookContentIndex.currentVersion
        let json = String(decoding: try JSONEncoder().encode(Library(books: [book])), as: UTF8.self)

        XCTAssertTrue(json.contains("contentIndexVersion"))
        XCTAssertFalse(json.contains("startCharacterOffset"))
        XCTAssertFalse(json.contains("globalCharacterOffset"))
    }

    func testMetadataSavePreservesExistingContentIndex() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let packageName = "IndexPreservation-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }

        var book = Book(
            title: "Original",
            format: .txt,
            filePath: package.appendingPathComponent("book.txt").path,
            md5Hash: "preserve",
            tmbDirectoryName: packageName,
            contentIndexVersion: BookContentIndex.currentVersion
        )
        let index = BookContentIndex.build(
            fromChapters: [Chapter(title: "One", text: "one two three")],
            format: .txt
        )
        try book.saveBookInfoThrowing(contentIndex: index)

        book.title = "Edited"
        LibraryPersistenceService.saveBookInfo(for: book)
        book.title = "Newest"
        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()
        let restored = try BookInfo.load(from: package)

        XCTAssertEqual(restored.metadata.title, "Newest")
        XCTAssertEqual(restored.contentIndex, index)
    }

    func testImmediateAnalysisSaveMergesNewestPendingBookState() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let packageName = "IncrementalAnalysis-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }

        let parserSnapshot = Book(
            title: "Parser Snapshot",
            format: .txt,
            filePath: package.appendingPathComponent("book.txt").path,
            md5Hash: "incremental",
            tmbDirectoryName: packageName
        )
        var newestBook = parserSnapshot
        newestBook.title = "Newest Metadata"
        newestBook.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 7)
        LibraryPersistenceService.saveBookInfo(for: newestBook)

        let index = BookContentIndex.build(
            fromChapters: [Chapter(title: "One", text: "one two three")],
            format: .txt
        )
        try LibraryPersistenceService.saveContentAnalysis(
            for: parserSnapshot,
            index: index,
            cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        )
        LibraryPersistenceService.flushPendingSave()

        let restored = try BookInfo.load(from: package)
        XCTAssertEqual(restored.metadata.title, "Newest Metadata")
        XCTAssertEqual(restored.state.readingPosition?.characterOffset, 7)
        XCTAssertEqual(restored.state.totalWordCount, 3)
        XCTAssertEqual(restored.state.contentIndexVersion, BookContentIndex.currentVersion)
        XCTAssertEqual(restored.state.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertEqual(restored.contentIndex, index)
    }

    func testAudioIndexRestoresMultiFileLayoutWithoutAssetParsing() throws {
        let base = URL(fileURLWithPath: "/tmp/audio", isDirectory: true)
        let chapters = [
            Chapter(
                title: "Track One",
                text: String(repeating: " ", count: 100),
                headings: [Heading(level: 1, text: "Track One")]
            ),
            Chapter(
                title: "Track Two",
                text: String(repeating: " ", count: 250),
                headings: [Heading(level: 1, text: "Track Two", chapterIndex: 1)]
            ),
        ]
        let index = BookContentIndex.build(
            fromChapters: chapters,
            format: .audio,
            audioFilePaths: ["/tmp/audio/01.mp3", "/tmp/audio/02.mp3"],
            audioBaseURL: base
        )

        XCTAssertEqual(index.audioLayout, .multiFile)
        XCTAssertEqual(index.totalAudioDuration ?? 0, 35, accuracy: 0.001)
        XCTAssertEqual(index.resolvedAudioFilePaths(relativeTo: base), [
            "/tmp/audio/01.mp3", "/tmp/audio/02.mp3",
        ])
        let restored = try XCTUnwrap(index.makeAudioDocumentContent(title: "Audio", author: "Author"))
        XCTAssertEqual(restored.chapters.map(\.text.utf16Length), [100, 250])
        XCTAssertEqual(restored.totalCharacterCount, 350)
    }

    func testSegmentedAudioIndexRoundTripsTiming() throws {
        let chapter = Chapter(
            title: "Segment",
            text: String(repeating: " ", count: 125),
            headings: [Heading(level: 1, text: "Segment")]
        )
        let index = BookContentIndex.build(
            fromChapters: [chapter],
            format: .audio,
            audioFilePaths: ["/tmp/audio/shared.mp3"],
            audioSegments: [AudioSegment(
                title: "Segment",
                file: "shared.mp3",
                startTime: 10,
                endTime: 22.5
            )]
        )

        let segment = try XCTUnwrap(index.restoredAudioSegments()?.first)
        XCTAssertEqual(index.audioLayout, .segmented)
        XCTAssertEqual(segment.file, "shared.mp3")
        XCTAssertEqual(segment.startTime, 10, accuracy: 0.001)
        XCTAssertEqual(segment.endTime, 22.5, accuracy: 0.001)
        XCTAssertEqual(
            index.resolvedAudioFilePaths(relativeTo: URL(fileURLWithPath: "/tmp/audio")),
            ["/tmp/audio/shared.mp3"]
        )
    }

    /// A chapter that names no file must void the whole file list. Dropping
    /// just that chapter's entry used to shift every later chapter onto the
    /// file of the chapter before it.
    func testChapterWithoutAudioFileVoidsTheFileList() {
        let base = URL(fileURLWithPath: "/tmp/audio", isDirectory: true)
        let tracks = ["01.mp3", "02.mp3", "03.mp3"]
        let index = BookContentIndex.build(
            fromChapters: tracks.map { Chapter(title: $0, text: String(repeating: " ", count: 20)) },
            format: .audio,
            audioFilePaths: tracks.map { base.appendingPathComponent($0).path },
            audioBaseURL: base
        )
        XCTAssertEqual(index.resolvedAudioFilePaths(relativeTo: base), tracks.map { "/tmp/audio/\($0)" })

        for missingPath in [nil, ""] {
            var damaged = index
            damaged.chapters[1].audio?.relativeFilePath = missingPath
            XCTAssertNil(damaged.resolvedAudioFilePaths(relativeTo: base), String(describing: missingPath))
        }
    }

    /// Segments follow the same rule: one without a file voids them all.
    func testSegmentWithoutAudioFileVoidsTheSegments() {
        let chapters = [Chapter(title: "First"), Chapter(title: "Second")]
        let index = BookContentIndex.build(
            fromChapters: chapters,
            format: .audio,
            audioSegments: [
                AudioSegment(title: "First", file: "shared.mp3", startTime: 0, endTime: 5),
                AudioSegment(title: "Second", file: "shared.mp3", startTime: 5, endTime: 9),
            ]
        )
        XCTAssertEqual(index.restoredAudioSegments()?.map(\.file), ["shared.mp3", "shared.mp3"])

        var damaged = index
        damaged.chapters[0].audio?.relativeFilePath = ""
        XCTAssertNil(damaged.restoredAudioSegments())
        XCTAssertNil(damaged.resolvedAudioFilePaths(relativeTo: URL(fileURLWithPath: "/tmp/audio")))
    }

    func testAudioAnalysisUsesPersistedIndexWithoutOpeningAsset() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let packageName = "SavedAudioIndex-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }

        var book = Book(
            title: "Saved Audio",
            format: .audio,
            filePath: package.appendingPathComponent("missing.m4b").path,
            md5Hash: "saved-audio",
            tmbDirectoryName: packageName,
            contentIndexVersion: BookContentIndex.currentVersion
        )
        let index = BookContentIndex.build(
            fromChapters: [Chapter(
                title: "Chapter",
                text: String(repeating: " ", count: 300),
                headings: [Heading(level: 1, text: "Chapter")]
            )],
            format: .audio
        )
        book.applyContentIndexSummary(index)
        try book.saveBookInfoThrowing(contentIndex: index)

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertTrue(result.usedPersistedIndex)
        XCTAssertEqual(result.content.totalCharacterCount, 300)
        XCTAssertEqual(result.index.totalAudioDuration ?? 0, 30, accuracy: 0.001)
    }

    func testTextAnalysisInjectsPersistedIndexIntoCacheLoad() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let packageName = "SavedTextIndex-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }

        let source = package.appendingPathComponent("book.md")
        let cache = package.appendingPathComponent("content.md")
        let markdown = "# Chapter\n\none two three"
        try markdown.write(to: source, atomically: true, encoding: .utf8)
        try markdown.write(to: cache, atomically: true, encoding: .utf8)
        var book = Book(
            title: "Saved Text",
            format: .markdown,
            filePath: source.path,
            md5Hash: "saved-text",
            tmbDirectoryName: packageName,
            cacheFormatVersion: MarkdownCacheService.currentCacheVersion,
            contentIndexVersion: BookContentIndex.currentVersion
        )
        let parsed = try MarkdownCacheService.loadFromCache(for: book)
        let index = parsed.contentIndex.replacingFormat(.markdown)
        book.applyContentIndexSummary(index)
        try book.saveBookInfoThrowing(contentIndex: index)

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertTrue(result.usedPersistedIndex)
        XCTAssertEqual(result.content.contentIndex, index)
        XCTAssertEqual(result.content.totalWordCount, index.totalWordCount)
    }

    func testParserVersionForcesPreviousCacheGenerationToRebuild() {
        XCTAssertEqual(MarkdownCacheService.currentCacheVersion, "3.0.7")
        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: "2.0.1"))
        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: "3.0.2"))
        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: "3.0.3"))
        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: "3.0.4"))
        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: "3.0.5"))
        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: "3.0.6"))
        XCTAssertFalse(MarkdownCacheService.isCacheOutdated(stored: "3.0.7"))
    }

    func testFailedRegenerationLeavesPreviousCacheReadable() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let packageName = "RetainedCache-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let cache = package.appendingPathComponent("content.md")
        try "# Last Good Cache".write(to: cache, atomically: true, encoding: .utf8)
        let book = Book(
            title: "Missing Source",
            format: .epub,
            filePath: package.appendingPathComponent("missing.epub").path,
            md5Hash: "missing-source",
            tmbDirectoryName: packageName,
            cacheFormatVersion: "2.0.1"
        )

        XCTAssertFalse(MarkdownCacheService.generateCache(for: book))
        XCTAssertEqual(try String(contentsOf: cache), "# Last Good Cache")
        XCTAssertEqual(try MarkdownCacheService.loadFromCache(for: book).allHeadings.first?.text, "Last Good Cache")
    }

    func testMigrationSelectsEveryLegacyFormatAndSkipsCompleteCurrentBooks() {
        for format in BookFormat.allCases {
            let legacy = Book(
                title: format.rawValue,
                format: format,
                filePath: "/tmp/legacy.\(format.fileExtensions.first ?? "book")",
                md5Hash: "legacy-\(format.rawValue)",
                totalWordCount: 1,
                totalCharacterCount: 10,
                audioDuration: format.isAudio ? 1 : nil,
                contentIndexVersion: nil
            )
            XCTAssertTrue(LibraryViewModel.needsContentAnalysis(legacy), format.rawValue)

            var current = legacy
            current.contentIndexVersion = BookContentIndex.currentVersion
            XCTAssertFalse(LibraryViewModel.needsContentAnalysis(current), format.rawValue)
        }
    }
}
