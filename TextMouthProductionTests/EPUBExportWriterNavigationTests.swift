import XCTest
import ZIPFoundation
@testable import TextMouth

/// The EPUB writer's contents, summary, direction, languages, and pages: the
/// things a review of the first version found it said wrongly or not at all.
/// They share `EPUBExportWriterTests`' helpers (an extension of its class, so
/// the two files are one set of tests).
extension EPUBExportWriterTests {

    // MARK: - The Summary Follows the Entries Written (B4)

    /// The sentence of the accessibility summary about the contents follows the
    /// entries the navigation document really holds: real headings; none, with
    /// one entry; none, with several.
    func testTheSummaryFollowsTheEntriesReallyWritten() throws {
        func summary(_ markdown: String) throws -> (sentence: String, entries: Int) {
            let url = try export(markdown)
            let sentence = try XCTUnwrap(metas("schema:accessibilitySummary", in: package(of: url)).first)
            return (sentence, try navLinks("toc", in: url).count)
        }

        let headed = try summary("# One\n\nWords.")
        XCTAssertTrue(headed.sentence.contains("Its headings are real headings, and the contents list links them."), headed.sentence)
        XCTAssertFalse(headed.sentence.contains("no headings"))

        let single = try summary("Words only.")
        XCTAssertEqual(single.entries, 1)
        XCTAssertTrue(single.sentence.contains("It has no headings, so the contents list has one entry for the whole book."), single.sentence)

        let several = try summary("<!-- chapter: A -->\nOne.\n\n<!-- chapter: B -->\nTwo.\n\n<!-- chapter: C -->\nThree.")
        XCTAssertEqual(several.entries, 3)
        XCTAssertTrue(several.sentence.contains("It has no headings, so the contents list has 3 entries for its chapters and the places it marks."), several.sentence)
        XCTAssertFalse(several.sentence.contains("one entry for the whole book"))

        let paged = try summary("# One\n\n<!-- page: 1 -->\nWords.")
        XCTAssertTrue(paged.sentence.contains("It has a page list, and the start of each page is marked in the text."))
        XCTAssertFalse(headed.sentence.contains("page list"))
    }

    /// The summary function says the same of the same facts, whatever the book.
    func testTheSummaryFunctionFollowsItsFacts() {
        XCTAssertTrue(EPUBPackageBuilder.accessibilitySummary(hasHeadings: true, entryCount: 9, hasPages: false).contains("real headings"))
        XCTAssertTrue(EPUBPackageBuilder.accessibilitySummary(hasHeadings: false, entryCount: 1, hasPages: false).contains("one entry"))
        XCTAssertTrue(EPUBPackageBuilder.accessibilitySummary(hasHeadings: false, entryCount: 2, hasPages: false).contains("has 2 entries"))
        XCTAssertTrue(EPUBPackageBuilder.accessibilitySummary(hasHeadings: false, entryCount: 2, hasPages: true).contains("page list"))
    }

    /// The summary is marked as English, the language it is written in, and a
    /// book with pages states page break markers beside page navigation.
    func testTheSummaryIsMarkedEnglishAndPagesStatePageBreakMarkers() throws {
        let package = try package(of: export("<!-- page: 1 -->\nWords.", book: ExportBookDetails(title: "T", language: "fr")))
        XCTAssertTrue(package.contains("<meta property=\"schema:accessibilitySummary\" xml:lang=\"en\">"))
        XCTAssertEqual(
            metas("schema:accessibilityFeature", in: package),
            ["tableOfContents", "readingOrder", "pageNavigation", "pageBreakMarkers"]
        )
    }

    // MARK: - Places the Contents Point At (B3)

    /// A heading annotation is an empty target with an id and an entry of the
    /// contents at its level, in the chapter's file, in reading order.
    func testAHeadingAnnotationIsATargetAndAnEntry() throws {
        let aside = MarkdownHeadingAnnotation(level: 2, text: "An Aside").markdown
        let inline = MarkdownHeadingAnnotation(level: 2, text: "Midway").markdown
        let url = try export("# Top\n\nBefore.\n\n\(aside)\n\nAfter, with \(inline) a place inside.")
        let body = try bodyLines("OEBPS/chapter-1.xhtml", in: url)
        XCTAssertTrue(body.contains("<span id=\"target_1\"></span>"), "\(body)")
        XCTAssertTrue(body.contains("<p>After, with <span id=\"target_2\"></span> a place inside.</p>"), "\(body)")
        let links = try navLinks("toc", in: url)
        XCTAssertEqual(links.map(\.text), ["Top", "An Aside", "Midway"])
        XCTAssertEqual(links.map(\.address), ["chapter-1.xhtml#top", "chapter-1.xhtml#target_1", "chapter-1.xhtml#target_2"])
        XCTAssertEqual(links.map(\.depth), [1, 2, 2])
    }

    // MARK: - A Contents Entry for the Opening Words (S7)

    /// A book with text before its first heading has an entry named for the
    /// book that links the file, so the opening words can be reached from the
    /// contents; a chapter with a title is named by its title.
    func testTextBeforeTheFirstHeadingHasAnEntryForTheOpeningWords() throws {
        let book = try export("Opening words.\n\n## First\n\nWords.")
        XCTAssertEqual(try navLinks("toc", in: book).map(\.text), ["Harbour Notes", "First"])
        XCTAssertEqual(try navLinks("toc", in: book).map(\.address), ["chapter-1.xhtml", "chapter-1.xhtml#first"])
        XCTAssertEqual(try navLinks("toc", in: book).map(\.depth), [1, 2], "the headings nest under the opening entry")

        let chapters = try export("<!-- chapter: Prologue -->\nOpening words.\n\n## Part\n\nWords.\n\n<!-- chapter: Two -->\n# Two\n\nMore.")
        XCTAssertEqual(try navLinks("toc", in: chapters).map(\.text), ["Prologue", "Part", "Two"])
    }

    // MARK: - A Chapter of Only Pages (S2)

    /// A chapter of nothing but the start of a page joins the next file, so
    /// the page lands at the next words; its title stays in the contents.
    func testAChapterOfOnlyAPageJoinsTheNextFile() throws {
        let url = try export("<!-- chapter: One -->\n# One\n\nWords one.\n\n<!-- chapter: Plate -->\n<!-- page: 3 -->\n\n<!-- chapter: Two -->\n# Two\n\nWords two.")
        XCTAssertEqual(try chapterPaths(of: url), ["OEBPS/chapter-1.xhtml", "OEBPS/chapter-2.xhtml"])
        let second = try bodyLines("OEBPS/chapter-2.xhtml", in: url)
        XCTAssertTrue(try XCTUnwrap(second.first).contains("id=\"page_1\""), "the page opens the next file: \(second)")
        XCTAssertEqual(try navLinks("toc", in: url).map(\.text), ["One", "Plate", "Two"])
        XCTAssertEqual(try navLinks("page-list", in: url).map(\.address), ["chapter-2.xhtml#page_1"])
    }

    /// Pages at the very end join the chapter before them.
    func testAChapterOfOnlyPagesAtTheEndJoinsTheOneBefore() throws {
        let url = try export("<!-- chapter: One -->\n# One\n\nWords.\n\n<!-- chapter: End -->\n<!-- page: 9 -->")
        XCTAssertEqual(try chapterPaths(of: url), ["OEBPS/chapter-1.xhtml"])
        XCTAssertTrue(try XCTUnwrap(bodyLines("OEBPS/chapter-1.xhtml", in: url).last).contains("id=\"page_1\""))
    }

    /// A book of one chapter of only pages is that chapter (there is nothing to join).
    func testABookOfOnlyPagesIsOneFile() throws {
        let url = try export("<!-- page: 1 -->\n\n<!-- page: 2 -->")
        XCTAssertEqual(try chapterPaths(of: url).count, 1)
        XCTAssertEqual(try navLinks("page-list", in: url).count, 2)
    }

    /// A chapter of only a comment has no block and makes no file: the chapter
    /// after it is the first.
    func testAChapterOfOnlyACommentMakesNoFile() throws {
        let url = try export("<!-- chapter: A -->\n<!-- a plain comment -->\n\n<!-- chapter: B -->\nWords.")
        XCTAssertEqual(try chapterPaths(of: url), ["OEBPS/chapter-1.xhtml"])
        XCTAssertTrue(try text("OEBPS/chapter-1.xhtml", in: url).contains("<title>B</title>"))
    }

    // MARK: - Pages in Table Cells (S3)

    /// A page in a cell is written in the cell, after as many characters as
    /// come before it; the page list links it.
    func testAPageInATableCellIsWrittenInTheCell() throws {
        let url = try export("| A | B |\n|---|---|\n| xy <!-- page: 8 --> z | w |")
        let body = try bodyLines("OEBPS/chapter-1.xhtml", in: url).joined(separator: "\n")
        XCTAssertTrue(
            body.contains("<td>xy <span epub:type=\"pagebreak\" role=\"doc-pagebreak\" id=\"page_1\" aria-label=\"8\" title=\"8\"></span> z</td>"),
            body
        )
        XCTAssertEqual(try navLinks("page-list", in: url).map(\.text), ["8"])
    }

    // MARK: - Languages (S4)

    /// A language that is not well-formed is no language: the package says
    /// "und" and no document carries it. Well-formed ones stay.
    func testALanguageThatIsNotWellFormedSaysUndetermined() throws {
        for tag in ["en-a", "en-x", "en-1", "en-a-b", "en-US-US", "sr-Latn-Cyrl", "ab-cd-ef-gh-ij-kl", "aa-bbb-ccc-ddd-eee"] {
            XCTAssertNil(ExportBookDetails.languageTag(tag), tag)
            let url = try export("Words.", book: ExportBookDetails(title: "T", language: tag))
            XCTAssertTrue(try package(of: url).contains("<dc:language>und</dc:language>"), tag)
            XCTAssertFalse(try text("OEBPS/chapter-1.xhtml", in: url).contains("xml:lang=\"\(tag)\""), tag)
        }
        for tag in ["en", "zh-Hant-TW", "sr-Latn", "de-CH-1996", "es-419", "en-a-bbb-x-private", "zh-yue", "en-US-x-twain"] {
            XCTAssertEqual(ExportBookDetails.languageTag(tag), tag, tag)
        }
    }

    // MARK: - Page Labels (S5)

    /// A page whose label has no word left is named by its number among the
    /// pages, in the page list and on the element.
    func testAPageLabelWithNothingLeftIsNumbered() throws {
        let url = try export("<!-- page: 1 -->\nOne.\n\n<!-- page: %01 -->\nTwo.\n\n<!-- page: %EF%BF%BF -->\nThree.")
        XCTAssertEqual(try navLinks("page-list", in: url).map(\.text), ["1", "2", "3"])
        let chapter = try text("OEBPS/chapter-1.xhtml", in: url)
        XCTAssertTrue(chapter.contains("id=\"page_2\" aria-label=\"2\" title=\"2\""))
        try assertWellFormed(url)
    }

    // MARK: - Direction (S8)

    /// A right-to-left language sets the direction on the root of every
    /// document and the spine; a left-to-right one writes none; a book with
    /// no language lets each block guess from its words.
    func testDirectionFollowsTheLanguage() throws {
        let rtl = try export("# \u{5E9}\u{5DC}\u{5D5}\u{5DD}\n\nWords.", book: ExportBookDetails(title: "T", language: "he"))
        for path in ["OEBPS/chapter-1.xhtml", "OEBPS/nav.xhtml"] {
            XCTAssertTrue(try text(path, in: rtl).contains(" lang=\"he\" xml:lang=\"he\" dir=\"rtl\">"), path)
        }
        XCTAssertTrue(try package(of: rtl).contains("<spine page-progression-direction=\"rtl\">"))
        XCTAssertFalse(try text("OEBPS/chapter-1.xhtml", in: rtl).contains("dir=\"auto\""))

        let ltr = try export("# One\n\nWords.", book: ExportBookDetails(title: "T", language: "en"))
        XCTAssertFalse(try text("OEBPS/chapter-1.xhtml", in: ltr).contains("dir="))
        XCTAssertTrue(try package(of: ltr).contains("<spine>"))

        let unknown = try export("# One\n\nWords.\n\n- Item\n\n> Quote", book: ExportBookDetails(title: "T"))
        let body = try bodyLines("OEBPS/chapter-1.xhtml", in: unknown)
        XCTAssertTrue(body.contains("<h1 id=\"one\" dir=\"auto\">One</h1>"), "\(body)")
        XCTAssertTrue(body.contains("<p dir=\"auto\">Words.</p>"))
        XCTAssertTrue(body.contains("<li dir=\"auto\">Item</li>"))
        XCTAssertTrue(body.contains("<blockquote dir=\"auto\">"))
        XCTAssertFalse(try text("OEBPS/chapter-1.xhtml", in: unknown).contains("dir=\"rtl\""))
        XCTAssertTrue(try package(of: unknown).contains("<spine>"))
    }

    /// The right-to-left languages are the ones written so.
    func testTheRightToLeftLanguages() throws {
        for tag in ["ar", "ar-EG", "he", "fa", "ur", "yi", "ps", "sd", "ug", "dv", "ckb"] {
            let url = try export("Words.", book: ExportBookDetails(title: "T", language: tag))
            XCTAssertTrue(try package(of: url).contains("page-progression-direction=\"rtl\""), tag)
        }
        for tag in ["en", "fr", "de", "ja", "zh-Hans", "ru"] {
            let url = try export("Words.", book: ExportBookDetails(title: "T", language: tag))
            XCTAssertFalse(try package(of: url).contains("page-progression-direction"), tag)
        }
    }

    // MARK: - What the Navigation Document Says of Itself (S10)

    /// The navigation document names its roles, and the headings of its two
    /// lists are marked as the English they are.
    func testTheNavigationDocumentNamesItsRolesAndItsOwnLanguage() throws {
        let nav = try text("OEBPS/nav.xhtml", in: export("# One\n\n<!-- page: 1 -->\nWords.", book: ExportBookDetails(title: "T", language: "de")))
        XCTAssertTrue(nav.contains("<nav epub:type=\"toc\" role=\"doc-toc\" id=\"toc\">"))
        XCTAssertTrue(nav.contains("<h1 lang=\"en\" xml:lang=\"en\">Contents</h1>"))
        XCTAssertTrue(nav.contains("<nav epub:type=\"page-list\" role=\"doc-pagelist\" id=\"page-list\" hidden=\"hidden\">"))
        XCTAssertTrue(nav.contains("<h1 lang=\"en\" xml:lang=\"en\">Pages</h1>"))
    }

    /// Every file of the ZIP is dated by the export's own date, not the clock.
    func testTheZIPIsDatedByTheExportsDate() throws {
        let archive = try Archive(url: export("# One\n\nWords."), accessMode: .read)
        for entry in archive {
            let date = try XCTUnwrap(entry.fileAttributes[.modificationDate] as? Date, entry.path)
            XCTAssertLessThanOrEqual(abs(date.timeIntervalSince(Self.exportDate)), 2, "\(entry.path) is dated \(date)")
        }
    }

    // MARK: - Where a File Ends (S10)

    /// A file ends after the block that passes the limit when a heading
    /// follows, and the start of a page that belongs to that heading begins
    /// the next file, not ends the first.
    func testAFileEndsBeforeThePagesThatABeginHeadingBeginsWith() throws {
        let filler = String(repeating: "word ", count: 120)
        let url = try export("# One\n\n\(filler)\n\n<!-- page: 2 -->\n## Two\n\nTail.", writer: Self.writer(maximumFileBytes: 300))
        XCTAssertEqual(try chapterPaths(of: url).count, 2)
        let first = try bodyLines("OEBPS/chapter-1.xhtml", in: url)
        XCTAssertFalse(try XCTUnwrap(first.last).contains("pagebreak"), "the page is not left at the end of the first file")
        let second = try bodyLines("OEBPS/chapter-2.xhtml", in: url)
        XCTAssertTrue(try XCTUnwrap(second.first).contains("id=\"page_1\""), "\(second)")
        XCTAssertTrue(second[1].hasPrefix("<h2 "))
    }

    /// A run of only pages is not ended at, so the pages stay together in a
    /// file instead of a file for each: the file ends before the run, when a
    /// heading follows the run.
    func testARunOfOnlyPagesIsNotSplitAtEveryPage() throws {
        let filler = String(repeating: "word ", count: 700)
        let pages = (1...30).map { "<!-- page: \($0) -->" }.joined(separator: "\n\n")
        let url = try export("# One\n\n\(filler)\n\n\(pages)\n\n## Two\n\nTail.", writer: Self.writer(maximumFileBytes: 3_000))
        XCTAssertEqual(try chapterPaths(of: url).count, 2, "one file ends before the pages, and they go with the heading")
        let second = try bodyLines("OEBPS/chapter-2.xhtml", in: url)
        XCTAssertEqual(second.filter { $0.contains("pagebreak") }.count, 30)
    }

    // MARK: - A File Cut Short Is Not an Export (B6)

    /// A file that holds every entry passes; one cut short, or holding other
    /// entries, does not.
    func testAFileCutShortOrWithOtherEntriesIsNotAnExport() throws {
        let url = try export("# One\n\nWords.")
        let all = try paths(of: url)
        XCTAssertNoThrow(try EPUBExportWriter.verify(url, holds: all))
        XCTAssertThrowsError(try EPUBExportWriter.verify(url, holds: Array(all.dropLast())))
        XCTAssertThrowsError(try EPUBExportWriter.verify(url, holds: all + ["OEBPS/extra.xhtml"]))

        let size = try Data(contentsOf: url).count
        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: UInt64(size - 10))
        try handle.close()
        XCTAssertThrowsError(try EPUBExportWriter.verify(url, holds: all))
    }
}
