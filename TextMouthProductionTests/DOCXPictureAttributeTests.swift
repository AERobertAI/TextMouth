import XCTest
@testable import TextMouth

/// The pictures Word keeps in `o:gfxdata` attributes, which no reader uses and
/// `XMLParser` cannot take past 10 MB: a DOCX holding a photo of more than
/// about 7.5 MB in a group lost every word after it, with only a log line
/// (found by the review of `readers/followups-1106`, and so on main too).
/// `DOCXPictureAttribute` cuts the value out of the bytes before the part is
/// parsed; these tests pin what it cuts, what it leaves, and what it costs.
final class DOCXPictureAttributeTests: XCTestCase {

    // MARK: - Helpers

    /// `data` made of `text`.
    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    /// What `DOCXPictureAttribute` makes of `text`, as text.
    private func removed(_ text: String) -> String {
        String(decoding: DOCXPictureAttribute.removingValues(from: bytes(text)), as: UTF8.self)
    }

    /// A picture of `count` repetitions of 16 base64 characters.
    private func picture(_ count: Int) -> String { String(repeating: "UEsDBBQAAAAIAA==", count: count) }

    // MARK: - What is cut

    /// The value of an `o:gfxdata` attribute in a start tag is emptied, with
    /// either quote, white space around the equals sign, and the other
    /// attributes of the tag, and the markup around it, left as they are. A
    /// value that holds `<`, `>`, and the other quote goes whole.
    func testTheValueOfAPictureAttributeIsEmptied() {
        XCTAssertEqual(removed("<v:group o:gfxdata=\"abc\"/>"), "<v:group o:gfxdata=\"\"/>")
        XCTAssertEqual(removed("<v:group o:gfxdata='abc'/>"), "<v:group o:gfxdata=''/>")
        XCTAssertEqual(removed("<v:group a=\"1\" o:gfxdata = \"abc\" b='2'>t</v:group>"), "<v:group a=\"1\" o:gfxdata = \"\" b='2'>t</v:group>")
        XCTAssertEqual(removed("<v:group o:gfxdata=\"a<b>'c\">t</v:group>"), "<v:group o:gfxdata=\"\">t</v:group>")
        XCTAssertEqual(removed("<a o:gfxdata=\"1\"/><b o:gfxdata='2'/><c o:gfxdata=\"3\"/>"), "<a o:gfxdata=\"\"/><b o:gfxdata=''/><c o:gfxdata=\"\"/>")
        XCTAssertEqual(removed("<a\no:gfxdata=\"1\"\n/>"), "<a\no:gfxdata=\"\"\n/>")
    }

    /// Nothing else is cut: the name in text, a comment, a CDATA section, a
    /// processing instruction, or an end tag; another attribute whose name
    /// ends in it or has another prefix; the tag's own name; an empty value.
    func testNothingButARealPictureAttributeIsCut() {
        let untouched = [
            "<w:t>o:gfxdata=\"abc\"</w:t>",
            "<r><!-- <v o:gfxdata=\"abc\"/> --></r>",
            "<r><![CDATA[<v o:gfxdata=\"abc\"/>]]></r>",
            "<?pi o:gfxdata=\"abc\"?><r/>",
            "<?pi <v o:gfxdata=\"abc\"/> ?><r/>",
            "<r a=\"<v o:gfxdata='abc'>\"/>",
            "<v xo:gfxdata=\"abc\"/>",
            "<v x:o:gfxdata=\"abc\"/>",
            "<v o:gfxdata2=\"abc\"/>",
            "<v O:gfxdata=\"abc\"/>",
            "<v gfxdata=\"abc\"/>",
            "<v o:gfxdata=\"\"/>",
            "<v o:gfxdata=abc/>",
            "<o:gfxdata=\"abc\"/>",
        ]
        for xml in untouched {
            XCTAssertEqual(removed(xml), xml, xml)
        }
        // The text after a real one is kept, and a later look-alike in text is too.
        XCTAssertEqual(removed("<v o:gfxdata=\"abc\"/><w:t>o:gfxdata=\"x\"</w:t>"), "<v o:gfxdata=\"\"/><w:t>o:gfxdata=\"x\"</w:t>")
    }

    /// A part with no such attribute comes back as the same bytes, and a UTF-16
    /// part (which Word does not write) is left alone.
    func testAPartWithoutOneIsReturnedAsItIs() throws {
        let plain = bytes("<w:document><w:body><w:p>words</w:p></w:body></w:document>")
        XCTAssertEqual(DOCXPictureAttribute.removingValues(from: plain), plain)
        let wide = try XCTUnwrap("<v o:gfxdata=\"abc\"/>".data(using: .utf16LittleEndian))
        XCTAssertEqual(DOCXPictureAttribute.removingValues(from: wide), wide)
        let marked = try XCTUnwrap("<v o:gfxdata=\"abc\"/>".data(using: .utf16))
        XCTAssertEqual(DOCXPictureAttribute.removingValues(from: marked), marked)
        XCTAssertEqual(DOCXPictureAttribute.removingValues(from: Data()), Data())
    }

    // MARK: - What it costs

    /// A value of 12 MB, past the 10 MB `XMLParser` stops at, is cut in the
    /// time of a pass over the bytes (a bound of five seconds, in a debug
    /// build, far above a pass and far below anything quadratic), and the
    /// result is a few bytes.
    func testAPassOverAPartOf12MBIsLinear() {
        let part = "<w:body><v:group o:gfxdata=\"" + picture(800_000) + "\"/><w:p>after</w:p></w:body>"
        XCTAssertGreaterThan(part.utf8.count, 12_000_000)
        let clock = ContinuousClock()
        let start = clock.now
        let cut = removed(part)
        XCTAssertLessThan(clock.now - start, .seconds(5))
        XCTAssertEqual(cut, "<w:body><v:group o:gfxdata=\"\"/><w:p>after</w:p></w:body>")
        // Many equals signs in a part that holds the name once are no quadratic walk either.
        let busy = String(repeating: "<a b=\"1\" c=\"2\"   =   =   =/>", count: 200_000) + part
        let busyStart = clock.now
        XCTAssertTrue(removed(busy).hasSuffix("<w:p>after</w:p></w:body>"))
        XCTAssertLessThan(clock.now - busyStart, .seconds(10))
    }

    // MARK: - The words after it

    /// The words after a group holding a photo of 12 MB are read: the parser
    /// never sees the picture. Before, it stopped at the attribute, and the
    /// words after it were lost.
    func testTheWordsAfterAPhotoOver10MBAreRead() throws {
        let body = docxParagraph(docxRun("Before the photo."))
            + "<w:p><w:r><w:pict><v:group xmlns:o=\"urn:schemas-microsoft-com:office:office\" o:gfxdata=\"\(picture(800_000))\"/></w:pict></w:r></w:p>"
            + docxParagraph(docxRun("After the photo."))
        let docx = try makeDOCXPackage(document: docxDocumentXML(body))
        let clock = ContinuousClock()
        let start = clock.now
        let markdown = try DOCXParser.extractMarkdown(from: docx, includesPages: false)
        XCTAssertLessThan(clock.now - start, .seconds(20))
        let heard = try MarkdownDocParser.parseChapter(markdown: markdown).text
        XCTAssertEqual(heard.split(whereSeparator: \.isWhitespace).joined(separator: " "), "Before the photo. After the photo.")
    }

    /// Words that quote the attribute are read as they are.
    func testWordsThatQuoteTheAttributeAreKept() throws {
        let body = docxParagraph(docxRun("Word keeps pictures in o:gfxdata=\"abc\" attributes."))
        let docx = try makeDOCXPackage(document: docxDocumentXML(body))
        let markdown = try DOCXParser.extractMarkdown(from: docx, includesPages: false)
        XCTAssertTrue(markdown.contains("o:gfxdata"), markdown)
        XCTAssertTrue(markdown.contains("abc"), markdown)
        XCTAssertTrue(markdown.contains("attributes."), markdown)
    }
}
