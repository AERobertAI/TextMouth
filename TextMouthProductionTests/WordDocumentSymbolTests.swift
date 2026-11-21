import XCTest
import SwiftSoup
@testable import TextMouth

/// Symbols (Insert Symbol) and the code page of each run, in both layouts of the Word reader.
///
/// A symbol is stored as the text "(" with `sprmCSymbol` (the font and the code of the character it shows).
/// Word 6 stores no `sprmCFSpec` beside it, so a reader that drops only the special "(" read every symbol as a
/// left parenthesis: 542 runs in 33 of 312 real documents, `0.67 µm` as `0.67 (m)`. Both layouts now read the
/// character of the Symbol font (the Adobe Symbol encoding), and a space for any other font, so no word joins.
///
/// The bytes of the old layout's tests are the real ones: a symbol is `4a 03 01 00 2d` (the sprm, a size of 3,
/// a font of 1, the code 0x2d); a run of Macintosh text in a Windows file is `49 01 00 01`.
final class WordDocumentSymbolTests: XCTestCase {

    typealias Builder = WordLegacyDocumentBuilder
    typealias Paragraph = Builder.Paragraph
    typealias Run = Builder.Run

    // MARK: - Helpers

    /// The inner HTML of the body of the document `data` is read as.
    private func body(of data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let html = try XCTUnwrap(WordDocumentReader.html(from: data, includesPages: false), file: file, line: line)
        let start = try XCTUnwrap(html.range(of: "<body>\n"), file: file, line: line)
        let end = try XCTUnwrap(html.range(of: "</body>"), file: file, line: line)
        return String(html[start.upperBound..<end.lowerBound])
    }

    /// A Word 6 document of `paragraphs` with the fonts Times New Roman, Symbol, and Wingdings (the sets 0, 2, 2).
    private func body(_ paragraphs: [Paragraph], configure: (inout Builder) -> Void = { _ in }) throws -> String {
        var builder = Builder()
        builder.paragraphs = paragraphs
        builder.fontNames = ["Times New Roman", "Symbol", "Wingdings"]
        builder.fontCharacterSets = [0, 2, 2]
        configure(&builder)
        return try body(of: builder.build())
    }

    /// `sprmCSymbol` of a Word 6 document: a size of 3, a 16-bit font, a one-byte character.
    private func symbol(font: Int, code: UInt8) -> [UInt8] {
        Builder.sprm(74, [3, UInt8(font), 0, code])
    }

    /// A run that is the placeholder "(" and a symbol.
    private func placeholder(font: Int, code: UInt8) -> Run {
        Run("(", sprms: symbol(font: font, code: code))
    }

    private func encoding(_ identifier: String) throws -> String.Encoding {
        try XCTUnwrap(TextEncodingCatalog.entry(forIdentifier: identifier)?.encoding, identifier)
    }

    // MARK: - Symbols in Word 6 and Word 95

    func testASymbolOfTheSymbolFontIsItsCharacter() throws {
        // 0x6d is mu (read as the micro sign), 0xb0 the degree sign, 0xb7 a bullet, 0xb1 plus-minus.
        XCTAssertEqual(try body([Paragraph(runs: [Run("0.67 "), placeholder(font: 1, code: 0x6D), Run("m")])]), "<p>0.67 \u{00B5}m</p>\n")
        XCTAssertEqual(try body([Paragraph(runs: [Run("28"), placeholder(font: 1, code: 0xB0), Run("C")])]), "<p>28\u{00B0}C</p>\n")
        XCTAssertEqual(try body([Paragraph(runs: [Run("x"), placeholder(font: 1, code: 0xB1), Run("y")])]), "<p>x\u{00B1}y</p>\n")
        XCTAssertEqual(try body([Paragraph(runs: [Run("a "), placeholder(font: 1, code: 0xB7), Run(" b")])]), "<p>a \u{2022} b</p>\n")
        // A bullet that begins a paragraph makes it an item of a list, as every bullet does.
        XCTAssertEqual(try body([Paragraph(runs: [placeholder(font: 1, code: 0xB7), Run(" item")])]), "<ul>\n<li>item</li>\n</ul>\n")
    }

    func testTheSymbolFontsCodeOneHundredNinetyIsALongDashBecauseThatIsWhatWordsAuthorsUseItFor() throws {
        // Code 190 is the extender of a horizontal arrow; in the real documents it stands alone between two words
        // ("goals" and "achieve") where a long dash is. It reads as U+2014, with the words either side apart.
        XCTAssertEqual(
            try body([Paragraph(runs: [Run("goals"), placeholder(font: 1, code: 190), Run("achieve")])]),
            "<p>goals\u{2014}achieve</p>\n"
        )
    }

    func testASymbolOfAFontOfPicturesIsASpaceSoTheWordsEitherSideStayApart() throws {
        XCTAssertEqual(try body([Paragraph(runs: [Run("a"), placeholder(font: 2, code: 0x6C), Run("b")])]), "<p>a b</p>\n")
        // And a font the table does not hold.
        XCTAssertEqual(try body([Paragraph(runs: [Run("a"), placeholder(font: 9, code: 0x6C), Run("b")])]), "<p>a b</p>\n")
    }

    func testACodeWithNoVoiceableCharacterIsASpace() throws {
        // 0xe6 is the top of a large parenthesis, a private-use character no voice speaks.
        XCTAssertEqual(try body([Paragraph(runs: [Run("a"), placeholder(font: 1, code: 0xE6), Run("b")])]), "<p>a b</p>\n")
    }

    func testAParenthesisThatIsNotASymbolIsKeptAndTextWithASymbolIsKept() throws {
        XCTAssertEqual(try body([Paragraph(runs: [Run("see (page 3)")])]), "<p>see (page 3)</p>\n")
        // Any text but the placeholder keeps its own characters.
        XCTAssertEqual(try body([Paragraph(runs: [Run("a"), Run("Q", sprms: symbol(font: 1, code: 0x6D)), Run("b")])]), "<p>aQb</p>\n")
    }

    func testASpecialParenthesisWithNoSymbolIsDroppedAsBefore() throws {
        // `sprmCFSpec` (117) marks a picture's anchor, stored as "(": it has no words.
        XCTAssertEqual(try body([Paragraph(runs: [Run("x"), Run("(", sprms: Builder.sprm(117, [1])), Run("y")])]), "<p>xy</p>\n")
        XCTAssertEqual(try body([Paragraph(runs: [Run("x"), Run("(", sprms: []), Run("y")])]), "<p>x(y</p>\n")
    }

    func testTextInTheSymbolFontIsInTheSymbolEncoding() throws {
        // Typed in the font named Symbol, "a", "b", and "c" are alpha, beta, and chi: that is what Word shows (textutil does not
        // decode text typed in Symbol in Word 6 and Word 95), and a listener must hear the letter that is shown.
        let inSymbol = Builder.sprm(93, [1, 0])
        XCTAssertEqual(try body([Paragraph(runs: [Run("abc", sprms: inSymbol)])]), "<p>\u{03B1}\u{03B2}\u{03C7}</p>\n")
        // Mixed with text of another font, and with a placeholder in the same font (whose "(" is not a letter of Symbol).
        let mixed = [Run("angle "), Run("a", sprms: inSymbol), Run(" and 28"), Run("(", sprms: inSymbol + symbol(font: 1, code: 0xB0)), Run("C")]
        XCTAssertEqual(try body([Paragraph(runs: mixed)]), "<p>angle \u{03B1} and 28\u{00B0}C</p>\n")
        // A code with no character a voice can speak is a space; the paragraph mark stays a mark.
        XCTAssertEqual(try body([Paragraph(runs: [Run("x"), Run("\u{E6}", sprms: inSymbol), Run("y")])]), "<p>x y</p>\n")
    }

    func testASymbolInHiddenOrDeletedTextIsNotRead() throws {
        for sprms in [Builder.hidden(), Builder.deleted()] {
            let run = Run("(", sprms: symbol(font: 1, code: 0xB0) + sprms)
            XCTAssertEqual(try body([Paragraph(runs: [Run("a"), run, Run("b")])]), "<p>ab</p>\n")
        }
    }

    func testTheSymbolOfTheTextReadsAsAWordInTheReadingText() throws {
        // `parseChapter`'s text, as a listener hears it: the dash and the degree sign are there, no stray parenthesis.
        var builder = Builder()
        builder.paragraphs = [Paragraph(runs: [Run("goals"), placeholder(font: 1, code: 190), Run("achieve at 28"), placeholder(font: 1, code: 0xB0), Run("C")])]
        builder.fontNames = ["Times New Roman", "Symbol"]
        builder.fontCharacterSets = [0, 2]
        let html = try XCTUnwrap(WordDocumentReader.html(from: builder.build(), includesPages: false))
        let markdown = try HTMLToMarkdownConverter.convert(
            document: SwiftSoup.parse(html), readingFlow: PublicationSemantics.ReadingFlow(source: html), includesPages: false
        )
        let text = try MarkdownDocParser.parseChapter(markdown: markdown, title: "", includeNavigationHeadings: true).text
        XCTAssertFalse(text.contains("("), text)
        XCTAssertTrue(text.contains("goals\u{2014}achieve at 28\u{00B0}C"), text)
    }

    // MARK: - Symbols in Word 97

    typealias Run97 = WordDocumentBuilder.Run

    /// A Word 97 document of one paragraph whose runs are `runs`, with these fonts.
    private func body97(_ runs: [Run97], fonts: [String] = ["Times New Roman", "Symbol", "Wingdings"]) throws -> String {
        var builder = WordDocumentBuilder()
        builder.paragraphs = [WordDocumentBuilder.Paragraph(runs: runs)]
        builder.fonts = fonts
        return try body(of: builder.build())
    }

    /// `(` with `sprmCSymbol` (0x6A09: a 16-bit font and a 16-bit character), and `sprmCFSpec` if `special`.
    private func placeholder97(font: Int, code: Int, special: Bool = true) -> Run97 {
        var run = Run97("(")
        run.extraModifiers = WordDocumentBuilder.le16(WordSprm.symbol) + WordDocumentBuilder.le16(font) + WordDocumentBuilder.le16(code)
        run.isSpecial = special
        return run
    }

    func testWord97ReadsASymbolOfTheSymbolFontAsItsCharacterWhetherOrNotItIsMarkedSpecial() throws {
        // A character in 0xF000 to 0xF0FF is its low byte: 0xF0B0 is code 0xB0, the degree sign.
        for special in [true, false] {
            XCTAssertEqual(
                try body97([Run97("28"), placeholder97(font: 1, code: 0xF0B0, special: special), Run97("C")]), "<p>28\u{00B0}C</p>\n"
            )
        }
        XCTAssertEqual(try body97([Run97("0.67 "), placeholder97(font: 1, code: 0x6D), Run97("m")]), "<p>0.67 \u{00B5}m</p>\n")
        XCTAssertEqual(try body97([Run97("goals"), placeholder97(font: 1, code: 190), Run97("achieve")]), "<p>goals\u{2014}achieve</p>\n")
    }

    func testWord97ReadsASymbolOfAnotherFontAsASpaceAndOneWithNoFontTableAsASpace() throws {
        XCTAssertEqual(try body97([Run97("a"), placeholder97(font: 2, code: 0xF06C), Run97("b")]), "<p>a b</p>\n")
        XCTAssertEqual(try body97([Run97("a"), placeholder97(font: 1, code: 0xF06C), Run97("b")], fonts: []), "<p>a b</p>\n")
    }

    func testWord97StillDropsASpecialParenthesisWithNoSymbol() throws {
        var special = Run97("(")
        special.isSpecial = true
        XCTAssertEqual(try body97([Run97("x"), special, Run97("y")]), "<p>xy</p>\n")
        XCTAssertEqual(try body97([Run97("x"), Run97("("), Run97("y")]), "<p>x(y</p>\n")
    }

    // MARK: - The Adobe Symbol encoding

    func testTheAdobeSymbolEncodingGivesTheConsortiumsCharacters() {
        XCTAssertEqual(AdobeSymbolEncoding.scalar(forCode: 0x20), " ")
        XCTAssertEqual(AdobeSymbolEncoding.scalar(forCode: 0x61), "\u{03B1}")
        XCTAssertEqual(AdobeSymbolEncoding.scalar(forCode: 0xA0), "\u{20AC}")
        XCTAssertEqual(AdobeSymbolEncoding.scalar(forCode: 0xB7), "\u{2022}")
        XCTAssertEqual(AdobeSymbolEncoding.scalar(forCode: 0xE5), "\u{2211}")
        // Not defined, private use, and past the table.
        XCTAssertNil(AdobeSymbolEncoding.scalar(forCode: 0x00))
        XCTAssertNil(AdobeSymbolEncoding.scalar(forCode: 0xE6))
        XCTAssertNil(AdobeSymbolEncoding.scalar(forCode: 0x100))
        XCTAssertNil(AdobeSymbolEncoding.scalar(forCode: -1))
    }

    func testNoCodeOfTheAdobeSymbolEncodingIsAPrivateUseCharacter() {
        for code in 0..<256 {
            if let scalar = AdobeSymbolEncoding.scalar(forCode: code) {
                XCTAssertFalse((0xE000...0xF8FF).contains(scalar.value), "code \(code)")
            }
        }
    }

    // MARK: - The Code Page of Each Run

    func testARunOfMacintoshTextInAWindowsFileIsMacRoman() throws {
        // `49 01 00 01` (sprmCChse 73: it differs, 0x0100) marks the run; é is 0x8E in Mac Roman, Ž in Windows-1252.
        let mac = try encoding("macintosh")
        let marked = Run("é", sprms: Builder.sprm(73, [1, 0x00, 0x01]), encoding: mac)
        XCTAssertEqual(try body([Paragraph(runs: [Run("caf"), marked])]), "<p>café</p>\n")
        // Not marked, the same byte 0x8E is Windows-1252's Z with a caron.
        XCTAssertEqual(try body([Paragraph(runs: [Run("caf"), Run("é", encoding: mac)])]), "<p>caf\u{017D}</p>\n")
    }

    func testARunOfWindowsTextInAMacintoshFileIsWindows1252() throws {
        // The file is marked Macintosh (the FIB's chs 256); a run marked 0 (ANSI) holds a right quote, 0x92.
        let mac = try encoding("macintosh")
        let windows = try encoding("windows-1252")
        let body = try body([Paragraph(runs: [Run("caf", encoding: mac), Run("é", encoding: mac), Run("\u{2019}", sprms: Builder.sprm(73, [1, 0, 0]), encoding: windows)])]) {
            $0.encoding = mac
            $0.characterSet = 256
        }
        XCTAssertEqual(body, "<p>café\u{2019}</p>\n")
    }

    func testAForeignFontAnywhereInTheTableDoesNotMakeTheWholeDocumentThatCodePage() throws {
        // A Greek font is in the table and used for one run; the text of the others is Windows-1252: ñ stays ñ.
        let greek = try encoding("windows-1253")
        let body = try body([Paragraph(runs: [
            Run("ma", sprms: Builder.sprm(93, [0, 0])), Run("ñ", sprms: Builder.sprm(93, [0, 0])), Run("ana "),
            Run("α", sprms: Builder.sprm(93, [1, 0]), encoding: greek),
        ])]) {
            $0.fontNames = ["Times New Roman", "Times New Roman Greek"]
            $0.fontCharacterSets = [0, 161]
        }
        XCTAssertEqual(body, "<p>mañana α</p>\n")
    }

    func testTheDocumentsDefaultIsTheForeignSetHoldingMostOfItsHighCharacters() throws {
        // Every high character is in a Cyrillic font or has no font of its own: the default is Windows-1251, so a run
        // with no font of its own reads as Cyrillic too, as it does in the real Cyrillic documents (whose language says English).
        let cyrillic = try encoding("windows-1251")
        let body = try body([Paragraph(runs: [Run("Привет", sprms: Builder.sprm(93, [1, 0]), encoding: cyrillic), Run(" "), Run("Ж", encoding: cyrillic)])]) {
            $0.fontNames = ["Times New Roman", "Times New Roman Cyr"]
            $0.fontCharacterSets = [0, 204]
        }
        XCTAssertEqual(body, "<p>Привет Ж</p>\n")
    }

    func testARunsFontCanComeFromItsParagraphStyle() throws {
        // More Latin high characters than Cyrillic ones: the default stays Windows-1252, and the paragraph in a style
        // whose font is Cyrillic reads as Cyrillic.
        let cyrillic = try encoding("windows-1251")
        let russian = Builder.Style(sti: 100, basedOn: 0, name: "Russian", characterSprms: Builder.sprm(93, [1, 0]))
        let body = try body([
            Paragraph("éééééééé"),
            Paragraph(runs: [Run("Привет", encoding: cyrillic)], style: 4),
        ]) {
            $0.styles.append(russian)
            $0.fontNames = ["Times New Roman", "Times New Roman Cyr"]
            $0.fontCharacterSets = [0, 204]
        }
        XCTAssertEqual(body, "<p>éééééééé</p>\n<p>Привет</p>\n")
    }

    func testAFarEastFontInAOneByteDocumentNamesNoCodePageForARun() throws {
        // 0xB0 and 0xD1 are the degree sign and N with a tilde in Windows-1252, and half-width katakana in Shift JIS.
        let body = try body([Paragraph(runs: [Run("\u{00B0}\u{00D1}", sprms: Builder.sprm(93, [2, 0]))])]) {
            $0.fontNames = ["Times New Roman", "Symbol", "MS Mincho"]
            $0.fontCharacterSets = [0, 2, 128]
        }
        XCTAssertEqual(body, "<p>\u{00B0}\u{00D1}</p>\n")
    }
}
