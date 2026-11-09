import XCTest
@testable import TextMouth

/// What `XMLInputGuard` finds in the raw bytes of an XML part before `XMLParser`
/// reads it: the attributes of a tag counted outside quotes, comments, and CDATA
/// sections; a document type declaration with an internal subset, found by its
/// structure and not by its first `>`; and the encodings the guard cannot see
/// through, by an allow-list of those it can. And what each reader that asks it
/// says in its own sentence (DAISY and SSML here; DOCX and EPUB in their own
/// tests), and that each place that parses untrusted XML asks it: the feed, OPML,
/// SMIL, PEF, and ODT manifest readers here.
final class XMLInputGuardTests: XCTestCase {

    // MARK: - Helpers

    /// `count` attributes with no value, as the text of a tag.
    private func attributes(_ count: Int) -> String {
        (0..<count).map { "a\($0)=\"\"" }.joined(separator: " ")
    }

    /// The problem the guard finds in `xml`, or nil.
    private func problem(_ xml: String) -> XMLInputGuard.Problem? {
        XMLInputGuard.problem(with: Data(xml.utf8))
    }

    /// A UTF-8 part with the declaration `<?xml version="1.0" encoding="NAME"?>`.
    private func declaring(_ name: String) -> String {
        "<?xml version=\"1.0\" encoding=\"\(name)\"?><r/>"
    }

    // MARK: - Counting attributes

    /// The limit is on the count: 1,024 are read, 1,025 refused, in a root
    /// and in a later tag.
    func testTheLimitIsOnTheCountOfAttributes() {
        XCTAssertNil(problem("<r \(attributes(1_024))/>"))
        XCTAssertEqual(problem("<r \(attributes(1_025))/>"), .tooManyAttributes)
        XCTAssertNil(problem("<r><p \(attributes(1_024))>x</p></r>"))
        XCTAssertEqual(problem("<r><p \(attributes(1_025))>x</p></r>"), .tooManyAttributes)
        // A value of any length is one attribute, with `>` and `=` and the other quote in it.
        XCTAssertNil(problem("<r a='" + String(repeating: ">=\"", count: 400_000) + "'/>"))
        XCTAssertNil(problem("<r a=\"" + String(repeating: "=' >", count: 400_000) + "\"/>"))
    }

    /// The count is of one tag: many tags of a few attributes each hold far
    /// more than the limit between them, as every real document does, and are
    /// read.
    func testTheCountStartsAgainInEachTag() {
        let tags = String(repeating: "<p a=\"1\" b=\"2\" c=\"3\"/>", count: 5_000)
        XCTAssertNil(problem("<r>\(tags)</r>"))
        // And the one tag over the limit among them is found.
        XCTAssertEqual(problem("<r>\(tags)<p \(attributes(1_025))/>\(tags)</r>"), .tooManyAttributes)
    }

    /// Quotes are honoured: a value holding thousands of `=` is one attribute
    /// (the quotes of both kinds), and a `>` in a value does not end the tag
    /// early, which would count the attributes after it in no tag at all.
    func testQuotesAreHonouredInCounting() {
        let equals = String(repeating: "a=b ", count: 3_000)
        XCTAssertNil(problem("<r v=\"\(equals)\"/>"))
        XCTAssertNil(problem("<r v='\(equals)'/>"))
        // A `>` inside a value, then many attributes: still one tag, still refused.
        XCTAssertEqual(problem("<r v=\">\" \(attributes(1_100))/>"), .tooManyAttributes)
    }

    /// What is not a start tag is not counted: a comment, a CDATA section, a
    /// processing instruction, an end tag, and text, however many `=` and tags
    /// they hold.
    func testCommentsCDATAAndOtherMarkupAreNotCounted() {
        let tags = String(repeating: "<x \(attributes(2_000))>", count: 3)
        XCTAssertNil(problem("<r><!-- \(tags) --></r>"))
        XCTAssertNil(problem("<r><![CDATA[\(tags)]]></r>"))
        XCTAssertNil(problem("<?pi \(attributes(2_000))?><r/>"))
        // Tags inside a processing instruction are not tags.
        XCTAssertNil(problem("<?pi <x \(attributes(2_000))> ?><r/>"))
        XCTAssertNil(problem("<r>\(attributes(2_000))</r>"))
        XCTAssertNil(problem("<r></r \(attributes(2_000))>"))
        // But after them, tags are counted again.
        XCTAssertEqual(problem("<r><!-- x --><![CDATA[ y ]]><p \(attributes(1_025))/></r>"), .tooManyAttributes)
    }

    /// An external document type (a DTBook's, an NCX's) is skipped by its
    /// quotes: a `>` or `[` inside an identifier does not end or open it.
    func testAnExternalDocumentTypeIsSkippedByItsQuotes() {
        let doctype = "<!DOCTYPE dtbook PUBLIC \"-//NISO//DTD dtbook 2005-3//EN\" \"http://example.org/a>b[c.dtd\">"
        XCTAssertNil(problem("<?xml version=\"1.0\"?>\(doctype)<dtbook><p>words</p></dtbook>"))
        XCTAssertEqual(problem("\(doctype)<dtbook><p \(attributes(1_025))/></dtbook>"), .tooManyAttributes)
    }

    /// A declaration is skipped by its quotes and brackets, so what is inside
    /// an identifier or a subset is not read as a tag: a `>` in a quoted
    /// identifier, with a tag of many attributes after it in the same quotes,
    /// is part of the declaration, and so is a tag-like text in brackets (which
    /// `hasTag` is given alone, since a part with a subset is refused first).
    func testADeclarationIsSkippedByItsQuotesAndBrackets() {
        XCTAssertNil(problem("<!DOCTYPE d PUBLIC \"a>\" \"b<x \(attributes(1_100))>\"><d/>"))
        let bracketed = Data("<!DOCTYPE d [<!ENTITY e \"x\"> <x \(attributes(1_100))>]><d/>".utf8)
        XCTAssertFalse(XMLInputGuard.hasTag(withMoreAttributesThan: XMLInputGuard.mostAttributesInATag, in: bracketed))
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
            XCTAssertEqual(problem(xml), .ownDefinitions, xml)
        }
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

    /// `text` in each of the encodings a part can have, by the shape the guard
    /// reads (`CodeUnits`): UTF-8 with and without a mark, UTF-16 and UTF-32
    /// both ways round, each with a byte-order mark and without one.
    private func shapes(of text: String) throws -> [(String, Data)] {
        func bytes(_ data: Data?, _ name: String) throws -> Data { try XCTUnwrap(data, name) }
        return [
            ("UTF-8", try bytes(text.data(using: .utf8), "utf8")),
            ("UTF-8 with a mark", Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)),
            ("UTF-16 little-endian, mark", try bytes(text.data(using: .utf16), "utf16")),
            ("UTF-16 little-endian", try bytes(text.data(using: .utf16LittleEndian), "utf16le")),
            ("UTF-16 big-endian", try bytes(text.data(using: .utf16BigEndian), "utf16be")),
            ("UTF-16 big-endian, mark", Data([0xFE, 0xFF]) + (try bytes(text.data(using: .utf16BigEndian), "utf16be"))),
            ("UTF-32 little-endian", try bytes(text.data(using: .utf32LittleEndian), "utf32le")),
            ("UTF-32 little-endian, mark", Data([0xFF, 0xFE, 0x00, 0x00]) + (try bytes(text.data(using: .utf32LittleEndian), "utf32le"))),
            ("UTF-32 big-endian", try bytes(text.data(using: .utf32BigEndian), "utf32be")),
            ("UTF-32 big-endian, mark", Data([0x00, 0x00, 0xFE, 0xFF]) + (try bytes(text.data(using: .utf32BigEndian), "utf32be"))),
        ]
    }

    /// The subset is found in every encoding a part can have, as the document
    /// type is, and a declaration of UTF-7 in each.
    func testAnInternalSubsetIsFoundInEveryEncoding() throws {
        for (name, data) in try shapes(of: "<?xml version=\"1.0\"?><!DOCTYPE d [<!ENTITY e \"x\">]><d>&e;</d>") {
            XCTAssertEqual(XMLInputGuard.problem(with: data), .ownDefinitions, name)
        }
        for (name, data) in try shapes(of: declaring("UTF-7")) {
            XCTAssertEqual(XMLInputGuard.problem(with: data), .encoding("UTF-7"), name)
        }
        // And many attributes, in each.
        for (name, data) in try shapes(of: "<r \(attributes(1_025))/>") {
            XCTAssertEqual(XMLInputGuard.problem(with: data), .tooManyAttributes, name)
        }
    }

    // MARK: - Encodings

    /// The allow-list takes the encodings whose bytes the guard sees through,
    /// whatever the case or the alias the parser knows them by: UTF-8, UTF-16
    /// and UTF-32 (in a part of that shape), US-ASCII, ISO-8859-1 to 16, the
    /// Windows code pages 1250 to 1258, KOI8, the Macintosh set, Shift_JIS,
    /// EUC-JP, EUC-KR, GB2312, GBK, GB18030, and Big5.
    func testTheEncodingsTheGuardSeesThroughAreAllowed() {
        var names = [
            "UTF-8", "utf-8", "Utf-8", "UTF8", "US-ASCII", "ascii", "ANSI_X3.4-1968",
            "latin1", "ISO-8859-1", "iso-8859-15", "ISO-8859-16", "ISO8859-2", "ISO_8859-9", "KOI8-R", "koi8-u",
            "macintosh", "Shift_JIS", "shift_jis", "SJIS", "EUC-JP", "EUC-KR", "GB2312", "GBK", "GB18030", "Big5", "big5-hkscs",
        ]
        names += (1250...1258).map { "windows-\($0)" } + (1250...1258).map { "CP\($0)" }
        for name in names {
            XCTAssertNil(problem(declaring(name)), name)
        }
        XCTAssertNil(problem("<?xml version=\"1.0\"?><r/>"))
        XCTAssertNil(problem("<r/>"))
    }

    /// Anything else is refused by the name it declares: the stateful
    /// encodings and every alias of them the parser knows (found by trying
    /// about 140 names), the EBCDIC code pages, and names that mean nothing.
    func testAnyOtherEncodingIsRefusedByItsDeclaredName() {
        let names = [
            "UTF-7", "utf-7", "UTF7", "UNICODE-1-1-UTF-7", "ISO-2022-JP", "iso-2022-kr", "ISO-2022-CN-EXT",
            "CSISO2022JP", "CSISO2022JP2", "CSISO2022KR", "CSISO2022CN", "HZ", "HZ-GB-2312",
            "IBM037", "IBM500", "CP1047", "EBCDIC-CP-US", "UTF-9", "x-unknown", "windows-1259", "windows-125", "CP12522",
            "ISO-8859-", "ISO-8859-100", "ISO-8859-x", "", "UTF-7 ",
        ]
        for name in names {
            XCTAssertEqual(problem(declaring(name)), .encoding(name), "\"\(name)\"")
        }
        // Declared single-quoted, after other pseudo-attributes, and with each kind of white space around `=`.
        XCTAssertEqual(problem("<?xml version='1.0' encoding='UTF-7'?><r/>"), .encoding("UTF-7"))
        XCTAssertEqual(problem("<?xml version=\"1.0\" encoding=\"UNICODE-1-1-UTF-7\" standalone=\"yes\"?><r/>"), .encoding("UNICODE-1-1-UTF-7"))
        for gap in [" ", "\t", "\n", "\r", "\r\n", " \n\t "] {
            XCTAssertEqual(
                problem("<?xml version=\"1.0\" encoding\(gap)=\(gap)\"UTF-7\"?><r/>"), .encoding("UTF-7"), gap.debugDescription)
            XCTAssertEqual(
                problem("<?xml version=\"1.0\" encoding\(gap)=\(gap)'CSISO2022JP'?><r/>"), .encoding("CSISO2022JP"), gap.debugDescription)
        }
        // EBCDIC is found by its bytes, with a declaration or none.
        XCTAssertEqual(XMLInputGuard.problem(with: Data([0x4C, 0x6F, 0xA7, 0x94, 0x40, 0xA5, 0x85, 0x99])), .encoding("EBCDIC"))
        // The name is shown as written, and a long one cut.
        XCTAssertEqual(problem(declaring("uTf-7")), .encoding("uTf-7"))
        XCTAssertEqual(problem(declaring(String(repeating: "x", count: 100))), .encoding(String(repeating: "x", count: 40)))
    }

    /// A UTF-16 or UTF-32 declaration is for a part of that shape: in a UTF-8
    /// part it is refused, and in another shape (a UTF-8 declaration in a
    /// UTF-16 part is fine, the guard reads the shape).
    func testUTF16AndUTF32AreAllowedOnlyInAPartOfThatShape() throws {
        XCTAssertEqual(problem(declaring("UTF-16")), .encoding("UTF-16"))
        XCTAssertEqual(problem(declaring("UTF-32")), .encoding("UTF-32"))
        XCTAssertEqual(problem(declaring("UCS-4")), .encoding("UCS-4"))
        for (name, data) in try shapes(of: declaring("UTF-16")) {
            let wide = name.contains("UTF-16")
            XCTAssertEqual(XMLInputGuard.problem(with: data), wide ? nil : .encoding("UTF-16"), name)
        }
        for (name, data) in try shapes(of: declaring("UTF-32")) {
            let wide = name.contains("UTF-32")
            XCTAssertEqual(XMLInputGuard.problem(with: data), wide ? nil : .encoding("UTF-32"), name)
        }
        for (name, data) in try shapes(of: declaring("UTF-8")) {
            XCTAssertNil(XMLInputGuard.problem(with: data), name)
        }
        // Text decoded already (an EPUB's package document) has no shape to ask of.
        XCTAssertNil(XMLInputGuard.problem(with: Data(declaring("UTF-16").utf8), isDecodedText: true))
        XCTAssertEqual(XMLInputGuard.problem(with: Data(declaring("UTF-7").utf8), isDecodedText: true), .encoding("UTF-7"))
    }

    /// The word in the text of a part with no declaration, or a declaration
    /// that is not first, is no declaration.
    func testAnEncodingWordOutsideTheDeclarationIsNoDeclaration() {
        XCTAssertNil(problem("<r>encoding=\"UTF-7\"</r>"))
        XCTAssertNil(problem("<r><?xml version=\"1.0\" encoding=\"UTF-7\"?></r>"))
        XCTAssertNil(problem("<?xml version=\"1.0\"?><r encoding=\"UTF-7\"/>"))
    }

    // MARK: - Feeds and OPML

    /// A feed or OPML document may declare entities of its own (old RSS feeds
    /// do), so only the encoding and the attributes are asked of it.
    func testFeedsAndOPMLAreAskedTheEncodingAndTheAttributesOnly() {
        func feedProblem(_ xml: String) -> XMLInputGuard.Problem? { XMLInputGuard.problemLeavingDefinitions(with: Data(xml.utf8)) }
        XCTAssertNil(feedProblem("<!DOCTYPE rss [<!ENTITY nbsp \"&#160;\">]><rss/>"))
        XCTAssertEqual(feedProblem(declaring("UTF-7")), .encoding("UTF-7"))
        XCTAssertEqual(feedProblem("<rss \(attributes(1_025))/>"), .tooManyAttributes)
        XCTAssertNil(feedProblem("<rss \(attributes(1_024))/>"))
        XCTAssertEqual(XMLInputGuard.reason(for: .encoding("UTF-7")), "it is written in the UTF-7 encoding, which TextMouth cannot read safely")
    }

    /// A feed is a fault, in the sentence the feed reader says of an unreadable
    /// feed ("The feed is damaged at line 1: …"), when a tag holds more than
    /// 1,024 attributes or it is written in an encoding the guard cannot see
    /// through: a hostile one cost 11 s at 3.3 MB and minutes at the 25 MB it reads.
    /// A feed that declares entities of its own, or holds 1,000 attributes or a
    /// 300 KB one, is read.
    func testAHostileFeedIsRefusedAndAnOrdinaryOneIsRead() throws {
        func feed(declaration: String = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", item: String = "<item>") -> Data {
            Data("\(declaration)<rss version=\"2.0\"><channel><title>Harbour News</title>\(item)<title>One</title></item></channel></rss>".utf8)
        }
        XCTAssertNoThrow(try FeedParser.parse(feed(), baseURL: nil))
        XCTAssertNoThrow(try FeedParser.parse(feed(item: "<item \(attributes(1_000))>"), baseURL: nil))
        XCTAssertNoThrow(try FeedParser.parse(feed(item: "<item a=\"\(String(repeating: "x", count: 300_000))\">"), baseURL: nil))
        XCTAssertNoThrow(try FeedParser.parse(
            feed(declaration: "<?xml version=\"1.0\"?><!DOCTYPE rss [<!ENTITY nbsp \"&#160;\">]>"), baseURL: nil))
        XCTAssertThrowsError(try FeedParser.parse(feed(item: "<item \(attributes(1_025))>"), baseURL: nil)) { error in
            XCTAssertEqual(
                error as? FeedParseError,
                .damaged(problem: "it has a tag with too many attributes for TextMouth to read safely", line: 1, column: 1))
        }
        for name in ["UTF-7", "UNICODE-1-1-UTF-7", "CSISO2022JP"] {
            XCTAssertThrowsError(try FeedParser.parse(feed(declaration: "<?xml version=\"1.0\" encoding=\"\(name)\"?>"), baseURL: nil), name) { error in
                XCTAssertEqual(
                    error as? FeedParseError,
                    .damaged(problem: "it is written in the \(name) encoding, which TextMouth cannot read safely", line: 1, column: 1))
            }
        }
    }

    /// The same for an OPML list of subscriptions.
    func testAHostileOPMLIsRefusedAndAnOrdinaryOneIsRead() throws {
        func opml(declaration: String = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", outline: String = "") -> Data {
            Data("\(declaration)<opml version=\"2.0\"><body><outline type=\"rss\" text=\"Harbour News\" xmlUrl=\"https://example.org/feed.xml\" \(outline)/></body></opml>".utf8)
        }
        XCTAssertEqual(try FeedOPML.subscriptions(in: opml()).count, 1)
        XCTAssertEqual(try FeedOPML.subscriptions(in: opml(outline: attributes(1_000))).count, 1)
        XCTAssertThrowsError(try FeedOPML.subscriptions(in: opml(outline: attributes(1_025)))) { error in
            XCTAssertEqual(
                error as? OPMLReadError,
                .damaged(problem: "it has a tag with too many attributes for TextMouth to read safely", line: 1))
        }
        XCTAssertThrowsError(try FeedOPML.subscriptions(in: opml(declaration: "<?xml version=\"1.0\" encoding\n=\n\"UTF-7\"?>"))) { error in
            XCTAssertEqual(
                error as? OPMLReadError,
                .damaged(problem: "it is written in the UTF-7 encoding, which TextMouth cannot read safely", line: 1))
        }
    }

    // MARK: - SMIL, PEF, and the ODT manifest

    /// The text sources of a SMIL file are found in an ordinary one, and in a
    /// file the guard refuses (1,025 attributes, an encoding it cannot read,
    /// entities of its own) too, without the XML parser: they are what
    /// tells a DAISY archive holds text, which keeps the archive from being
    /// deleted after its audio is imported. A hostile file names the
    /// sources it names and nothing more, and a quote, a prefix, or a
    /// look-alike element is read as the XML parser reads it.
    func testTheSMILTextSourcesOfAHostileFileAreStillFound() {
        func smil(_ extra: String = "", head: String = "") -> Data {
            Data("\(head)<smil><body><par><text src=\"chapter.html#p1\" \(extra)/></par></body></smil>".utf8)
        }
        XCTAssertEqual(SMILTextSources.scan(smil()), ["chapter.html#p1"])
        XCTAssertEqual(SMILTextSources.scan(smil(attributes(1_000))), ["chapter.html#p1"])
        XCTAssertEqual(SMILTextSources.scan(smil(attributes(1_025))), ["chapter.html#p1"], "1,025 attributes")
        XCTAssertEqual(
            SMILTextSources.scan(smil(head: declaring("UTF-7").replacingOccurrences(of: "<r/>", with: ""))),
            ["chapter.html#p1"], "UTF-7")
        XCTAssertEqual(
            SMILTextSources.scan(smil(head: "<!DOCTYPE smil [<!ENTITY e \"x\">]>")), ["chapter.html#p1"], "entities")
        // Read as text: single quotes, a prefix, the attribute after many, and
        // no look-alikes (`textual`, `data-src`, a source outside a text element).
        let tricky = Data("""
        <!DOCTYPE smil [<!ENTITY e "x">]><smil:smil><smil:par>
        <smil:text id='a' src='one.html#a'/><textual src="no.html"/><text data-src="no.html"/>
        <audio src="no.mp3"/><text   \n  src = "two.html#b"/><text id="c"/>
        </smil:par></smil:smil>
        """.utf8)
        XCTAssertEqual(SMILTextSources.scan(tricky), ["one.html#a", "two.html#b"])
        // Unclosed start tags are read in one pass.
        let started = Date()
        let unclosed = Data("<!DOCTYPE x [<!ENTITY e \"x\">]>".utf8) + Data(String(repeating: "<text ", count: 200_000).utf8)
        XCTAssertEqual(SMILTextSources.scan(unclosed), [])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "200,000 unclosed tags took too long")
        // An external type, which DAISY's SMIL files name, is read.
        XCTAssertEqual(
            SMILTextSources.scan(smil(head: "<!DOCTYPE smil PUBLIC \"-//W3C//DTD SMIL 1.0//EN\" \"http://www.w3.org/TR/REC-smil/SMIL10.dtd\">")),
            ["chapter.html#p1"])
    }

    /// A PEF file is read in an ordinary form, and is a damaged PEF when a tag
    /// holds 1,025 attributes or it is written in an encoding the guard cannot
    /// see through; its title and author, read from the first 64 KB, are none then.
    func testAHostilePEFIsDamagedAndAnOrdinaryOneIsRead() throws {
        func pef(rowAttributes: String = "", declaration: String = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>") -> String {
            """
            \(declaration)
            <pef version="2008-1" xmlns="http://www.daisy.org/ns/2008/pef">
            <head><meta xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Harbour Notes</dc:title><dc:creator>A. Keeper</dc:creator></meta></head>
            <body><volume><section><page><row \(rowAttributes)>⠁⠃</row></page></section></volume></body>
            </pef>
            """
        }
        XCTAssertEqual(try BrailleFileReader.pages(fromPEF: Data(pef().utf8)).pages, [["⠁⠃"]])
        XCTAssertEqual(try BrailleFileReader.pages(fromPEF: Data(pef(rowAttributes: attributes(1_000)).utf8)).pages, [["⠁⠃"]])
        for hostile in [pef(rowAttributes: attributes(1_025)), pef(declaration: "<?xml version=\"1.0\" encoding=\"UTF-7\"?>")] {
            XCTAssertThrowsError(try BrailleFileReader.pages(fromPEF: Data(hostile.utf8))) { error in
                XCTAssertEqual(error as? BrailleFileError, .damagedPEF)
            }
        }
        // The title and author for the import.
        let folder = try makeSandboxDirectory("PEFGuard")
        func metadata(_ text: String) throws -> (title: String?, author: String?, language: String?) {
            let url = folder.appendingPathComponent("\(UUID().uuidString).pef")
            try Data(text.utf8).write(to: url)
            return BrailleFileReader.pefMetadata(of: url)
        }
        XCTAssertEqual(try metadata(pef()).title, "Harbour Notes")
        XCTAssertEqual(try metadata(pef()).author, "A. Keeper")
        XCTAssertNil(try metadata(pef(rowAttributes: attributes(1_025))).title)
        XCTAssertNil(try metadata(pef(declaration: "<?xml version=\"1.0\" encoding=\"UTF-7\"?>")).title)
    }

    /// An ODT's manifest is read for encryption data: found in an ordinary one,
    /// and a manifest the guard refuses is taken for one with none.
    func testAHostileODTManifestIsTakenForOneWithoutEncryption() throws {
        func manifest(_ extra: String = "", declaration: String = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>") -> Data {
            Data("""
                \(declaration)
                <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" \(extra)>
                <manifest:file-entry manifest:full-path="content.xml"><manifest:encryption-data/></manifest:file-entry>
                </manifest:manifest>
                """.utf8)
        }
        func isEncrypted(_ manifest: Data) throws -> Bool {
            let zip = try makeTemporaryZip(prefix: "ODTManifestGuard", entries: ["META-INF/manifest.xml": manifest])
            addTeardownBlock { try? FileManager.default.removeItem(at: zip) }
            return TextutilSourceCheck.isEncryptedOpenDocument(zip)
        }
        XCTAssertTrue(try isEncrypted(manifest()))
        XCTAssertTrue(try isEncrypted(manifest(attributes(1_000))))
        XCTAssertFalse(try isEncrypted(manifest(attributes(1_025))))
        XCTAssertFalse(try isEncrypted(manifest(declaration: "<?xml version=\"1.0\" encoding=\"UTF-7\"?>")))
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
    /// it is read. One with a subset of its own, or in an encoding the guard
    /// cannot see through, is not damaged, so it is refused in a sentence that
    /// says what is the matter and what to do, not that it is damaged.
    func testADTBookWithAnExternalTypeIsReadAndOneWithASubsetOrAnEncodingIsRefused() throws {
        let body = "<dtbook><book><bodymatter><level1><p>Words here.</p></level1></bodymatter></book></dtbook>"
        let external = "<?xml version=\"1.0\"?><!DOCTYPE dtbook PUBLIC \"-//NISO//DTD dtbook 2005-3//EN\" "
            + "\"http://www.daisy.org/z3986/2005/dtbook-2005-3.dtd\">" + body
        XCTAssertTrue(try DTBookToMarkdownConverter(data: Data(external.utf8), file: "book.xml").convert().markdown.contains("Words here."))
        let own = "<?xml version=\"1.0\"?><!DOCTYPE dtbook [<!ENTITY e \"x\">]>" + body
        XCTAssertThrowsError(try DTBookToMarkdownConverter(data: Data(own.utf8), file: "book.xml").convert()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "TextMouth can't safely read the file \u{201C}book.xml\u{201D} in this DAISY book, because it defines "
                    + "entities of its own. Open the book in the program that made it, save it again, then import it again.")
        }
        let stateful = "<?xml version=\"1.0\" encoding=\"CSISO2022JP\"?>" + body
        XCTAssertThrowsError(try DTBookToMarkdownConverter(data: Data(stateful.utf8), file: "book.xml").convert()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "TextMouth can't safely read the file \u{201C}book.xml\u{201D} in this DAISY book, because it is written "
                    + "in the CSISO2022JP encoding. Save it as UTF-8, then import it again.")
        }
    }

    /// An SSML file is refused in the SSML damaged-file sentence when a tag
    /// has too many attributes, and in a sentence of its own, for a file that
    /// is not damaged, when it defines entities or is in an encoding the guard
    /// cannot see through; a text file, so the next step is the editor's.
    func testSSMLIsRefusedInItsOwnSentences() {
        XCTAssertThrowsError(try SSMLReader.html(from: Data("<speak \(attributes(1_025))>words</speak>".utf8))) { error in
            XCTAssertEqual(error as? SSMLReader.Failure, .damaged(reason: XMLInputGuard.tooManyAttributesProblem))
            XCTAssertEqual(
                error.localizedDescription,
                "This SSML file is damaged or incomplete: it has a tag with too many attributes for TextMouth to read safely.")
        }
        XCTAssertThrowsError(try SSMLReader.html(from: Data("<!DOCTYPE speak [<!ENTITY e \"x\">]><speak>&e;</speak>".utf8))) { error in
            XCTAssertEqual(error as? SSMLReader.Failure, .unsafe(.ownDefinitions))
            XCTAssertEqual(
                error.localizedDescription,
                "TextMouth can't safely read this SSML file, because it defines entities of its own. "
                    + "Open it in a text editor, take the entity definitions out, save it, then import it again.")
        }
        XCTAssertThrowsError(try SSMLReader.html(from: Data("<?xml version=\"1.0\" encoding=\"UTF-7\"?><speak>words</speak>".utf8))) { error in
            XCTAssertEqual(error as? SSMLReader.Failure, .unsafe(.encoding("UTF-7")))
            XCTAssertEqual(
                error.localizedDescription,
                "TextMouth can't safely read this SSML file, because it is written in the UTF-7 encoding. "
                    + "Save it as UTF-8, then import it again.")
        }
        XCTAssertNoThrow(try SSMLReader.html(from: Data("<speak>words</speak>".utf8)))
    }

    /// The sentence for a subset or an encoding is the same words in each
    /// package format but for what holds the file and what is opened again.
    func testTheRefusalSentencesNameTheFileAndSayWhatToDo() {
        XCTAssertEqual(
            XMLInputGuard.refusalSentence(for: .ownDefinitions, file: "word/document.xml", in: "this document", original: "the document"),
            "TextMouth can't safely read the file \u{201C}word/document.xml\u{201D} in this document, because it defines entities "
                + "of its own. Open the document in the program that made it, save it again, then import it again.")
        XCTAssertEqual(
            XMLInputGuard.refusalSentence(for: .encoding("UTF-7"), file: "word/document.xml", in: "this document", original: "the document"),
            "TextMouth can't safely read the file \u{201C}word/document.xml\u{201D} in this document, because it is written in the "
                + "UTF-7 encoding. Save it as UTF-8, then import it again.")
        // Too many attributes is damage, in the format's own damaged-file sentence.
        XCTAssertNil(XMLInputGuard.refusalSentence(for: .tooManyAttributes, file: "x", in: "this document", original: "the document"))
    }

    // MARK: - Cancel

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
}
