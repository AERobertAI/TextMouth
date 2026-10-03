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
    /// Made on each use: `TestZIPEntry` is not `Sendable`, so a static
    /// constant holding it would be shared mutable state.
    private static var lookupEntries: [TestZIPEntry] {
        [
            .folder("Text/"),
            TestZIPEntry("Text/Page.html", Data("first exact".utf8)),
            TestZIPEntry("text/page.HTML", Data("first by case".utf8)),
            TestZIPEntry("Text/Page.html", Data("second exact".utf8)),
            TestZIPEntry("TEXT/PAGE.HTML", Data("second by case".utf8)),
            TestZIPEntry("cafe\u{301}.html", Data("decomposed".utf8)),
            TestZIPEntry("caf\u{E9}.html", Data("composed".utf8)),
        ]
    }

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

    // MARK: - Opening content.md (PERF22)

    /// The chapter split as it was before PERF22: every line copied into an
    /// array, and each chapter's lines joined again and trimmed.
    private static func splitChaptersBefore(_ markdown: String) -> [(title: String, content: String)] {
        let prefix = "<!-- chapter: "
        let suffix = " -->"
        let lines = markdown.components(separatedBy: "\n")
        var sections: [(title: String, content: String)] = []
        var currentTitle = ""
        var currentLines: [String] = []
        var foundMarker = false
        for line in lines {
            if line.hasPrefix(prefix) && line.hasSuffix(suffix) {
                if foundMarker {
                    let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        sections.append((title: currentTitle, content: content))
                    }
                }
                let titleStart = line.index(line.startIndex, offsetBy: prefix.count)
                let titleEnd = line.index(line.endIndex, offsetBy: -suffix.count)
                var title = String(line[titleStart..<titleEnd])
                if title.contains("<!--") {
                    title = title.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                }
                currentTitle = title
                currentLines = []
                foundMarker = true
            } else {
                currentLines.append(line)
            }
        }
        if foundMarker {
            let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                sections.append((title: currentTitle, content: content))
            }
        }
        return sections
    }

    /// Cached Markdown that puts the chapter split's every rule to the
    /// test: markers first, last, alone, and in a row; marker lookalikes
    /// that are not whole marker lines (a leading space, words after, a CR
    /// LF line ending, a combining mark after the prefix or the suffix);
    /// titles empty, accented, and holding a comment; sections empty or only
    /// whitespace; and line breaks other than a line feed.
    private static let splitEdgeCases: [String] = [
        "", "\n", "\n\n", "No markers at all.\nSecond line.",
        "<!-- chapter: One -->\nText one.\n<!-- chapter: Two -->\nText two.",
        "Before any marker.\n<!-- chapter: One -->\nText.\n",
        "<!-- chapter: One -->\n<!-- chapter: Two -->\n\n  \t\n<!-- chapter: Three -->\nThree.",
        "<!-- chapter: One -->", "<!-- chapter: One -->\n", "<!-- chapter: Last -->\nEnd without a line feed",
        "<!-- chapter: One -->\r\nCR LF text.\r\n<!-- chapter: Two -->\r\nMore.\r\n",
        "<!-- chapter: One -->\nText.\r\n<!-- chapter: Two -->\nMore.",
        " <!-- chapter: Indented -->\nText.", "<!-- chapter: Words --> after\nText.",
        "<!-- chapter: \u{301}Mark after the prefix -->\nText.", "<!-- chapter: Mark after the suffix -->\u{301}\nText.",
        "<!-- chapter:  -->\nUntitled.", "<!-- chapter: Caf\u{E9} \u{2014} \u{65E5}\u{672C} -->\nAccented title.",
        "<!-- chapter: Title <!-- old annotation --> kept -->\nText.",
        "<!-- chapter: One -->\n\u{2028}Line separator\u{2028}\n\u{85}\n<!-- chapter: Two -->\n\u{A0}",
        "<!-- chapter: One -->\nA\rB\rC old Mac line ends\n<!-- chapter: Two -->\n\r",
        "<!-- chapter: One -->\n\u{FEFF}\n<!-- chapter: Two -->\n\u{200B}",
    ]

    /// The split finds the chapters the line-array split found, with the
    /// same titles and the same trimmed text, for every golden book's
    /// content.md, the edge cases above, and two thousand random documents
    /// of marker lines and tricky text.
    func testChapterSplitMatchesTheSplitItReplaces() throws {
        typealias Fixtures = TextPipelineFixtures
        var documents = Self.splitEdgeCases
        for (_, url) in try goldenBooks() {
            let book = try Fixtures.imported(url, for: self)
            documents.append(try String(contentsOf: MarkdownCacheService.cacheURL(for: book), encoding: .utf8))
        }
        var random = SeededGenerator(state: 22)
        let markers = ["<!-- chapter: A -->", "<!-- chapter: B c -->", "<!-- chapter:  -->", "<!-- chapter: \u{E9} -->"]
        let lines = markers + Fixtures.randomTrickyTexts(count: 60, maximumPieces: 8, seed: 2_222)
        for _ in 0..<2_000 {
            let count = Int(random.next() % 12)
            documents.append((0..<count).map { _ in lines[Int(random.next() % UInt64(lines.count))] }.joined(separator: "\n"))
        }
        for markdown in documents {
            let split = MarkdownCacheService.splitChapters(markdown)
            let before = Self.splitChaptersBefore(markdown)
            XCTAssertEqual(split.map(\.title), before.map(\.title), markdown.debugDescription)
            XCTAssertEqual(split.map(\.content), before.map(\.content), markdown.debugDescription)
        }
    }

    /// A marker line too short to hold the marker's prefix and suffix apart
    /// (`<!-- chapter: -->`, whose one space both share) names a chapter
    /// with no title. Reading a title there once stopped the app, so a
    /// Markdown book holding that line could not be opened.
    func testAMarkerTooShortForATitleNamesAnUntitledChapter() {
        let sections = MarkdownCacheService.splitChapters("<!-- chapter: -->\nWords.\n<!-- chapter: Two -->\nMore.")
        XCTAssertEqual(sections.map(\.title), ["", "Two"])
        XCTAssertEqual(sections.map(\.content), ["Words.", "More."])
    }

    // MARK: - Markdown Literals and Plain-Text Headings (PERF23)

    /// `MarkdownLiteral.escaped` as it was before PERF23: a scalar at a time.
    private static func escapedBefore(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if MarkdownLiteral.isASCIIPunctuation(scalar) {
                result.append("\\")
                result.append(scalar)
            } else if scalar == "\u{FEFF}" {
                result.append(contentsOf: "&#xFEFF;".unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// Every scalar of the Basic Multilingual Plane, and every 97th of the
    /// planes above it, in one string.
    private static let manyScalars: String = {
        let values = Array(UInt32(0)...0xFFFF) + Array(stride(from: UInt32(0x10000), through: 0x10FFFF, by: 97))
        return String(String.UnicodeScalarView(values.compactMap(Unicode.Scalar.init)))
    }()

    /// The texts the plain-text comparisons read: the review's edge strings,
    /// random strings of tricky pieces, its prose, every scalar above, and
    /// TestData's Pride and Prejudice and Markdown sample.
    private func plainTextComparisonInputs() throws -> [String] {
        typealias Fixtures = TextPipelineFixtures
        var texts = Fixtures.edgeTexts + Fixtures.randomTrickyTexts(count: 3_000, seed: 23)
        texts.append(Fixtures.plainText(bytes: 131_072))
        texts.append(Self.manyScalars)
        texts.append(try TextFileDecoder.readText(at: try requireFile("pride.txt"), format: .txt))
        texts.append(try TextFileDecoder.readText(at: try requireFile("sample.md"), format: .markdown))
        return texts
    }

    /// Escaping writes exactly what escaping a scalar at a time wrote.
    func testEscapingMatchesTheScalarLoopItReplaces() throws {
        for text in try plainTextComparisonInputs() {
            XCTAssertEqual(MarkdownLiteral.escaped(text), Self.escapedBefore(text), text.debugDescription.prefix(80).description)
        }
    }

    /// Lines whose capitals, small letters, and line endings put the
    /// plain-text heading rules to the test, a few hundred random ones per
    /// document: all-caps lines with and without other scripts, lines that
    /// uppercasing changes only outside ASCII, titlecase digraphs,
    /// ligatures, sharp s, dotted and dotless i, Greek, Cherokee, Roman
    /// numerals, combining marks, ATX and setext syntax, and lines either
    /// side of 3 and 80 Characters.
    private static func headingTestDocuments(count: Int, seed: UInt64) -> [String] {
        let lines = [
            "CHAPTER ONE", "Chapter one", "chapter one", "\u{C9}COLE", "\u{E9}cole", "STRASSE", "stra\u{DF}e",
            "\u{1E9E}AUS", "\u{1C5}OKTOR", "\u{1C4}OKTOR", "\u{FB01}NAL", "\u{3A3}\u{39F}\u{3A6}\u{399}\u{391}",
            "\u{3C3}\u{3BF}\u{3C6}\u{3B9}\u{3B1}", "\u{130}STANBUL", "\u{131}stanbul", "\u{13A0}\u{13A1}\u{13A2}",
            "\u{AB70}\u{AB71}\u{AB72}", "\u{216B} ROMAN", "\u{217B} roman", "CAFE\u{301}", "cafe\u{301}",
            "\u{65E5}\u{672C}\u{8A9E}", "ABC 123 def", "123 ABC", "A B C", "AB", "ABC", "MIXED case LINE",
            "# Heading #", "###", "####### seven", "## ", "===", "---", "--", "=====", "-----", "", "   ", "\t",
            String(repeating: "A", count: 80), String(repeating: "A", count: 81), "A\u{0}BC", "\u{0}",
            "PART \u{2160}: THE \u{C6}THER", "ONE\u{2028}TWO", "x", "plain prose of an ordinary line",
        ]
        let separators = ["\n", "\n", "\n", "\r\n", "\r", "\u{2028}", "\u{85}", "\n\n"]
        var random = SeededGenerator(state: seed)
        return (0..<count).map { _ in
            (0..<Int(random.next() % 300)).map { _ in
                lines[Int(random.next() % UInt64(lines.count))] + separators[Int(random.next() % UInt64(separators.count))]
            }.joined()
        }
    }

    /// The plain-text line analysis as it was before PERF23
    /// (`PlainTextParser.blocks(in:)` with its heading rules).
    private enum PlainTextBefore {
        static func blocks(in text: String) -> [PlainTextParser.Block] {
            let lines = TextFileDecoder.normalizingLineEndings(text)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let underlines = Set(lines.indices.filter { isSetextUnderline(lines[$0]) })
            var blocks: [PlainTextParser.Block] = []
            var paragraph: [String] = []
            var consumedUnderline: Int?
            func endParagraph() {
                guard !paragraph.isEmpty else { return }
                blocks.append(.paragraph(lines: paragraph))
                paragraph = []
            }
            for (index, line) in lines.enumerated() {
                if index == consumedUnderline { continue }
                if !underlines.contains(index), let heading = heading(at: index, in: lines, underlines: underlines) {
                    endParagraph()
                    blocks.append(.heading(level: heading.level, text: readable(heading.label)))
                    if heading.isUnderlined { consumedUnderline = index + 1 }
                } else if line.isEmpty {
                    endParagraph()
                } else {
                    paragraph.append(readable(line))
                }
            }
            endParagraph()
            return blocks
        }

        static func heading(at index: Int, in lines: [String], underlines: Set<Int>) -> (level: Int, label: String, isUnderlined: Bool)? {
            let line = lines[index]
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6 {
                    let label = String(line.dropFirst(level))
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                        .trimmingCharacters(in: .whitespaces)
                    if !label.isEmpty { return (level, label, false) }
                }
            }
            if !line.isEmpty && underlines.contains(index + 1) {
                return (lines[index + 1].hasPrefix("=") ? 1 : 2, line, true)
            }
            if line.count >= 3 && line.count <= 80
                && line.uppercased() == line
                && line.rangeOfCharacter(from: .letters) != nil
                && line.filter({ $0.isLetter }).count >= 3 {
                return (2, line, false)
            }
            return nil
        }

        static func isSetextUnderline(_ line: String) -> Bool {
            line.count >= 3 && (line.allSatisfy({ $0 == "=" }) || line.allSatisfy({ $0 == "-" }))
        }

        static func readable(_ line: String) -> String {
            guard line.unicodeScalars.contains("\u{0}") else { return line }
            return String(String.UnicodeScalarView(line.unicodeScalars.map { $0 == "\u{0}" ? "\u{FFFD}" : $0 }))
        }
    }

    /// The line analysis finds the headings and paragraphs it found before:
    /// on every plain-text comparison input, on the plain-text fixture the
    /// parser tests share, and on five hundred documents of lines chosen to
    /// test the heading rules.
    func testPlainTextBlocksMatchTheAnalysisTheyReplace() throws {
        var texts = try plainTextComparisonInputs() + Self.headingTestDocuments(count: 500, seed: 2_323)
        texts.append(PlainTextFixture.combined)
        for text in texts {
            XCTAssertEqual(PlainTextParser.blocks(in: text), PlainTextBefore.blocks(in: text), text.debugDescription.prefix(80).description)
        }
    }

    // MARK: - Markdown Whitespace (PERF25)

    /// `ParserUtilities.normalizeMarkdownWhitespace` as it was before
    /// PERF25: a regular expression for every line.
    private static func normalizedWhitespaceBefore(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        var result: [String] = []
        var blankCount = 0
        for line in lines {
            if line.isEmpty {
                blankCount += 1
                if blankCount <= 2 { result.append(line) }
            } else {
                blankCount = 0
                result.append(line)
            }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalizing whitespace writes exactly what the regular expression
    /// wrote: for a line ending in each scalar of the Basic Multilingual
    /// Plane and every 97th above it, alone, doubled, and after a space; for
    /// runs of mixed whitespace and blank lines; and for the other
    /// plain-text inputs, the review's Markdown with tables among them.
    func testWhitespaceNormalizationMatchesTheExpressionItReplaces() throws {
        typealias Fixtures = TextPipelineFixtures
        let scalars = Self.manyScalars.unicodeScalars.filter { $0 != "\n" }
        var texts = [scalars.map { "a\($0)\n\($0)\($0)\nb \($0)\n\($0)" }.joined(separator: "\n")]
        let whitespace = [" ", "\t", "\u{0B}", "\u{0C}", "\r", "\u{85}", "\u{A0}", "\u{2028}", "\u{2029}", "\u{3000}", "\u{200B}", "\n", "\n\n", "x"]
        var random = SeededGenerator(state: 25)
        for _ in 0..<2_000 {
            texts.append((0..<Int(random.next() % 24)).map { _ in whitespace[Int(random.next() % UInt64(whitespace.count))] }.joined())
        }
        texts += try plainTextComparisonInputs()
        texts.append(Fixtures.markdownWithTables(bytes: 131_072))
        for text in texts {
            XCTAssertEqual(
                ParserUtilities.normalizeMarkdownWhitespace(text), Self.normalizedWhitespaceBefore(text),
                text.debugDescription.prefix(80).description
            )
        }
    }

    // MARK: - DAISY Audio (PERF24)

    /// The generated DAISY audio book as a deflated ZIP archive, and as a
    /// folder of loose files, removed when the test ends.
    private func daisyAudioBookCopies(audioBytes: Int) throws -> (files: [String: Data], zip: URL, folder: URL) {
        let files = TextPipelineFixtures.daisyAudioBook(audioBytes: audioBytes)
        let zip = try makeTemporaryZip(
            prefix: "TextPipelineDAISY",
            orderedEntries: files.keys.sorted().map { TestZIPEntry($0, files[$0] ?? Data()) },
            compressionMethod: .deflate
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: zip) }
        let folder = try TextPipelineFixtures.temporaryFolder(for: self)
        for (path, data) in files {
            try data.write(to: folder.appendingPathComponent(path))
        }
        return (files, zip, folder)
    }

    /// Converting a DAISY audio book copies each audio file byte for byte,
    /// from a ZIP archive and from a folder of loose files, and writes the
    /// same manifest, as a package served from memory converts.
    func testDAISYAudioIsCopiedByteForByte() throws {
        let book = try daisyAudioBookCopies(audioBytes: 300_000)
        let providers: [(String, DAISYFileProvider)] = [
            ("archive", ArchiveFileProvider(archive: try Archive(url: book.zip, accessMode: .read))),
            ("folder", DirectoryFileProvider(baseURL: book.folder)),
            ("memory", InMemoryDAISYPackage(text: [:], binary: book.files)),
        ]
        var manifests: [Data] = []
        for (name, provider) in providers {
            let audio = try TextPipelineFixtures.temporaryFolder(for: self)
            let manifest = try DAISYAudioConverter.convertToAudioBook(from: provider, version: .daisy202, toDirectory: audio)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audio.path).sorted(), ["extra.mp3", "track.mp3"], name)
            for file in ["extra.mp3", "track.mp3"] {
                XCTAssertEqual(try Data(contentsOf: audio.appendingPathComponent(file)), book.files[file], "\(name): \(file)")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            manifests.append(try encoder.encode(manifest))
        }
        XCTAssertEqual(Set(manifests).count, 1)
    }

    /// Converting a DAISY audio book from a ZIP archive holds no audio file
    /// whole in memory: the heap grows by far less than the 32 MB audio file
    /// while it is copied, as it grew by more than the whole file when each
    /// file was read into memory before being written out.
    func testDAISYAudioIsCopiedWithoutBeingHeldInMemory() throws {
        let book = try daisyAudioBookCopies(audioBytes: 32 * 1_048_576)
        let provider = ArchiveFileProvider(archive: try Archive(url: book.zip, accessMode: .read))
        let audio = try TextPipelineFixtures.temporaryFolder(for: self)
        let baseline = HeapSampler.heapInUse()
        let sampler = HeapSampler()
        _ = try DAISYAudioConverter.convertToAudioBook(from: provider, version: .daisy202, toDirectory: audio)
        let growth = sampler.stop() - baseline
        XCTAssertLessThan(growth, 8 * 1_048_576, "the heap grew by \(growth / 1_048_576) MB")
        XCTAssertEqual(try Data(contentsOf: audio.appendingPathComponent("track.mp3")), book.files["track.mp3"])
    }

    /// An audio file an import's budget refuses, because it holds more
    /// than the archive records for it, or more than the most TextMouth
    /// reads from one file, is not copied, and nothing of it is left behind;
    /// the budget keeps the refusal for the import to report.
    func testRefusedDAISYAudioLeavesNothingBehind() throws {
        let book = try daisyAudioBookCopies(audioBytes: 300_000)
        try setRecordedSize(of: "track.mp3", in: book.zip, to: 1_000)
        let refusals: [(String, ArchiveEntryLimits)] = [
            ("past its recorded size", .standard),
            ("past the limit", ArchiveEntryLimits(audio: 500, text: ArchiveEntryLimits.standard.text)),
        ]
        for (reason, limits) in refusals {
            let budget = ArchiveBudget()
            let provider = ArchiveFileProvider(archive: try Archive(url: book.zip, accessMode: .read), budget: budget)
            let audio = try TextPipelineFixtures.temporaryFolder(for: self)
            _ = try ArchiveEntryLimits.$current.withValue(limits) {
                try DAISYAudioConverter.convertToAudioBook(from: provider, version: .daisy202, toDirectory: audio)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audio.path), ["extra.mp3"], reason)
            XCTAssertNotNil(budget.violation, reason)
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
