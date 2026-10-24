import XCTest
import SwiftSoup
@testable import TextMouth

/// EPUB page lists and page-break markup, and the HTML converter's (PG05).
///
/// A book's pages are the publisher's page list when it has one (the EPUB 3
/// navigation document's `page-list` or the EPUB 2 NCX's `pageList`), else its
/// page-break elements. Each page is written into the chapter's Markdown as a
/// page marker that is never spoken, and a page-break element's own page
/// number (which CSS hides from sighted readers) is not read, though any other
/// words in it are (ST02). These
/// tests read the synthetic samples of `TestData/format-samples/epub3-pages`
/// and `epub2-pages` (made by `make_epub_pages.py`) through
/// `EPUBParser.prepareBook` and check where each page begins, by the words of
/// the reading text that follow its offset.
final class EPUBPageListTests: XCTestCase {

    // MARK: - Helpers

    /// The reading text of `chapter` from the page's offset to its end, found
    /// through UTF-16 as every saved place is.
    private func text(from page: PageBreak, in chapter: Chapter) -> String {
        let units = Array(chapter.text.utf16)
        guard page.characterOffset >= 0, page.characterOffset <= units.count else { return "" }
        return String(decoding: units[page.characterOffset...], as: UTF16.self)
    }

    /// Check that `chapter` holds exactly the pages `expected` names, in order,
    /// each with its label and the words its offset begins.
    private func assertPages(
        of chapter: Chapter,
        _ expected: [(label: String, begins: String)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(chapter.pages.map(\.label), expected.map(\.label), file: file, line: line)
        guard chapter.pages.count == expected.count else { return }
        for (page, wanted) in zip(chapter.pages, expected) {
            XCTAssertEqual(page.chapterIndex, 0, "a parse leaves the chapter index 0", file: file, line: line)
            XCTAssertTrue(
                text(from: page, in: chapter).hasPrefix(wanted.begins),
                "page \(wanted.label) should begin at “\(wanted.begins)” but begins at “\(text(from: page, in: chapter).prefix(30))”",
                file: file, line: line
            )
        }
    }

    /// The chapters of a sample read with or without pages, from a copy.
    private func chaptersOf(_ sample: String, includesPages: Bool = true) throws -> [EPUBParser.PreparedChapter] {
        try EPUBParser.prepareBook(url: copyOfFormatSample(sample), includesPages: includesPages).chapters
    }

    /// Markdown converted from `html`, and the chapter it parses to with the
    /// page markers read, as content.md is read.
    private func parsed(
        _ html: String,
        pages: HTMLPageTargets = HTMLPageTargets(),
        includesPages: Bool = true
    ) throws -> (markdown: String, chapter: Chapter) {
        let markdown = try HTMLToMarkdownConverter.convert(html, pages: pages, includesPages: includesPages)
        let chapter = try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true)
        return (markdown, chapter)
    }

    /// Write an EPUB 3 to a new file in a folder of this test's own: the
    /// package document is built here from `manifest`, `spine`, and the
    /// attributes of the spine element; `members` are the other files, by
    /// path under OEBPS/ and text.
    private func makeEPUB(
        manifest: String,
        spine: String,
        spineAttributes: String = "",
        members: [String: String]
    ) throws -> URL {
        let package = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>Page Test \(UUID().uuidString)</dc:title><dc:language>en</dc:language>
            </metadata>
            <manifest>\(manifest)</manifest>
            <spine\(spineAttributes)>\(spine)</spine>
            </package>
            """
        var entries = [
            TestZIPEntry("mimetype", Data("application/epub+zip".utf8)),
            TestZIPEntry("META-INF/container.xml", Data("""
                <?xml version="1.0"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
                """.utf8)),
            TestZIPEntry("OEBPS/content.opf", Data(package.utf8)),
        ]
        for (path, content) in members.sorted(by: { $0.key < $1.key }) {
            entries.append(TestZIPEntry("OEBPS/\(path)", Data(content.utf8)))
        }
        let zip = try makeTemporaryZip(prefix: "TextMouthPageTest", orderedEntries: entries)
        let folder = try makeSandboxDirectory("EPUBPages")
        let epub = folder.appendingPathComponent("book.epub")
        try FileManager.default.moveItem(at: zip, to: epub)
        return epub
    }

    /// An XHTML document whose body is `body`.
    private func xhtml(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>T</title></head><body>\(body)</body></html>
        """
    }

    // MARK: - The EPUB 3 page list

    /// The page list names the pages in its own order, with its own labels,
    /// each at the first word of the element it links to: a chapter's start,
    /// an empty span before a paragraph, a page-break element in a paragraph,
    /// a heading, a place inside a word, and a paragraph in the next chapter.
    /// A label repeated is two pages.
    func testThePageListNamesThePagesInItsOrderAtTheWordsEachBegins() throws {
        let chapters = try chaptersOf("epub3-pages/page-list.epub")
        XCTAssertEqual(chapters.count, 2)
        guard chapters.count == 2 else { return }
        let (first, second) = (chapters[0].chapter, chapters[1].chapter)

        assertPages(of: first, [
            ("i", "First Delivery"),
            ("ii", "The crate came in"),
            ("1", "until somebody signed"),
            ("2", "Opening the Crate"),
            ("3", "telephone and a coil"),
            ("3", "The coil was wound"),
        ])
        assertPages(of: second, [("4", "The second crate held")])
        XCTAssertEqual(first.pages.first?.characterOffset, 0, "page i begins the chapter")
    }

    /// A page-break element's own number is not read, whether the list names
    /// it (the "1") or not (the "99"), and a page inside a word leaves the word
    /// whole. (Words in a page-break element are read: see ST02 below.)
    func testAPageBreaksOwnNumberIsNotRead() throws {
        let chapters = try chaptersOf("epub3-pages/page-list.epub")
        guard let first = chapters.first?.chapter else { return XCTFail("no chapter") }

        XCTAssertTrue(first.text.contains("sat by the door until somebody signed for it."), first.text)
        XCTAssertTrue(first.text.contains("pencilled a note in the margin."), first.text)
        XCTAssertTrue(first.text.contains("a brass telephone and a coil of cable."), first.text)
        XCTAssertFalse(first.text.contains("99"), first.text)
        XCTAssertFalse(first.text.contains("door 1"), first.text)
    }

    /// The page-break element the list does not name is no page, and an entry
    /// whose target lies in hidden content is dropped with that content.
    func testAnUnlistedPageBreakAndAHiddenTargetAreNotPages() throws {
        let chapters = try chaptersOf("epub3-pages/page-list.epub")
        guard let first = chapters.first?.chapter else { return XCTFail("no chapter") }

        XCTAssertFalse(first.pages.map(\.label).contains("99"))
        XCTAssertFalse(first.pages.map(\.label).contains("H1"))
        XCTAssertFalse(first.text.contains("This paragraph is not shown"), "hidden content is not read")
        XCTAssertEqual(first.pages.count, 6)
    }

    /// An element that is a page-list target and a TOC target gets the page
    /// marker first, then the heading annotation, and both name the same place.
    func testAPageTargetThatIsAlsoATOCTargetWritesThePageFirst() throws {
        let chapters = try chaptersOf("epub3-pages/page-list.epub")
        guard let first = chapters.first else { return XCTFail("no chapter") }

        let page = first.markdown.range(of: "<!-- page: 2 -->")
        let annotation = first.markdown.range(of: MarkdownHeadingAnnotation(level: 2, text: "Opening the Crate").markdown)
        guard let page, let annotation else { return XCTFail("both markers should be written: \(first.markdown)") }
        XCTAssertLessThan(page.lowerBound, annotation.lowerBound)
        let heading = first.chapter.headings.first { $0.text == "Opening the Crate" }
        XCTAssertEqual(heading?.characterOffset, first.chapter.pages.first { $0.label == "2" }?.characterOffset)
    }

    /// Pages are markers in the chapter's Markdown (so content.md keeps them)
    /// and the parse of that Markdown finds the same pages.
    func testThePagesAreInTheMarkdownAndItsParseFindsThem() throws {
        let chapters = try chaptersOf("epub3-pages/page-list.epub")
        guard chapters.count == 2 else { return XCTFail("expected two chapters") }

        XCTAssertEqual(chapters[0].markdown.components(separatedBy: "<!-- page: ").count - 1, 6)
        XCTAssertEqual(chapters[1].markdown.components(separatedBy: "<!-- page: ").count - 1, 1)
        for item in chapters {
            let reparsed = try MarkdownDocParser.parseChapter(
                markdown: item.markdown, title: "", includeNavigationHeadings: true
            )
            XCTAssertEqual(reparsed.pages, item.chapter.pages)
            XCTAssertEqual(reparsed.text, item.chapter.text)
        }
    }

    // MARK: - Without pages

    /// With `includesPages` false the book reads as cache format 3.0.7 read
    /// it: no marker, and the page-break elements' text is read, joined to the
    /// words beside it (the "1" and "99" have no space after them in the markup).
    func testWithoutPagesTheBookReadsAsItDidBefore() throws {
        let chapters = try chaptersOf("epub3-pages/page-list.epub", includesPages: false)
        XCTAssertEqual(chapters.count, 2)
        for item in chapters {
            XCTAssertTrue(item.chapter.pages.isEmpty)
            XCTAssertFalse(item.markdown.contains("<!-- page:"), item.markdown)
        }
        guard let first = chapters.first?.chapter else { return }
        XCTAssertTrue(first.text.contains("sat by the door 1until somebody"), first.text)
        XCTAssertTrue(first.text.contains("pencilled a note 99in the margin."), first.text)
        XCTAssertTrue(first.text.contains("a brass telephone and a coil"), first.text)
    }

    /// The other samples have no pages and no markers without them either.
    func testNoSampleHasPagesWhenTheyAreNotIncluded() throws {
        for sample in ["epub3-pages/pagebreaks-only.epub", "epub2-pages/pagelist.epub"] {
            for item in try chaptersOf(sample, includesPages: false) {
                XCTAssertTrue(item.chapter.pages.isEmpty, sample)
                XCTAssertFalse(item.markdown.contains("<!-- page:"), sample)
            }
        }
    }

    /// A page list most often names empty anchors: between words with a space
    /// on either side, or after a space at the end of a paragraph or a line.
    /// Such a book reads the same with pages as without, every word and space
    /// alike, so places counted in its text do not move: the space after an
    /// anchor is dropped as it is without the marker, and the space before
    /// one that ends a line is trimmed as the line's last. Before, "One
    /// <span/> two" read "One  two" at every page, and phrase search could not
    /// cross a page. The EPUB 2 sample, whose anchors stand before their
    /// words, reads the same too.
    func testEmptyPageAnchorsReadTheSameWithAndWithoutPages() throws {
        let labels = ["1", "2", "3", "4", "5", "6", "7"]
        let nav = xhtml("""
            <nav epub:type="toc"><ol><li><a href="ch1.xhtml">The Crossing</a></li></ol></nav>
            <nav epub:type="page-list"><ol>\(labels.map { "<li><a href=\"ch1.xhtml#p\($0)\">\($0)</a></li>" }.joined())</ol></nav>
            """)
        let chapter = xhtml("""
            <h1>The Crossing</h1>
            <p>The ferry left <span id="p1"></span> at noon.</p>
            <p>It crossed <a id="p2"></a> the strait <em>and <span id="p3"></span> docked</em> by two.</p>
            <ul><li>Rope <span id="p4"></span> and tar</li></ul>
            <p>The pier <span id="p5"></span>
            stood empty. <span id="p6"></span></p>
            <p>A gull called. <span id="p7"></span><br/>Nobody answered.</p>
            """)
        let epub = try makeEPUB(
            manifest: """
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                """,
            spine: "<itemref idref=\"ch1\"/>",
            members: ["nav.xhtml": nav, "ch1.xhtml": chapter]
        )

        let withPages = try EPUBParser.prepareBook(url: epub).chapters.map(\.chapter)
        let withoutPages = try EPUBParser.prepareBook(url: epub, includesPages: false).chapters.map(\.chapter)
        XCTAssertEqual(withPages.map(\.text), withoutPages.map(\.text))
        XCTAssertEqual(withPages.first?.pages.map(\.label), labels)
        let text = withPages.first?.text ?? ""
        XCTAssertFalse(text.contains("  "), text)
        XCTAssertTrue(text.contains("It crossed the strait and docked by two."), text)

        let sample = "epub2-pages/pagelist.epub"
        XCTAssertEqual(
            try chaptersOf(sample).map(\.chapter.text), try chaptersOf(sample, includesPages: false).map(\.chapter.text)
        )
    }

    // MARK: - Page-break elements without a page list

    /// With no page list every labelled page-break element is a page: labelled
    /// by its `aria-label`, its `title`, or its text. The page-break's text is
    /// not read, and the one with no label is no page and adds no text.
    func testWithoutAPageListEveryLabelledPageBreakIsAPage() throws {
        let chapters = try chaptersOf("epub3-pages/pagebreaks-only.epub")
        XCTAssertEqual(chapters.count, 1)
        guard let chapter = chapters.first?.chapter else { return }

        assertPages(of: chapter, [
            ("5", "The second sheet opens"),
            ("6", "Survey Methods"),
            ("7", "Each was checked twice."),
        ])
        XCTAssertTrue(chapter.text.contains("tide tables. The second sheet opens"), chapter.text)
        XCTAssertTrue(chapter.text.contains("Nothing was written here. The unmarked break joins two sentences."), chapter.text)
        XCTAssertTrue(chapter.text.contains("at noon. Each was checked"), chapter.text)
        XCTAssertFalse(chapter.text.contains("tables. V"), "the aria-labelled break's text is not read")
    }

    /// A page-break element inside a heading is written before the heading,
    /// never inside it: the page begins where the heading does, and the
    /// heading's label is unchanged.
    func testAPageBreakInsideAHeadingIsWrittenBeforeIt() throws {
        let chapters = try chaptersOf("epub3-pages/pagebreaks-only.epub")
        guard let chapter = chapters.first?.chapter else { return XCTFail("no chapter") }

        let heading = chapter.headings.first { $0.level == 2 }
        XCTAssertEqual(heading?.text, "Survey Methods")
        XCTAssertEqual(chapter.pages.first { $0.label == "6" }?.characterOffset, heading?.characterOffset)
    }

    /// A heading that holds a page-break element's number leaves it out of
    /// its label, as the body text does: "Part <page 9>Two" is the heading
    /// "Part Two", read aloud and listed so, and page 9 begins where the
    /// heading does. The label was "Part 9Two" while this was pinned the
    /// other way (PG05 left `HTMLReadingText` alone).
    func testAHeadingLeavesAPageBreaksNumberOutOfItsLabel() throws {
        let result = try parsed("<h2>Part <span epub:type=\"pagebreak\" title=\"9\">9</span>Two</h2><p>Body words.</p>")
        XCTAssertEqual(result.chapter.pages.map(\.label), ["9"])
        XCTAssertEqual(result.chapter.pages.first?.characterOffset, 0)
        XCTAssertEqual(result.chapter.headings.first?.text, "Part Two")
        XCTAssertFalse(result.chapter.text.contains("9"), "the number is read nowhere: \(result.chapter.text)")
        XCTAssertTrue(result.markdown.hasPrefix("<!-- page: 9 -->"), result.markdown)
        XCTAssertTrue(result.markdown.contains("## Part Two\n"), result.markdown)
    }

    /// Whatever inline markup a page-break element inside a heading stands
    /// in, the label reads as the same markup does in a paragraph, where the
    /// number is not read: its number in the other numbering ("V" for page
    /// 5), a break inside emphasis, a trailing period, and two breaks whose
    /// markup is the same. The number leaves no space behind where the source
    /// gave none, as in a paragraph. A block is the one difference, since a
    /// heading is one line: it keeps the words on either side apart.
    func testAHeadingsLabelReadsAsTheSameMarkupDoesInAParagraph() throws {
        let markups = [
            ("Chapter <span role=\"doc-pagebreak\" aria-label=\"5\">V</span>Five", "Chapter Five"),
            ("<em>Part <span epub:type=\"pagebreak\" title=\"9\">9</span></em> Two", "Part Two"),
            ("Part<span epub:type=\"pagebreak\" title=\"9\">9</span>Two", "PartTwo"),
            ("A <span epub:type=\"pagebreak\" title=\"1\">1</span>B <span epub:type=\"pagebreak\" title=\"1\">1</span>C", "A B C"),
            ("One <b>two <span epub:type=\"pagebreak\" title=\"4\">4.</span></b> three", "One two three"),
        ]
        for (markup, label) in markups {
            let heading = try parsed("<h2>\(markup)</h2>")
            let paragraph = try parsed("<p>\(markup)</p>")
            XCTAssertEqual(heading.chapter.headings.first?.text, label, markup)
            XCTAssertEqual(paragraph.chapter.text, label, markup)
            XCTAssertFalse(heading.chapter.pages.isEmpty, markup)
            XCTAssertEqual(heading.chapter.pages.map(\.label), paragraph.chapter.pages.map(\.label), markup)
        }

        let block = try parsed("<h2>Part<div epub:type=\"pagebreak\" title=\"9\">9</div>Two</h2>")
        XCTAssertEqual(block.chapter.headings.first?.text, "Part Two")
        XCTAssertEqual(block.chapter.pages.map(\.label), ["9"])
    }

    /// Words in a page-break element are words of the heading, as they are
    /// of a paragraph (ST02): only a page's own number is left out of the
    /// label. A page the book's page list names is the same, whatever its
    /// element holds; and a heading that was nothing but the number is no
    /// heading, its page kept.
    func testAHeadingKeepsWordsAPageBreakHoldsAndTheNumberOfAListedPageGoesToo() throws {
        let words = try parsed("<h2>Part <span epub:type=\"pagebreak\" title=\"9\">Nine</span> Two</h2>")
        XCTAssertEqual(words.chapter.headings.first?.text, "Part Nine Two")
        XCTAssertEqual(words.chapter.pages.map(\.label), ["9"])

        let listed = try parsed(
            "<h2>Part <span id=\"p9\" epub:type=\"pagebreak\">IX</span>Two</h2><p>Body.</p>",
            pages: HTMLPageTargets(markers: ["p9": MarkdownPageMarker(label: "9", ordinal: 1)], pageBreaksArePages: false)
        )
        XCTAssertEqual(listed.chapter.headings.first?.text, "Part Two")
        XCTAssertEqual(listed.chapter.pages.map(\.label), ["9"])

        let alone = try parsed("<h2><span epub:type=\"pagebreak\" title=\"9\">9</span></h2><p>Body words.</p>")
        XCTAssertTrue(alone.chapter.headings.isEmpty, "\(alone.chapter.headings.map(\.text))")
        XCTAssertEqual(alone.chapter.pages.map(\.label), ["9"])
        XCTAssertEqual(alone.chapter.text, "Body words.")
    }

    /// Without pages a heading reads exactly as cache format 3.0.7 wrote it,
    /// the number in its label.
    func testAHeadingKeepsAPageBreaksNumberWithoutPages() throws {
        let result = try parsed(
            "<h2>Part <span epub:type=\"pagebreak\" title=\"9\">9</span>Two</h2>",
            includesPages: false
        )
        XCTAssertEqual(result.chapter.headings.first?.text, "Part 9Two")
        XCTAssertTrue(result.chapter.pages.isEmpty)
    }

    /// The elements a label leaves out are found by identity: leaving out
    /// the first of two spans with the same markup leaves the second in.
    func testALabelLeavesOutTheElementsNamedAndNoOther() throws {
        let document = try SwiftSoup.parse("<h2 id=\"h\">Part <span id=\"a\">9</span>Two <span id=\"b\">9</span></h2>")
        let heading = try XCTUnwrap(try document.select("#h").first())
        let first = try XCTUnwrap(try document.select("#a").first())
        let second = try XCTUnwrap(try document.select("#b").first())

        XCTAssertEqual(HTMLReadingText.label(of: heading), "Part 9Two 9")
        XCTAssertEqual(HTMLReadingText.label(of: heading, leavingOut: [first]), "Part Two 9")
        XCTAssertEqual(HTMLReadingText.label(of: heading, leavingOut: [second]), "Part 9Two")
        XCTAssertEqual(HTMLReadingText.label(of: heading, leavingOut: [first, second]), "Part Two")
        // An element that is not below the heading changes nothing.
        let elsewhere = try XCTUnwrap(try SwiftSoup.parse("<p>9</p>").select("p").first())
        XCTAssertEqual(HTMLReadingText.label(of: heading, leavingOut: [elsewhere]), "Part 9Two 9")
    }

    // MARK: - The EPUB 2 page list

    /// The NCX's pageList gives the pages: a label from `navLabel/text`, else
    /// the target's `value`, at the element each `content/@src` names.
    func testTheNCXPageListGivesThePagesAndAnEmptyLabelReadsItsValue() throws {
        let chapters = try chaptersOf("epub2-pages/pagelist.epub")
        XCTAssertEqual(chapters.count, 2)
        guard chapters.count == 2 else { return }

        assertPages(of: chapters[0].chapter, [
            ("A-1", "Each sack was weighed"),
            ("3", "on a slate"),
        ])
        assertPages(of: chapters[1].chapter, [("4", "At dusk the tally")])
    }

    // MARK: - Precedence, blank documents, and duplicate ids

    /// A book with both an EPUB 3 page list and an NCX pageList takes the
    /// navigation document's, and its page-break elements the list does not
    /// name are not pages.
    func testTheNavigationDocumentsPageListWinsOverTheNCXs() throws {
        let nav = xhtml("""
            <nav epub:type="toc"><ol><li><a href="ch1.xhtml">Title</a></li></ol></nav>
            <nav epub:type="page-list"><ol><li><a href="ch1.xhtml#a">N1</a></li></ol></nav>
            """)
        let ncx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <navMap><navPoint id="n" playOrder="1"><navLabel><text>Title</text></navLabel><content src="ch1.xhtml"/></navPoint></navMap>
            <pageList><pageTarget id="t" type="normal" value="1"><navLabel><text>X1</text></navLabel><content src="ch1.xhtml#b"/></pageTarget></pageList>
            </ncx>
            """
        let chapter = xhtml("""
            <h1>Title</h1><p id="a">Alpha text.</p><p id="b">Bravo text.</p>
            <p>Charlie <span epub:type="pagebreak" title="C">c</span>text.</p>
            """)
        let epub = try makeEPUB(
            manifest: """
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                """,
            spine: "<itemref idref=\"ch1\"/>", spineAttributes: " toc=\"ncx\"",
            members: ["nav.xhtml": nav, "toc.ncx": ncx, "ch1.xhtml": chapter]
        )

        let chapters = try EPUBParser.prepareBook(url: epub).chapters
        XCTAssertEqual(chapters.count, 1)
        guard let first = chapters.first?.chapter else { return }
        assertPages(of: first, [("N1", "Alpha text.")])
        XCTAssertTrue(first.text.contains("Charlie text."), first.text)
    }

    /// A document that holds only page markers (and so no text) is blank, as
    /// it was before pages: it is counted, not read, and its pages go with it.
    func testADocumentHoldingOnlyPagesIsBlankAndItsPagesAreDropped() throws {
        let nav = xhtml("""
            <nav epub:type="toc"><ol><li><a href="ch1.xhtml">Title</a></li></ol></nav>
            <nav epub:type="page-list"><ol>
            <li><a href="ch1.xhtml#a">1</a></li><li><a href="ch2.xhtml">2</a></li><li><a href="ch2.xhtml#b">3</a></li>
            </ol></nav>
            """)
        let epub = try makeEPUB(
            manifest: """
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
                """,
            spine: "<itemref idref=\"ch1\"/><itemref idref=\"ch2\"/>",
            members: [
                "nav.xhtml": nav,
                "ch1.xhtml": xhtml("<h1>Title</h1><p id=\"a\">Alpha text.</p>"),
                "ch2.xhtml": xhtml("<span id=\"b\"/><span epub:type=\"pagebreak\" title=\"9\"/>"),
            ]
        )

        let book = try EPUBParser.prepareBook(url: epub)
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertEqual(book.report.blankChapterCount, 1)
        guard let first = book.chapters.first else { return }
        assertPages(of: first.chapter, [("1", "Alpha text.")])
        XCTAssertFalse(first.markdown.contains("page: 2"))
    }

    /// Two elements with the id an entry names are one page, at the first.
    func testAnIdTwoElementsShareNamesOnePageAtTheFirst() throws {
        let marker = MarkdownPageMarker(label: "7", ordinal: 1)
        let result = try parsed(
            "<p id=\"x\">First owner.</p><p id=\"x\">Second owner.</p>",
            pages: HTMLPageTargets(markers: ["x": marker], pageBreaksArePages: false)
        )
        XCTAssertEqual(result.chapter.pages.map(\.label), ["7"])
        XCTAssertEqual(result.chapter.pages.first?.characterOffset, 0)
        XCTAssertEqual(result.markdown.components(separatedBy: "<!-- page:").count - 1, 1)
    }

    // MARK: - The converter on its own

    /// Standalone HTML: a page-break element is a page, its text is not read,
    /// and the page begins at the word after it.
    func testStandaloneHTMLPageBreakIsAPageAndItsTextIsNotRead() throws {
        let result = try parsed("<p>One <span role=\"doc-pagebreak\" aria-label=\"12\">12</span>two</p>")
        XCTAssertEqual(result.chapter.text, "One two")
        XCTAssertEqual(result.chapter.pages.map(\.label), ["12"])
        XCTAssertEqual(result.chapter.pages.first.map { text(from: $0, in: result.chapter) }, "two")
    }

    /// Without pages the same HTML converts exactly as it did: no marker, and
    /// the page-break element's text read, joined to the word after it.
    func testStandaloneHTMLWithoutPagesReadsThePageBreaksText() throws {
        let result = try parsed("<p>One <span role=\"doc-pagebreak\" aria-label=\"12\">12</span>two</p>", includesPages: false)
        XCTAssertEqual(result.chapter.text, "One 12two")
        XCTAssertTrue(result.chapter.pages.isEmpty)
        XCTAssertFalse(result.markdown.contains("<!--"))
    }

    /// Pages are not found by a parse that does not read generated markers.
    func testAnOrdinaryParseSeesNoPages() throws {
        let markdown = try HTMLToMarkdownConverter.convert("<p>One <span epub:type=\"pagebreak\" title=\"3\"/>two</p>")
        XCTAssertTrue(markdown.contains("<!-- page: 3 -->"), markdown)
        let chapter = try MarkdownDocParser.parseChapter(markdown: markdown, title: "")
        XCTAssertTrue(chapter.pages.isEmpty)
        XCTAssertEqual(chapter.text, "One two")
    }

    /// A page that begins inside preformatted text or a code span is written
    /// before it, never inside, so the code is read as written.
    func testAPageInsideCodeIsWrittenBeforeTheCode() throws {
        let block = try parsed("<p>Before.</p><pre>line one\nline <span epub:type=\"pagebreak\" title=\"8\"/>two</pre>")
        XCTAssertEqual(block.chapter.pages.map(\.label), ["8"])
        XCTAssertEqual(block.chapter.pages.first.map { text(from: $0, in: block.chapter) }?.hasPrefix("line one"), true)
        XCTAssertTrue(block.chapter.text.contains("line one\nline two"), block.chapter.text)

        let span = try parsed("<p>Use <code>a<span epub:type=\"pagebreak\" title=\"9\"/>b</code> here.</p>")
        XCTAssertEqual(span.chapter.pages.map(\.label), ["9"])
        XCTAssertEqual(span.chapter.pages.first.map { text(from: $0, in: span.chapter) }?.hasPrefix("ab here."), true)
    }

    /// A page that begins a list item is written as a block in that item and
    /// names the item's words.
    func testAPageThatBeginsAListItemNamesItsWords() throws {
        let result = try parsed("<ul><li>One</li><li><span epub:type=\"pagebreak\" title=\"3\"/>Two</li></ul>")
        XCTAssertEqual(result.chapter.pages.map(\.label), ["3"])
        XCTAssertEqual(result.chapter.pages.first.map { text(from: $0, in: result.chapter) }?.hasPrefix("Two"), true)
        XCTAssertTrue(result.chapter.text.contains("One"), result.chapter.text)
    }

    /// A page-break element with no label at all is no page, adds no text, and
    /// does not join the words around it.
    func testAPageBreakWithNoLabelIsNoPage() throws {
        let result = try parsed("<p>One <span epub:type=\"pagebreak\"></span> <b epub:type=\"pagebreak\"> </b>two</p>")
        XCTAssertTrue(result.chapter.pages.isEmpty)
        XCTAssertEqual(result.chapter.text, "One two")
        XCTAssertFalse(result.markdown.contains("<!-- page:"))
    }

    // MARK: - Page-break elements holding words (ST02)

    /// The sentence the tests below put in a page-break element.
    private let warSentence = "The war began in the spring of that year, and nobody was ready for it."

    /// A page-break element that holds a paragraph, with its page's label in
    /// `title`: the page begins before the paragraph, and the paragraph is read.
    func testAPageBreakHoldingAParagraphIsReadAfterItsPage() throws {
        let result = try parsed("<p>Before.</p><div epub:type=\"pagebreak\" title=\"12\"><p>\(warSentence)</p></div><p>After.</p>")

        XCTAssertTrue(result.chapter.text.contains(warSentence), result.chapter.text)
        assertPages(of: result.chapter, [("12", "The war began")])
    }

    /// Short words that are not the page's label are words, not a number.
    func testShortWordsUnlikeTheLabelAreRead() throws {
        let result = try parsed("<p>One <span epub:type=\"pagebreak\" title=\"12\">Hello there</span> two</p>")

        XCTAssertTrue(result.chapter.text.contains("Hello there"), result.chapter.text)
        assertPages(of: result.chapter, [("12", "Hello")])
    }

    /// A number under a longer label ("12" under "Page 12") is not the page's
    /// own label, so it is read (stable020 review, finding 2), as the reading
    /// without pages reads it; the page begins at it.
    func testANumberUnderALongerLabelIsRead() throws {
        let html = "<p>One <span role=\"doc-pagebreak\" aria-label=\"Page 12\">12</span>two</p>"
        let result = try parsed(html)

        XCTAssertEqual(result.chapter.text, "One 12two")
        XCTAssertEqual(result.chapter.text, try parsed(html, includesPages: false).chapter.text, "the two readings differ")
        assertPages(of: result.chapter, [("Page 12", "12two")])
    }

    /// A number with a caption ("Page XII" under the label "xii") is not the
    /// page's own label either: the caption is read, and the page begins at it.
    func testACaptionedNumberIsRead() throws {
        let result = try parsed("<p>One <span epub:type=\"pagebreak\" title=\"xii\">Page XII</span> two</p>")

        XCTAssertTrue(result.chapter.text.contains("One Page XII two"), result.chapter.text)
        assertPages(of: result.chapter, [("xii", "Page XII")])
    }

    /// A page-break element whose text is a heading that looks like a number
    /// ("IV", "XII.", "I", "1984", "1, 2, 3."), under the page "5", is read,
    /// and the page begins at it (stable020 review, finding 2). Only the
    /// page's own label, however spelled, or its twin, is not read.
    func testOnlyThePagesOwnLabelOrItsTwinIsNotRead() throws {
        for heading in ["IV", "XII.", "I", "1984", "1, 2, 3."] {
            let result = try parsed("<p>One <span epub:type=\"pagebreak\" title=\"5\">\(heading)</span> two</p>")
            XCTAssertTrue(result.chapter.text.contains("One \(heading) two"), "\(heading): \(result.chapter.text)")
            assertPages(of: result.chapter, [("5", heading)])
        }
        for own in ["5", "5.", "V", "v"] {
            let result = try parsed("<p>One <span epub:type=\"pagebreak\" title=\"5\">\(own)</span>two</p>")
            XCTAssertEqual(result.chapter.text, "One two", own)
            assertPages(of: result.chapter, [("5", "two")])
        }
    }

    /// Words made only of Roman numeral letters ("Mix", "Civil") in a
    /// page-break element under the page "5" are words, not the page's
    /// number, and are read (stable020 review, finding 2).
    func testWordsOfRomanNumeralLettersAreRead() throws {
        for word in ["Mix", "Civil"] {
            let result = try parsed("<p>One <span epub:type=\"pagebreak\" title=\"5\">\(word)</span> two</p>")
            XCTAssertTrue(result.chapter.text.contains("One \(word) two"), "\(word): \(result.chapter.text)")
            assertPages(of: result.chapter, [("5", word)])
        }
    }

    /// A page-break element with no label that holds a paragraph begins no
    /// page (the paragraph's first words would be a page label that Go to Page
    /// reads out), and its words are read.
    func testAnUnlabelledPageBreakHoldingAParagraphIsReadAndIsNoPage() throws {
        let result = try parsed("<div epub:type=\"pagebreak\"><p>\(warSentence)</p></div>")

        XCTAssertTrue(result.chapter.text.contains(warSentence), result.chapter.text)
        XCTAssertTrue(result.chapter.pages.isEmpty)
        XCTAssertFalse(result.markdown.contains("<!-- page:"), result.markdown)
    }

    /// Without any attribute the element's short text still names its page
    /// and is not read.
    func testAnUnlabelledShortNumberIsStillAPageAndNotRead() throws {
        let result = try parsed("<p>One <span epub:type=\"pagebreak\">xii</span>two</p>")

        XCTAssertEqual(result.chapter.text, "One two")
        XCTAssertEqual(result.chapter.pages.map(\.label), ["xii"])
    }

    /// A page the book's page list names at an element that holds a paragraph:
    /// the page is the list's, and the paragraph is read.
    func testAListedPageBreakHoldingAParagraphIsRead() throws {
        let nav = xhtml("""
            <nav epub:type="toc"><ol><li><a href="ch1.xhtml">Title</a></li></ol></nav>
            <nav epub:type="page-list"><ol><li><a href="ch1.xhtml#p7">7</a></li></ol></nav>
            """)
        let chapter = xhtml("""
            <h1>Title</h1><p>Alpha.</p><p id="p7" epub:type="pagebreak">\(warSentence)</p>
            """)
        let epub = try makeEPUB(
            manifest: """
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                """,
            spine: "<itemref idref=\"ch1\"/>",
            members: ["nav.xhtml": nav, "ch1.xhtml": chapter]
        )

        let chapters = try EPUBParser.prepareBook(url: epub).chapters
        guard let first = chapters.first?.chapter else { return XCTFail("no chapter") }
        assertPages(of: first, [("7", "The war began")])
        XCTAssertTrue(first.text.contains(warSentence), first.text)
    }

    /// The reading without pages reads a page-break element's words, and with
    /// pages they read the same, so the two readings differ by no word.
    func testWithoutPagesAPageBreakHoldingWordsReadsAsBefore() throws {
        let html = "<p>Before.</p><div epub:type=\"pagebreak\" title=\"12\"><p>\(warSentence)</p></div><p>After.</p>"
        let with = try parsed(html)
        let without = try parsed(html, includesPages: false)

        XCTAssertEqual(without.chapter.text, with.chapter.text)
        XCTAssertFalse(without.markdown.contains("<!-- page:"), without.markdown)
    }

    // MARK: - Publication semantics

    /// Page-break and page-list vocabulary: the `epub:type` and `role` tokens,
    /// without regard to case or to other tokens beside them, and nothing else.
    func testThePageBreakAndPageListVocabulary() throws {
        func element(_ markup: String) throws -> Element {
            guard let element = try SwiftSoup.parseBodyFragment(markup).body()?.children().first() else {
                throw XCTSkip("no element in \(markup)")
            }
            return element
        }
        XCTAssertTrue(PublicationSemantics.isPageBreak(try element("<span epub:type=\"pagebreak\"></span>")))
        XCTAssertTrue(PublicationSemantics.isPageBreak(try element("<span role=\"doc-pagebreak\"></span>")))
        XCTAssertTrue(PublicationSemantics.isPageBreak(try element("<div epub:type=\"x PageBreak\"></div>")))
        XCTAssertFalse(PublicationSemantics.isPageBreak(try element("<span epub:type=\"pagebreaks\"></span>")))
        XCTAssertFalse(PublicationSemantics.isPageBreak(try element("<span class=\"pagebreak\"></span>")))

        XCTAssertTrue(PublicationSemantics.isPageList(try element("<nav epub:type=\"page-list\"></nav>")))
        XCTAssertTrue(PublicationSemantics.isPageList(try element("<div role=\"doc-pagelist\"></div>")))
        XCTAssertFalse(PublicationSemantics.isPageList(try element("<span epub:type=\"page-list\"></span>")))
        XCTAssertFalse(PublicationSemantics.isPageList(try element("<nav epub:type=\"toc\"></nav>")))
        // A page list is still supplementary navigation, as it was.
        XCTAssertTrue(PublicationSemantics.isSupplementaryNavigation(try element("<nav epub:type=\"page-list\"></nav>")))
        XCTAssertTrue(PublicationSemantics.isSupplementaryNavigation(try element("<nav epub:type=\"landmarks\"></nav>")))
    }

    /// Only markup that spells "pagebreak" can hold a page-break element.
    func testOnlyMarkupSpellingPageBreakMayHoldOne() {
        for markup in ["epub:type=\"pagebreak\"", "role=\"DOC-PAGEBREAK\"", "pagepagebreak", "ppagebreak"] {
            XCTAssertTrue(PublicationSemantics.mayCarryPageBreak(markup), markup)
        }
        for markup in ["", "<p>plain</p>", "pagebrea", "page break", "page-break", "agebreak", "pagebreaX"] {
            XCTAssertFalse(PublicationSemantics.mayCarryPageBreak(markup), markup)
        }
    }
}
