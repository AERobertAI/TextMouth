import XCTest
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
