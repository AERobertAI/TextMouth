import XCTest
@testable import TextMouth

/// A loose XML file is known by its root element, never by its extension
/// alone (FMT04, FMT13): a DTBook is a DAISY book, a Word 2003 XML document
/// is WordML, and any other XML is something TextMouth does not read.
final class XMLDocumentSnifferTests: XCTestCase {
    /// The DTBook 2005-3 namespace.
    private let dtbookNamespace = "http://www.daisy.org/z3986/2005/dtbook/"

    /// The kind of the document that `text` spells, as UTF-8 bytes.
    private func kind(of text: String) -> XMLRootKind {
        XMLDocumentSniffer.rootKind(of: Data(text.utf8))
    }

    // MARK: - Bytes

    /// A DTBook behind a full prolog (an XML declaration, a comment, a
    /// processing instruction, and a DOCTYPE that names its DTD by an http
    /// URL) is a DTBook, with a namespace and without one, and the DTD is
    /// never fetched (the parse would stall or fail without a network).
    func testADTBookBehindAFullPrologIsADTBook() {
        let prolog = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!-- Made for the harbour -->
            <?xml-stylesheet type="text/css" href="book.css"?>
            <!DOCTYPE dtbook PUBLIC "-//NISO//DTD dtbook 2005-3//EN" "http://www.daisy.org/z3986/2005/dtbook-2005-3.dtd">

            """
        XCTAssertEqual(kind(of: prolog + "<dtbook xmlns=\"\(dtbookNamespace)\" version=\"2005-3\"><head/></dtbook>"), .dtbook)
        XCTAssertEqual(kind(of: prolog + "<dtbook version=\"2005-3\"><head/></dtbook>"), .dtbook)
    }

    /// The root's local name decides, whatever prefix it carries.
    func testAPrefixedDTBookRootIsADTBook() {
        XCTAssertEqual(kind(of: "<d:dtbook xmlns:d=\"\(dtbookNamespace)\"/>"), .dtbook)
    }

    /// A prefix of a real DTBook, cut off inside its head, still names its
    /// root: the parse ends in an error the sniffer ignores.
    func testACutOffDTBookIsStillADTBook() {
        XCTAssertEqual(kind(of: "<?xml version=\"1.0\"?><dtbook xmlns=\"\(dtbookNamespace)\"><head><meta name=\"dc:Ti"), .dtbook)
    }

    /// The start of the WordML sample, read as bytes, is WordML.
    func testTheWordMLSampleIsWordML() throws {
        let sample = try Data(contentsOf: copyOfFormatSample("wordml/headings.wordml"))
        XCTAssertEqual(XMLDocumentSniffer.rootKind(of: sample.prefix(XMLDocumentSniffer.scanLength)), .wordML)
    }

    /// Every other kind of document is `.other`: a `wordDocument` root in
    /// another namespace, an `html` root, a `catalog` root, garbage bytes,
    /// and no bytes at all.
    func testEveryOtherDocumentIsOther() {
        XCTAssertEqual(kind(of: "<w:wordDocument xmlns:w=\"urn:example:not-word\"/>"), .other)
        XCTAssertEqual(kind(of: "<wordDocument/>"), .other)
        XCTAssertEqual(kind(of: "<html><body><p>Hello</p></body></html>"), .other)
        XCTAssertEqual(kind(of: "<?xml version=\"1.0\"?><catalog><item/></catalog>"), .other)
        XCTAssertEqual(XMLDocumentSniffer.rootKind(of: Data([0x00, 0xFF, 0xFE, 0x13, 0x37, 0x80])), .other)
        XCTAssertEqual(kind(of: "Dear reader, this is not markup."), .other)
        XCTAssertEqual(kind(of: "<?xml version=\"1.0\"?><!-- no root here -->"), .other)
        XCTAssertEqual(XMLDocumentSniffer.rootKind(of: Data()), .other)
    }

    /// The scan stops after `scanLength` bytes: a root element that begins
    /// only after that many bytes of comment is `.other`, while the same
    /// document with a short comment is a DTBook. That is the documented
    /// limit.
    func testARootBeyondTheScanLengthIsOther() {
        let padding = String(repeating: "x", count: XMLDocumentSniffer.scanLength)
        XCTAssertEqual(XMLDocumentSniffer.scanLength, 65_536)

        let tooLate = "<?xml version=\"1.0\"?><!-- \(padding) --><dtbook/>"
        XCTAssertEqual(XMLDocumentSniffer.rootKind(of: Data(tooLate.utf8)), .other)

        let inTime = "<?xml version=\"1.0\"?><!-- short --><dtbook/>"
        XCTAssertEqual(XMLDocumentSniffer.rootKind(of: Data(inTime.utf8)), .dtbook)
    }

    // MARK: - Files

    /// A file is read only as far as the scan length: a DTBook whose root
    /// comes after the scan, in a file far larger than it, is `.other`.
    func testAFileIsReadOnlyAsFarAsTheScanLength() throws {
        let folder = try makeSandboxDirectory("XMLSniffer")
        let late = folder.appendingPathComponent("late.xml")
        let padding = String(repeating: "x", count: XMLDocumentSniffer.scanLength * 2)
        try Data("<?xml version=\"1.0\"?><!-- \(padding) --><dtbook/>".utf8).write(to: late)

        XCTAssertEqual(XMLDocumentSniffer.rootKind(ofFileAt: late), .other)
    }

    /// The kind is told from the root element alone, so a DTBook in UTF-16
    /// (with its byte order mark), in ISO 8859-1, or with Cyrillic head
    /// text, and one behind a long comment, is a DTBook: the DAISY reader
    /// finds a DTBook by this answer and by no search of its own.
    func testADTBookInAnyEncodingOrBehindALongCommentIsADTBook() throws {
        let body = "<dtbook xmlns=\"\(dtbookNamespace)\"><head><meta name=\"dc:Title\" content=\"Записки \u{E9}\"/></head></dtbook>"
        let comment = "<!-- " + String(repeating: "Licensed for reading. ", count: 40) + "-->\n"
        let utf16 = try XCTUnwrap(("<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n" + body).data(using: .utf16))
        let latin1 = try XCTUnwrap(
            ("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n<dtbook><head><meta name=\"a\" content=\"\u{E9}\"/></head></dtbook>")
                .data(using: .isoLatin1)
        )

        XCTAssertEqual(XMLDocumentSniffer.rootKind(of: utf16), .dtbook)
        XCTAssertEqual(XMLDocumentSniffer.rootKind(of: latin1), .dtbook)
        XCTAssertEqual(kind(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + body), .dtbook)
        XCTAssertEqual(kind(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + comment + body), .dtbook)
    }

    // MARK: - Blank Files

    /// A file with no bytes, and one of only white space (a byte order
    /// mark may lead it), holds no text; a file with any other character,
    /// a missing file, and a folder do not.
    func testOnlyAnEmptyOrWhiteSpaceFileHoldsNoText() throws {
        let folder = try makeSandboxDirectory("XMLSniffer")
        func file(_ name: String, _ bytes: Data) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try bytes.write(to: url)
            return url
        }

        XCTAssertTrue(XMLDocumentSniffer.holdsNoText(fileAt: try file("empty.xml", Data())))
        XCTAssertTrue(XMLDocumentSniffer.holdsNoText(fileAt: try file("spaces.xml", Data(" \n\t\r\n ".utf8))))
        XCTAssertTrue(XMLDocumentSniffer.holdsNoText(fileAt: try file("bom.xml", Data([0xEF, 0xBB, 0xBF, 0x0A]))))
        XCTAssertFalse(XMLDocumentSniffer.holdsNoText(fileAt: try file("text.xml", Data(" \n x ".utf8))))
        XCTAssertFalse(XMLDocumentSniffer.holdsNoText(fileAt: try file("root.xml", Data("<a/>".utf8))))
        XCTAssertFalse(XMLDocumentSniffer.holdsNoText(fileAt: folder.appendingPathComponent("absent.xml")))
        XCTAssertFalse(XMLDocumentSniffer.holdsNoText(fileAt: folder))
    }

    /// White space that runs past the scan length is not known to be all
    /// white space (only the start is read), so the file is not called blank.
    func testWhiteSpaceBeyondTheScanLengthIsNotCalledBlank() throws {
        let folder = try makeSandboxDirectory("XMLSniffer")
        let long = folder.appendingPathComponent("long.xml")
        try Data(repeating: 0x20, count: XMLDocumentSniffer.scanLength + 1).write(to: long)

        XCTAssertFalse(XMLDocumentSniffer.holdsNoText(fileAt: long))
    }

    /// A missing file and a folder are `.other`, without a crash.
    func testAMissingFileAndAFolderAreOther() throws {
        let folder = try makeSandboxDirectory("XMLSniffer")

        XCTAssertEqual(XMLDocumentSniffer.rootKind(ofFileAt: folder.appendingPathComponent("absent.xml")), .other)
        XCTAssertEqual(XMLDocumentSniffer.rootKind(ofFileAt: folder), .other)
        XCTAssertNil(XMLDocumentSniffer.bookFormat(ofFileAt: folder))
    }

    /// The format of a loose XML file is DAISY for a DTBook and Word 2003
    /// XML for WordML; the book-format detection agrees, whatever case the
    /// extension is in. (Every other XML file has none: see the refusal in
    /// `DTBookImportTests`.)
    func testABookFormatIsDAISYForADTBookAndWordMLForWordML() throws {
        let dtbook = try copyOfFormatSample("dtbook/harbour-standalone.xml")
        let shouting = try copyOfFormatSample("dtbook/harbour-standalone.xml", named: "BOOK.XML")
        let wordML = try copyOfFormatSample("wordml/headings.wordml", named: "notes.xml")

        XCTAssertEqual(XMLDocumentSniffer.rootKind(ofFileAt: dtbook), .dtbook)
        XCTAssertEqual(XMLDocumentSniffer.rootKind(ofFileAt: wordML), .wordML)
        XCTAssertEqual(XMLDocumentSniffer.bookFormat(ofFileAt: dtbook), .daisy)
        XCTAssertEqual(XMLDocumentSniffer.bookFormat(ofFileAt: wordML), .wordml)

        XCTAssertEqual(BookFormat.detect(from: dtbook), .daisy)
        XCTAssertEqual(BookFormat.detect(from: shouting), .daisy)
        XCTAssertEqual(BookFormat.detect(from: wordML), .wordml)
    }
}
