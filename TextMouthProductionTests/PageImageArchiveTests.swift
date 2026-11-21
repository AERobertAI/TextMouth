import XCTest
import ZIPFoundation
@testable import TextMouth

/// Comic book archives (FMT34): the pictures of a ZIP named .cbz, in the
/// natural order of their paths, with what an optional ComicInfo.xml says of
/// the book and its pages, each page read from the archive in its turn
/// within the limits of one file and checked against its checksum.
final class PageImageArchiveTests: XCTestCase {
    private typealias Script = ScriptedPageRecognizer

    // MARK: - Pages

    /// Pictures are pages in the natural order of their paths, a folder's
    /// together; hidden files, `__MACOSX`, folders, and files of other kinds
    /// are passed over.
    func testThePicturesArePagesInNaturalOrder() throws {
        let page = try PageImageFixtures.plainPage()
        let url = try PageImageFixtures.comicArchive([
            TestZIPEntry("page10.png", page),
            TestZIPEntry("page2.png", page),
            TestZIPEntry("page1.jpg", page),
            TestZIPEntry.folder("Extras/"),
            TestZIPEntry("Extras/sketch.png", page),
            TestZIPEntry(".hidden.png", page),
            TestZIPEntry("__MACOSX/._page1.jpg", page),
            TestZIPEntry("readme.txt", Data("scanned by the harbour club".utf8)),
            TestZIPEntry("Thumbs.db", Data([0, 1, 2])),
        ], for: self)

        let archive = try PageImageArchive(url: url)

        XCTAssertEqual(archive.pages.map(\.entry.path), ["Extras/sketch.png", "page1.jpg", "page2.png", "page10.png"])
        XCTAssertEqual(archive.pages.map(\.title), ["Page 1", "Page 2", "Page 3", "Page 4"])
        XCTAssertNil(archive.comicInfo)
        XCTAssertEqual(archive.subject, .archive)
    }

    /// ComicInfo.xml names the book and its writer, and its pages: a deleted
    /// picture is no page, a cover is titled as one, and a bookmark names its
    /// page's chapter, made fit for a chapter line.
    func testComicInfoNamesTheBookAndItsPages() throws {
        let page = try PageImageFixtures.plainPage()
        let info = PageImageFixtures.comicInfo("""
            <Title>The Harbour Office</Title>
            <Series>Harbour Notices</Series>
            <Number>1</Number>
            <Writer>Odile Banerjee</Writer>
            <Summary>A very long summary that is never read.</Summary>
            <Pages>
              <Page Image="0" Type="FrontCover"/>
              <Page Image="1" Type="Deleted"/>
              <Page Image="2" Bookmark="Chapter 1 --> The   Pier&#10;at dawn"/>
              <Page Image="3" Type="Story"/>
            </Pages>
            """)
        let url = try PageImageFixtures.comicArchive([
            TestZIPEntry("ComicInfo.xml", info),
            TestZIPEntry("001.png", page), TestZIPEntry("002.png", page),
            TestZIPEntry("003.png", page), TestZIPEntry("004.png", page),
        ], for: self)

        let archive = try PageImageArchive(url: url)

        XCTAssertEqual(archive.comicInfo?.bookTitle, "The Harbour Office")
        XCTAssertEqual(archive.comicInfo?.writer, "Odile Banerjee")
        XCTAssertEqual(archive.pages.map(\.entry.path), ["001.png", "003.png", "004.png"])
        XCTAssertEqual(archive.pages.map(\.title), ["Front Cover", "Chapter 1 - The Pier at dawn", "Page 3"])
        let names = try XCTUnwrap(PageImageArchive.metadata(ofArchiveAt: url))
        XCTAssertEqual(names.title, "The Harbour Office")
        XCTAssertEqual(names.author, "Odile Banerjee")
    }

    /// A page's Type is a list of values apart by white space, "Story" when
    /// it lists none (ComicInfo 2.0 and the 2.1 draft): a picture whose list
    /// holds "Deleted" is no page, and one whose list holds a cover is titled
    /// by the first cover in it.
    func testAPagesTypeIsAListOfValues() throws {
        let page = try PageImageFixtures.plainPage()
        let info = PageImageFixtures.comicInfo("""
            <Pages>
              <Page Image="0" Type="FrontCover Story"/>
              <Page Image="1" Type="Advertisement Deleted"/>
              <Page Image="2" Type="  Story   BackCover "/>
              <Page Image="3"/>
            </Pages>
            """)
        let url = try PageImageFixtures.comicArchive([
            TestZIPEntry("ComicInfo.xml", info),
            TestZIPEntry("001.png", page), TestZIPEntry("002.png", page),
            TestZIPEntry("003.png", page), TestZIPEntry("004.png", page),
        ], for: self)

        let archive = try PageImageArchive(url: url)

        XCTAssertEqual(archive.pages.map(\.entry.path), ["001.png", "003.png", "004.png"])
        XCTAssertEqual(archive.pages.map(\.title), ["Front Cover", "Back Cover", "Page 3"])
        XCTAssertEqual(PageImageComicInfo.Page(type: nil, bookmark: nil).types, ["Story"])
        XCTAssertEqual(PageImageComicInfo.Page(type: "Advertisement Deleted", bookmark: nil).types, ["Advertisement", "Deleted"])
        XCTAssertEqual(PageImageWording.coverTitle(forPageTypes: ["Story", "BackCover", "FrontCover"]), "Back Cover")
        XCTAssertNil(PageImageWording.coverTitle(forPageTypes: ["Story", "Letters"]))
    }

    /// A book with no title of its own is named by its series and number,
    /// and a ComicInfo.xml that cannot be read is passed over, the book read
    /// without it.
    func testABookIsNamedByItsSeriesAndABrokenDescriptionIsPassedOver() throws {
        let page = try PageImageFixtures.plainPage()
        let series = try PageImageFixtures.comicArchive([
            TestZIPEntry("ComicInfo.xml", PageImageFixtures.comicInfo("<Series>Harbour Notices</Series><Number>2</Number>")),
            TestZIPEntry("1.png", page),
        ], for: self)
        let broken = try PageImageFixtures.comicArchive([
            TestZIPEntry("ComicInfo.xml", Data("<ComicInfo><Title>Unclosed".utf8)),
            TestZIPEntry("1.png", page),
        ], for: self)
        let entities = try PageImageFixtures.comicArchive([
            TestZIPEntry("ComicInfo.xml", Data("""
            <?xml version="1.0"?><!DOCTYPE ComicInfo [<!ENTITY big "harbour">]><ComicInfo><Title>&big;</Title></ComicInfo>
            """.utf8)),
            TestZIPEntry("1.png", page),
        ], for: self)

        let cdata = try PageImageFixtures.comicArchive([
            TestZIPEntry("ComicInfo.xml", PageImageFixtures.comicInfo("<Title><![CDATA[Ferries & Tides]]></Title>")),
            TestZIPEntry("1.png", page),
        ], for: self)

        XCTAssertEqual(try PageImageArchive(url: series).comicInfo?.bookTitle, "Harbour Notices 2")
        XCTAssertEqual(try PageImageArchive(url: cdata).comicInfo?.bookTitle, "Ferries & Tides", "a CDATA title is read")
        XCTAssertNil(try PageImageArchive(url: broken).comicInfo)
        XCTAssertNil(try PageImageArchive(url: entities).comicInfo, "entities of its own are never read")
        XCTAssertEqual(try PageImageArchive(url: broken).pageCount, 1)
    }

    /// The ComicInfo.xml nearest the archive's top describes it, in any
    /// capitals, and one too large to be a description is passed over.
    func testTheDescriptionNearestTheTopIsRead() throws {
        let page = try PageImageFixtures.plainPage()
        let url = try PageImageFixtures.comicArchive([
            TestZIPEntry("Book/ComicInfo.xml", PageImageFixtures.comicInfo("<Title>Inner</Title>")),
            TestZIPEntry("comicinfo.XML", PageImageFixtures.comicInfo("<Title>Outer</Title>")),
            TestZIPEntry("Book/1.png", page),
        ], for: self)
        let huge = PageImageFixtures.comicInfo("<Title>Huge</Title><Summary>"
            + String(repeating: "x", count: Int(PageImageArchive.maximumComicInfoBytes)) + "</Summary>")
        let tooLarge = try PageImageFixtures.comicArchive([
            TestZIPEntry("ComicInfo.xml", huge), TestZIPEntry("1.png", page),
        ], for: self)

        XCTAssertEqual(try PageImageArchive(url: url).comicInfo?.title, "Outer")
        XCTAssertNil(try PageImageArchive(url: tooLarge).comicInfo)
    }

    // MARK: - Refusals

    /// A file that is no ZIP archive, an archive without pictures, and one
    /// whose every picture ComicInfo.xml deletes are refused, each in its
    /// words.
    func testArchivesThatHoldNoPagesAreRefused() throws {
        let notZip = try PageImageFixtures.write(Data("Rar!\u{1A}\u{07}\u{00}".utf8), named: "rar.cbz", for: self)
        let empty = try PageImageFixtures.comicArchive([TestZIPEntry("readme.txt", Data("no pictures".utf8))], for: self)
        let deleted = try PageImageFixtures.comicArchive([
            TestZIPEntry("ComicInfo.xml", PageImageFixtures.comicInfo(#"<Pages><Page Image="0" Type="Deleted"/></Pages>"#)),
            TestZIPEntry("1.png", try PageImageFixtures.plainPage()),
        ], for: self)

        for (url, expected) in [(notZip, PageImageError.notAnArchive), (empty, .noPictures), (deleted, .noPictures)] {
            XCTAssertThrowsError(try PageImageArchive(url: url), url.lastPathComponent) { error in
                XCTAssertEqual(error as? PageImageError, expected, url.lastPathComponent)
            }
        }
    }

    /// An archive of more pictures than TextMouth reads in one book is
    /// refused at its first picture past the limit, as its entries are
    /// listed, before any is sorted or read (here with a limit of 3, the
    /// book's being 2,000), whatever follows it; one of exactly the limit is
    /// not, and its description is still the shallowest.
    func testAnArchiveOfTooManyPicturesIsRefused() throws {
        let entries = (1...4).map { TestZIPEntry("\($0).png", Data([0])) }
            + [TestZIPEntry("Extra/ComicInfo.xml", PageImageFixtures.comicInfo("<Title>Deeper</Title>")),
               TestZIPEntry("ComicInfo.xml", PageImageFixtures.comicInfo("<Title>Top</Title>"))]
        let url = try PageImageFixtures.comicArchive(entries, for: self)

        XCTAssertThrowsError(try PageImageArchive(url: url, maximumPages: 3)) { error in
            XCTAssertEqual(error as? PageImageError, .tooManyPictures)
        }
        let atTheLimit = try PageImageArchive(url: url, maximumPages: 4)
        XCTAssertEqual(atTheLimit.pageCount, 4)
        XCTAssertEqual(atTheLimit.comicInfo?.title, "Top")
        XCTAssertEqual(PageImageWording.maximumPages, 2_000)
    }

    // MARK: - Reading the Pages

    /// A page whose file is damaged, or is no picture, is named in the
    /// report while the others are read, and the book keeps its original.
    func testADamagedPageIsNamedWhileTheOthersAreRead() throws {
        let page = try PageImageFixtures.plainPage()
        let url = try PageImageFixtures.comicArchive([
            TestZIPEntry("1.png", page),
            TestZIPEntry("2.png", Data("not a picture at all".utf8)),
            TestZIPEntry("3.png", page),
        ], for: self)
        let script = Script([.lines(PageImageFixtures.paragraph(["First page"])), .lines(PageImageFixtures.paragraph(["Third page"]))])

        let extraction = try PageImageReader.extract(PageImageArchive(url: url), includesPages: true, recognizer: script)

        XCTAssertEqual(script.pictures.count, 2, "the damaged page is never read")
        XCTAssertEqual(
            extraction.report.message,
            "Text recognition could not read 1 of 3 pages: page 2 (its file could not be read as a picture)."
        )
        XCTAssertEqual(extraction.report.container, "this comic book archive")
        XCTAssertEqual(
            extraction.markdown,
            "<!-- chapter: Page 1 -->\n<!-- page: 1 -->\n\nFirst page\n\n<!-- page: 2 -->\n\n"
                + "<!-- chapter: Page 3 -->\n<!-- page: 3 -->\n\nThird page"
        )
    }

    /// A page whose bytes do not match the archive's checksum is damaged,
    /// in the words a damaged member of an EPUB gets.
    func testAPageFailingItsChecksumIsDamaged() throws {
        let page = try PageImageFixtures.plainPage()
        let url = try PageImageFixtures.comicArchive([TestZIPEntry("1.png", page)], for: self)
        // The stored file's bytes, changed in place: its checksum no longer matches.
        let bytes = try Data(contentsOf: url)
        let start = try XCTUnwrap(bytes.range(of: page.prefix(16))).lowerBound + 20
        var changed = bytes
        changed[start] ^= 0xFF
        try changed.write(to: url)
        let archive = try PageImageArchive(url: url)

        XCTAssertThrowsError(try archive.decodedPage(at: 0)) { error in
            XCTAssertEqual(error as? PageImageError, .damagedPage(file: "1.png", reason: PageImageWording.failsChecksum))
        }
    }

    /// The sample reads as two pages in order, named by its ComicInfo.xml,
    /// its first page the front cover.
    func testTheSampleArchive() throws {
        let archive = try PageImageArchive(url: copyOfFormatSample("cbz/harbour-notices.cbz"))

        XCTAssertEqual(archive.pages.map(\.entry.path), ["page-001.png", "page-002.png"])
        XCTAssertEqual(archive.pages.map(\.title), ["Front Cover", "Page 2"])
        XCTAssertEqual(archive.comicInfo?.bookTitle, "The Harbour Office")
        XCTAssertEqual(archive.comicInfo?.writer, "Odile Banerjee")
        XCTAssertEqual(try archive.decodedPage(at: 1).image.width, 1_224)
    }
}
