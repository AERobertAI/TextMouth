import CryptoKit
import XCTest
@testable import TextMouth

/// Real Kindle KF8 books (FMT48), kept in `TestData/format-samples`, read as
/// an import reads them and compared with the same book as an EPUB through
/// TextMouth's EPUB reader, the yardstick: the same words in the same order,
/// the same headings at the same levels, and the same pages. Two come from
/// outside (Standard Ebooks' The Time Machine and Project Gutenberg's The
/// Yellow Wallpaper, both made by calibre: their EXTH 535 says so), one is a
/// hybrid file from Amazon's kindlegen (libmobi's), and the others were made
/// here from EPUBs that are kept beside them (`Scripts/make-kf8-samples.py`
/// and the edge books of `Scripts/make-kf8-edge-samples.py`, converted by
/// calibre and by kindlegen as black boxes).
final class KF8RealBookTests: XCTestCase {

    // MARK: - Helpers

    /// The sample read into chapters, as an import reads it.
    private func prepared(_ sample: String, named name: String? = nil) throws -> MOBIParser.PreparedBook {
        try MOBIParser.prepareBook(url: copyOfFormatSample(sample, named: name))
    }

    /// The sample's EPUB read by the EPUB reader.
    private func epub(_ sample: String) throws -> EPUBParser.PreparedBook {
        try EPUBParser.prepareBook(url: copyOfFormatSample(sample))
    }

    /// A hybrid sample read from the half asked for.
    private func hybrid(_ sample: String, _ half: MOBIBook.HybridChoice) throws -> MOBIParser.PreparedBook {
        let bytes = [UInt8](try Data(contentsOf: formatSampleURL(sample)))
        let book = try MOBIBook(bytes: bytes, hybrid: half)
        return try MOBIParser.preparedBook(
            sections: book.sections, metadata: book.metadata, fallbackTitle: "Hybrid", includesPages: book.includesPages)
    }

    /// Every chapter's text, as its words: white space made single spaces, and
    /// the characters no one sees (a soft hyphen, a zero-width space, a word
    /// joiner, a byte order mark used as one) left out, as the words a listener hears.
    private func words(_ chapters: [Chapter]) -> [String] {
        let invisible: Set<Unicode.Scalar> = ["\u{AD}", "\u{200B}", "\u{2060}", "\u{FEFF}"]
        return chapters.flatMap { chapter in
            chapter.text.split(whereSeparator: \.isWhitespace).map { word in
                String(String.UnicodeScalarView(word.unicodeScalars.filter { !invisible.contains($0) }))
            }
        }.filter { !$0.isEmpty }
    }

    /// The SHA-256 of `words` joined by single spaces, in lowercase hexadecimal.
    private func digest(_ words: [String]) -> String {
        SHA256.hash(data: Data(words.joined(separator: " ").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The headings of `chapters` as "level: text".
    private func headings(_ chapters: [Chapter]) -> [String] {
        chapters.flatMap { $0.headings.map { "\($0.level): \($0.text)" } }
    }

    /// The labels of the pages of `chapters`, in book order.
    private func pageLabels(_ chapters: [Chapter]) -> [String] {
        chapters.flatMap { $0.pages.map(\.label) }
    }

    // MARK: - Standard Ebooks' The Time Machine, from calibre

    func testTheTimeMachineReadsAsItsChaptersWithItsNames() throws {
        let book = try prepared("azw3/se-the-time-machine.azw3")
        XCTAssertEqual(book.title, "The Time Machine")
        XCTAssertEqual(book.author, "H. G. Wells")
        XCTAssertEqual(book.language, "en")
        let chapters = book.chapters.map(\.chapter)
        XCTAssertEqual(chapters.map(\.title), [
            "The Time Machine", "Imprint", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII",
            "Epilogue", "Endnotes", "Colophon", "Uncopyright",
        ])
        XCTAssertEqual(headings(chapters), ["1: The Time Machine"] + chapters.dropFirst().map { "2: \($0.title)" })
    }

    func testTheTimeMachineHasTheWordsOfItsEPUBAndNoSoftHyphen() throws {
        let kf8 = words(try prepared("azw3/se-the-time-machine.azw3").chapters.map(\.chapter))
        XCTAssertEqual(kf8.count, 33_011)
        XCTAssertEqual(kf8.prefix(8).joined(separator: " "), "The Time Machine By H. G. Wells. Imprint")
        XCTAssertEqual(kf8.suffix(8).joined(separator: " "), "that has given all of us so much.")
        // The same words in the same order as Standard Ebooks' own EPUB of the book, which is
        // not kept here (it is a half megabyte): this is the digest of the words the EPUB reader
        // reads from it, but for one word. The AZW3 spells the end-note's number "1." in its text,
        // where the EPUB has it as the number of a list item that the reading text leaves out.
        XCTAssertEqual(digest(kf8), "a81a9d59b6b82f9dd4edd5a5073b454fdb18e8d61949d9441f998b444efbb236")
        let raw = try prepared("azw3/se-the-time-machine.azw3").chapters.map(\.chapter.text).joined()
        XCTAssertFalse(raw.contains("\u{AD}"), "the book's soft hyphens are not read")
    }

    func testTheTimeMachineHasNoContentsPageAtItsEnd() throws {
        let book = try prepared("azw3/se-the-time-machine.azw3")
        XCTAssertEqual(book.chapters.last?.chapter.title, "Uncopyright")
    }

    // MARK: - Project Gutenberg's The Yellow Wallpaper, from calibre

    func testTheYellowWallpaperKF8ReadsLikeItsEPUBFromProjectGutenberg() throws {
        // The KF8 file is named .mobi: the header's version decides, not the name.
        let book = try prepared("mobi/pg1952-yellow-wallpaper-kf8.mobi")
        XCTAssertEqual(book.title, "The Yellow Wallpaper")
        XCTAssertEqual(book.author, "Charlotte Perkins Gilman")
        let chapters = book.chapters.map(\.chapter)
        let kf8 = words(chapters)
        XCTAssertEqual(kf8.count, 9_127)
        // The digest of the words Project Gutenberg's EPUB of the same book gives the EPUB reader
        // (that EPUB is not kept): the same words in the same order.
        XCTAssertEqual(digest(kf8), "aa27cad3e68df7e2756f9bcad186f3d695c9d91bbf712469fa993fb5ebbbebe8")
        // The same headings at the same levels as that EPUB's.
        XCTAssertEqual(headings(chapters), [
            "2: The Project Gutenberg eBook of The Yellow Wallpaper", "1: The Yellow Wallpaper",
            "2: By Charlotte Perkins Gilman", "2: THE FULL PROJECT GUTENBERG™ LICENSE",
        ])
        // calibre cut the EPUB's two documents into four, and added a contents page at the end that is not read.
        // The piece of the license that opens with no heading goes on with the license before it, so the
        // license is one section, with no heading made from the title calibre gave the piece (the EPUB reader,
        // which reads each document whole, has the license twice).
        XCTAssertEqual(chapters.map(\.title), [
            "The Project Gutenberg eBook of The Yellow Wallpaper", "By Charlotte Perkins Gilman",
            "THE FULL PROJECT GUTENBERG™ LICENSE",
        ])
        XCTAssertFalse(chapters.contains { $0.title == "Table of Contents" })
    }

    // MARK: - Project Gutenberg's A Modest Proposal, from calibre

    /// The essay is a document with no heading whose `<title>` is the header page's, so a repeated title once
    /// joined it to the header (two chapters, where the EPUB has three), and the license's opening words, in the first
    /// piece calibre cut the license into, were read at the end of the essay. Chapter for chapter, the KF8 file and
    /// the EPUB must now be the same book: the same titles, the same number of words in each, the same words in
    /// the same order.
    func testAModestProposalReadsAsItsEPUBsThreeChaptersWithTheLicensesOpeningInTheLicense() throws {
        let book = try prepared("mobi/pg1080-modest-proposal-kf8.mobi")
        XCTAssertTrue(book.title.hasPrefix("A Modest Proposal"), book.title)
        let chapters = book.chapters.map(\.chapter)
        let source = try epub("azw3/pg1080-modest-proposal.epub").chapters.map(\.chapter)
        let found = chapters.map { "\"\($0.title)\" (\($0.wordCount) words)" }.joined(separator: "; ")
        XCTAssertEqual(chapters.map(\.title), source.map(\.title), found)
        XCTAssertEqual(chapters.map(\.title), [
            "The Project Gutenberg eBook of A Modest Proposal", "A Modest Proposal", "THE FULL PROJECT GUTENBERG™ LICENSE",
        ], found)
        XCTAssertEqual(chapters.map(\.wordCount), source.map(\.wordCount), "words in each chapter: \(found)")
        XCTAssertEqual(chapters.map(\.wordCount), [169, 3_386, 2_906], found)
        let kf8 = words(chapters)
        XCTAssertEqual(kf8.count, 6_461)
        XCTAssertEqual(digest(kf8), digest(words(source)), "the words, in order, of the KF8 book and of its EPUB")
        // The essay's chapter holds the essay and not the license's opening, which begins the license's chapter.
        let essay = chapters[1].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let license = chapters[2].text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(essay.hasSuffix("my wife past child-bearing."), String(essay.suffix(120)))
        XCTAssertTrue(license.hasPrefix("*** END OF THE PROJECT GUTENBERG EBOOK"), String(license.prefix(120)))
        XCTAssertEqual(headings(chapters), headings(source), "the same headings at the same levels")
    }

    // MARK: - The Quay Almanac, made here from an EPUB

    func testTheQuayAlmanacAZW3ReadsLikeItsEPUBInEveryWayCounted() throws {
        let kf8 = try prepared("azw3/quay-almanac.azw3")
        let source = try epub("azw3/quay-almanac.epub")
        XCTAssertEqual(kf8.title, source.title)
        XCTAssertEqual(kf8.author, source.author)
        let (kf8Chapters, epubChapters) = (kf8.chapters.map(\.chapter), source.chapters.map(\.chapter))
        XCTAssertEqual(kf8Chapters.map(\.title), epubChapters.map(\.title))
        XCTAssertEqual(kf8Chapters.map(\.title), ["Tides", "Ferries", "Lost property"])
        XCTAssertEqual(words(kf8Chapters), words(epubChapters))
        XCTAssertEqual(words(kf8Chapters).count, 2_401)
        XCTAssertEqual(headings(kf8Chapters), headings(epubChapters))
        XCTAssertEqual(headings(kf8Chapters), [
            "1: Tides", "2: Spring tides", "3: Floods", "2: Neap tides", "2: From the ledger",
            "1: Ferries", "2: Timetable", "1: Lost property",
        ])
        // The page breaks, one written with epub:type and one with role, which calibre left in different spellings.
        XCTAssertEqual(pageLabels(kf8Chapters), pageLabels(epubChapters))
        XCTAssertEqual(pageLabels(kf8Chapters), ["2", "3", "9"])
        // The text of each chapter, character for character. (The cache's Markdown differs in the links'
        // destinations, which the EPUB writes as file names and the AZW3 as kindle:pos places; no one hears them.)
        XCTAssertEqual(kf8Chapters.map(\.text), epubChapters.map(\.text))
    }

    func testTheQuayAlmanacPicturesAreReadByTheirDescriptionsAndItsListsAndTableComeThrough() throws {
        let text = words(try prepared("azw3/quay-almanac.azw3").chapters.map(\.chapter)).joined(separator: " ")
        for expected in ["A chalk map of the pier", "Tickets are sold at the hatch.", "seven o'clock", "the direction of the wind"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
    }

    func testTheQuayAlmanacHybridReadsLikeItsEPUBFromItsKF8HalfAndFlatFromItsMOBI6Half() throws {
        let source = try epub("azw3/quay-almanac.epub").chapters.map(\.chapter)
        let newer = try hybrid("mobi/quay-almanac-hybrid.mobi", .kf8).chapters.map(\.chapter)
        XCTAssertEqual(newer.map(\.title), source.map(\.title))
        XCTAssertEqual(words(newer), words(source))
        XCTAssertEqual(headings(newer), headings(source))
        XCTAssertEqual(pageLabels(newer), ["2", "3", "9"])
        // The MOBI 6 half of a calibre hybrid has every heading at level 1 and no pages, and it
        // reads the contents page calibre added: the reason a hybrid is read from its KF8 half.
        let older = try hybrid("mobi/quay-almanac-hybrid.mobi", .mobi6).chapters.map(\.chapter)
        XCTAssertEqual(Set(headings(older).map { String($0.prefix(2)) }), ["1:"])
        XCTAssertTrue(pageLabels(older).isEmpty)
        XCTAssertEqual(headings(older).count, headings(newer).count)
        XCTAssertEqual(words(older).count, words(newer).count + 10, "ten words of a contents page, which only the MOBI 6 half has")
    }

    // MARK: - Hybrids

    func testTheKindlegenHybridsReadWithTheSameWordsFromEitherHalfAndAtLeastTheHeadingsFromTheKF8Half() throws {
        for (sample, wordCount) in [("mobi/pg8121-ghosts-hybrid.mobi", 27_276), ("mobi/libmobi-unicode-huffdic.mobi", 3_580)] {
            let newer = try hybrid(sample, .kf8).chapters.map(\.chapter)
            let older = try hybrid(sample, .mobi6).chapters.map(\.chapter)
            XCTAssertEqual(words(newer), words(older), sample)
            XCTAssertEqual(words(newer).count, wordCount, sample)
            XCTAssertGreaterThanOrEqual(headings(newer).count, headings(older).count, sample)
            // Every heading the MOBI 6 half has is in the KF8 half at the same level (but for the one a chapter
            // with no heading is given, which the MOBI 6 half of Ghosts starts with).
            XCTAssertTrue(Set(headings(older).filter { !$0.hasSuffix("Chapter 1") }).isSubset(of: Set(headings(newer))), sample)
        }
    }

    func testGhostsReadFromItsKF8HalfHasItsNamesAndFourChapters() throws {
        let book = try prepared("mobi/pg8121-ghosts-hybrid.mobi")
        XCTAssertEqual(book.title, "Ghosts")
        XCTAssertEqual(book.author, "Henrik Ibsen")
        // The license piece at the end has no heading and the title of the piece before it, so it goes on with ACT THIRD (S4).
        XCTAssertEqual(book.chapters.count, 4)
        XCTAssertEqual(book.chapters.map(\.chapter.title)[1...3], ["GHOSTS", "ACT SECOND.", "ACT THIRD."])
        XCTAssertTrue(words(book.chapters.map(\.chapter)).joined(separator: " ").contains("Théâtre Libre"))
    }

    // MARK: - The review's edge books

    /// The edge book `name` read four ways: from calibre's AZW3, from the KF8 half of calibre's hybrid (nil when it
    /// has none), and from the KF8 half of kindlegen's hybrid; and the EPUB it was made from.
    private func edge(_ name: String) throws -> (epub: [Chapter], readings: [String: [Chapter]]) {
        let source = try epub("azw3/edge/\(name).epub").chapters.map(\.chapter)
        var readings: [String: [Chapter]] = [
            "calibre AZW3": try prepared("azw3/edge/\(name).azw3").chapters.map(\.chapter),
            "kindlegen hybrid": try hybrid("mobi/edge/\(name)-kindlegen-hybrid.mobi", .kf8).chapters.map(\.chapter),
        ]
        if let url = try? formatSampleURL("mobi/edge/\(name)-calibre-hybrid.mobi"), FileManager.default.fileExists(atPath: url.path) {
            readings["calibre hybrid"] = try hybrid("mobi/edge/\(name)-calibre-hybrid.mobi", .kf8).chapters.map(\.chapter)
        }
        return (source, readings)
    }

    func testALastPageWithWordsOfItsOwnIsReadInEveryKindOfFile() throws {
        // toc-last: an author's contents page and a note, last in the book, which the guide names as the contents.
        // toc-mixed: the last chapter, with its list at its end. toc-epilogue: a guide entry that names the epilogue.
        // The review found 38, 401, and 300 words lost; every word must be read now, in every file.
        for name in ["toc-last", "toc-mixed", "toc-epilogue"] {
            let (source, readings) = try edge(name)
            for (what, chapters) in readings {
                XCTAssertEqual(words(chapters), words(source), "\(name) as \(what)")
            }
        }
    }

    func testABookOfOneDocumentWhoseGuideNamesItIsNotRefusedInEveryKindOfFile() throws {
        let (source, readings) = try edge("toc-single")
        XCTAssertGreaterThan(words(source).count, 50)
        for (what, chapters) in readings {
            XCTAssertEqual(words(chapters), words(source), "toc-single as \(what)")
        }
    }

    func testWordsInAnSVGPictureAreRead() throws {
        // svg-words: the SVG's visible text, title, and description (the EPUB reader reads them), which calibre
        // and kindlegen move out of the markup into a flow.
        let (source, readings) = try edge("svg-words")
        XCTAssertTrue(words(source).contains(where: { $0.hasPrefix("w5") }))
        // kindlegen's hybrid declares a text length that leaves its SVG flows outside the declared text: they are
        // read through the flow table's end.
        for (what, chapters) in readings {
            XCTAssertEqual(words(chapters), words(source), "svg-words as \(what)")
        }
    }

    func testNavigationListsAreNotReadAloudInRealFiles() throws {
        // nav-in-spine has an EPUB 3 navigation document in its spine; page-list has a page list. calibre strips the
        // prefix from their epub:type, and the words must still be the EPUB reader's.
        for name in ["nav-in-spine", "page-list"] {
            let (source, readings) = try edge(name)
            for (what, chapters) in readings {
                XCTAssertEqual(words(chapters), words(source), "\(name) as \(what)")
                XCTAssertEqual(headings(chapters), headings(source), "\(name) as \(what)")
                // An EPUB whose pages are named only by its page list has none in KF8: the format keeps no page list.
                if name == "nav-in-spine" { XCTAssertEqual(pageLabels(chapters), pageLabels(source), "\(name) as \(what)") }
            }
        }
    }

    func testPagesCalibreCutAtPageBreakStylesAreOneChapterWithNoFalseHeadings() throws {
        // page-break-style: calibre cut one document in four places, one in the middle of a paragraph. Its pieces
        // go on with the chapter before them, whose heading is the document's own.
        let (source, readings) = try edge("page-break-style")
        for (what, chapters) in readings {
            XCTAssertEqual(words(chapters), words(source), "page-break-style as \(what)")
            XCTAssertEqual(headings(chapters), headings(source), "page-break-style as \(what)")
            XCTAssertEqual(chapters.map(\.title), source.map(\.title), "page-break-style as \(what)")
        }
        // The cut in the middle of a paragraph does not break it: the EPUB reads that paragraph whole.
        let calibre = try XCTUnwrap(readings["calibre AZW3"])
        XCTAssertEqual(calibre.map(\.text), source.map(\.text), "text, paragraph by paragraph")
    }

    // MARK: - Whatever the file is named

    func testAKF8BookReadsTheSameWhateverItsFileIsNamed() throws {
        let reference = try prepared("azw3/quay-almanac.azw3").chapters.map(\.markdown)
        for name in ["book.mobi", "book.azw", "book.prc", "book.AZW3"] {
            XCTAssertEqual(try prepared("azw3/quay-almanac.azw3", named: name).chapters.map(\.markdown), reference, name)
        }
    }

    func testTheMetadataOfAKF8BookReadsWithoutItsText() throws {
        let metadata = try MOBIParser.readMetadata(url: formatSampleURL("azw3/quay-almanac.azw3"))
        XCTAssertEqual(metadata, MOBIBook.Metadata(title: "Quay Almanac", author: "Casimir Oyelaran", language: "en"))
        let hybrid = try MOBIParser.readMetadata(url: formatSampleURL("mobi/quay-almanac-hybrid.mobi"))
        XCTAssertEqual(hybrid.title, "Quay Almanac")
    }

    // MARK: - The whole import

    func testAnAZW3FileImportsAndOpensWithItsChaptersHeadingsAndPages() throws {
        let imported = try importedForTest(try copyOfFormatSample("azw3/quay-almanac.azw3"))
        XCTAssertEqual(imported.book.format, .mobi)
        XCTAssertEqual(imported.book.title, "Quay Almanac")
        XCTAssertEqual(imported.book.author, "Casimir Oyelaran")
        XCTAssertTrue(imported.report.isComplete)
        XCTAssertEqual(imported.book.pageReaderVersion, PageReaderVersions.current(for: .mobi))
        let content = try openedContent(of: imported.book)
        XCTAssertEqual(content.chapters.map(\.title), ["Tides", "Ferries", "Lost property"])
        XCTAssertEqual(headingLines(of: content).count, 8)
        XCTAssertEqual(content.pages.breaks.map(\.label), ["2", "3", "9"])
    }

    func testTheTimeMachineImportsAsEighteenChapters() throws {
        let imported = try importedForTest(try copyOfFormatSample("azw3/se-the-time-machine.azw3"))
        XCTAssertEqual(imported.book.title, "The Time Machine")
        XCTAssertEqual(try openedContent(of: imported.book).chapters.count, 18)
    }
}
