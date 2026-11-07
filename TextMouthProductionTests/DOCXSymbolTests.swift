import XCTest
@testable import TextMouth

// MARK: - Symbols in Word Documents (DOCX)

/// How the DOCX reader reads a symbol (`w:sym`, with its `w:font` and `w:char`)
/// and text typed in a symbol font (Word stores it as U+F020 to U+F0FF in
/// `w:t`): as the Word 97 reader does, through the same tables by font
/// (`WordSymbolFontEncodings`), so a listener hears "5 µm" and "firm's" and not
/// nothing, and the words on either side of a picture are not run together.
final class DOCXSymbolTests: XCTestCase {

    // MARK: - Fixtures

    /// A run holding the symbol `char` of the font `font` (either left out when nil).
    private func symbol(_ font: String?, _ char: String?, properties: String = "") -> String {
        let rPr = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        let fontAttribute = font.map { " w:font=\"\($0)\"" } ?? ""
        let charAttribute = char.map { " w:char=\"\($0)\"" } ?? ""
        return "<w:r>\(rPr)<w:sym\(fontAttribute)\(charAttribute)/></w:r>"
    }

    /// A run of `text` whose own font is `font` (`w:ascii`).
    private func typed(_ text: String, in font: String) -> String {
        docxRun(text, "<w:rFonts w:ascii=\"\(font)\" w:hAnsi=\"\(font)\"/>")
    }

    /// The words a listener hears of a body, with white space made one space.
    private func heard(
        _ body: String, styles: String? = nil, fontTable: String? = nil, footnotes: String? = nil
    ) throws -> String {
        let docx = try makeDOCXPackage(
            document: docxDocumentXML(body), styles: styles, footnotes: footnotes,
            otherParts: fontTable.map { [DOCXParser.Part.fontTable: $0] } ?? [:])
        let markdown = try DOCXParser.extractMarkdown(from: docx, includesPages: false)
        return try MarkdownDocParser.parseChapter(markdown: markdown).text
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The paragraph "{before}{middle}{after}" with the three as runs.
    private func between(_ middle: String, before: String = "a", after: String = "b") -> String {
        docxParagraph(docxRun(before) + middle + docxRun(after))
    }

    /// A styles part with `styles` inside `w:styles` (and `defaults` in `w:docDefaults`).
    private func stylesPart(_ styles: String, defaults: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        \(defaults.isEmpty ? "" : "<w:docDefaults><w:rPrDefault><w:rPr>\(defaults)</w:rPr></w:rPrDefault></w:docDefaults>")
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        \(styles)
        </w:styles>
        """
    }

    /// A font table declaring each of `fonts` (name and character set, in hexadecimal).
    private func fontTablePart(_ fonts: [(String, String)]) -> String {
        let entries = fonts.map { "<w:font w:name=\"\($0.0)\"><w:charset w:val=\"\($0.1)\"/></w:font>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:fonts xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\(entries)</w:fonts>"
    }

    // MARK: - w:sym

    /// A symbol of the font named Symbol, or a clone of it, is the character of the Adobe Symbol encoding:
    /// as a character of U+F000 to U+F0FF (its low byte is the code) or as the code itself.
    func testASymbolInTheSymbolFontIsTheSymbolEncodingsCharacter() throws {
        XCTAssertEqual(try heard(docxParagraph(docxRun("Angle ") + symbol("Symbol", "F061") + symbol("Symbol", "F062") + docxRun(" x"))),
                       "Angle \u{03B1}\u{03B2} x")
        XCTAssertEqual(try heard(between(symbol("Symbol", "0070"), before: "2")), "2\u{03C0}b")
        XCTAssertEqual(try heard(between(symbol("symbol", "F0B7"))), "a\u{2022}b")
        XCTAssertEqual(try heard(between(symbol("MT Symbol", "F061"))), "a\u{03B1}b")
    }

    /// A font of pictures reads as a space, whatever the code: nothing a voice can say, and the words
    /// on either side must not run together.
    func testASymbolInAFontOfPicturesIsASpace() throws {
        for font in ["Wingdings", "Wingdings 2", "Webdings", "ZapfDingbats", "Monotype Sorts"] {
            XCTAssertEqual(try heard(between(symbol(font, "F06C"))), "a b", font)
            XCTAssertEqual(try heard(between(symbol(font, "006C"))), "a b", font)
        }
    }

    /// A WordPerfect font is read by the small table of the codes real documents settle, and a code
    /// that table does not settle is a space.
    func testASymbolInAWordPerfectFontIsReadByItsTable() throws {
        XCTAssertEqual(try heard(docxParagraph(docxRun("firm") + symbol("WP TypographicSymbols", "F03D") + docxRun("s"))), "firm\u{2019}s")
        XCTAssertEqual(try heard(docxParagraph(docxRun("a ") + symbol("WP TypographicSymbols", "F041") + docxRun("b") + symbol("WP TypographicSymbols", "F040"))),
                       "a \u{201C}b\u{201D}")
        XCTAssertEqual(try heard(docxParagraph(docxRun("firm") + symbol("WP TypographicSymbols", "F030") + docxRun("s"))), "firm s")
        XCTAssertEqual(try heard(docxParagraph(docxRun("28") + symbol("WP MathA", "F045") + docxRun("C"))), "28\u{00B0}C")
    }

    /// An ordinary text font's code is a character of its code page, and its character in U+F0xx is read
    /// through the Symbol table, as textutil reads it (the Word 97 reader's decision).
    func testASymbolInAnOrdinaryFontIsReadThroughItsCodePageOrTheSymbolTable() throws {
        XCTAssertEqual(try heard(docxParagraph(docxRun("caf") + symbol("Arial", "00E9") + docxRun("!"))), "caf\u{00E9}!")
        XCTAssertEqual(try heard(docxParagraph(docxRun("x") + symbol("Arial", "0041") + docxRun("y"))), "xAy")
        XCTAssertEqual(try heard(docxParagraph(docxRun("5 ") + symbol("Arial", "F06D") + docxRun("m"))), "5 \u{00B5}m")
        XCTAssertEqual(try heard(between(symbol("Arial", "F0E9"))), "a b")
        // A space or a control code is none a voice can say.
        XCTAssertEqual(try heard(between(symbol("Arial", "0020"))), "a b")
        XCTAssertEqual(try heard(between(symbol("Arial", "0001"))), "a b")
    }

    /// A symbol with no font, no character, or a character that is not up to four hexadecimal digits
    /// is a space.
    func testASymbolWithoutAReadableFontOrCharacterIsASpace() throws {
        XCTAssertEqual(try heard(between(symbol(nil, "F061"))), "a b")
        XCTAssertEqual(try heard(between(symbol("Symbol", nil))), "a b")
        XCTAssertEqual(try heard(between(symbol("Symbol", "ZZ"))), "a b")
        XCTAssertEqual(try heard(between(symbol("Symbol", "F0610"))), "a b")
        // A sign is no digit: a negative code would trap the tables.
        XCTAssertEqual(try heard(between(symbol("Symbol", "-1"))), "a b")
        XCTAssertEqual(try heard(between(symbol("Arial", "-41"))), "a b")
        XCTAssertEqual(try heard(between(symbol("Symbol", "+61"))), "a b")
        XCTAssertEqual(try heard(between(symbol("Symbol", " 61"))), "a b")
        XCTAssertEqual(try heard(between(symbol("Symbol", ""))), "a b")
        XCTAssertEqual(try heard(between(symbol("", "F061"))), "a b")
    }

    /// A symbol in hidden text is not read, and one in a footnote is.
    func testASymbolInHiddenTextIsNotReadAndOneInANoteIs() throws {
        XCTAssertEqual(try heard(between(symbol("Symbol", "F061", properties: "<w:vanish/>"))), "ab")
        let footnote = "<w:footnote w:id=\"1\"><w:p><w:r><w:footnoteRef/></w:r><w:r><w:t> See </w:t></w:r><w:r><w:sym w:font=\"Symbol\" w:char=\"F061\"/></w:r></w:p></w:footnote>"
        let body = docxParagraph(docxRun("Text") + "<w:r><w:footnoteReference w:id=\"1\"/></w:r>")
        XCTAssertTrue(try heard(body, footnotes: docxNotesXML(root: "footnotes", footnote)).hasSuffix("See \u{03B1}"))
    }

    // MARK: - Text typed in a symbol font

    /// Text typed in the Symbol font (U+F020 to U+F0FF) is in the Symbol encoding, among other text of the run.
    func testTextTypedInTheSymbolFontIsInTheSymbolEncoding() throws {
        XCTAssertEqual(try heard(docxParagraph(docxRun("Angle ") + typed("\u{F061}\u{F062}", in: "Symbol") + docxRun(" x"))), "Angle \u{03B1}\u{03B2} x")
        XCTAssertEqual(try heard(docxParagraph(typed("2\u{F070}r", in: "Symbol"))), "2\u{03C0}r")
    }

    /// In a font of pictures it reads as a space, in a WordPerfect font by its table, and in an ordinary
    /// font through the Symbol table (maths typed so reads as itself, as in textutil's reading).
    func testTextTypedInOtherFontsIsReadAsTheirCodesAre() throws {
        XCTAssertEqual(try heard(docxParagraph(docxRun("a") + typed("\u{F06C}", in: "Wingdings") + docxRun("b"))), "a b")
        XCTAssertEqual(try heard(docxParagraph(docxRun("firm") + typed("\u{F03D}", in: "WP TypographicSymbols") + docxRun("s"))), "firm\u{2019}s")
        XCTAssertEqual(try heard(docxParagraph(docxRun("firm") + typed("\u{F030}", in: "WP TypographicSymbols") + docxRun("s"))), "firm s")
        XCTAssertEqual(try heard(docxParagraph(docxRun("5 ") + typed("\u{F06D}", in: "Arial") + docxRun("m"))), "5 \u{00B5}m")
        XCTAssertEqual(try heard(docxParagraph(docxRun("2*") + typed("\u{F070}", in: "Times New Roman") + docxRun("."))), "2*\u{03C0}.")
        XCTAssertEqual(try heard(docxParagraph(docxRun("a") + typed("\u{F0E9}", in: "Arial") + docxRun("b"))), "a b")
        // A character of an ordinary font that is not in that range is itself.
        XCTAssertEqual(try heard(docxParagraph(typed("caf\u{00E9}", in: "Arial"))), "caf\u{00E9}")
    }

    /// Text in a run that names no font, under styles that name none, keeps its characters.
    func testTextOfNoNamedFontKeepsItsCharacters() throws {
        XCTAssertEqual(try heard(docxParagraph(docxRun("a\u{F061}b"))), "a\u{F061}b")
        // And characters outside U+F020 to U+F0FF are never changed.
        XCTAssertEqual(try heard(docxParagraph(typed("a\u{F01F}\u{F100}b", in: "Symbol"))), "a\u{F01F}\u{F100}b")
    }

    /// The font of a run is the run's own, else its character style's, else its paragraph style's, else the
    /// document defaults', each through the styles it is based on (the Word 97 reader's order).
    func testTheFontOfARunIsTheRunsThenItsCharacterStylesThenItsParagraphStylesThenTheDefaults() throws {
        let styles = stylesPart("""
            <w:style w:type="paragraph" w:styleId="PicturePara"><w:name w:val="PicturePara"/><w:rPr><w:rFonts w:ascii="Wingdings"/></w:rPr></w:style>
            <w:style w:type="paragraph" w:styleId="PictureParaChild"><w:name w:val="PictureParaChild"/><w:basedOn w:val="PicturePara"/></w:style>
            <w:style w:type="paragraph" w:styleId="SymbolPara"><w:name w:val="SymbolPara"/><w:rPr><w:rFonts w:hAnsi="Symbol"/></w:rPr></w:style>
            <w:style w:type="character" w:styleId="SymbolChar"><w:name w:val="SymbolChar"/><w:rPr><w:rFonts w:ascii="Symbol"/></w:rPr></w:style>
            <w:style w:type="character" w:styleId="SymbolCharChild"><w:name w:val="SymbolCharChild"/><w:basedOn w:val="SymbolChar"/></w:style>
            <w:style w:type="character" w:styleId="PictureChar"><w:name w:val="PictureChar"/><w:rPr><w:rFonts w:ascii="Wingdings"/></w:rPr></w:style>
            <w:style w:type="character" w:styleId="Loop"><w:name w:val="Loop"/><w:basedOn w:val="Loop"/></w:style>
            """, defaults: "<w:rFonts w:ascii=\"Symbol\" w:hAnsi=\"Symbol\"/>")
        func word(_ run: String, style: String? = nil) throws -> String {
            try heard(docxParagraph(docxRun("a") + run + docxRun("b"), style: style), styles: styles)
        }
        let alpha = docxRun("\u{F061}")
        // The document defaults' font, when nothing else names one.
        XCTAssertEqual(try word(alpha), "a\u{03B1}b")
        // A paragraph style's (itself, through its base, and by w:hAnsi) over the defaults.
        XCTAssertEqual(try word(alpha, style: "PicturePara"), "a b")
        XCTAssertEqual(try word(alpha, style: "PictureParaChild"), "a b")
        XCTAssertEqual(try word(alpha, style: "SymbolPara"), "a\u{03B1}b")
        // A character style's over the paragraph's, itself and through its base.
        XCTAssertEqual(try word(docxRun("\u{F061}", "<w:rStyle w:val=\"SymbolChar\"/>"), style: "PicturePara"), "a\u{03B1}b")
        XCTAssertEqual(try word(docxRun("\u{F061}", "<w:rStyle w:val=\"SymbolCharChild\"/>"), style: "PicturePara"), "a\u{03B1}b")
        XCTAssertEqual(try word(docxRun("\u{F061}", "<w:rStyle w:val=\"PictureChar\"/>")), "a b")
        // The run's own over both.
        XCTAssertEqual(try word(docxRun("\u{F061}", "<w:rStyle w:val=\"SymbolChar\"/><w:rFonts w:ascii=\"Wingdings\"/>")), "a b")
        XCTAssertEqual(try word(docxRun("\u{F061}", "<w:rStyle w:val=\"PictureChar\"/><w:rFonts w:ascii=\"Symbol\"/>")), "a\u{03B1}b")
        // A style that loops back on itself, or that names a style the part lacks, names no font.
        XCTAssertEqual(try word(docxRun("\u{F061}", "<w:rStyle w:val=\"Loop\"/>")), "a\u{03B1}b")
        XCTAssertEqual(try word(docxRun("\u{F061}", "<w:rStyle w:val=\"Missing\"/>"), style: "Missing"), "a\u{03B1}b")
        // A symbol's font is its own attribute, not the run's.
        XCTAssertEqual(try heard(between(symbol("Symbol", "F061"), before: "a", after: "b"), styles: styles), "a\u{03B1}b")
    }

    /// The properties from before a tracked change (`w:rPrChange`) say nothing of the text as it stands.
    func testAFontInARecordOfATrackedChangeIsNotTheRunsFont() throws {
        let styles = stylesPart("", defaults: "<w:rFonts w:ascii=\"Symbol\"/>")
        let run = docxRun("\u{F061}", "<w:rPrChange w:id=\"1\" w:author=\"A\"><w:rPr><w:rFonts w:ascii=\"Wingdings\"/></w:rPr></w:rPrChange>")
        XCTAssertEqual(try heard(docxParagraph(docxRun("a") + run + docxRun("b")), styles: styles), "a\u{03B1}b")
    }

    // MARK: - The font table

    /// A font of the symbol character set (`w:charset` 02) that no table of names holds is a font of
    /// pictures, as in Word 97; with no font table it is read as a text font.
    func testTheFontTablesCharacterSetDecidesAFontNoTableNames() throws {
        let body = between(symbol("Odd Pictures", "0041"))
        XCTAssertEqual(try heard(body, fontTable: fontTablePart([("Odd Pictures", "02")])), "a b")
        XCTAssertEqual(try heard(body, fontTable: fontTablePart([("odd pictures", "02")])), "a b")
        XCTAssertEqual(try heard(body, fontTable: fontTablePart([("Odd Pictures", "00")])), "aAb")
        XCTAssertEqual(try heard(body), "aAb")
        // A character set that is not a byte declares nothing.
        XCTAssertEqual(try heard(body, fontTable: fontTablePart([("Odd Pictures", "0200")])), "aAb")
        XCTAssertEqual(try heard(body, fontTable: fontTablePart([("Odd Pictures", "zz")])), "aAb")
        // The same for text typed in the font.
        XCTAssertEqual(try heard(docxParagraph(docxRun("a") + typed("\u{F041}", in: "Odd Pictures") + docxRun("b")),
                                 fontTable: fontTablePart([("Odd Pictures", "02")])), "a b")
    }

    /// A damaged font table loses the character sets and nothing else: the book is read.
    func testADamagedFontTableNeverLosesTheBook() throws {
        let damaged = "<?xml version=\"1.0\"?><w:fonts xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:font w:name=\"Odd Pictures\"><w:charset w:val=\"02\"/>"
        XCTAssertEqual(try heard(between(symbol("Symbol", "F061")), fontTable: damaged), "a\u{03B1}b")
        XCTAssertEqual(try heard(between(symbol("Odd Pictures", "0041")), fontTable: damaged), "aAb")
        // And one that is hostile (a subset of its own) is refused without refusing the book.
        let hostile = "<?xml version=\"1.0\"?><!DOCTYPE fonts [<!ENTITY e \"x\">]><w:fonts xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"/>"
        XCTAssertEqual(try heard(between(symbol("Symbol", "F061")), fontTable: hostile), "a\u{03B1}b")
    }

    // MARK: - The shared tables

    /// The reader asks the tables of the Word 97 reader, with no table of its own: what the tables say
    /// of a font and a code is what `WordXMLFonts` makes of them.
    func testTheFontsAskTheSharedTables() {
        var fonts = WordXMLFonts()
        fonts.declare(font: "Odd Pictures", characterSet: "02")
        XCTAssertEqual(fonts.characterSets, ["odd pictures": 2])
        XCTAssertEqual(fonts.symbol(font: "Symbol", character: 0xF061), "\u{03B1}")
        XCTAssertEqual(
            WordSymbolFontEncodings.scalar(forCode: 0x61, inFontNamed: "SYMBOL", characterSet: 2, isPrivateUse: false), "\u{03B1}")
        XCTAssertEqual(WordSymbolFontEncodings.scalar(forCode: 0x3D, inFontNamed: "WP TypographicSymbols", characterSet: 0, isPrivateUse: true), "\u{2019}")
        XCTAssertNil(WordSymbolFontEncodings.scalar(forCode: 0x41, inFontNamed: "Odd Pictures", characterSet: 2, isPrivateUse: false))
        XCTAssertEqual(WordXMLFonts.character("F061"), 0xF061)
        XCTAssertEqual(WordXMLFonts.character("61"), 0x61)
        XCTAssertNil(WordXMLFonts.character("F0610"))
        XCTAssertNil(WordXMLFonts.character("-1"))
        XCTAssertNil(WordXMLFonts.character("+61"))
        XCTAssertNil(WordXMLFonts.character("0x1"))
        XCTAssertEqual(WordXMLFonts.character("ff"), 0xFF)
        XCTAssertNil(WordXMLFonts.character(nil))
        XCTAssertEqual(fonts.readingSymbolText("a\u{F061}b", inFont: nil), "a\u{F061}b")
        XCTAssertEqual(fonts.readingSymbolText("ab", inFont: "Symbol"), "ab")
        XCTAssertEqual(fonts.readingSymbolText("a\u{F061}b", inFont: "Symbol"), "a\u{03B1}b")
    }
}

// MARK: - Symbols in Word 2003 XML Documents

/// The same for a Word 2003 XML document (`.wordml`): `w:sym`, text typed in a
/// symbol font, the run's font by its own `w:rFonts`, its styles, and the
/// document defaults, and the character sets of `w:fonts`.
final class WordMLSymbolTests: XCTestCase {

    // MARK: - Fixtures

    /// A Word 2003 XML document with `head` before its body holding `body`.
    private func document(body: String, head: String = "") -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<w:wordDocument xmlns:w=\"http://schemas.microsoft.com/office/word/2003/wordml\" "
            + "xmlns:wx=\"http://schemas.microsoft.com/office/word/2003/auxHint\" xml:space=\"preserve\">"
            + "\(head)<w:body><wx:sect>\(body)</wx:sect></w:body></w:wordDocument>"
    }

    /// The words of the paragraphs the reader makes of the document, tags left out.
    private func heard(_ body: String, head: String = "") throws -> String {
        let url = try makeSandboxDirectory("WordMLSymbol").appendingPathComponent("test.xml")
        try Data(document(body: body, head: head).utf8).write(to: url)
        let html = try WordMLDocumentReader.html(of: url, includesPages: false)
        return odfBodyLines(html).joined(separator: " ")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A paragraph of runs.
    private func paragraph(_ runs: String...) -> String { "<w:p>\(runs.joined())</w:p>" }

    /// A run of `text`, with `properties` as its run properties.
    private func run(_ text: String, _ properties: String = "") -> String {
        "<w:r>\(properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>")<w:t>\(text)</w:t></w:r>"
    }

    /// A run holding the symbol `char` of `font`.
    private func symbol(_ font: String?, _ char: String?, properties: String = "") -> String {
        let fontAttribute = font.map { " w:font=\"\($0)\"" } ?? ""
        let charAttribute = char.map { " w:char=\"\($0)\"" } ?? ""
        return "<w:r>\(properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>")<w:sym\(fontAttribute)\(charAttribute)/></w:r>"
    }

    /// The paragraph "a{middle}b".
    private func between(_ middle: String) -> String { paragraph(run("a"), middle, run("b")) }

    // MARK: - w:sym

    /// A symbol is read through its font as in the DOCX reader and the Word 97 reader.
    func testASymbolIsReadThroughItsFont() throws {
        XCTAssertEqual(try heard(paragraph(run("Angle "), symbol("Symbol", "F061"), symbol("Symbol", "F062"), run(" x"))), "Angle \u{03B1}\u{03B2} x")
        XCTAssertEqual(try heard(between(symbol("Symbol", "0070"))), "a\u{03C0}b")
        XCTAssertEqual(try heard(between(symbol("Wingdings", "F06C"))), "a b")
        XCTAssertEqual(try heard(paragraph(run("firm"), symbol("WP TypographicSymbols", "F03D"), run("s"))), "firm\u{2019}s")
        XCTAssertEqual(try heard(paragraph(run("firm"), symbol("WP TypographicSymbols", "F030"), run("s"))), "firm s")
        XCTAssertEqual(try heard(paragraph(run("caf"), symbol("Arial", "00E9"), run("!"))), "caf\u{00E9}!")
        XCTAssertEqual(try heard(paragraph(run("5 "), symbol("Arial", "F06D"), run("m"))), "5 \u{00B5}m")
        XCTAssertEqual(try heard(between(symbol(nil, "F061"))), "a b")
        XCTAssertEqual(try heard(between(symbol("Symbol", "ZZ"))), "a b")
        XCTAssertEqual(try heard(between(symbol("Symbol", "F061", properties: "<w:vanish/>"))), "ab")
    }

    // MARK: - Text typed in a symbol font

    /// Text in U+F020 to U+F0FF is read in the font of the run: its own `w:rFonts`, its character style's,
    /// its paragraph style's, or the document defaults'.
    func testTextTypedInASymbolFontIsReadInTheFontOfTheRun() throws {
        func font(_ name: String) -> String { "<w:rFonts w:ascii=\"\(name)\" w:h-ansi=\"\(name)\"/>" }
        XCTAssertEqual(try heard(paragraph(run("a"), run("\u{F061}\u{F062}", font("Symbol")), run("b"))), "a\u{03B1}\u{03B2}b")
        XCTAssertEqual(try heard(paragraph(run("a"), run("\u{F06C}", font("Wingdings")), run("b"))), "a b")
        XCTAssertEqual(try heard(paragraph(run("5 "), run("\u{F06D}", font("Arial")), run("m"))), "5 \u{00B5}m")
        XCTAssertEqual(try heard(paragraph(run("x\u{F070}y", "<w:rFonts w:h-ansi=\"Symbol\"/>"))), "x\u{03C0}y")
        // No font named anywhere: the characters stay.
        XCTAssertEqual(try heard(paragraph(run("a\u{F061}b"))), "a\u{F061}b")

        let head = """
            <w:styles>
            <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Symbol"/></w:rPr></w:rPrDefault></w:docDefaults>
            <w:style w:type="paragraph" w:styleId="PicturePara"><w:name w:val="PicturePara"/><w:rPr><w:rFonts w:ascii="Wingdings"/></w:rPr></w:style>
            <w:style w:type="paragraph" w:styleId="PictureChild"><w:name w:val="PictureChild"/><w:basedOn w:val="PicturePara"/></w:style>
            <w:style w:type="character" w:styleId="SymbolChar"><w:name w:val="SymbolChar"/><w:rPr><w:rFonts w:ascii="Symbol"/></w:rPr></w:style>
            </w:styles>
            """
        func styled(_ text: String, paragraphStyle: String? = nil, characterStyle: String? = nil, direct: String = "") throws -> String {
            let paragraphProperties = paragraphStyle.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
            let characterProperties = (characterStyle.map { "<w:rStyle w:val=\"\($0)\"/>" } ?? "") + direct
            return try heard("<w:p>\(paragraphProperties)\(run("a"))\(run(text, characterProperties))\(run("b"))</w:p>", head: head)
        }
        XCTAssertEqual(try styled("\u{F061}"), "a\u{03B1}b")
        XCTAssertEqual(try styled("\u{F061}", paragraphStyle: "PicturePara"), "a b")
        XCTAssertEqual(try styled("\u{F061}", paragraphStyle: "PictureChild"), "a b")
        XCTAssertEqual(try styled("\u{F061}", paragraphStyle: "PicturePara", characterStyle: "SymbolChar"), "a\u{03B1}b")
        XCTAssertEqual(try styled("\u{F061}", characterStyle: "SymbolChar", direct: "<w:rFonts w:ascii=\"Wingdings\"/>"), "a b")
    }

    /// The font table of the document's head (`w:fonts`) says a font no table of names holds is a font of
    /// pictures when its character set is 2.
    func testTheFontTablesCharacterSetDecidesAFontNoTableNames() throws {
        let body = between(symbol("Odd Pictures", "0041"))
        let fonts = "<w:fonts><w:font w:name=\"Odd Pictures\"><w:charset w:val=\"02\"/></w:font></w:fonts>"
        XCTAssertEqual(try heard(body, head: fonts), "a b")
        XCTAssertEqual(try heard(body), "aAb")
        XCTAssertEqual(try heard(paragraph(run("a"), run("\u{F041}", "<w:rFonts w:ascii=\"Odd Pictures\"/>"), run("b")), head: fonts), "a b")
    }
}
