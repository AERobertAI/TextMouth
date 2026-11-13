import XCTest
@testable import TextMouth

/// What the Markdown nesting guard (`MarkdownNesting`) does where content.md is
/// written and read (`MarkdownCacheService`): an import of a file nested too
/// deeply to read is refused with the guard's sentence and writes nothing, and
/// a chapter refused while content.md is read is never dropped, so nothing that
/// commits for the text read (Edit Text, a rebuild, the pages' re-read, the
/// exports) commits for a shorter one. Every deep input here is plainly deep
/// (thousands of `>` marks) and none is built to pass the count.
final class MarkdownNestingCacheTests: XCTestCase {

    // MARK: - Helpers

    /// Thousands of nested quotes around `words`: far past the limit.
    private func deepQuotes(around words: String) -> String {
        String(repeating: ">", count: 5_000) + " " + words
    }

    /// A content.md of three chapters whose middle one is `deep`.
    private func contentWithAMiddleChapter(_ deep: String) -> String {
        "<!-- chapter: First -->\nFirst chapter words.\n\n"
            + "<!-- chapter: Second -->\n\(deep)\n\n"
            + "<!-- chapter: Third -->\nThird chapter words."
    }

    /// A disposable Markdown book whose source file holds `source`.
    private func makeBook(source: String) throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        let name = "MarkdownNestingCache-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: name)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        let file = package.appendingPathComponent("source.md")
        try source.write(to: file, atomically: true, encoding: .utf8)
        return Book(title: "Nesting fixture", format: .markdown, filePath: file.path,
                    md5Hash: UUID().uuidString, tmbDirectoryName: name)
    }

    private let standardLimit = MarkupGuard.Limits.standard.deepestNesting

    // MARK: - An import

    /// A deeply nested file is refused with the sentence, and no content.md is left behind.
    func testImportingADeeplyNestedFileIsRefusedAndWritesNothing() throws {
        let book = try makeBook(source: deepQuotes(around: "Quoted words"))

        XCTAssertThrowsError(try MarkdownCacheService.generateReportedCacheContent(for: book)) {
            XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: self.standardLimit))
            XCTAssertTrue(($0 as? MarkupRefusal)?.errorDescription?.contains("128") == true)
        }
        XCTAssertFalse(MarkdownCacheService.cacheExists(for: book))
        // The callers that treat a failure as no cache get none.
        XCTAssertNil(MarkdownCacheService.generateCacheContent(for: book))
        XCTAssertFalse(MarkdownCacheService.cacheExists(for: book))
    }

    /// A deep chapter among others refuses the whole file the same way.
    func testImportingAFileWithOneDeepChapterIsRefused() throws {
        let book = try makeBook(source: contentWithAMiddleChapter(deepQuotes(around: "Quoted words")))

        XCTAssertThrowsError(try MarkdownCacheService.generateReportedCacheContent(for: book)) {
            XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: self.standardLimit))
        }
        XCTAssertFalse(MarkdownCacheService.cacheExists(for: book))
    }

    /// A refused rebuild leaves the text the book already has, as every failed rebuild does.
    func testARefusedRebuildKeepsTheCacheTheBookHas() throws {
        let book = try makeBook(source: "Shallow words.")
        XCTAssertNotNil(try MarkdownCacheService.generateReportedCacheContent(for: book))
        let cache = book.tmbDirectory.appendingPathComponent("content.md")
        let before = try Data(contentsOf: cache)

        try deepQuotes(around: "Quoted words").write(toFile: book.filePath, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MarkdownCacheService.generateReportedCacheContent(for: book))

        XCTAssertEqual(try Data(contentsOf: cache), before)
    }

    /// A file nested as books nest still imports.
    func testImportingAShallowFileStillWorks() throws {
        let book = try makeBook(source: "> A quote\n>\n> > A quote in a quote\n\n- an item\n  - an inner item")
        let generated = try XCTUnwrap(MarkdownCacheService.generateReportedCacheContent(for: book))
        XCTAssertTrue(generated.content.chapters.map(\.text).joined().contains("A quote in a quote"))
    }

    // MARK: - Reading content.md

    /// A refused chapter keeps its place and its raw text; its neighbours read as they did.
    func testARefusedChapterIsKeptAsWritten() {
        let deep = deepQuotes(around: "Quoted words")
        let content = MarkdownCacheService.parseMultiChapterMarkdown(
            contentWithAMiddleChapter(deep), bookTitle: "Book", bookAuthor: "Author"
        )

        XCTAssertEqual(content.chapters.map(\.title), ["First", "Second", "Third"])
        XCTAssertEqual(content.chapters[0].text, "First chapter words.")
        XCTAssertEqual(content.chapters[1].text, deep)
        XCTAssertEqual(content.chapters[2].text, "Third chapter words.")
        // A titled chapter appears in the heading list, as every titled chapter does.
        XCTAssertEqual(content.chapters[1].headings.map(\.text), ["Second"])
    }

    /// Where every chapter is refused, each still holds its words: the text holds something
    /// for Edit Text, which says "holds no chapter with anything in it" only when that is true.
    func testWhenEveryChapterIsRefusedEachStillHoldsItsWords() {
        let markdown = "<!-- chapter: One -->\n\(deepQuotes(around: "alpha"))\n\n<!-- chapter: Two -->\n\(deepQuotes(around: "beta"))"
        let content = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: "Book", bookAuthor: "")

        XCTAssertEqual(content.chapters.count, 2)
        XCTAssertTrue(content.chapters.allSatisfy { chapter in chapter.text.contains { !$0.isWhitespace } })
        XCTAssertTrue(content.chapters[0].text.hasSuffix("alpha"))
        XCTAssertTrue(content.chapters[1].text.hasSuffix("beta"))
    }

    /// A text with no chapter markers that is refused is one chapter of its raw text.
    func testARefusedTextWithNoMarkersIsOneRawChapter() {
        let deep = deepQuotes(around: "Quoted words")
        let content = MarkdownCacheService.parseMultiChapterMarkdown(deep, bookTitle: "Book", bookAuthor: "")
        XCTAssertEqual(content.chapters.map(\.text), [deep])
    }

    /// A text with nothing refused reads exactly as before, and writes no line.
    func testNothingRefusedLogsNothing() {
        let lines = logLines(in: .debug) {
            let content = MarkdownCacheService.parseMultiChapterMarkdown(
                "<!-- chapter: One -->\n> A quote\n\n<!-- chapter: Two -->\nWords.", bookTitle: "Book", bookAuthor: ""
            )
            XCTAssertEqual(content.chapters.map(\.text), ["A quote", "Words."])
        }
        XCTAssertEqual(lines.filter { $0.contains(MarkdownCacheService.keptRawLogTag) }, [])
    }

    /// The refusal is logged once for the whole parse, with counts and no words.
    func testTheRefusalIsLoggedOnceWithoutTheBooksWords() {
        let markdown = "<!-- chapter: Secretive Title -->\n\(deepQuotes(around: "alpha"))\n\n"
            + "<!-- chapter: Another -->\n\(deepQuotes(around: "beta"))\n\n<!-- chapter: Fine -->\nWords."
        let lines = logLines(in: .debug) {
            _ = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: "Hidden Book", bookAuthor: "")
        }

        let ours = lines.filter { $0.contains(MarkdownCacheService.keptRawLogTag) }
        XCTAssertEqual(ours.count, 1, "\(ours)")
        XCTAssertTrue(ours.first?.contains("2 of 3 chapters") == true, "\(ours)")
        for word in ["Secretive", "Hidden", "alpha", "beta"] {
            XCTAssertFalse(ours.joined().contains(word), word)
        }
    }

    // MARK: - The refusing parse

    /// The parse for a write throws for a deep chapter, and gives the content otherwise.
    func testTheRefusingParseThrowsForADeepChapterOnly() throws {
        XCTAssertThrowsError(
            try MarkdownCacheService.parseMultiChapterMarkdownRefusing(
                contentWithAMiddleChapter(deepQuotes(around: "Quoted words")), bookTitle: "Book", bookAuthor: ""
            )
        ) {
            XCTAssertEqual($0 as? MarkupRefusal, .nestedTooDeeply(limit: self.standardLimit))
        }
        XCTAssertThrowsError(
            try MarkdownCacheService.parseMultiChapterMarkdownRefusing(
                deepQuotes(around: "Quoted words"), bookTitle: "Book", bookAuthor: ""
            )
        )
        let fine = try MarkdownCacheService.parseMultiChapterMarkdownRefusing(
            contentWithAMiddleChapter("> Shallow"), bookTitle: "Book", bookAuthor: ""
        )
        XCTAssertEqual(fine.chapters.map(\.text), ["First chapter words.", "Shallow", "Third chapter words."])
    }
}
