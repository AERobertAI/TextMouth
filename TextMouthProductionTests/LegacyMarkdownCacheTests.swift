import XCTest
@testable import TextMouth

final class LegacyMarkdownCacheTests: XCTestCase {
    private func parse(_ markdown: String) -> DocumentContent {
        MarkdownCacheService.parseMultiChapterMarkdown(
            markdown,
            bookTitle: "Test Book",
            bookAuthor: "Author"
        )
    }

    func testMultiChapterMarkdownSplitsAtMarkers() {
        let content = parse("""
        <!-- chapter: Introduction -->
        # Introduction

        Intro text.
        <!-- chapter: Chapter One -->
        # Chapter One

        First chapter.
        <!-- chapter: Chapter Two -->
        # Chapter Two

        Second chapter.
        """)
        XCTAssertEqual(content.chapters.map(\.title), ["Introduction", "Chapter One", "Chapter Two"])
    }

    func testMarkdownWithoutMarkersProducesSingleChapter() {
        let content = parse("# My Book\n\nWhole book text.\n\n## Section\n\nSection text.")
        XCTAssertEqual(content.chapters.count, 1)
        XCTAssertTrue(content.chapters[0].text.contains("Whole book text"))
    }

    func testEmptyMarkedChaptersAreSkipped() {
        let content = parse("""
        <!-- chapter: Empty -->

        <!-- chapter: Content -->
        # Real Content

        Actual text.
        """)
        XCTAssertEqual(content.chapters.count, 1)
        XCTAssertEqual(content.chapters[0].title, "Content")
    }

    func testCachedChapterHeadingsReceiveCorrectChapterIndices() {
        let content = parse("""
        <!-- chapter: One -->
        # One

        ## Section A
        Text.
        <!-- chapter: Two -->
        # Two

        ## Section B
        Text.
        """)
        XCTAssertFalse(content.chapters[0].headings.isEmpty)
        XCTAssertFalse(content.chapters[1].headings.isEmpty)
        XCTAssertEqual(Set(content.allHeadings.map(\.chapterIndex)), Set([0, 1]))
    }

    func testCachedMarkdownRoundTripPreservesChapterText() {
        let content = parse("""
        <!-- chapter: One -->
        # One

        The quick brown fox.
        <!-- chapter: Two -->
        # Two

        Jumped over the lazy dog.
        """)
        XCTAssertTrue(content.chapters[0].text.contains("quick brown fox"))
        XCTAssertTrue(content.chapters[1].text.contains("lazy dog"))
    }

    func testTitledChaptersWithoutMarkdownHeadingsGetSyntheticHeadings() {
        let content = parse("""
        <!-- chapter: Red Pill Blue Pill -->
        Opening text.
        <!-- chapter: Job Interview -->
        Interview text.
        <!-- chapter: The Leith Police -->
        Police text.
        """)
        XCTAssertEqual(content.allHeadings.map(\.text), [
            "Red Pill Blue Pill", "Job Interview", "The Leith Police",
        ])
        XCTAssertTrue(content.allHeadings.allSatisfy { $0.level == 1 })
    }

    func testExistingMarkdownHeadingsAreNotDoubled() {
        let content = parse("""
        <!-- chapter: Introduction -->
        # Introduction

        Welcome.
        <!-- chapter: Chapter One -->
        # Chapter One

        Story.
        """)
        XCTAssertEqual(content.chapters[0].headings.count, 1)
        XCTAssertEqual(content.chapters[1].headings.count, 1)
    }

    func testMixedChaptersUseRealOrSyntheticHeadingsAsNeeded() {
        let content = parse("""
        <!-- chapter: Copyright -->
        Published text.
        <!-- chapter: Chapter 1 -->
        # Chapter 1

        ## Section A
        Story.
        <!-- chapter: Chapter 2 -->
        More story.
        """)
        XCTAssertEqual(content.chapters[0].headings.map(\.text), ["Copyright"])
        XCTAssertEqual(content.chapters[1].headings.map(\.text), ["Chapter 1", "Section A"])
        XCTAssertEqual(content.chapters[2].headings.map(\.text), ["Chapter 2"])
    }

    func testEmptyChapterTitleDoesNotCreateSyntheticHeading() {
        let content = parse("""
        <!-- chapter:  -->
        Untitled image page.
        <!-- chapter: Real Chapter -->
        Actual content.
        """)
        XCTAssertTrue(content.chapters[0].headings.isEmpty)
        XCTAssertEqual(content.chapters[1].headings.map(\.text), ["Real Chapter"])
    }

    func testInjectedHeadingTextRemainsInPlainContent() {
        let content = parse("""
        <!-- chapter: Part 1 -->
        # Part 1

        <!-- chapter: Red Pill Blue Pill -->
        # Red Pill Blue Pill

        Opening text.
        """)
        XCTAssertEqual(content.allHeadings.map(\.text), ["Part 1", "Red Pill Blue Pill"])
        XCTAssertTrue(content.chapters[1].text.contains("Red Pill Blue Pill"))
    }

    func testLargeMarkedCacheCreatesOneHeadingPerTitledChapter() {
        let markdown = (1...50).map {
            "<!-- chapter: Chapter \($0) -->\nContent \($0)."
        }.joined(separator: "\n\n")
        let content = parse(markdown)
        XCTAssertEqual(content.chapters.count, 50)
        XCTAssertEqual(content.allHeadings.count, 50)
    }

    func testCachedChapterGlobalOffsetsUseUTF16Coordinates() {
        let content = parse("""
        <!-- chapter: One -->
        # One

        🙂 first.
        <!-- chapter: Two -->
        # Two

        Second.
        """)
        XCTAssertEqual(content.chapterStartOffset(0), 0)
        XCTAssertEqual(content.chapterStartOffset(1), content.chapters[0].text.utf16.count)
    }

    /// A chapter marker written before format 3.0.5 could carry a leaked
    /// heading annotation. The chapter title, and the heading made from it
    /// when the chapter has none, show only the visible label.
    func testLegacyChapterMarkerTitlesDropAnnotationComments() {
        let leaked = MarkdownHeadingAnnotation(level: 1, text: "10").markdown + "2"
        let content = parse("""
        <!-- chapter: \(leaked) -->
        Body text.
        <!-- chapter: Plain title -->
        More text.
        """)
        XCTAssertEqual(content.chapters.map(\.title), ["2", "Plain title"])
        XCTAssertEqual(content.allHeadings.map(\.text), ["2", "Plain title"])
    }

    func testNilAndEmptyCacheVersionsAreOutdated() {
        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: nil, current: "2.0.0"))
        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: "", current: "2.0.0"))
    }

    func testSemanticCacheVersionComparison() {
        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: "1.0.0", current: "2.0.0"))
        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: "2.0.0", current: "2.1.0"))
        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: "2.0.0", current: "2.0.1"))
        XCTAssertFalse(MarkdownCacheService.isCacheOutdated(stored: "2.1.0", current: "2.1.0"))
        XCTAssertFalse(MarkdownCacheService.isCacheOutdated(stored: "3.0.0", current: "2.0.0"))
    }

    func testBookCanStoreCurrentCacheFormatVersion() {
        var item = Book(
            title: "Cached",
            format: .epub,
            filePath: "/tmp/cached.epub",
            md5Hash: "cached"
        )
        XCTAssertNil(item.cacheFormatVersion)
        item.cacheFormatVersion = MarkdownCacheService.currentCacheVersion
        XCTAssertEqual(item.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
    }

    // MARK: - Plain Text

    /// Import a plain-text source through the production path, which copies
    /// it into a package, writes content.md, and stamps the cache version.
    private func importPlainTextBook(_ source: String) throws -> Book {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Plain Fixture.txt")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let book = try FileImportService.importFile(from: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        return book
    }

    /// The content.md written for a .txt book reads exactly like the direct
    /// parser: one chapter, the same text, and the same headings. No literal
    /// text is stored as an HTML comment, so none can hide or split a chapter.
    func testPlainTextCacheFileReadsLikeTheDirectParser() throws {
        let book = try importPlainTextBook(PlainTextFixture.combined)
        XCTAssertEqual(book.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)

        let cached = try MarkdownCacheService.loadFromCache(for: book)
        let direct = try BookParser.parse(url: URL(fileURLWithPath: book.filePath), format: .txt)
        let chapter = assertSamePlainTextReading(cached: cached, direct: direct)
        XCTAssertEqual(chapter?.text, PlainTextFixture.combinedReading)

        let markdown = try String(
            contentsOf: TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory), encoding: .utf8
        )
        XCTAssertFalse(markdown.contains("<!--"))
    }

    /// A .txt line spelled like a chapter marker is text. The cache used to
    /// copy it verbatim, so the reader took it for a marker: the words before
    /// it vanished and the line itself became a chapter title.
    func testPlainTextChapterMarkerLookalikeStaysText() {
        let content = parse(PlainTextParser.markdown(
            text: "Opening words.\n<!-- chapter: Not A Chapter -->\nClosing words."
        ))
        XCTAssertEqual(content.chapters.count, 1)
        XCTAssertEqual(
            content.chapters.first?.text,
            "Opening words. <!-- chapter: Not A Chapter --> Closing words."
        )
        XCTAssertEqual(content.allHeadings, [])
    }

    /// A reader opening a .txt package written at format 3.0.5 must replace
    /// its cache and persisted index, whose text lost Markdown-looking
    /// characters, with a literal rebuild that matches the direct parser, and
    /// afterwards reuse the rebuilt index.
    func testPlainTextCacheFromFormat305IsRebuiltAsLiteralText() throws {
        let body = "*Starred* words -- and <b>tags</b> & [links](x)."
        var book = try importPlainTextBook("OPENING\n\(body)")
        let direct = try BookParser.parse(url: URL(fileURLWithPath: book.filePath), format: .txt)
        // Recreate what format 3.0.5 stored: the all-caps line marked up as a
        // heading and every other line copied verbatim for the Markdown reader.
        try "## OPENING\n\(body)".write(
            to: TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory), atomically: true, encoding: .utf8
        )
        book.cacheFormatVersion = "3.0.5"
        let legacy = try MarkdownCacheService.loadFromCache(for: book)
        XCTAssertEqual(legacy.chapters.map(\.text), ["OPENING\n\nStarred words \u{2013} and tags & links."])
        try book.saveBookInfoThrowing(contentIndex: legacy.contentIndex.replacingFormat(.txt))

        XCTAssertTrue(MarkdownCacheService.isCacheOutdated(stored: book.cacheFormatVersion))
        let result = try BookContentAnalysisService.load(
            book: book,
            regenerateTextCache: MarkdownCacheService.isCacheOutdated(stored: book.cacheFormatVersion)
        )
        XCTAssertFalse(result.usedPersistedIndex)
        XCTAssertEqual(result.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        XCTAssertEqual(result.content.chapters.map(\.text), ["OPENING\n\n\(body)"])
        assertSamePlainTextReading(cached: result.content, direct: direct)
        XCTAssertEqual(result.index.allHeadings, direct.allHeadings)

        try LibraryPersistenceService.saveContentAnalysis(
            for: book, index: result.index, cacheFormatVersion: result.cacheFormatVersion
        )
        book.cacheFormatVersion = result.cacheFormatVersion
        let reopened = try BookContentAnalysisService.load(book: book)
        XCTAssertTrue(reopened.usedPersistedIndex)
        assertSamePlainTextReading(cached: reopened.content, direct: direct)
    }
}
