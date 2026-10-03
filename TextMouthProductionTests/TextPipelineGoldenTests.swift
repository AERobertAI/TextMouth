import SwiftSoup
import XCTest
import ZIPFoundation
@testable import TextMouth

/// Golden tests for the text pipeline's performance work (PERF18 to PERF25
/// in TODO-2026-09-04.md). Each change there makes a reading path faster
/// without changing a byte of what it produces, so these tests hold the
/// output recorded on main before the first change (a4d6e10) and compare
/// today's output with it: every content.md the import writes, the reading
/// each book opens to (titles, text, headings, and word counts), and the
/// Markdown and chapters the converters make directly.
///
/// A deliberate change of output (one that bumps the cache format) changes
/// these records too: each failure message shows the digest found, which
/// replaces the one recorded once the new output has been checked.
final class TextPipelineGoldenTests: XCTestCase {

    // MARK: - Every Book Fixture

    /// The books whose caches and readings are recorded: TestData's books,
    /// the review's synthetic books at sizes a Debug build reads quickly,
    /// and the generated EPUBs, by the name each is recorded under.
    private func goldenBooks() throws -> [(name: String, url: URL)] {
        typealias Fixtures = TextPipelineFixtures
        var books = try Fixtures.testDataBooks().map { (name: $0.lastPathComponent, url: $0) }
        books += [
            ("synthetic-256k.txt", try Fixtures.writeText(Fixtures.plainText(bytes: 262_144), named: "Synthetic Prose.txt", for: self)),
            ("synthetic-256k.md", try Fixtures.writeText(Fixtures.markdownWithTables(bytes: 262_144), named: "Synthetic Tables.md", for: self)),
            ("synthetic-128k-inline.html", try Fixtures.writeText(Fixtures.html(bytes: 131_072), named: "Synthetic Inline.html", for: self)),
            ("synthetic-256k-plain.html", try Fixtures.writeText(Fixtures.html(bytes: 262_144, inlineMarkup: false), named: "Synthetic Plain.html", for: self)),
            ("navigation.epub", try Fixtures.writeEPUB(Fixtures.navigationEPUB(), named: "Ferry Timetable.epub", for: self)),
            ("ncx.epub", try Fixtures.writeEPUB(Fixtures.ncxEPUB(), named: "Lock Keeping.epub", for: self)),
            ("converted-12.epub", try Fixtures.writeEPUB(
                Fixtures.convertedBookEPUB(documents: 12, paragraphs: 6, images: 30), named: "Converted Anthology.epub", for: self
            )),
        ]
        return books
    }

    /// content.md as the import writes it for each golden book, recorded on
    /// main before PERF18.
    private static let recordedCaches: [String: String] = [
        "alice.docx": "3cd03f3458bf2cb1",
        "alice.epub": "7693c954870e8e27",
        "converted-12.epub": "65ea3c4fb57ed662",
        "daisy202_test.zip": "73cbd773fe100236",
        "frankenstein.html": "ca20689835e6a4af",
        "hyperion_daisy.zip": "538946f073739b22",
        "lathe_of_heaven_daisy.zip": "c64cfa237817b844",
        "navigation.epub": "7fb5af1466eab9ab",
        "ncx.epub": "f7ee1d34be3f7637",
        "pride.txt": "b66f077f6e38e5db",
        "sample.md": "2d9a584acbd95311",
        "synthetic-128k-inline.html": "7112a6c84ea01040",
        "synthetic-256k-plain.html": "f96a6fae58fbd3bf",
        "synthetic-256k.md": "c16d170995d4e3ea",
        "synthetic-256k.txt": "806aeb6f5aae9ae1",
        "test_book.docx": "03acb604568b522c",
        "wipo-treaty-d202-text-only.zip": "8dda044877b014a8",
    ]

    /// What each golden book opens to (`TextPipelineFixtures.digest(of:index:)`
    /// of the chapters and index `BookContentAnalysisService.load` returns),
    /// recorded on main before PERF18.
    private static let recordedReadings: [String: String] = [
        "alice.docx": "6a2383388d488ef7",
        "alice.epub": "98ad24b7bb26f619",
        "converted-12.epub": "a9fe607222334425",
        "daisy202_test.zip": "62d8163491526652",
        "frankenstein.html": "33e7c31909a348d3",
        "hyperion_daisy.zip": "eaa1858c33d55019",
        "lathe_of_heaven_daisy.zip": "24cdd2a8c98160f0",
        "navigation.epub": "1f70d1864a1fcac1",
        "ncx.epub": "e30260221f303883",
        "pride.txt": "13cc79a1071a228a",
        "sample.md": "29fd3ff8a8da5608",
        "synthetic-128k-inline.html": "9f950f2e3160b6b7",
        "synthetic-256k-plain.html": "786ae6ae01ae07b7",
        "synthetic-256k.md": "aebbd93e18ff88df",
        "synthetic-256k.txt": "9279d920ee2030b6",
        "test_book.docx": "073d8be3776366b6",
        "wipo-treaty-d202-text-only.zip": "604aaf38d809f5ad",
    ]

    /// Every golden book imports to the content.md recorded for it, and
    /// opens to the recorded chapters, headings, and word counts.
    func testEveryBookKeepsItsRecordedCacheAndReading() throws {
        for (name, url) in try goldenBooks() {
            let book = try TextPipelineFixtures.imported(url, for: self)
            let cache = try Data(contentsOf: MarkdownCacheService.cacheURL(for: book))
            XCTAssertEqual(TextPipelineFixtures.digest(cache), Self.recordedCaches[name], "content.md of \(name)")

            let opened = try BookContentAnalysisService.load(book: book)
            XCTAssertEqual(
                TextPipelineFixtures.digest(of: opened.content.chapters, index: opened.index),
                Self.recordedReadings[name],
                "reading of \(name)"
            )
        }
    }

    // MARK: - EPUB Extraction

    /// The chapters and report the EPUB reader prepares for each generated
    /// EPUB: the digest of each chapter's Markdown in order, the digest of
    /// the chapters themselves, and the report's sentence.
    private static let recordedEPUBExtractions: [String: (markdown: [String], chapters: String, report: String)] = [
        "converted-12.epub": (
            markdown: [
                "e3a6c5c14e55db08",
                "571c607c1fc2bced",
                "0138b8fcaba4dd05",
                "794c5881f58e1c06",
                "881dd55fa878a745",
                "fe792e8aeb5d1596",
                "d2f38994be6e3ae9",
                "683179d269c62715",
                "2ca9d6c3969a51b9",
                "5a2d0cd0ac8ba995",
                "a7af7a8c8525c0f7",
                "e6a3f557e740b058",
            ],
            chapters: "e9fce5faca30b1f7",
            report: "Every chapter was read."
        ),
        "navigation.epub": (
            markdown: [
                "c65f192e68d054e3",
                "bfde0f8260eb0068",
                "ba5a0ebb74638753",
                "3c6cb98a64eaf8e7",
                "fc43daeac9c69ca8",
                "77302990b8c5d718",
            ],
            chapters: "a6ddb36bc04099cd",
            report: "3 of 10 chapters could not be read: chapter 6 (“OEBPS/notes.txt”) is a “text/plain” file, which TextMouth cannot read; chapter 7 (“ghost”) has no file listed in this EPUB book; chapter 9 (“OEBPS/text/lost.xhtml”) is missing from this EPUB book."
        ),
        "ncx.epub": (
            markdown: [
                "b22c9de19cf8f824",
                "0e2050414c30df0e",
                "879fd6c13eccde00",
            ],
            chapters: "803241c2eab711ae",
            report: "Every chapter was read."
        ),
    ]

    /// The EPUB reader prepares the recorded Markdown and chapters, and the
    /// recorded report of chapters left out, for each generated EPUB, which
    /// together take every navigation path the reader has.
    func testGeneratedEPUBsPrepareTheRecordedChaptersAndReport() throws {
        typealias Fixtures = TextPipelineFixtures
        let epubs = [
            ("navigation.epub", Fixtures.navigationEPUB()),
            ("ncx.epub", Fixtures.ncxEPUB()),
            ("converted-12.epub", Fixtures.convertedBookEPUB(documents: 12, paragraphs: 6, images: 30)),
        ]
        for (name, entries) in epubs {
            let url = try Fixtures.writeEPUB(entries, named: name, for: self)
            let prepared = try EPUBParser.prepareBook(url: url)
            let recorded = Self.recordedEPUBExtractions[name]
            XCTAssertEqual(prepared.chapters.map { Fixtures.digest($0.markdown) }, recorded?.markdown, "Markdown of \(name)")
            XCTAssertEqual(Fixtures.digest(of: prepared.chapters.map(\.chapter)), recorded?.chapters, "chapters of \(name)")
            XCTAssertEqual(prepared.report.message, recorded?.report, "report of \(name)")
        }
    }

    /// What the generated EPUBs' navigation gives their chapters, named
    /// outright: destinations that only a contents page late in the
    /// reading order names still reach the earlier chapters they lie in,
    /// hidden elements are never read whatever case their attribute is
    /// written in (though a hidden branch of a navigation document's TOC
    /// still names a heading, as EPUB 3.3 asks), the word "hidden" in a
    /// chapter's text is read like any other, an id written with a
    /// character reference is a destination, and a later copy of a member
    /// in the archive is never read.
    func testGeneratedEPUBsKeepEveryDestinationAndLeaveHiddenContentOut() throws {
        typealias Fixtures = TextPipelineFixtures
        let navigation = try EPUBParser.prepareBook(
            url: try Fixtures.writeEPUB(Fixtures.navigationEPUB(), named: "navigation.epub", for: self)
        ).chapters.map(\.chapter)
        let lockKeeping = try EPUBParser.prepareBook(
            url: try Fixtures.writeEPUB(Fixtures.ncxEPUB(), named: "ncx.epub", for: self)
        ).chapters.map(\.chapter)
        let headings = Set((navigation + lockKeeping).flatMap { $0.headings.map(\.text) })
        let text = (navigation + lockKeeping).map(\.text).joined(separator: "\n")

        // Named only by the index at the back of the book.
        for label in ["First mooring", "Second mooring", "Late notes"] {
            XCTAssertTrue(headings.contains(label), label)
        }
        XCTAssertEqual(navigation.last?.title, "Index of places")
        // Named by the navigation document, the NCX, the guide, and a
        // contents page early in the reading order.
        for label in ["Weekday sailings & times", "Night boats", "Fares table", "Signal codes", "The Crossing",
                      "On deck", "Harbor notes", "Moorings", "A hidden branch", "The first lock", "Gates", "Upstream"] {
            XCTAssertTrue(headings.contains(label), label)
        }
        for hidden in ["This paragraph is hidden", "Hidden words", "Mixed-case hidden words", "A hidden item",
                       "A hidden heading", "Capital hidden words", "More capital hidden words",
                       "A contents page that is hidden"] {
            XCTAssertFalse(text.contains(hidden), hidden)
            XCTAssertFalse(headings.contains(hidden), hidden)
        }
        XCTAssertTrue(text.contains("nobody marked it hidden in the markup"))
        XCTAssertTrue(text.contains("Café on the üpper reach"))
        XCTAssertFalse(text.contains("A LATER COPY"))
    }

    /// Markup that never spells "hidden", in any mix of capitals, can give
    /// no element the attribute; markup that does, anywhere, may.
    func testOnlyMarkupSpellingHiddenMayHideAnElement() {
        let mayHide = [
            "<p hidden>a</p>", "<P HIDDEN>a</P>", "<div HiDdEn=\"\">a</div>", "a hidden word in text",
            "hidhidden", "hhidden", "hiddenhidden", "xHIDDEN", "hidden",
        ]
        let cannotHide = [
            "", "<p>plain</p>", "hidde", "idden", "hid den", "hid\u{AD}den", "hid&#100;en",
            "h\u{130}dden", "ｈｉｄｄｅｎ", "<p data-hide=\"1\">a</p>",
        ]
        for markup in mayHide {
            XCTAssertTrue(PublicationSemantics.mayCarryHiddenAttribute(markup), markup)
        }
        for markup in cannotHide {
            XCTAssertFalse(PublicationSemantics.mayCarryHiddenAttribute(markup), markup)
        }
    }

    /// A document's reading-flow rules give, for every element of every
    /// document in the generated EPUBs, exactly the answers the rules for
    /// markup of unknown source give, whether or not its markup can hide.
    func testDocumentReadingFlowAnswersAsTheGeneralRulesDo() throws {
        typealias Fixtures = TextPipelineFixtures
        let documents = (Fixtures.navigationEPUB() + Fixtures.ncxEPUB())
            .filter { entry in [".xhtml", ".html"].contains { entry.path.hasSuffix($0) } }
            .map { String(decoding: $0.data, as: UTF8.self) }
        var checked = 0
        var skipped = 0
        for html in documents {
            let flow = PublicationSemantics.ReadingFlow(source: html)
            if !flow.mayHideElements { skipped += 1 }
            for element in try SwiftSoup.parse(html).getAllElements() {
                XCTAssertEqual(flow.excludes(element), PublicationSemantics.isExcludedFromReadingFlow(element), "\(element)")
                XCTAssertEqual(flow.isHidden(element), PublicationSemantics.isHidden(element), "\(element)")
                checked += 1
            }
        }
        // Both kinds of document were checked.
        XCTAssertGreaterThan(skipped, 0)
        XCTAssertLessThan(skipped, documents.count)
        XCTAssertGreaterThan(checked, 100)
    }

    // MARK: - Word Counts (PERF21)

    /// The word count as it was counted before PERF21: the pieces a split
    /// at every whitespace Character leaves.
    private static func wordCountBefore(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Every chapter counts the words the split it replaces counted: on the
    /// review's edge strings, five thousand random strings built from pieces
    /// whose neighbors decide where Characters begin, the review's prose,
    /// and the reading text of every TestData book and generated EPUB.
    func testWordCountsMatchTheSplitTheyReplace() throws {
        typealias Fixtures = TextPipelineFixtures
        var texts = Fixtures.edgeTexts + Fixtures.randomTrickyTexts(count: 5_000, seed: 21)
        texts.append(Fixtures.plainText(bytes: 131_072))
        let books = try goldenBooks()
        var chapters: [String] = []
        for (_, url) in books {
            let book = try Fixtures.imported(url, for: self)
            chapters += try BookContentAnalysisService.load(book: book).content.chapters.map(\.text)
        }
        // Every book gave at least one chapter, so none was compared vacuously.
        XCTAssertGreaterThanOrEqual(chapters.count, books.count)
        for text in texts + chapters {
            XCTAssertEqual(
                Chapter(text: text).wordCount, Self.wordCountBefore(text),
                text.unicodeScalars.prefix(40).map { String($0.value, radix: 16) }.joined(separator: " ")
            )
        }
    }

    // MARK: - Archive Lookups (PERF20)

    /// Members of an archive whose paths repeat, differ only in case, or
    /// differ only in how an accented letter is encoded, in that order.
    private static let lookupEntries: [TestZIPEntry] = [
        .folder("Text/"),
        TestZIPEntry("Text/Page.html", Data("first exact".utf8)),
        TestZIPEntry("text/page.HTML", Data("first by case".utf8)),
        TestZIPEntry("Text/Page.html", Data("second exact".utf8)),
        TestZIPEntry("TEXT/PAGE.HTML", Data("second by case".utf8)),
        TestZIPEntry("cafe\u{301}.html", Data("decomposed".utf8)),
        TestZIPEntry("caf\u{E9}.html", Data("composed".utf8)),
    ]

    /// An indexed archive lists every entry in the archive's order, and
    /// finds each path, exactly and without regard to case, as the archive's
    /// own lookups find it: in the archive above, in every archive among
    /// TestData's books, and in the generated EPUBs. Every path is tried as
    /// written, in capitals, and in small letters, with paths no entry has.
    func testIndexedArchiveFindsEveryPathAsTheArchiveDoes() throws {
        typealias Fixtures = TextPipelineFixtures
        var urls = try ["alice.epub", "alice.docx", "test_book.docx", "daisy202_test.zip", "hyperion_daisy.zip",
                        "lathe_of_heaven_daisy.zip", "wipo-treaty-d202-text-only.zip"].map { try requireFile($0) }
        urls.append(try Fixtures.writeEPUB(Self.lookupEntries, named: "lookups.zip", for: self))
        urls.append(try Fixtures.writeEPUB(Fixtures.navigationEPUB(), named: "navigation.epub", for: self))
        urls.append(try Fixtures.writeEPUB(Fixtures.ncxEPUB(), named: "ncx.epub", for: self))
        for url in urls {
            let archive = try Archive(url: url, accessMode: .read)
            let index = IndexedArchive(archive)
            XCTAssertEqual(index.entries, Array(archive), url.lastPathComponent)
            let paths = index.entries.map(\.path)
            var probes = paths + ["", "missing", "/"]
            probes += paths.map { $0.uppercased() }
            probes += paths.map { $0.lowercased() }
            for path in probes {
                XCTAssertEqual(index[path], archive[path], "\(url.lastPathComponent): \(path)")
                let firstFile = archive.first { $0.type == .file && $0.path.lowercased() == path.lowercased() }
                XCTAssertEqual(index.file(matchingCaseInsensitively: path), firstFile, "\(url.lastPathComponent): \(path)")
            }
        }
    }

    /// A DAISY book's files are found as the archive finds them: the first
    /// entry at a path wins (paths compare as Swift compares strings, so an
    /// accented letter written either way is one path), and a path no entry
    /// has exactly finds the first file that matches it without regard to
    /// case. Every file is listed, in the archive's order.
    func testArchiveMembersAreFoundAsTheArchiveFindsThem() throws {
        let zip = try makeTemporaryZip(prefix: "TextPipelineLookup", orderedEntries: Self.lookupEntries)
        addTeardownBlock { try? FileManager.default.removeItem(at: zip) }
        let provider = ArchiveFileProvider(archive: try Archive(url: zip, accessMode: .read))

        XCTAssertEqual(try provider.readFile(at: "Text/Page.html"), Data("first exact".utf8))
        XCTAssertEqual(try provider.readFile(at: "text/page.HTML"), Data("first by case".utf8))
        XCTAssertEqual(try provider.readFile(at: "TEXT/page.html"), Data("first exact".utf8))
        XCTAssertEqual(try provider.readFile(at: "caf\u{E9}.html"), Data("decomposed".utf8))
        XCTAssertEqual(try provider.readFile(at: "CAFE\u{301}.HTML"), Data("decomposed".utf8))
        XCTAssertThrowsError(try provider.readFile(at: "Text/Missing.html"))
        XCTAssertEqual(provider.listFiles(), Self.lookupEntries.filter { $0.type == .file }.map(\.path))
    }

    // MARK: - HTML Conversion (PERF18)

    /// Small documents whose emphasis and links take every branch of the
    /// converter's inline wrapping, with the Markdown recorded for each.
    private static let recordedConversions: [(html: String, markdown: String)] = [
        ("<p>Plain <em>emphasis</em> and <strong>strong</strong> words.</p>", "Plain *emphasis* and **strong** words\\."),
        ("<p><em>outer <strong>inner</strong> outer</em> and <b><i>both</i></b></p>", "*outer inner outer* and **both**"),
        ("<p><em>see <a href=\"x.html\">the link</a> here</em></p>", "*see [the link](<x.html>) here*"),
        ("<p><a href=\"y.html\"><b>bold link</b></a> and <a href=\"z\"><em>a</em> b <em>c</em></a></p>", "[**bold link**](<y.html>) and [*a* b *c*](<z>)"),
        ("<p><em>*star*</em> <i>[bracket]</i> <b>\"quoted\"</b> <em>(paren)</em>.</p>", "\\*star\\* \\[*bracket*\\] \\\"**quoted**\\\" \\(*paren*\\)\\."),
        ("<p><em>path\\</em> <em>a\\*</em> <strong>\\\\</strong></p>", "*path*\\\\ *a*\\\\\\* \\\\\\\\"),
        ("<p>Café <em>naïve façade</em> — “quoted” <a href=\"z\">Ångström</a> 👍🏽</p>", "Café *naïve façade* — “quoted” [Ångström](<z>) 👍🏽"),
        ("<p>x<em> \u{301}mark</em>y and e<em>\u{301}</em>f and 日本<em>語</em>です</p>", "x *\u{301}mark*y and e*\u{301}*f and 日本*語*です"),
        ("<p><em>one</em><em>two</em> <em>three</em><strong>four</strong></p>", "*one*two *three*four"),
        ("<p>a<em></em>b a<em> </em>b a<a href=\"q\"> </a>b</p>", "ab a b a b"),
        ("<p><em><code>code</code> after</em> and <em>before <code>code</code></em></p>", "*`code` after* and before `code`"),
        ("<p><em>line<br>break</em> and <a href=\"l\">link<br>break</a></p>", "line  \nbreak and link  \nbreak"),
        ("<p>a<a href=\"q\"> spaced </a>b and <a href=\"a&lt;b&gt;\\c d\">odd</a></p>", "a [spaced](<q>) b and [odd](<a\\<b\\>\\\\c d>)"),
        ("<p><a href=\"r\"><img alt=\" Alt text \" src=\"i.png\"></a> and <a href=\"\">empty href</a></p>", "[![Alt text](<i.png>)](<r>) and empty href"),
        ("<p><em>— dash</em> <em>dash —</em> <em>“quote”</em> <em>¿qué?</em></p>", "— *dash* *dash* — “*quote*” ¿*qué*\\?"),
        ("<ul><li><em>item</em> one</li><li>two <a href=\"t\">link</a></li></ul><blockquote><p><b>Bold</b> quote</p></blockquote>", "- *item* one\n- two [link](<t>)\n\n> **Bold** quote"),
        ("<h2 id=\"h\"><em>Heading</em> words</h2><p><em>after heading</em></p>", "## Heading words\n\n*after heading*"),
    ]

    /// Each small document converts to the Markdown recorded for it.
    func testInlineMarkupConvertsToTheRecordedMarkdown() throws {
        for (html, markdown) in Self.recordedConversions {
            XCTAssertEqual(try HTMLToMarkdownConverter.convert(html, stripDuplicateNavigation: true), markdown, html)
        }
    }

    /// Converting HTML takes time in proportion to its length, however many
    /// emphases and links it holds. Each one once copied all the Markdown
    /// converted before it (PERF18), so eight times the document took about
    /// forty times as long in a Debug build (and sixty in Release); now it
    /// takes about eight times as long. The bound between the two leaves
    /// room for a busy machine, and each time is the fastest of three runs.
    func testInlineMarkupConversionTimeGrowsInProportionToTheDocument() throws {
        let short = TextPipelineFixtures.html(bytes: 32_768)
        let long = TextPipelineFixtures.html(bytes: 262_144)
        let shortTime = try TextPipelineFixtures.fastestTime(of: 3) { _ = try HTMLToMarkdownConverter.convert(short) }
        let longTime = try TextPipelineFixtures.fastestTime(of: 3) { _ = try HTMLToMarkdownConverter.convert(long) }
        print(String(format: "PERF18 scaling: %.1f ms for 32 KB, %.1f ms for 256 KB", shortTime * 1_000, longTime * 1_000))
        XCTAssertLessThan(
            longTime, shortTime * 20,
            String(format: "%.0f ms for 256 KB against %.0f ms for 32 KB", longTime * 1_000, shortTime * 1_000)
        )
    }

    /// The review's synthetic HTML, with and without inline markup, converts
    /// to the recorded Markdown, by digest.
    private static let recordedSyntheticConversions: [String: String] = [
        "inline-256k": "ef83cc42b1dbbdfb",
        "inline-64k": "0078e5dcc4e8f60d",
        "plain-512k": "deca566528fcc977",
    ]

    /// The review's synthetic HTML converts to the recorded Markdown.
    func testSyntheticHTMLConvertsToTheRecordedMarkdown() throws {
        let documents = [
            ("inline-64k", TextPipelineFixtures.html(bytes: 65_536)),
            ("inline-256k", TextPipelineFixtures.html(bytes: 262_144)),
            ("plain-512k", TextPipelineFixtures.html(bytes: 524_288, inlineMarkup: false)),
        ]
        for (name, html) in documents {
            let markdown = try HTMLToMarkdownConverter.convert(html, stripDuplicateNavigation: true)
            XCTAssertEqual(TextPipelineFixtures.digest(markdown), Self.recordedSyntheticConversions[name], name)
        }
    }
}
