import Combine
import XCTest
import ZIPFoundation
@testable import TextMouth

/// Exercise the actual EPUB import, Markdown cache, and reader index together.
final class EPUBHeadingRecoveryTests: XCTestCase {
    /// Reproduce the reported shape without including any copyrighted book text:
    /// 122 spine documents, 27 semantic headings, and an incomplete EPUB 3 TOC.
    func testSparseNavigationRecoversAll122ChaptersWithoutChangingSpeech() throws {
        let book = try makeSparseBook()
        let cached = try MarkdownCacheService.loadFromCache(for: book)
        let direct = try EPUBParser.parse(url: URL(fileURLWithPath: book.filePath))

        for content in [cached, direct] {
            XCTAssertEqual(content.chapters.count, 122)
            XCTAssertEqual(content.allHeadings.count, 127)
            XCTAssertEqual(Set(content.allHeadings.map(\.chapterIndex)), Set(0..<122))
            XCTAssertEqual(content.chapters[30].title, "Section 31 from Contents")
            XCTAssertEqual(content.chapters[110].title, "Chapter 111")
            XCTAssertEqual(content.chapters[30].text, "Styled section 31\n\nBody 31.")
            XCTAssertEqual(content.chapters[110].text, "Styled section 111\n\nBody 111.")
        }
        XCTAssertEqual(cached.allHeadings, direct.allHeadings)
        XCTAssertEqual(cached.chapters.map(\.text), direct.chapters.map(\.text))
    }

    /// Resolve URLs against the navigation document, retain nested fragment
    /// targets, and prefer actual headings when a TOC points at the same text.
    func testEPUB3NavigationRetainsFragmentHeadingsAndIgnoresPageLists() throws {
        let html = """
        <html><body><h1 id="opening">Opening</h1>
        <p>🙂 Detail was mentioned earlier.</p><p id="detail">Detail</p><p>Ending.</p></body></html>
        """
        let book = try makeBook(
            chapters: [("Text/chapter one.xhtml", html)],
            extraFiles: ["Navigation/nested/nav.xhtml": """
            <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
            <nav epub:type="page-list"><ol><li><a href="../../Text/chapter%20one.xhtml">Page 9</a></li></ol></nav>
            <nav epub:type="toc"><ol>
            <li><a href="../../Text/./chapter%20one.xhtml#opening">Opening from TOC</a><ol>
              <li><a href="../../Text/chapter%20one.xhtml#detail">Detail</a></li>
              <li><a href="../../Text/chapter%20one.xhtml#detail">Duplicate target</a></li>
            </ol></li>
            <li><a href="https://example.invalid/Text/chapter%20one.xhtml">External</a></li>
            </ol></nav></body></html>
            """],
            manifest: """
            <item id="nav" href="../Navigation/nested/nav.xhtml" media-type="application/xhtml+xml" properties="scripted nav"/>
            """
        )
        let content = try MarkdownCacheService.loadFromCache(for: book)
        let chapter = try XCTUnwrap(content.chapters.first)
        XCTAssertEqual(content.allHeadings.map(\.text), ["Opening", "Detail"])
        XCTAssertEqual(content.allHeadings.map(\.level), [1, 2])
        let target = try XCTUnwrap(chapter.text.range(of: "Detail", options: .backwards))
        XCTAssertEqual(content.allHeadings.last?.characterOffset, chapter.text.utf16Offset(of: target.lowerBound))
        let direct = try EPUBParser.parse(url: URL(fileURLWithPath: book.filePath))
        XCTAssertEqual(direct.allHeadings, content.allHeadings)
        XCTAssertEqual(direct.chapters.map(\.text), content.chapters.map(\.text))
    }

    /// NCX references are relative to the NCX, including sibling directories,
    /// encoded filenames, and nested sections within the same spine document.
    func testNestedNCXUsesDeclaredSpineTOCAndCanonicalPaths() throws {
        let book = try makeBook(
            chapters: [("Text/part one.xhtml", "<p id='part'>Part</p><p>🙂 Body.</p><p id='section'>Section</p>")],
            extraFiles: [
                "Navigation/nested/toc.ncx": """
                <ncx><navMap><navPoint><navLabel><text>Part from NCX</text></navLabel>
                <content src="../../Text/part%20one.xhtml#part"/>
                <navPoint><navLabel><text>Section from NCX</text></navLabel>
                <content src="../../Text/./part%20one.xhtml#section"/></navPoint>
                </navPoint></navMap></ncx>
                """,
                "Navigation/unused.ncx": """
                <ncx><navMap><navPoint><navLabel><text>Wrong TOC</text></navLabel>
                <content src="../Text/part%20one.xhtml#part"/></navPoint></navMap></ncx>
                """
            ],
            manifest: """
            <item id="unused" href="../Navigation/unused.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="toc" href="../Navigation/nested/toc.ncx" media-type="application/x-dtbncx+xml"/>
            """,
            spineAttributes: "toc='toc'"
        )
        let content = try MarkdownCacheService.loadFromCache(for: book)
        XCTAssertEqual(content.allHeadings.map(\.text), ["Part from NCX", "Section from NCX"])
        XCTAssertEqual(content.allHeadings.map(\.level), [1, 2])
        XCTAssertEqual(content.chapters.first?.text, "Part\n\n🙂 Body.\n\nSection")
        XCTAssertEqual(content.allHeadings.last?.characterOffset, "Part\n\n🙂 Body.\n\n".utf16.count)
        let direct = try EPUBParser.parse(url: URL(fileURLWithPath: book.filePath))
        XCTAssertEqual(direct.allHeadings, content.allHeadings)
    }

    /// Every spine chapter needs a start destination even if its only semantic
    /// heading is a later subsection. Ordinary prose links are not a TOC.
    func testUnlistedChaptersUseDistinctDocumentTitlesThenNumberedFallbacks() throws {
        let book = try makeBook(chapters: [
            ("Text/one.xhtml", "<html><head><title>Fixture Book</title></head><body><p>Opening.</p><h2>Later section</h2></body></html>"),
            ("Text/two.xhtml", "<html><head><title>A useful title</title></head><body><p>Body.</p></body></html>"),
            ("Text/three.xhtml", "<p>Read <a href='two.xhtml'>an unrelated link</a>.</p>")
        ])
        let content = try MarkdownCacheService.loadFromCache(for: book)
        XCTAssertEqual(content.chapters.map(\.title), ["Chapter 1", "A useful title", "Chapter 3"])
        XCTAssertEqual(content.chapters[0].headings.map(\.text), ["Chapter 1", "Later section"])
        XCTAssertEqual(content.chapters[0].headings.map(\.characterOffset), [0, "Opening.\n\n".utf16.count])
        XCTAssertEqual(content.chapters[1].text, "Body.")
    }

    /// Labels are navigation metadata, not Markdown or extra spoken text. This
    /// also covers a one-document EPUB, where chapter markers used to be lost.
    func testSingleChapterNavigationLabelsPreserveLiteralPunctuation() throws {
        let label = "*Literal* [title] `code` <!-- marker --> 🙂"
        let book = try makeBook(
            chapters: [("Text/one.xhtml", "<p>Original speech.</p>")],
            extraFiles: ["Navigation/nav.xhtml": """
            <nav xmlns:epub="http://www.idpf.org/2007/ops" epub:type="toc"><ol>
            <li><a href="../Text/one.xhtml">\(xmlEscaped(label))</a></li>
            </ol></nav>
            """],
            manifest: "<item id='nav' href='../Navigation/nav.xhtml' media-type='application/xhtml+xml' properties='nav'/>"
        )
        let content = try MarkdownCacheService.loadFromCache(for: book)
        XCTAssertEqual(content.allHeadings.map(\.text), [label])
        XCTAssertEqual(content.chapters.first?.text, "Original speech.")
    }

    /// Inline and list-item anchors must survive conversion at their own text
    /// positions, including fragment-only links in an in-spine navigation file.
    func testInlineAndListTargetsKeepTextAndFragmentOnlyCoordinates() throws {
        let html = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="toc"><ol><li><a href="#inline">Inline label</a></li>
        <li><a href="#item">List label</a></li></ol></nav>
        <h1>Start</h1><p>🙂 Before <span id="inline">after</span>.</p>
        <ul><li id="item">Item</li></ul></body></html>
        """
        let book = try makeBook(chapters: [("Text/one.xhtml", html)], navigationSpineIndex: 0)
        let content = try MarkdownCacheService.loadFromCache(for: book)
        let chapter = try XCTUnwrap(content.chapters.first)
        let unannotated = try EPUBParser.parseChapterHTML(html)
        XCTAssertEqual(chapter.text, unannotated.text)
        XCTAssertEqual(chapter.headings.map(\.text), ["Start", "Inline label", "List label"])
        for (label, targetText) in [("Inline label", "after"), ("List label", "Item")] {
            let range = try XCTUnwrap(chapter.text.range(of: targetText))
            XCTAssertEqual(chapter.headings.first { $0.text == label }?.characterOffset, chapter.text.utf16Offset(of: range.lowerBound))
        }
    }

    /// A section-only TOC must not give the chapter's start the same name as a
    /// later target; missing fragment targets still get a usable chapter entry.
    func testPartialAndBrokenNavigationStillProvideChapterStarts() throws {
        let book = try makeBook(
            chapters: [
                ("Text/one.xhtml", "<p>Introduction.</p><p id='detail'>Detail.</p>"),
                ("Text/two.xhtml", "<h1></h1><p>Original.</p>")
            ],
            extraFiles: ["Navigation/nav.xhtml": """
            <nav xmlns:ops="http://www.idpf.org/2007/ops" ops:type="toc"><ol>
            <li><a href="../Text/one.xhtml#detail">Detail label</a></li>
            <li><a href="../Text/two.xhtml#missing">Recovered title</a></li>
            </ol></nav>
            """],
            manifest: "<item id='nav' href='../Navigation/nav.xhtml' media-type='application/xhtml+xml' properties='nav'/>"
        )
        let content = try MarkdownCacheService.loadFromCache(for: book)
        XCTAssertEqual(content.chapters[0].headings.map(\.text), ["Chapter 1", "Detail label"])
        XCTAssertEqual(content.chapters[1].headings.map(\.text), ["Recovered title"])
        XCTAssertEqual(content.chapters[1].text, "Original.")
    }

    /// An EPUB 2 guide may identify a visible TOC outside the spine. It should
    /// supply names without adding its own document to the chapter count.
    func testGuideTOCOutsideSpineSuppliesChapterNames() throws {
        let book = try makeBook(
            chapters: [("Text/one.xhtml", "<p>Body.</p>")],
            extraFiles: ["Navigation/contents.xhtml": """
            <p><a href="../Text/one.xhtml">Unrelated header</a></p>
            <section id="book-toc"><p><a href="../Text/one.xhtml">Title from guide</a></p></section>
            """],
            guide: "<guide><reference type='toc' href='../Navigation/contents.xhtml#book-toc'/></guide>"
        )
        let content = try MarkdownCacheService.loadFromCache(for: book)
        XCTAssertEqual(content.chapters.count, 1)
        XCTAssertEqual(content.allHeadings.map(\.text), ["Title from guide"])
        XCTAssertEqual(content.chapters.first?.text, "Body.")
    }

    /// Retain image-only spine documents and their navigation identities, even
    /// when their speech duration is zero and the next chapter shares an offset.
    func testImageOnlyChapterRetainsNavigationWithZeroTextDuration() throws {
        let book = try makeBook(chapters: [
            ("Text/cover.xhtml", "<img src='cover.jpg' alt=''/>"),
            ("Text/main.xhtml", "<h1>Main</h1><p>Reading text.</p>")
        ])
        let content = try MarkdownCacheService.loadFromCache(for: book)
        XCTAssertEqual(content.chapters.count, 2)
        XCTAssertEqual(content.chapters[0].text, "")
        XCTAssertEqual(content.allHeadings.map(\.text), ["Chapter 1", "Main"])
        XCTAssertEqual(Set(content.allHeadings.map(\.id)).count, 2)
        XCTAssertEqual(content.globalOffset(chapterIndex: 1, localOffset: 0), 0)
        let startRemaining = content.estimatedTimeRemaining(fromGlobalOffset: 0, wpm: 200)
        XCTAssertTrue(startRemaining.isFinite)
        XCTAssertEqual(startRemaining, content.estimatedReadingTime(wpm: 200))
    }

    /// The actual reader exposes recovered destinations to the heading screen
    /// and moves its cursor to an originally missing chapter when activated.
    @MainActor
    func testReaderPublishesAndNavigatesToRecoveredChapter() async throws {
        let book = try makeSparseBook()
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let savedAutoPlay = settings.autoPlayOnNavigate
        settings.autoPlayOnNavigate = false
        defer { settings.autoPlayOnNavigate = savedAutoPlay }
        let reader = ReaderViewModel(book: book, libraryViewModel: library, settingsViewModel: settings)
        defer { reader.close() }
        let loaded = expectation(description: "EPUB reader loaded")
        let subscription = reader.$isLoading.filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        defer { subscription.cancel() }
        await fulfillment(of: [loaded], timeout: 10)

        XCTAssertNil(reader.errorMessage)
        XCTAssertEqual(reader.headings.count, 127)
        let heading = try XCTUnwrap(reader.headings.first { $0.chapterIndex == 30 })
        XCTAssertEqual(heading.text, "Section 31 from Contents")
        XCTAssertTrue(HeadingNavigatorView.accessibilityDescription(text: heading.text, level: heading.level).hasPrefix(heading.text))
        reader.navigateToHeading(heading)
        XCTAssertEqual(reader.currentChapterIndex, 30)
        XCTAssertEqual(reader.currentCharacterOffset, 0)
    }

    /// Ordinary comments and malformed metadata cannot invent destinations.
    /// Code samples containing our syntax remain code, not navigation.
    func testHeadingAnnotationsAreOptInAndDoNotConsumeOrdinaryComments() throws {
        let annotation = MarkdownHeadingAnnotation(level: 2, text: "Metadata title")
        let markdown = "\(annotation.markdown)\n\nBody.\n\n<!-- ordinary -->\n\n<!-- textmouth-heading: invalid -->"
        let plain = try MarkdownDocParser.parseChapter(markdown: markdown)
        let cached = try MarkdownDocParser.parseChapter(markdown: markdown, includeNavigationHeadings: true)
        XCTAssertTrue(plain.headings.isEmpty)
        XCTAssertEqual(cached.headings.map(\.text), ["Metadata title"])
        XCTAssertEqual(cached.text, plain.text)
        let code = try MarkdownDocParser.parseChapter(markdown: "```\n\(annotation.markdown)\n```", includeNavigationHeadings: true)
        XCTAssertTrue(code.headings.isEmpty)
        XCTAssertTrue(code.text.contains(annotation.markdown))
    }

    /// A reader opening a 3.0.3 package must replace its stale 27-heading index
    /// with the repaired cache/index while keeping text coordinates and state.
    func testOutdatedCacheAndPersistedIndexAreRebuiltTogether() throws {
        var book = try makeSparseBook()
        let legacyMarkdown = try sparseChapters().map { _, html in
            let markdown = try HTMLToMarkdownConverter.convert(html, stripDuplicateNavigation: true)
            return "<!-- chapter:  -->\n\(markdown)"
        }.joined(separator: "\n\n")
        try legacyMarkdown.write(to: book.tmbDirectory.appendingPathComponent("content.md"), atomically: true, encoding: .utf8)
        book.cacheFormatVersion = "3.0.3"
        book.readingPosition = ReadingPosition(chapterIndex: 30, characterOffset: 19)
        // Stored dates intentionally have whole-second precision.
        book.readingPosition?.lastUpdated = Date(timeIntervalSince1970: 1_000)
        book.bookmarks = [Bookmark(number: 1, chapterIndex: 30, characterOffset: 19, label: "Saved location", dateCreated: Date(timeIntervalSince1970: 1_000))]
        let legacyContent = try MarkdownCacheService.loadFromCache(for: book)
        XCTAssertEqual(legacyContent.allHeadings.count, 27)
        let oldIndex = legacyContent.contentIndex.replacingFormat(.epub)
        book.skippedHeadingIDs = [try XCTUnwrap(legacyContent.allHeadings.first?.id)]
        try book.saveBookInfoThrowing(contentIndex: oldIndex)

        let result = try BookContentAnalysisService.load(
            book: book,
            regenerateTextCache: MarkdownCacheService.isCacheOutdated(stored: book.cacheFormatVersion)
        )
        XCTAssertFalse(result.usedPersistedIndex)
        XCTAssertEqual(result.content.allHeadings.count, 127)
        XCTAssertEqual(result.content.chapters.map(\.text), legacyContent.chapters.map(\.text))
        XCTAssertEqual(result.index.totalCharacterCount, oldIndex.totalCharacterCount)
        XCTAssertEqual(result.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        try LibraryPersistenceService.saveContentAnalysis(for: book, index: result.index, cacheFormatVersion: result.cacheFormatVersion)
        book.cacheFormatVersion = result.cacheFormatVersion
        let reopened = try BookContentAnalysisService.load(book: book)
        XCTAssertTrue(reopened.usedPersistedIndex)
        XCTAssertEqual(reopened.content.allHeadings, result.content.allHeadings)
        let info = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(info.state.readingPosition, book.readingPosition)
        XCTAssertEqual(info.bookmarks, book.bookmarks)
        XCTAssertEqual(info.state.skippedHeadingIDs, book.skippedHeadingIDs)
        XCTAssertTrue(Set(legacyContent.allHeadings.map(\.id)).isSubset(of: Set(result.content.allHeadings.map(\.id))))
    }

    /// Direct HTML and EPUB parsing must locate the actual heading occurrence,
    /// after repeated body labels and text requiring UTF-16 coordinates.
    func testDirectHTMLAndEPUBHeadingOffsetsMatchTheirActualText() throws {
        let html = "<p>🙂 Repeat appears here first.</p><h2>Repeat</h2><p>After.</p>"
        let chapters = [
            try EPUBParser.parseChapterHTML(html),
            try XCTUnwrap(HTMLParser.parse(html: html).chapters.first)
        ]
        for chapter in chapters {
            let actual = try XCTUnwrap(chapter.text.range(of: "Repeat", options: .backwards))
            XCTAssertEqual(chapter.headings.first?.characterOffset, chapter.text.utf16Offset(of: actual.lowerBound))
        }
    }

    /// Fixing direct HTML coordinates must preserve source words and literal
    /// punctuation rather than accidentally interpreting them as Markdown.
    func testDirectHTMLPreservesLiteralTextAndPreformattedWhitespace() throws {
        let html = """
        <p>🙂 Repeat uses &lt;literal&gt;, *asterisks*, [brackets], and `backticks`.</p>
        <h2>Repeat</h2><pre>one  two\n  three</pre><p>After.</p>
        """
        let chapter = try XCTUnwrap(HTMLParser.parse(html: html).chapters.first)
        XCTAssertEqual(chapter.text, "🙂 Repeat uses <literal>, *asterisks*, [brackets], and `backticks`. Repeat one  two\n  three After.")
        let range = try XCTUnwrap(chapter.text.range(of: "Repeat", options: .backwards))
        XCTAssertEqual(chapter.headings.first?.characterOffset, chapter.text.utf16Offset(of: range.lowerBound))
    }

    /// Optional corpus verification uses only a disposable copy supplied by the
    /// build setting. Ordinary test runs have no dependency on a user's library.
    func testCopiedHelliconiaRetainsTextAndRecoversEveryChapter() throws {
        let fixturePath = Bundle(for: Self.self).object(forInfoDictionaryKey: "TextMouthEPUBRegressionFixture") as? String ?? ""
        guard !fixturePath.isEmpty, !fixturePath.hasPrefix("$(") else {
            throw XCTSkip("Set TEXTMOUTH_EPUB_REGRESSION_FIXTURE to a copied EPUB package.")
        }
        let fixture = URL(fileURLWithPath: fixturePath)
        let oldMarkdown = try String(contentsOf: fixture.appendingPathComponent("content.md"), encoding: .utf8)
        let previous = MarkdownCacheService.parseMultiChapterMarkdown(oldMarkdown, bookTitle: "Fixture", bookAuthor: "")
        let source = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture, includingPropertiesForKeys: nil).first { $0.pathExtension == "epub" })
        var book = try FileImportService.importFile(from: source)
        let package = book.tmbDirectory
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        // Compare the full regeneration/index path before and after performance
        // changes. Timing is diagnostic, never a flaky test pass/fail threshold.
        let clock = ContinuousClock()
        var durations: [Double] = []
        for _ in 0..<3 {
            let start = clock.now
            let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &book))
            let elapsed = start.duration(to: clock.now).components
            durations.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            XCTAssertEqual(index.allHeadings.count, 127)
        }
        print("EPUB_CACHE_REBUILD_SECONDS \(durations)")
        // Profile a bounded batch against serial execution using independent
        // disposable copies, so the comparison includes real parsing and writes.
        let batchBooks = try (0..<4).map { _ -> Book in
            var copy = Book(
                title: book.title, author: book.author, format: book.format,
                filePath: "", md5Hash: book.md5Hash, folderPath: book.folderPath,
                tmbDirectoryName: "CacheBatch-\(UUID().uuidString).tmb"
            )
            let directory = copy.tmbDirectory
            try FileManager.default.copyItem(at: package, to: directory)
            copy.filePath = directory.appendingPathComponent(URL(fileURLWithPath: book.filePath).lastPathComponent).path
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            return copy
        }
        for workers in [1, 2] {
            let finished = expectation(description: "Cache batch with \(workers) workers")
            let start = clock.now
            TextCacheUpdateQueue.run(books: batchBooks, concurrentEPUBs: workers, update: { original in
                var copy = original
                let index = MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &copy)
                XCTAssertEqual(index?.allHeadings.count, 127)
            }, completion: { finished.fulfill() })
            wait(for: [finished], timeout: 60)
            let elapsed = start.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            print("EPUB_BATCH_SECONDS workers=\(workers) seconds=\(seconds)")
        }
        let current = try MarkdownCacheService.loadFromCache(for: book)
        XCTAssertEqual(previous.chapters.count, 122)
        XCTAssertEqual(previous.allHeadings.count, 27)
        XCTAssertEqual(current.chapters.count, 122)
        XCTAssertEqual(current.allHeadings.count, 127)
        XCTAssertEqual(Set(current.allHeadings.map(\.chapterIndex)), Set(0..<122))
        // Report chapter numbers on failure without dumping an entire novel.
        for (index, pair) in zip(current.chapters, previous.chapters).enumerated() {
            XCTAssertTrue(pair.0.text == pair.1.text, "Reading text changed in chapter \(index + 1)")
        }
        XCTAssertTrue(Set(previous.allHeadings.map(\.id)).isSubset(of: Set(current.allHeadings.map(\.id))))
        XCTAssertTrue(current.chapters[17].title.contains("Death of a Grandfather"))
    }

    /// Create a sparse-navigation book with a conventional in-body contents
    /// section, matching the structure observed in the reported EPUB.
    private func makeSparseBook() throws -> Book {
        try makeBook(chapters: sparseChapters(), extraFiles: ["Navigation/nav.xhtml": """
        <nav xmlns:epub="http://www.idpf.org/2007/ops" epub:type="toc"><ol>
        <li><a href="../Text/chapter1.xhtml">Heading 1</a></li></ol></nav>
        """], manifest: "<item id='nav' href='../Navigation/nav.xhtml' media-type='application/xhtml+xml' properties='nav'/>")
    }

    /// Keep the fixture text stable so a regression can compare every chapter's
    /// speech before and after navigation repair, not merely heading counts.
    private func sparseChapters() -> [(String, String)] {
        (1...122).map { number in
            let body: String
            if number == 1 {
                let headings = (1...6).map { "<h1>Heading \($0)</h1>" }.joined()
                let links = (23...105).map { "<p><a href='chapter\($0).xhtml'>Section \($0) from Contents</a></p>" }.joined()
                body = "\(headings)<section id='contents'>\(links)</section>"
            } else if number <= 22 {
                body = "<h1>Heading \(number)</h1><p>Body \(number).</p>"
            } else {
                body = "<section><p class='p3'>Styled section \(number)</p><p>Body \(number).</p></section>"
            }
            return ("Text/chapter\(number).xhtml", "<html><head><title>Fixture Book</title></head><body>\(body)</body></html>")
        }
    }

    /// Build and import a real ZIP in the hosted tests' isolated library.
    private func makeBook(
        chapters: [(String, String)],
        extraFiles: [String: String] = [:],
        manifest: String = "",
        spineAttributes: String = "",
        navigationSpineIndex: Int? = nil,
        guide: String = ""
    ) throws -> Book {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source")
        var files = extraFiles
        var chapterManifest = ""
        var spine = ""
        for (index, chapter) in chapters.enumerated() {
            files[chapter.0] = chapter.1
            let href = chapter.0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chapter.0
            let properties = navigationSpineIndex == index ? "properties='nav'" : ""
            chapterManifest += "<item id='c\(index)' href='../\(xmlEscaped(href))' media-type='application/xhtml+xml' \(properties)/>"
            spine += "<itemref idref='c\(index)'/>"
        }
        files["META-INF/container.xml"] = "<container><rootfiles><rootfile full-path='Package/package.opf'/></rootfiles></container>"
        files["Package/package.opf"] = """
        <package><metadata><title>Fixture Book</title><creator>Test Author</creator></metadata>
        <manifest>\(chapterManifest)\(manifest)</manifest><spine \(spineAttributes)>\(spine)</spine>\(guide)</package>
        """
        for (path, text) in files {
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        let archive = directory.appendingPathComponent("book.epub")
        try FileManager.default.zipItem(at: source, to: archive, shouldKeepParent: false)
        let book = try FileImportService.importFile(from: archive)
        addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        return book
    }

    /// Escape fixture metadata once for both XML text and attribute contexts.
    private func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
