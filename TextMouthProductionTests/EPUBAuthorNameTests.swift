import XCTest
@testable import TextMouth

/// Which name a package document gives a book's author
/// (`EPUBParser.authorName(in:)`): read for the direct reader and the text
/// cache by `parseOPF`, and for imports and Book Info by `readMetadata`,
/// which every test here asks together.
final class EPUBAuthorNameTests: XCTestCase {

    func testACreatorNamesTheAuthor() throws {
        XCTAssertEqual(try author(metadata: "<dc:creator>Wilhelmina Achterberg</dc:creator>"), "Wilhelmina Achterberg")
    }

    /// The name is read without the line breaks and indentation a
    /// pretty-printed package puts around it.
    func testTheNameIsReadWithoutTheSpaceAroundIt() throws {
        let metadata = "<dc:creator>\n          Wilhelmina Achterberg\n        </dc:creator>"
        XCTAssertEqual(try author(metadata: metadata), "Wilhelmina Achterberg")
    }

    /// An EPUB 2 package listing its illustrator before its author names the
    /// author: the creator with the role `aut`.
    func testTheCreatorWithTheAuthorRoleIsPreferredToAnEarlierOne() throws {
        let metadata = """
        <dc:creator opf:role="ill">Pieter Vandenbroucke</dc:creator>
        <dc:creator opf:role="aut">Wilhelmina Achterberg</dc:creator>
        """
        XCTAssertEqual(try author(metadata: metadata), "Wilhelmina Achterberg")
    }

    /// An EPUB 3 package gives a creator its role in a meta element refining it.
    func testARoleRefiningACreatorCountsAsItsRole() throws {
        let metadata = """
        <dc:creator id="ill">Pieter Vandenbroucke</dc:creator>
        <meta refines="#ill" property="role" scheme="marc:relators">ill</meta>
        <dc:creator id="aut">Wilhelmina Achterberg</dc:creator>
        <meta refines="#aut" property="role" scheme="marc:relators">aut</meta>
        """
        XCTAssertEqual(try author(metadata: metadata), "Wilhelmina Achterberg")
    }

    /// Without any author role, the first creator naming anyone is the
    /// author, as it always was; one holding only spaces names no one.
    func testWithoutAnAuthorRoleTheFirstNamedCreatorIsTheAuthor() throws {
        let metadata = """
        <dc:creator opf:role="edt">   </dc:creator>
        <dc:creator opf:role="edt">Gardner Dozois</dc:creator>
        """
        XCTAssertEqual(try author(metadata: metadata), "Gardner Dozois")
    }

    /// A package with no `dc:creator` names the author in a
    /// `dcterms:creator` meta element, the generic EPUB 3.0 form some
    /// converters write, which listed a fifth of the user's library under
    /// an unknown author.
    func testADCTermsCreatorMetaNamesTheAuthorWhenNoCreatorElementDoes() throws {
        let metadata = """
        <dc:title>Century Rain</dc:title>
        <meta property="dcterms:creator">Alastair Reynolds</meta>
        <meta property="dcterms:modified">2022-03-19T06:29:56Z</meta>
        """
        XCTAssertEqual(try author(metadata: metadata), "Alastair Reynolds")
    }

    /// A creator holding only the placeholder, as calibre writes for a book
    /// with no author, names no one, so the next place is read.
    func testACreatorHoldingThePlaceholderNamesNoOne() throws {
        let metadata = """
        <dc:creator opf:role="aut">Unknown</dc:creator>
        <meta property="dcterms:creator">Alastair Reynolds</meta>
        """
        XCTAssertEqual(try author(metadata: metadata), "Alastair Reynolds")
    }

    /// A contributor with the author role names the author when nothing
    /// else does; one with another role, such as calibre's book producer,
    /// never does.
    func testAContributorWithTheAuthorRoleNamesTheAuthorLast() throws {
        let metadata = """
        <dc:contributor opf:role="bkp">calibre (5.36.0) [http://calibre-ebook.com]</dc:contributor>
        <dc:contributor opf:role="aut">Russell Hoban</dc:contributor>
        """
        XCTAssertEqual(try author(metadata: metadata), "Russell Hoban")
        let producerOnly = "<dc:contributor opf:role=\"bkp\">calibre (5.36.0) [http://calibre-ebook.com]</dc:contributor>"
        XCTAssertNil(try author(metadata: producerOnly))
    }

    /// A package naming no author gives the reader the placeholder and an
    /// import an empty author, which the import lists under the placeholder.
    func testAPackageNamingNoAuthorGivesEachReaderItsFallback() throws {
        let opf = package(metadata: "<dc:title>Quick Start</dc:title>")

        XCTAssertEqual(try EPUBParser.parseOPF(opf).author, Book.unknownAuthor)
        XCTAssertEqual(try EPUBParser.readMetadata(url: try writtenEPUB(opf: opf)).author, "")
        let imported = ImportedFileMetadata.read(from: try writtenEPUB(opf: opf), format: .epub)
        XCTAssertEqual(imported.author, Book.unknownAuthor)
    }

    // MARK: - Fixtures

    /// The author both `parseOPF` and `readMetadata` read from a package
    /// whose metadata element holds `metadata`, or nil when it names no
    /// one; the two must agree.
    private func author(metadata: String) throws -> String? {
        let opf = package(metadata: metadata)
        let direct = try EPUBParser.parseOPF(opf).author
        let read = try EPUBParser.readMetadata(url: try writtenEPUB(opf: opf)).author
        let named: String? = direct == Book.unknownAuthor ? nil : direct
        XCTAssertEqual(read, named ?? "", "readMetadata and parseOPF read different authors")
        return named
    }

    /// A package document whose metadata element holds `metadata` beside
    /// the identifier, with one chapter in its reading order.
    private func package(metadata: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:opf="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">urn:uuid:5d1c0e7a-2b4f-4c8e-9a6d-3f2e1b0c9d8e</dc:identifier>
        \(metadata)
        </metadata>
        <manifest><item id="c1" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c1"/></spine>
        </package>
        """
    }

    /// An EPUB file holding `opf` as its package document and one short
    /// chapter, in a folder removed when the test ends.
    private func writtenEPUB(opf: String) throws -> URL {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let chapter = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head>
        <body><h1>One</h1><p>A page of words.</p></body></html>
        """
        let entries = [
            TestZIPEntry("mimetype", Data("application/epub+zip".utf8)),
            TestZIPEntry("META-INF/container.xml", Data(container.utf8)),
            TestZIPEntry("OEBPS/package.opf", Data(opf.utf8)),
            TestZIPEntry("OEBPS/chapter.xhtml", Data(chapter.utf8)),
        ]
        return try TextPipelineFixtures.writeEPUB(entries, named: "author.epub", for: self)
    }
}
