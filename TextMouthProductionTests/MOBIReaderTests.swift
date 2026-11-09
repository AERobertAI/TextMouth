import XCTest
@testable import TextMouth

/// TextMouth's own reader of Kindle (MOBI 6) books (FMT42), against the real
/// files in `TestData/format-samples/mobi` (Project Gutenberg's and one made
/// with calibre), and through the import path a listener uses. Books built in
/// code are in `MOBIBookStructureTests`, and hostile files in
/// `MOBIHostileFileTests`.
final class MOBIReaderTests: XCTestCase {

    // MARK: - Helpers

    /// `text` with every run of white space made one space, so a comparison
    /// does not depend on how paragraphs are separated.
    private func spaced(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Asserts that reading the file at `url` fails with `error`, and with
    /// that error's exact sentence.
    private func assertRefused(
        _ url: URL, _ error: MOBIError, sentence: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try MOBIParser.prepareBook(url: url), file: file, line: line) {
            XCTAssertEqual($0 as? MOBIError, error, file: file, line: line)
            XCTAssertEqual($0.localizedDescription, sentence, file: file, line: line)
        }
    }

    // MARK: - Project Gutenberg's MOBI 6

    func testTheYellowWallpaperNamesItsTitleAuthorAndLanguage() throws {
        let book = try MOBIParser.prepareBook(url: copyOfFormatSample("mobi/pg1952-yellow-wallpaper.mobi"))
        XCTAssertEqual(book.title, "The Yellow Wallpaper")
        XCTAssertEqual(book.author, "Charlotte Perkins Gilman")
        XCTAssertEqual(book.language, "en")
    }

    func testTheYellowWallpaperReadsAsItsStoryBetweenGutenbergsFrontAndBackMatter() throws {
        let book = try MOBIParser.prepareBook(url: copyOfFormatSample("mobi/pg1952-yellow-wallpaper.mobi"))
        // The contents (NCX) has three entries, so there are three chapters,
        // and the 109 bytes of head before the first entry are no chapter.
        XCTAssertEqual(book.chapters.map(\.chapter.title), [
            "The Project Gutenberg eBook of The Yellow Wallpaper, by Charlotte Perkins Gilman",
            "The Yellow Wallpaper",
            "THE FULL PROJECT GUTENBERG LICENSE",
        ])
        guard book.chapters.count == 3 else { return XCTFail("chapters: \(book.chapters.map(\.chapter.title))") }
        let story = spaced(book.chapters[1].chapter.text)
        XCTAssertTrue(story.hasPrefix(
            "The Yellow Wallpaper By Charlotte Perkins Gilman It is very seldom that mere ordinary people "
                + "like John and myself secure ancestral halls for the summer."), String(story.prefix(160)))
        // The last words of the story; the curly quotes are the book's own.
        XCTAssertTrue(story.contains(
            "“I’ve got out at last,” said I, “in spite of you and Jane! And I’ve pulled off most of the paper, "
                + "so you can’t put me back!” Now why should that man have fainted? But he did, and right across "
                + "my path by the wall, so that I had to creep over him every time!"))
        XCTAssertTrue(spaced(book.chapters[2].chapter.text).hasPrefix("THE FULL PROJECT GUTENBERG LICENSE PLEASE READ THIS BEFORE"))
    }

    func testTheYellowWallpaperHasNoPagesAndNoMarkupInItsWords() throws {
        let book = try MOBIParser.prepareBook(url: copyOfFormatSample("mobi/pg1952-yellow-wallpaper.mobi"))
        for prepared in book.chapters {
            XCTAssertFalse(prepared.markdown.contains("<!-- page:"), prepared.chapter.title)
            XCTAssertTrue(prepared.chapter.pages.isEmpty, prepared.chapter.title)
            for forbidden in ["<", ">", "filepos", "mbp:"] {
                XCTAssertFalse(prepared.chapter.text.contains(forbidden), "\(forbidden) in \(prepared.chapter.title)")
            }
        }
    }

    func testTheYellowWallpaperContentsEntriesAreEachChaptersFirstHeading() throws {
        let content = try MOBIParser.parse(url: copyOfFormatSample("mobi/pg1952-yellow-wallpaper.mobi"))
        XCTAssertEqual(content.chapters.count, 3)
        for chapter in content.chapters {
            XCTAssertEqual(chapter.headings.first?.text, chapter.title)
            XCTAssertEqual(chapter.headings.first?.level, 1)
            XCTAssertEqual(chapter.headings.first?.characterOffset, 0)
        }
    }

    // MARK: - calibre's MOBI 6 with a contents

    func testTheFerryNotesChaptersAndHeadingsComeFromItsContents() throws {
        let book = try MOBIParser.prepareBook(url: copyOfFormatSample("mobi/ferry-notes-ncx.mobi"))
        XCTAssertEqual(book.title, "Ferry Notes")
        XCTAssertEqual(book.author, "Ottoline Brannock")
        // calibre writes every entry of its contents at depth 0, sections
        // included, so each of the five is a chapter.
        XCTAssertEqual(book.chapters.map(\.chapter.title), [
            "The Morning Crossing", "Buying a Ticket", "Reading the Timetable", "The Evening Crossing", "Lost Property",
        ])
        guard book.chapters.count == 5 else { return XCTFail("chapters: \(book.chapters.map(\.chapter.title))") }
        XCTAssertTrue(spaced(book.chapters[0].chapter.text).hasPrefix(
            "The Morning Crossing The first ferry leaves the Tallow Quay at seven and reaches the island before the bakers have finished their loaves."))
        XCTAssertTrue(spaced(book.chapters[1].chapter.text).contains("The hatch opens when the kettle behind it boils."))
        XCTAssertTrue(spaced(book.chapters[4].chapter.text).contains("keys for as long as it takes someone to ask."))
    }

    func testAnImageWithoutAltTextAddsNoWordsToTheFerryNotes() throws {
        let book = try MOBIParser.prepareBook(url: copyOfFormatSample("mobi/ferry-notes-ncx.mobi"))
        guard book.chapters.count == 5 else { return XCTFail("chapters: \(book.chapters.map(\.chapter.title))") }
        let last = spaced(book.chapters[4].chapter.text)
        XCTAssertTrue(last.hasSuffix("keys for as long as it takes someone to ask."), last)
    }

    // MARK: - Refusals

    func testTheCopyProtectedSampleIsRefusedWithTheCopyProtectionSentence() throws {
        assertRefused(
            try copyOfFormatSample("mobi/yellow-wallpaper-drm-flagged-synthetic.mobi"), .copyProtected,
            sentence: "This Kindle book is copy-protected, and TextMouth can't read copy-protected books.")
    }

    // MARK: - The metadata

    func testTheMetadataOfEachSampleReadsWithoutTheText() throws {
        let gutenberg = try MOBIParser.readMetadata(url: formatSampleURL("mobi/pg1952-yellow-wallpaper.mobi"))
        XCTAssertEqual(gutenberg.title, "The Yellow Wallpaper")
        XCTAssertEqual(gutenberg.author, "Charlotte Perkins Gilman")
        // A protected or KF8 book still names its title.
        let protected = try MOBIParser.readMetadata(url: formatSampleURL("mobi/yellow-wallpaper-drm-flagged-synthetic.mobi"))
        XCTAssertEqual(protected.title, "The Yellow Wallpaper")
        let kf8 = try MOBIParser.readMetadata(url: formatSampleURL("mobi/pg1952-yellow-wallpaper-kf8.mobi"))
        XCTAssertEqual(kf8.author, "Charlotte Perkins Gilman")
    }

    // MARK: - The format

    func testKindleBooksAreRecognizedByTheirExtensions() throws {
        XCTAssertEqual(BookFormat.mobi.rawValue, "mobi")
        XCTAssertEqual(BookFormat.mobi.displayName, "Kindle Book (MOBI)")
        // An .azw3 is a Kindle book in KF8 (FMT48), which the same reader reads.
        for name in ["a.mobi", "a.MOBI", "a.prc", "a.azw", "a.azw3", "a.AZW3"] {
            XCTAssertEqual(BookFormat.detect(from: URL(fileURLWithPath: "/tmp/\(name)")), .mobi, name)
        }
        // A MOBI 6 book has no print pages, a KF8 book (FMT48) has its EPUB's page-break
        // elements, and both are the format "mobi": its page reader is 1.1.0 (soft hyphens are left out of
        // a MOBI 6 book's words, and a KF8 book's license begins with its opening words).
        XCTAssertEqual(PageReaderVersions.current(for: .mobi), "1.1.0")
    }

    func testThePanelOffersKindleBooks() {
        XCTAssertTrue(FileImportService.supportedTypes.contains { $0.identifier == "com.textmouth.mobi" })
    }

    func testTheFinderOffersTextMouthForKindleBooks() throws {
        for fileExtension in ["mobi", "prc", "azw", "azw3"] {
            let type = try XCTUnwrap(documentType(listing: fileExtension), fileExtension)
            XCTAssertEqual(type["CFBundleTypeRole"] as? String, "Viewer")
            XCTAssertEqual(type["LSHandlerRank"] as? String, "Alternate")
        }
    }

    // MARK: - Import

    func testTheYellowWallpaperImportsWithItsNamesAndOpensAsThreeChapters() throws {
        let imported = try importedForTest(try copyOfFormatSample("mobi/pg1952-yellow-wallpaper.mobi"))
        XCTAssertEqual(imported.book.format, .mobi)
        XCTAssertEqual(imported.book.title, "The Yellow Wallpaper")
        XCTAssertEqual(imported.book.author, "Charlotte Perkins Gilman")
        XCTAssertTrue(imported.report.isComplete)

        let content = try openedContent(of: imported.book)
        XCTAssertEqual(content.chapters.map(\.title), [
            "The Project Gutenberg eBook of The Yellow Wallpaper, by Charlotte Perkins Gilman",
            "The Yellow Wallpaper",
            "THE FULL PROJECT GUTENBERG LICENSE",
        ])
        XCTAssertTrue(spaced(allText(of: content)).contains("It is very seldom that mere ordinary people"))
        XCTAssertTrue(content.pages.breaks.isEmpty, "a Kindle book has no print pages")
        XCTAssertEqual(imported.book.pageReaderVersion, "1.1.0")
    }

    func testAnImportedKindleBookReadsTheSameFromItsSourceAfterItsTextIsRemoved() throws {
        let imported = try importedForTest(try copyOfFormatSample("mobi/ferry-notes-ncx.mobi"))
        let before = try openedContent(of: imported.book)
        try FileManager.default.removeItem(at: MarkdownCacheService.cacheURL(for: imported.book))
        let after = try BookContentAnalysisService.load(book: imported.book, regenerateTextCache: true).content
        XCTAssertEqual(allText(of: after), allText(of: before))
        XCTAssertEqual(headingLines(of: after), headingLines(of: before))
        XCTAssertEqual(headingLines(of: before), [
            "1: The Morning Crossing", "1: Buying a Ticket", "1: Reading the Timetable",
            "1: The Evening Crossing", "1: Lost Property",
        ])
    }

    func testImportingTheProtectedSampleFailsWithItsSentence() throws {
        for (sample, sentence) in [
            ("mobi/yellow-wallpaper-drm-flagged-synthetic.mobi",
             "This Kindle book is copy-protected, and TextMouth can't read copy-protected books."),
        ] {
            let url = try copyOfFormatSample(sample)
            XCTAssertThrowsError(try FileImportService.importFileWithReport(from: url), sample) {
                XCTAssertTrue($0.localizedDescription.hasSuffix(sentence), $0.localizedDescription)
            }
        }
    }

    func testAFileNamedMobiThatIsNotAKindleBookFailsToImportWithAPlainSentence() throws {
        let url = try writeMOBI(Array("This is only a note.".utf8), named: "note.mobi")
        XCTAssertThrowsError(try FileImportService.importFileWithReport(from: url)) {
            XCTAssertTrue(
                $0.localizedDescription.hasSuffix("This file is not a Kindle book that TextMouth can read."),
                $0.localizedDescription)
        }
    }
}
