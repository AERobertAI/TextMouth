import XCTest
import SwiftSoup
@testable import TextMouth

// MARK: - Asking an Element for its EPUB Types by Name

/// A document's elements are asked for the types they carry by the names of
/// the attributes that end in ":type" (`PublicationSemantics.typeAttributeNames`),
/// instead of through a list of all their attributes (the November 14, 2026
/// import speed-up, H6). Wherever the markup gives names, every answer must
/// be the one the list gives; wherever it does not, the names are nil.
final class PublicationSemanticsTypeNamesTests: XCTestCase {

    // MARK: - Helpers

    /// Markup with the attributes and elements in `body`, in a page.
    private func page(_ body: String) -> String {
        "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>t</title></head><body>\(body)</body></html>"
    }

    /// Asks every element of `html` the three questions by name and by list,
    /// and returns how many elements answered yes to any, so a test can
    /// check that the documents do hold what they are meant to.
    @discardableResult
    private func assertSameAnswers(_ html: String, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let names = PublicationSemantics.typeAttributeNames(in: html)
        let document = try SwiftSoup.parse(html)
        var positives = 0
        for element in try document.getAllElements().array() {
            let list = (
                PublicationSemantics.isPageBreak(element), PublicationSemantics.isPageList(element),
                PublicationSemantics.isSupplementaryNavigation(element)
            )
            let byName = (
                PublicationSemantics.isPageBreak(element, typeNames: names), PublicationSemantics.isPageList(element, typeNames: names),
                PublicationSemantics.isSupplementaryNavigation(element, typeNames: names)
            )
            // With no names (nil) the list is what answers, so the answers agree trivially.
            XCTAssertTrue(list == byName, "\(element.tagName()) in \(html)", file: file, line: line)
            if list.0 || list.1 || list.2 { positives += 1 }
        }
        return positives
    }

    // MARK: - What the names are

    /// The usual spelling gives its one name; a document with no ":type" gives
    /// an empty list, so that no element is asked at all.
    func testTheCommonCases() {
        XCTAssertEqual(PublicationSemantics.typeAttributeNames(in: page("<p epub:type=\"pagebreak\" id=\"x\">1</p>")), ["epub:type"])
        XCTAssertEqual(PublicationSemantics.typeAttributeNames(in: page("<p>no types here</p>")), [])
        XCTAssertEqual(PublicationSemantics.typeAttributeNames(in: ""), [])
        // Another prefix, capitals, two of them, with the name repeated.
        XCTAssertEqual(
            PublicationSemantics.typeAttributeNames(in: page("<p ops:type=\"a\"></p><p EPUB:TYPE='b'></p><p ops:type=\"c\"></p>")),
            ["ops:type", "epub:type"]
        )
        // The quote of the value before it, no space between the attributes.
        XCTAssertEqual(PublicationSemantics.typeAttributeNames(in: page("<p id=\"a\"epub:type=\"pagebreak\">1</p>")), ["epub:type"])
        // The name at the very start and the very end of the markup.
        XCTAssertEqual(PublicationSemantics.typeAttributeNames(in: "epub:type"), ["epub:type"])
        XCTAssertEqual(PublicationSemantics.typeAttributeNames(in: "<p epub:type"), ["epub:type"])
    }

    /// A name that merely contains ":type", and a namespace declaration that
    /// is not a type, are not names that end in it.
    func testNamesThatDoNotEndInType() {
        XCTAssertEqual(PublicationSemantics.typeAttributeNames(in: page("<p epub:typed=\"x\" epub:types=\"y\"></p>")), [])
        XCTAssertEqual(PublicationSemantics.typeAttributeNames(in: page("<p xmlns:type=\"u\"></p>")), ["xmlns:type"])
    }

    /// Anything the scan cannot be sure of gives nil, so the list decides.
    func testMarkupItCannotBeSureOfGivesNoNames() {
        // Prose or a value with ":type" after a space or another character.
        XCTAssertNil(PublicationSemantics.typeAttributeNames(in: page("<p>the :type of a thing</p>")))
        XCTAssertNil(PublicationSemantics.typeAttributeNames(in: page("<a href=\"http://a.example:type\">a</a>")))
        // A name beyond ASCII, a tag named so, and the prefix SwiftSoup reads as a request.
        XCTAssertNil(PublicationSemantics.typeAttributeNames(in: page("<p \u{E9}pub:type=\"x\"></p>")))
        XCTAssertNil(PublicationSemantics.typeAttributeNames(in: page("<epub:type>x</epub:type>")))
        XCTAssertNil(PublicationSemantics.typeAttributeNames(in: page("<a abs:type=\"x\">x</a>")))
        // A name that ends in a character no name ends in.
        XCTAssertNil(PublicationSemantics.typeAttributeNames(in: page("<p epub:type\"x\"></p>")))
    }

    // MARK: - The answers

    /// Page breaks, page lists and landmarks are found as they are through
    /// the list, in markup written the usual way and in the ways books vary.
    func testTheAnswersAreTheLists() throws {
        let documents = [
            page("<span epub:type=\"pagebreak\" id=\"p1\" title=\"1\"/><p>text</p><span role=\"doc-pagebreak\">2</span>"),
            page("<nav epub:type=\"page-list\"><ol><li><a href=\"#a\">1</a></li></ol></nav><nav epub:type=\"landmarks\"></nav><nav epub:type=\"toc\"></nav>"),
            page("<section epub:type=\"frontmatter pagebreak\"></section><div EPUB:TYPE=\"PageBreak\"></div><div epub:type=\"x landmarks y\"></div>"),
            page("<nav ops:type=\"page-list\"></nav><nav epub:type=\"toc\" ops:type=\"landmarks\"></nav><span data-epub:type=\"pagebreak\"></span>"),
            page("<p>no types</p><nav role=\"doc-pagelist\"></nav><nav role=\"doc-landmarks\"></nav>"),
            page("<span epub:typed=\"pagebreak\"></span><!-- epub:type=\"pagebreak\" --><script>var s = 'epub:type';</script>"),
            page("<p>the :type of it</p><span epub:type=\"pagebreak\"></span>"),
            page("<a href=\"http://x.example:type\">l</a><span epub:type=\"pagebreak\"></span><nav epub:type='page-list'></nav>"),
            page("<div id=\"a\"epub:type=\"landmarks\"></div><div id='b'epub:type='pagebreak'></div>"),
            page(String(repeating: "<p class=\"c\">words</p>", count: 200)),
            "",
        ]
        var positives = 0
        for html in documents { positives += try assertSameAnswers(html) }
        // The documents above do hold page breaks, page lists, and landmarks.
        XCTAssertGreaterThanOrEqual(positives, 14)
    }

    /// An element is asked by name for each name the document has, whichever
    /// attribute carries the type.
    func testEachNameOfTheDocumentIsAsked() throws {
        let html = page("<span ops:type=\"pagebreak\"></span><span epub:type=\"pagebreak\"></span><span foo:type=\"x\"></span>")
        let names = try XCTUnwrap(PublicationSemantics.typeAttributeNames(in: html))
        XCTAssertEqual(Set(names), ["ops:type", "epub:type", "foo:type"])
        let breaks = try SwiftSoup.parse(html).select("span").array().map { PublicationSemantics.isPageBreak($0, typeNames: names) }
        XCTAssertEqual(breaks, [true, true, false])
        // With no names, no element is a page break by its type.
        let none = try SwiftSoup.parse(html).select("span").array().map { PublicationSemantics.isPageBreak($0, typeNames: []) }
        XCTAssertEqual(none, [false, false, false])
    }

    /// The reading flow built from the markup answers as the static rules do.
    func testTheReadingFlowAnswersAsTheStaticRulesDo() throws {
        let html = page("<span epub:type=\"pagebreak\"></span><nav epub:type=\"page-list\"></nav><nav epub:type=\"toc\"></nav><div hidden=\"\"></div>")
        let flow = PublicationSemantics.ReadingFlow(source: html)
        XCTAssertEqual(flow.typeNames, ["epub:type"])
        for element in try SwiftSoup.parse(html).getAllElements().array() {
            XCTAssertEqual(flow.isPageBreak(element), PublicationSemantics.isPageBreak(element), element.tagName())
            XCTAssertEqual(flow.excludes(element), PublicationSemantics.isExcludedFromReadingFlow(element), element.tagName())
        }
        XCTAssertNil(PublicationSemantics.ReadingFlow.unknownSource.typeNames)
    }
}
