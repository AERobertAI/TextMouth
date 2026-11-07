import XCTest
@testable import TextMouth

/// What a code of a symbol font means, by the font, in both layouts of the Word reader
/// (`WordSymbolFontEncodings`), and Word 97 text typed in a symbol font (stored as U+F020 to U+F0FF).
///
/// The first reading gave a space for a symbol of any font but Symbol, and `firm's` in a WordPerfect font's
/// apostrophe read `firm s`. The WordPerfect codes here are the ones the real documents settle: a code that sits
/// in `firm_s` over and over is an apostrophe, the two that open and close a quotation are its quotation marks.
final class WordDocumentSymbolFontTests: XCTestCase {

    typealias Builder = WordLegacyDocumentBuilder
    typealias Paragraph = Builder.Paragraph
    typealias Run = Builder.Run
    typealias Run97 = WordDocumentBuilder.Run

    /// The fonts both layouts' documents have here, in order, with their character sets in a Word 6 file.
    private static let fonts = [
        "Times New Roman", "Symbol", "Wingdings", "WP TypographicSymbols", "WP MathA", "Arial", "WP IconicSymbolsA", "MT Symbol",
    ]
    private static let characterSets = [0, 2, 2, 0, 0, 0, 0, 2]

    // MARK: - Helpers

    /// The inner HTML of the body of the document `data` is read as.
    private func body(of data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let html = try XCTUnwrap(WordDocumentReader.html(from: data, includesPages: false), file: file, line: line)
        let start = try XCTUnwrap(html.range(of: "<body>\n"), file: file, line: line)
        let end = try XCTUnwrap(html.range(of: "</body>"), file: file, line: line)
        return String(html[start.upperBound..<end.lowerBound])
    }

    /// A Word 6 document of one paragraph of `runs`.
    private func body(_ runs: [Run]) throws -> String {
        var builder = Builder()
        builder.paragraphs = [Paragraph(runs: runs)]
        builder.fontNames = Self.fonts
        builder.fontCharacterSets = Self.characterSets
        return try body(of: builder.build())
    }

    /// The run that is a symbol (`sprmCSymbol`) of font `font` and code `code`: the placeholder "(".
    private func symbol(font: Int, code: UInt8) -> Run {
        Run("(", sprms: Builder.sprm(74, [3, UInt8(font), 0, code]))
    }

    /// A Word 97 document of one paragraph of `runs`, with the fonts above, and any more `configure` sets.
    private func body97(_ runs: [Run97], configure: (inout WordDocumentBuilder) -> Void = { _ in }) throws -> String {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [WordDocumentBuilder.Paragraph(runs: runs)]
        builder.fonts = Self.fonts
        configure(&builder)
        return try body(of: builder.build())
    }

    /// A Word 97 run of `text` whose font is `font` (`sprmCRgFtc0`).
    private func run97(_ text: String, font: Int) -> Run97 {
        var run = Run97(text)
        run.extraModifiers = WordDocumentBuilder.le16(WordSprm.fontAscii) + WordDocumentBuilder.le16(font)
        return run
    }

    /// A Word 97 symbol (`sprmCSymbol`): the placeholder "(" with a font and a code.
    private func symbol97(font: Int, code: Int) -> Run97 {
        var run = Run97("(")
        run.extraModifiers = WordDocumentBuilder.le16(WordSprm.symbol) + WordDocumentBuilder.le16(font) + WordDocumentBuilder.le16(code)
        run.isSpecial = true
        return run
    }

    // MARK: - A symbol in Word 6 and Word 95

    func testAWordPerfectApostropheKeepsItsWordWhole() throws {
        // 0x3D of WP TypographicSymbols is the right single quotation mark: `firm_s` in the real documents.
        XCTAssertEqual(try body([Run("firm"), symbol(font: 3, code: 0x3D), Run("s")]), "<p>firm\u{2019}s</p>\n")
        // Its other codes that the documents settle: the opening single quotation mark, the double quotation marks,
        // the section sign, the inverted question mark, and a bullet.
        XCTAssertEqual(try body([Run("a"), symbol(font: 3, code: 0x3E), Run("b")]), "<p>a\u{2018}b</p>\n")
        XCTAssertEqual(try body([Run("a "), symbol(font: 3, code: 0x41), Run("b"), symbol(font: 3, code: 0x40)]), "<p>a \u{201C}b\u{201D}</p>\n")
        XCTAssertEqual(try body([Run("x"), symbol(font: 3, code: 0x27), Run("1")]), "<p>x\u{00A7}1</p>\n")
        XCTAssertEqual(try body([Run("x"), symbol(font: 3, code: 0x29), Run("y")]), "<p>x\u{00BF}y</p>\n")
        XCTAssertEqual(try body([Run("x"), symbol(font: 3, code: 0x24), Run("y")]), "<p>x\u{2022}y</p>\n")
    }

    func testACodeNoRealDocumentSettlesIsASpace() throws {
        XCTAssertEqual(try body([Run("a"), symbol(font: 3, code: 0x30), Run("b")]), "<p>a b</p>\n")
        // WP MathA: the degree sign and the bullet are settled, the rest are not.
        XCTAssertEqual(try body([Run("28"), symbol(font: 4, code: 0x45), Run("C")]), "<p>28\u{00B0}C</p>\n")
        XCTAssertEqual(try body([Run("a"), symbol(font: 4, code: 0x41), Run("b")]), "<p>a b</p>\n")
    }

    func testAFontOfPicturesIsASpaceWhateverItsCode() throws {
        // Wingdings, and a WordPerfect font with no table.
        for font in [2, 6] {
            XCTAssertEqual(try body([Run("a"), symbol(font: font, code: 0x3D), Run("b")]), "<p>a b</p>\n", "font \(font)")
        }
    }

    func testAnOrdinaryTextFontIsReadThroughItsOwnCodePage() throws {
        // Arial, character set 0: 0xE9 is e-acute in Windows-1252, 0x41 is "A".
        XCTAssertEqual(try body([Run("caf"), symbol(font: 5, code: 0xE9), Run("!")]), "<p>caf\u{00E9}!</p>\n")
        XCTAssertEqual(try body([Run("x"), symbol(font: 5, code: 0x41), Run("y")]), "<p>xAy</p>\n")
        // A space, and a control, are spaces.
        XCTAssertEqual(try body([Run("a"), symbol(font: 5, code: 0x20), Run("b")]), "<p>a b</p>\n")
        XCTAssertEqual(try body([Run("a"), symbol(font: 5, code: 0x01), Run("b")]), "<p>a b</p>\n")
    }

    func testAFontThatIsTheSymbolFontUnderAnotherNameIsReadAsSymbol() throws {
        // MT Symbol: 0x61 is alpha.
        XCTAssertEqual(try body([Run("a"), symbol(font: 7, code: 0x61), Run("b")]), "<p>a\u{03B1}b</p>\n")
    }

    // MARK: - A symbol in Word 97

    func testWord97ReadsASymbolByItsFontToo() throws {
        XCTAssertEqual(try body97([Run97("firm"), symbol97(font: 3, code: 0xF03D), Run97("s")]), "<p>firm\u{2019}s</p>\n")
        XCTAssertEqual(try body97([Run97("caf"), symbol97(font: 5, code: 0xE9), Run97("!")]), "<p>caf\u{00E9}!</p>\n")
        // In an ordinary font a code outside 0xF000 to 0xF0FF is the character itself.
        XCTAssertEqual(try body97([Run97("a"), symbol97(font: 5, code: 0x2260), Run97("b")]), "<p>a\u{2260}b</p>\n")
        XCTAssertEqual(try body97([Run97("a"), symbol97(font: 6, code: 0xF041), Run97("b")]), "<p>a b</p>\n")
    }

    // MARK: - Word 97 text typed in a symbol font

    func testWord97TextTypedInSymbolIsInTheSymbolEncoding() throws {
        // Stored as U+F061 and U+F062; Symbol's 0x61 and 0x62 are alpha and beta.
        XCTAssertEqual(try body97([Run97("angle "), run97("\u{F061}\u{F062}", font: 1), Run97(" x")]), "<p>angle \u{03B1}\u{03B2} x</p>\n")
    }

    func testWord97TextTypedInAFontOfPicturesIsASpace() throws {
        XCTAssertEqual(try body97([Run97("a"), run97("\u{F06C}", font: 2), Run97("b")]), "<p>a b</p>\n")
    }

    func testWord97TextTypedInAWordPerfectFontIsReadByItsTable() throws {
        XCTAssertEqual(try body97([Run97("firm"), run97("\u{F03D}", font: 3), Run97("s")]), "<p>firm\u{2019}s</p>\n")
        XCTAssertEqual(try body97([Run97("firm"), run97("\u{F030}", font: 3), Run97("s")]), "<p>firm s</p>\n")
    }

    func testWord97TextTypedInAnOrdinaryFontIsTheLowByteInItsCodePage() throws {
        XCTAssertEqual(try body97([Run97("caf"), run97("\u{F0E9}", font: 5), Run97("!")]), "<p>caf\u{00E9}!</p>\n")
        // A character of the font that is not in 0xF020 to 0xF0FF is itself.
        XCTAssertEqual(try body97([Run97("caf"), run97("\u{00E9}", font: 1), Run97("!")]), "<p>caf\u{00E9}!</p>\n")
    }

    func testWord97TakesTheFontOfTheCharacterStyleThenTheParagraphStyleThenTheSheetsDefault() throws {
        // A character style at index 12 sets Symbol; a paragraph style at 13 sets Symbol too.
        let styles = WordDocumentBuilder.standardStyles + [
            WordDocumentBuilder.Style(builtInIdentifier: 0, kind: 2, fontIndex: 1),
            WordDocumentBuilder.Style(builtInIdentifier: 0, kind: 1, fontIndex: 1),
        ]
        let fromCharacterStyle = try body97([Run97("\u{F061}", characterStyle: 12)]) { $0.styles = styles }
        XCTAssertEqual(fromCharacterStyle, "<p>\u{03B1}</p>\n")
        var paragraph = WordDocumentBuilder.Paragraph(runs: [Run97("\u{F061}")])
        paragraph.style = 13
        var builder = WordDocumentBuilder()
        builder.paragraphs = [paragraph]
        builder.fonts = Self.fonts
        builder.styles = styles
        XCTAssertEqual(try body(of: builder.build()), "<p>\u{03B1}</p>\n")
        // The sheet's default font, when nothing else says; the run's own font wins over it.
        let fromDefault = try body97([Run97("\u{F061}")]) { $0.defaultFont = 1 }
        XCTAssertEqual(fromDefault, "<p>\u{03B1}</p>\n")
        let overridden = try body97([run97("\u{F061}", font: 0)]) { $0.defaultFont = 1 }
        // Times New Roman is an ordinary font: the low byte 0x61 is "a".
        XCTAssertEqual(overridden, "<p>a</p>\n")
    }

    func testWord97TextOfAnUnknownFontKeepsItsCharacters() throws {
        // No font table: nothing says what the code means, so it stays what the file holds.
        XCTAssertEqual(try body97([Run97("a\u{F061}b")]) { $0.fonts = [] }, "<p>a\u{F061}b</p>\n")
    }

    // MARK: - The table

    func testTheReadingOfAFontIsDecidedByItsNameThenItsCharacterSet() {
        typealias Encodings = WordSymbolFontEncodings
        XCTAssertEqual(Encodings.reading(ofFontNamed: "symbol", characterSet: 2), .adobeSymbol)
        XCTAssertEqual(Encodings.reading(ofFontNamed: "mt symbol", characterSet: 0), .adobeSymbol)
        XCTAssertEqual(Encodings.reading(ofFontNamed: "wingdings 2", characterSet: 0), .pictures)
        XCTAssertEqual(Encodings.reading(ofFontNamed: "monotype sorts", characterSet: 0), .pictures)
        XCTAssertEqual(Encodings.reading(ofFontNamed: "zapfdingbats", characterSet: 0), .pictures)
        // Any font of the symbol character set, whatever it is called, and a WordPerfect font with no table.
        XCTAssertEqual(Encodings.reading(ofFontNamed: "unheard of", characterSet: 2), .pictures)
        XCTAssertEqual(Encodings.reading(ofFontNamed: "wp iconicsymbolsa", characterSet: 0), .pictures)
        XCTAssertEqual(Encodings.reading(ofFontNamed: "arial", characterSet: 0), .text)
        guard case .table(let table) = Encodings.reading(ofFontNamed: "wp typographicsymbols", characterSet: 0) else {
            return XCTFail("a table was expected")
        }
        XCTAssertEqual(table[0x3D], "\u{2019}")
    }

    func testAnOrdinaryFontsCodeIsNilWhenItIsASpaceOrAControl() {
        XCTAssertNil(WordSymbolFontEncodings.scalar(forCode: 0x20, reading: .text))
        XCTAssertNil(WordSymbolFontEncodings.scalar(forCode: 0x09, reading: .text))
        XCTAssertNil(WordSymbolFontEncodings.scalar(forCode: 0x81, reading: .text))
        XCTAssertEqual(WordSymbolFontEncodings.scalar(forCode: 0x80, reading: .text), "\u{20AC}")
    }
}
