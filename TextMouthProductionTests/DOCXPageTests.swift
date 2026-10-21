import XCTest
@testable import TextMouth

/// Where a Word document's pages begin (PG07). A DOCX marks a page in four
/// ways: a `w:br` of type page, a paragraph that says `w:pageBreakBefore`
/// (itself or through its style), a section whose break starts a page, and
/// the `w:lastRenderedPageBreak` Word leaves where its last layout broke a
/// page. The converter writes `<!-- page: LABEL -->` at each, numbered from
/// 1 with each section's restart and format, and never changes the reading
/// text. Each test reads a document as an import does
/// (`DOCXParser.extractMarkdown`, then the content.md parse) or converts a
/// small document built in memory.
final class DOCXPageTests: XCTestCase {

    // MARK: - Styles

    /// A style that sets `w:pageBreakBefore` starts a page, and so does a
    /// style based on it, however long the chain; a style that turns it off
    /// ends the chain with no page, whatever the styles behind it say.
    func testStylesTakePageBreakBeforeFromTheirBasedOnChain() throws {
        let styles = try Self.styles("""
        <w:style w:type="paragraph" w:styleId="Base"><w:name w:val="Base"/>
        <w:pPr><w:pageBreakBefore/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Child"><w:name w:val="Child"/><w:basedOn w:val="Base"/></w:style>
        <w:style w:type="paragraph" w:styleId="Grandchild"><w:name w:val="Grandchild"/><w:basedOn w:val="Child"/></w:style>
        <w:style w:type="paragraph" w:styleId="TurnedOff"><w:name w:val="TurnedOff"/><w:basedOn w:val="Base"/>
        <w:pPr><w:pageBreakBefore w:val="0"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="AfterOff"><w:name w:val="AfterOff"/><w:basedOn w:val="TurnedOff"/></w:style>
        <w:style w:type="paragraph" w:styleId="TurnedOnAgain"><w:name w:val="TurnedOnAgain"/><w:basedOn w:val="TurnedOff"/>
        <w:pPr><w:pageBreakBefore w:val="true"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Plain"><w:name w:val="Plain"/></w:style>
        """)

        XCTAssertEqual(styles.pageBreakBeforeStyles, ["Base", "Child", "Grandchild", "TurnedOnAgain"])
    }

    /// Every spelling of off in an on/off property turns it off ("0",
    /// "false", "off"); a missing value and every other value leave it on.
    func testPageBreakBeforeValuesOffAreZeroFalseAndOff() throws {
        let styles = try Self.styles("""
        <w:style w:type="paragraph" w:styleId="Zero"><w:pPr><w:pageBreakBefore w:val="0"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="False"><w:pPr><w:pageBreakBefore w:val="false"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Off"><w:pPr><w:pageBreakBefore w:val="off"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="One"><w:pPr><w:pageBreakBefore w:val="1"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="On"><w:pPr><w:pageBreakBefore w:val="on"/></w:pPr></w:style>
        <w:style w:type="paragraph" w:styleId="Bare"><w:pPr><w:pageBreakBefore/></w:pPr></w:style>
        """)

        XCTAssertEqual(styles.pageBreakBeforeStyles, ["One", "On", "Bare"])
    }

    /// A loop in the `w:basedOn` chain, a style based on one the part does
    /// not define, and a style whose only `w:pageBreakBefore` stands in a
    /// tracked change (the formatting from before the change) start no page.
    func testLoopsMissingStylesAndTrackedChangesStartNoPage() throws {
        let styles = try Self.styles("""
        <w:style w:type="paragraph" w:styleId="A"><w:basedOn w:val="B"/></w:style>
        <w:style w:type="paragraph" w:styleId="B"><w:basedOn w:val="A"/></w:style>
        <w:style w:type="paragraph" w:styleId="Orphan"><w:basedOn w:val="Nowhere"/></w:style>
        <w:style w:type="paragraph" w:styleId="Changed"><w:pPr><w:pPrChange w:id="1">
        <w:pPr><w:pageBreakBefore/></w:pPr></w:pPrChange></w:pPr></w:style>
        """)

        XCTAssertTrue(styles.pageBreakBeforeStyles.isEmpty)
    }

    /// A document that has no styles part starts no page by style, and a
    /// style without an ID cannot give its page break to unstyled paragraphs.
    func testAStyleWithoutAnIDStartsNoPage() throws {
        let styles = try Self.styles("""
        <w:style w:type="paragraph"><w:pPr><w:pageBreakBefore/></w:pPr></w:style>
        """)

        XCTAssertTrue(styles.pageBreakBeforeStyles.isEmpty)
        XCTAssertTrue(DOCXStyles().pageBreakBeforeStyles.isEmpty)
    }

    // MARK: - Page Numbers

    /// Roman numerals run from 1 to 3999, in lower and upper case; past that,
    /// and at 0, the number is written in decimal.
    func testRomanNumeralsRunFromOneToThreeThousandNineHundredNinetyNine() {
        let lower = DOCXPageNumberFormat.lowerRoman
        XCTAssertEqual((1...5).map(lower.label(forNumber:)), ["i", "ii", "iii", "iv", "v"])
        XCTAssertEqual(lower.label(forNumber: 14), "xiv")
        XCTAssertEqual(lower.label(forNumber: 1994), "mcmxciv")
        XCTAssertEqual(lower.label(forNumber: 3999), "mmmcmxcix")
        XCTAssertEqual(lower.label(forNumber: 4000), "4000")
        XCTAssertEqual(lower.label(forNumber: 0), "0")
        XCTAssertEqual(DOCXPageNumberFormat.upperRoman.label(forNumber: 4), "IV")
        XCTAssertEqual(DOCXPageNumberFormat.upperRoman.label(forNumber: 2024), "MMXXIV")
    }

    /// Letters are counted as Word counts them: a to z, then aa, bb, cc to
    /// zz, then aaa, and so on, up to 32 of one letter; past that, and at 0,
    /// the number is written in decimal.
    func testLettersRepeatAsWordCountsThem() {
        let lower = DOCXPageNumberFormat.lowerLetter
        XCTAssertEqual(lower.label(forNumber: 1), "a")
        XCTAssertEqual(lower.label(forNumber: 26), "z")
        XCTAssertEqual(lower.label(forNumber: 27), "aa")
        XCTAssertEqual(lower.label(forNumber: 28), "bb")
        XCTAssertEqual(lower.label(forNumber: 53), "aaa")
        XCTAssertEqual(DOCXPageNumberFormat.upperLetter.label(forNumber: 2), "B")
        XCTAssertEqual(DOCXPageNumberFormat.upperLetter.label(forNumber: 28), "BB")
        // The last number with a letter run of 32, and the first without one.
        XCTAssertEqual(lower.label(forNumber: 26 * 32), String(repeating: "z", count: 32))
        XCTAssertEqual(lower.label(forNumber: 26 * 32 + 1), String(26 * 32 + 1))
        XCTAssertEqual(lower.label(forNumber: 0), "0")
    }

    /// Every format Word offers beyond the five is written as decimal.
    func testOtherFormatsAreDecimal() {
        for name in [nil, "decimal", "chineseCounting", "ordinal", "decimalZero", "bullet", ""] {
            XCTAssertEqual(DOCXPageNumberFormat(name), .decimal, "format \(name ?? "none")")
        }
        XCTAssertEqual(DOCXPageNumberFormat("lowerRoman"), .lowerRoman)
        XCTAssertEqual(DOCXPageNumberFormat("upperRoman"), .upperRoman)
        XCTAssertEqual(DOCXPageNumberFormat("lowerLetter"), .lowerLetter)
        XCTAssertEqual(DOCXPageNumberFormat("upperLetter"), .upperLetter)
        XCTAssertEqual(DOCXPageNumberFormat.decimal.label(forNumber: 12), "12")
    }

    /// A restart number is a whole number from 0 to 999,999 written in ASCII
    /// digits; anything else is ignored.
    func testRestartNumbersAreWholeNumbersFromZeroTo999999() {
        XCTAssertEqual(DOCXSection.restartNumber("0"), 0)
        XCTAssertEqual(DOCXSection.restartNumber("7"), 7)
        XCTAssertEqual(DOCXSection.restartNumber("999999"), 999_999)
        XCTAssertEqual(DOCXSection.restartNumber("0000012"), 12)
        for ignored in [nil, "", "-3", "+3", "abc", "1.5", "1000000", "99999999999999999999", "\u{0663}"] {
            XCTAssertNil(DOCXSection.restartNumber(ignored), "start \(ignored ?? "none")")
        }
    }

    /// A section's break starts a page unless it is continuous or starts a
    /// column; no `w:type` means `nextPage`.
    func testSectionTypesStartAPageExceptContinuousAndNextColumn() {
        XCTAssertTrue(DOCXSection.typeStartsPage(nil))
        for type in ["nextPage", "oddPage", "evenPage", "unknown"] {
            XCTAssertTrue(DOCXSection.typeStartsPage(type), type)
        }
        XCTAssertFalse(DOCXSection.typeStartsPage("continuous"))
        XCTAssertFalse(DOCXSection.typeStartsPage("nextColumn"))
    }

    // MARK: - Helpers

    /// The WordprocessingML namespace each part declares.
    static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    /// A styles part holding the style definitions `definitions`.
    static func stylesPart(_ definitions: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="\(wordNamespace)">
        \(definitions)
        </w:styles>
        """
    }

    /// The styles `definitions` declares, read by the production parser.
    static func styles(_ definitions: String) throws -> DOCXStyles {
        try DOCXStylesParser(data: Data(stylesPart(definitions).utf8), file: DOCXParser.Part.styles).parse()
    }
}
