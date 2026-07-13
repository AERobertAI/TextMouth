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
}
