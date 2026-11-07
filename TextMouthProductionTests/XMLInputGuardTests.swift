import XCTest
@testable import TextMouth

/// What `XMLInputGuard` finds in the raw bytes of an XML part before `XMLParser`
/// reads it: the attributes of a tag counted outside quotes, comments, and CDATA
/// sections; a document type declaration with an internal subset, found by its
/// structure and not by its first `>`; and the encodings the guard cannot see
/// through. And what each reader that asks it says, in the sentence of its own
/// damaged-file error (DAISY and SSML here; DOCX, EPUB, ODT, and Word 2003 XML
/// in their own tests).
final class XMLInputGuardTests: XCTestCase {

    // MARK: - Helpers

    /// `count` attributes with no value, as the text of a tag.
    private func attributes(_ count: Int) -> String {
        (0..<count).map { "a\($0)=\"\"" }.joined(separator: " ")
    }

    /// The reason the guard refuses `xml` for, or nil.
    private func problem(_ xml: String) -> String? {
        XMLInputGuard.problem(with: Data(xml.utf8))
    }

    // MARK: - Counting attributes

    /// The limit is on the count: 1,024 are read, 1,025 refused, in a root
    /// and in a later tag.
    func testTheLimitIsOnTheCountOfAttributes() {
        XCTAssertNil(problem("<r \(attributes(1_024))/>"))
        XCTAssertEqual(problem("<r \(attributes(1_025))/>"), XMLInputGuard.tooManyAttributesProblem)
        XCTAssertNil(problem("<r><p \(attributes(1_024))>x</p></r>"))
        XCTAssertEqual(problem("<r><p \(attributes(1_025))>x</p></r>"), XMLInputGuard.tooManyAttributesProblem)
        // A value of any length is one attribute, with `>` and `=` and the other quote in it.
        XCTAssertNil(problem("<r a='" + String(repeating: ">=\"", count: 400_000) + "'/>"))
        XCTAssertNil(problem("<r a=\"" + String(repeating: "=' >", count: 400_000) + "\"/>"))
    }

    /// Quotes are honoured: a value holding thousands of `=` is one attribute
    /// (the quotes of both kinds), and a `>` in a value does not end the tag
    /// early, which would count the attributes after it in no tag at all.
    func testQuotesAreHonouredInCounting() {
        let equals = String(repeating: "a=b ", count: 3_000)
        XCTAssertNil(problem("<r v=\"\(equals)\"/>"))
        XCTAssertNil(problem("<r v='\(equals)'/>"))
        // A `>` inside a value, then many attributes: still one tag, still refused.
        XCTAssertEqual(problem("<r v=\">\" \(attributes(1_100))/>"), XMLInputGuard.tooManyAttributesProblem)
    }

    /// What is not a start tag is not counted: a comment, a CDATA section, a
    /// processing instruction, an end tag, and text, however many `=` and tags
    /// they hold.
    func testCommentsCDATAAndOtherMarkupAreNotCounted() {
        let tags = String(repeating: "<x \(attributes(2_000))>", count: 3)
        XCTAssertNil(problem("<r><!-- \(tags) --></r>"))
        XCTAssertNil(problem("<r><![CDATA[\(tags)]]></r>"))
        XCTAssertNil(problem("<?pi \(attributes(2_000))?><r/>"))
        XCTAssertNil(problem("<r>\(attributes(2_000))</r>"))
        XCTAssertNil(problem("<r></r \(attributes(2_000))>"))
        // But after them, tags are counted again.
        XCTAssertEqual(problem("<r><!-- x --><![CDATA[ y ]]><p \(attributes(1_025))/></r>"), XMLInputGuard.tooManyAttributesProblem)
    }

    /// An external document type (a DTBook's, an NCX's) is skipped by its
    /// quotes: a `>` or `[` inside an identifier does not end or open it.
    func testAnExternalDocumentTypeIsSkippedByItsQuotes() {
        let doctype = "<!DOCTYPE dtbook PUBLIC \"-//NISO//DTD dtbook 2005-3//EN\" \"http://example.org/a>b[c.dtd\">"
        XCTAssertNil(problem("<?xml version=\"1.0\"?>\(doctype)<dtbook><p>words</p></dtbook>"))
        XCTAssertEqual(problem("\(doctype)<dtbook><p \(attributes(1_025))/></dtbook>"), XMLInputGuard.tooManyAttributesProblem)
    }

    // MARK: - Internal subsets

    /// A subset is found by the structure of the declaration, quotes included:
    /// not by its first `>`, which an entity's value can hold.
    func testAnInternalSubsetIsFoundByTheStructureOfTheDeclaration() {
        let subsets = [
            "<!DOCTYPE d [<!ENTITY e \"x\">]><d/>",
            // The first `>` and a comment opening are inside the entity's value.
            "<!DOCTYPE d [<!ENTITY e \"x>y<!--\">]><d/>",
            "<!DOCTYPE d SYSTEM 'a.dtd' [<!ATTLIST d a CDATA \"\">]><d/>",
            "<?xml version=\"1.0\"?><!-- c --><!DOCTYPE d [ ]><d/>",
        ]
        for xml in subsets {
            XCTAssertTrue(XMLInputGuard.declaresInternalSubset(Data(xml.utf8)), xml)
            XCTAssertEqual(problem(xml), XMLInputGuard.ownDefinitionsProblem, xml)
        }
        // The hostile root after the subset is counted too, once the subset is not the reason.
        XCTAssertTrue(XMLInputGuard.declaresDocumentType(Data(subsets[0].utf8)))
    }

    /// An identifier alone holds no subset, whatever it contains, and
    /// `<!DOCTYPE` or `[` in a comment, text, or a value is no declaration.
    func testAnExternalDocumentTypeAndLookAlikesHoldNoSubset() {
        let none = [
            "<!DOCTYPE d><d/>",
            "<!DOCTYPE d SYSTEM \"a.dtd\"><d/>",
            "<!DOCTYPE d PUBLIC \"-//X//[Y]//EN\" \"http://example.org/[x].dtd\"><d/>",
            "<!-- <!DOCTYPE d [ <!ENTITY e \"x\"> ]> --><d/>",
            "<d>text <!DOCTYPE d [ ]></d>",
            "<d a=\"<!DOCTYPE d [ ]>\"/>",
            "<?xml version=\"1.0\"?><d/>",
        ]
        for xml in none {
            XCTAssertFalse(XMLInputGuard.declaresInternalSubset(Data(xml.utf8)), xml)
            XCTAssertNil(problem(xml), xml)
        }
    }

    /// The subset is found in every encoding a part can have, as the document
    /// type is.
    func testAnInternalSubsetIsFoundInEveryEncoding() throws {
        let xml = "<?xml version=\"1.0\"?><!DOCTYPE d [<!ENTITY e \"x\">]><d>&e;</d>"
        let encodings: [(String, Data?)] = [
            ("UTF-8", xml.data(using: .utf8)),
            ("UTF-16 with a mark", xml.data(using: .utf16)),
            ("UTF-16 little-endian", xml.data(using: .utf16LittleEndian)),
            ("UTF-16 big-endian", xml.data(using: .utf16BigEndian)),
            ("UTF-32 little-endian", xml.data(using: .utf32LittleEndian)),
            ("UTF-8 with a mark", Data([0xEF, 0xBB, 0xBF]) + Data(xml.utf8)),
        ]
        for (name, data) in encodings {
            XCTAssertEqual(XMLInputGuard.problem(with: try XCTUnwrap(data, name)), XMLInputGuard.ownDefinitionsProblem, name)
        }
    }

    // MARK: - Encodings

    /// EBCDIC is found by the bytes of `<?xm` (XML 1.0, appendix F), and the
    /// stateful encodings by the name an XML declaration gives them, in any
    /// case, with either quote, and in UTF-16 too. The encodings that keep
    /// ASCII's bytes, or are seen through, are not refused.
    func testTheEncodingsTheGuardCannotSeeThroughAreRefused() throws {
        let ebcdic = Data([0x4C, 0x6F, 0xA7, 0x94, 0x40, 0xA5, 0x85, 0x99])
        XCTAssertEqual(XMLInputGuard.problem(with: ebcdic), XMLInputGuard.unreadableEncodingProblem)
        for name in ["UTF-7", "utf-7", "UTF7", "ISO-2022-JP", "iso-2022-kr", "ISO-2022-CN-EXT", "HZ", "HZ-GB-2312"] {
            for quote in ["\"", "'"] {
                let xml = "<?xml version=\(quote)1.0\(quote) encoding=\(quote)\(name)\(quote)?><r/>"
                XCTAssertEqual(problem(xml), XMLInputGuard.unreadableEncodingProblem, xml)
            }
        }
        // Space around the equals sign, standalone after it, and a byte-order mark before it.
        XCTAssertEqual(problem("<?xml version=\"1.0\" encoding = 'UTF-7' standalone=\"yes\"?><r/>"), XMLInputGuard.unreadableEncodingProblem)
        let marked = Data([0xEF, 0xBB, 0xBF]) + Data("<?xml version=\"1.0\" encoding=\"UTF-7\"?><r/>".utf8)
        XCTAssertEqual(XMLInputGuard.problem(with: marked), XMLInputGuard.unreadableEncodingProblem)
        let wide = try XCTUnwrap("<?xml version=\"1.0\" encoding=\"ISO-2022-JP\"?><r/>".data(using: .utf16))
        XCTAssertEqual(XMLInputGuard.problem(with: wide), XMLInputGuard.unreadableEncodingProblem)
        for name in ["UTF-8", "utf-8", "UTF-16", "UTF-32", "ISO-8859-1", "windows-1252", "Shift_JIS", "EUC-JP", "GB2312", "US-ASCII"] {
            XCTAssertNil(problem("<?xml version=\"1.0\" encoding=\"\(name)\"?><r/>"), name)
        }
        XCTAssertNil(problem("<?xml version=\"1.0\"?><r/>"))
        XCTAssertNil(problem("<r/>"))
        // The word in the text of a part with no declaration is no declaration.
        XCTAssertNil(problem("<r>encoding=\"UTF-7\"</r>"))
        XCTAssertNil(problem("<r><?xml version=\"1.0\" encoding=\"UTF-7\"?></r>"))
    }

    // MARK: - The readers' sentences

    /// A DTBook (DAISY) that holds a tag with too many attributes is refused
    /// in the DAISY damaged-file sentence, naming the file.
    func testADTBookWithATooManyAttributesTagIsRefusedInTheDAISYSentence() {
        let dtbook = "<dtbook><book><bodymatter><p \(attributes(1_025))>words</p></bodymatter></book></dtbook>"
        XCTAssertThrowsError(try DTBookToMarkdownConverter(data: Data(dtbook.utf8), file: "book.xml").convert()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The file \u{201C}book.xml\u{201D} in this DAISY book is damaged or incomplete: "
                    + "it has a tag with too many attributes for TextMouth to read safely. "
                    + "Get a fresh copy of the book, then import it again.")
        }
    }

    /// A DTBook names its type by an external identifier, which is no hazard:
    /// it is read. One with a subset of its own is refused in the same sentence.
    func testADTBookWithAnExternalTypeIsReadAndOneWithASubsetIsRefused() throws {
        let body = "<dtbook><book><bodymatter><level1><p>Words here.</p></level1></bodymatter></book></dtbook>"
        let external = "<?xml version=\"1.0\"?><!DOCTYPE dtbook PUBLIC \"-//NISO//DTD dtbook 2005-3//EN\" "
            + "\"http://www.daisy.org/z3986/2005/dtbook-2005-3.dtd\">" + body
        XCTAssertTrue(try DTBookToMarkdownConverter(data: Data(external.utf8), file: "book.xml").convert().markdown.contains("Words here."))
        let own = "<?xml version=\"1.0\"?><!DOCTYPE dtbook [<!ENTITY e \"x\">]>" + body
        XCTAssertThrowsError(try DTBookToMarkdownConverter(data: Data(own.utf8), file: "book.xml").convert()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The file \u{201C}book.xml\u{201D} in this DAISY book is damaged or incomplete: "
                    + "it defines entities or attributes of its own, which TextMouth cannot read safely. "
                    + "Get a fresh copy of the book, then import it again.")
        }
    }

    /// An SSML file is refused in the SSML damaged-file sentence, which ends
    /// with the reason and a full stop: for a tag with too many attributes,
    /// a subset of its own, and an encoding the guard cannot see through.
    func testSSMLIsRefusedInItsOwnDamagedFileSentence() {
        let cases: [(xml: String, reason: String)] = [
            ("<speak \(attributes(1_025))>words</speak>", XMLInputGuard.tooManyAttributesProblem),
            ("<!DOCTYPE speak [<!ENTITY e \"x\">]><speak>&e;</speak>", XMLInputGuard.ownDefinitionsProblem),
            ("<?xml version=\"1.0\" encoding=\"UTF-7\"?><speak>words</speak>", XMLInputGuard.unreadableEncodingProblem),
        ]
        for testCase in cases {
            XCTAssertThrowsError(try SSMLReader.html(from: Data(testCase.xml.utf8)), testCase.reason) { error in
                XCTAssertEqual(error as? SSMLReader.Failure, .damaged(reason: testCase.reason))
                XCTAssertEqual(error.localizedDescription, "This SSML file is damaged or incomplete: \(testCase.reason).")
            }
        }
        XCTAssertNoThrow(try SSMLReader.html(from: Data("<speak>words</speak>".utf8)))
    }

    /// A DTBook conversion hears Cancel: cancelled before it begins, a
    /// document of thousands of elements ends with `ImportCancelled` (the check
    /// is every 256 parser events), and one that is not cancelled finishes.
    func testADTBookConversionHearsCancel() throws {
        let paragraphs = String(repeating: "<p>Words here.</p>", count: 3_000)
        let dtbook = "<dtbook><book><bodymatter><level1>\(paragraphs)</level1></bodymatter></book></dtbook>"
        let cancellation = ImportCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(
            try ImportCancellation.$current.withValue(cancellation) {
                try DTBookToMarkdownConverter(data: Data(dtbook.utf8), file: "book.xml").convert()
            }
        ) { error in
            XCTAssertEqual(error as? ImportCancelled, ImportCancelled())
        }
        let finished = try ImportCancellation.$current.withValue(ImportCancellation()) {
            try DTBookToMarkdownConverter(data: Data(dtbook.utf8), file: "book.xml").convert()
        }
        XCTAssertTrue(finished.markdown.contains("Words here."))
    }

    /// The sentences say what is wrong in words a listener can use, and none
    /// says no real file has it.
    func testTheSentencesAreForAListener() {
        for reason in [XMLInputGuard.tooManyAttributesProblem, XMLInputGuard.ownDefinitionsProblem, XMLInputGuard.unreadableEncodingProblem] {
            XCTAssertTrue(reason.hasPrefix("it "), reason)
            XCTAssertTrue(reason.hasSuffix("for TextMouth to read safely") || reason.hasSuffix("TextMouth cannot read safely"), reason)
            XCTAssertFalse(reason.contains("start tag"), reason)
            XCTAssertFalse(reason.contains("no real file"), reason)
        }
    }
}
