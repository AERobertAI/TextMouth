import XCTest
@testable import TextMouth

/// A book read in the encoding the listener chose in Book Information
/// (encodingchoice): every byte in that encoding, whatever the bytes say of
/// themselves, and strictly: a file whose bytes are not valid in it is
/// refused by name, with nothing dropped or replaced. Fixtures are written as
/// bytes, so each expectation can be checked by eye.
final class TextEncodingChoiceDecoderTests: XCTestCase {

    // MARK: - Fixtures

    /// "Привет, мир" in Windows-1251.
    private static let cyrillic1251: [UInt8] = [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x2C, 0x20, 0xEC, 0xE8, 0xF0]
    private static let cyrillicText = "Привет, мир"

    /// Decode `bytes` as the plain-text file "Fixture.txt", or a file of
    /// `format`, read as the listener chose: in `identifier`.
    private func decode(_ bytes: [UInt8], chosen identifier: String, format: BookFormat = .txt) throws -> DecodedText {
        try TextFileDecoder.decode(
            Data(bytes), fileName: "Fixture.\(format.fileExtensions.first ?? "txt")", format: format, policy: .chosen(identifier)
        )
    }

    /// The encoding Core Foundation knows by the IANA name `label`.
    private func encoding(_ label: String) throws -> String.Encoding {
        try XCTUnwrap(TextFileDecoder.encoding(forLabel: label), label)
    }

    // MARK: - Reading a Choice

    /// A choice reads every byte in the chosen encoding, and says it was
    /// chosen.
    func testAChoiceReadsTheFileInTheChosenEncoding() throws {
        let decoded = try decode(Self.cyrillic1251, chosen: "windows-1251")
        XCTAssertEqual(decoded.text, Self.cyrillicText)
        XCTAssertEqual(decoded.encoding, try encoding("windows-1251"))
        XCTAssertEqual(decoded.basis, .chosen)
        XCTAssertNil(decoded.guessedEncodingIdentifier, "a choice is not a guess")
    }

    /// A choice overrules everything the bytes say of themselves: valid
    /// UTF-8, an HTML declaration, and a byte-order mark, whose bytes are
    /// read as characters of the chosen encoding like any others.
    func testAChoiceOverrulesWhatTheBytesSayOfThemselves() throws {
        // "é" in UTF-8 is 0xC3 0xA9, which Windows-1251 reads as "Г©".
        XCTAssertEqual(try decode([0xC3, 0xA9], chosen: "windows-1251").text, "Г©")

        // An HTML file that declares ISO 8859-1 is read as Windows-1251 when chosen.
        let declared = Array("<meta charset=\"iso-8859-1\"><p>".utf8) + Self.cyrillic1251
        let html = try decode(declared, chosen: "windows-1251", format: .html)
        XCTAssertEqual(html.basis, .chosen)
        XCTAssertTrue(html.text.hasSuffix(Self.cyrillicText), html.text)

        // A UTF-8 byte-order mark, read as Windows-1251, is three letters of it.
        XCTAssertEqual(try decode([0xEF, 0xBB, 0xBF, 0x41], chosen: "windows-1251").text, "п»їA")
    }

    /// UTF-8 can be chosen, as "utf-8". Its byte-order mark, a signature
    /// rather than a word, is removed as it is from every reading.
    func testUTF8CanBeChosenAndItsByteOrderMarkIsRemoved() throws {
        let decoded = try decode([0xEF, 0xBB, 0xBF, 0x43, 0x61, 0x66, 0xC3, 0xA9], chosen: TextFileDecoder.utf8Identifier)
        XCTAssertEqual(decoded.text, "Café")
        XCTAssertEqual(decoded.encoding, .utf8)
        XCTAssertEqual(decoded.basis, .chosen)
        XCTAssertEqual(TextFileDecoder.utf8Identifier, "utf-8")
    }

    /// Windows-1252, chosen, reads every byte, the five Windows leaves
    /// undefined included, as the fallback does.
    func testWindows1252ChosenReadsEveryByte() throws {
        let everyByte = (0...255).map(UInt8.init)
        let decoded = try decode(everyByte, chosen: "windows-1252")
        XCTAssertEqual(decoded.text, TextFileDecoder.windows1252Text(Data(everyByte)).replacingOccurrences(of: "\r", with: "\n"))
        XCTAssertEqual(decoded.basis, .chosen)
    }

    /// A choice's identifier is read in any letter case, and every encoding
    /// of the catalog can be chosen.
    func testEveryCatalogEncodingAndUTF8CanBeChosen() throws {
        XCTAssertEqual(TextFileDecoder.chosenEncoding(forIdentifier: "UTF-8"), .utf8)
        XCTAssertEqual(TextFileDecoder.chosenEncoding(forIdentifier: "Windows-1251"), try encoding("windows-1251"))
        for entry in TextEncodingCatalog.entries {
            XCTAssertEqual(TextFileDecoder.chosenEncoding(forIdentifier: entry.identifier), entry.encoding, entry.identifier)
        }
        XCTAssertNil(TextFileDecoder.chosenEncoding(forIdentifier: "x-cp1999"))
    }

    /// The name a listener hears for a choice: "UTF-8", the catalog's name,
    /// or the identifier itself for one TextMouth does not know.
    func testTheNameOfAChoice() {
        XCTAssertEqual(TextFileDecoder.chosenEncodingName(forIdentifier: "utf-8"), "UTF-8")
        XCTAssertEqual(TextFileDecoder.chosenEncodingName(forIdentifier: "cp932"), "Shift JIS (Japanese)")
        XCTAssertEqual(TextFileDecoder.chosenEncodingName(forIdentifier: "koi8-r"), "KOI8-R (Russian)")
        XCTAssertEqual(TextFileDecoder.chosenEncodingName(forIdentifier: "x-cp1999"), "x-cp1999")
    }

    // MARK: - Refusing a Choice

    /// Bytes that are not UTF-8 are refused when UTF-8 is chosen, naming the
    /// file and the encoding, rather than read by the fallback.
    func testUTF8ChosenRefusesBytesThatAreNotUTF8() {
        XCTAssertThrowsError(try decode(Self.cyrillic1251, chosen: "utf-8")) { error in
            XCTAssertEqual(error as? TextEncodingError, .invalidForChosenEncoding(file: "Fixture.txt", encoding: "UTF-8"))
        }
    }

    /// A byte the chosen encoding does not define is refused: Windows-1251
    /// has no 0x98, Windows-1253 no 0xAA, ISO 8859-8 no 0xC0.
    func testAByteTheChosenEncodingDoesNotDefineIsRefused() {
        let cases: [(identifier: String, name: String, byte: UInt8)] = [
            ("windows-1251", "Windows-1251 (Cyrillic)", 0x98),
            ("windows-1253", "Windows-1253 (Greek)", 0xAA),
            ("iso-8859-8", "ISO 8859-8 (Hebrew)", 0xC0),
        ]
        for (identifier, name, byte) in cases {
            XCTAssertThrowsError(try decode([0x41, byte, 0x42], chosen: identifier), identifier) { error in
                XCTAssertEqual(error as? TextEncodingError, .invalidForChosenEncoding(file: "Fixture.txt", encoding: name))
            }
        }
    }

    /// Malformed bytes in a multi-byte encoding are refused, though
    /// Foundation's readers of these encodings read each of them, as measured
    /// on macOS 26.3: a byte that cannot follow a lead byte (EUC-JP, GB 2312,
    /// Shift JIS, CP949), a single shift before a byte it cannot take
    /// (EUC-JP), a byte above ASCII or a cut-off escape (ISO-2022-JP), a lone
    /// 0x80 (GB 18030), and a character cut off by the end (Big5, EUC-KR).
    func testMalformedMultiByteTextIsRefused() throws {
        let malformed: [(identifier: String, bytes: [UInt8])] = [
            ("euc-jp", [0x41, 0xA1, 0x42]),
            ("euc-jp", [0x41, 0x8E, 0x42]),
            ("gb2312", [0x41, 0xA1, 0x42]),
            ("cp932", [0x41, 0x81, 0x7F]),
            ("shift_jis", [0x41, 0x81, 0x7F]),
            ("iso-2022-jp", [0x41, 0x80, 0x42]),
            ("iso-2022-jp", [0x41, 0x1B, 0x24]),
            ("gb18030", [0x41, 0x80, 0x42]),
            ("big5", [0x41, 0xA4]),
            ("euc-kr", [0x41, 0xB0]),
            ("cp949", [0x41, 0x81, 0x20]),
        ]
        for (identifier, bytes) in malformed {
            XCTAssertNil(
                TextFileDecoder.strictlyDecodedText(Data(bytes), in: try encoding(identifier)),
                "\(identifier) read \(bytes)"
            )
            XCTAssertThrowsError(try decode(bytes, chosen: identifier), "\(identifier) read \(bytes)")
        }
    }

    /// EUC-JP's JIS X 0212 characters (the single shift 0x8F and two bytes)
    /// are refused: Foundation's reader takes the last of the three bytes for
    /// the start of another character, so "Le café." with é written so
    /// (0x8F 0xAB 0xB1, as Python's euc_jp writes it) would read "Le café窺"
    /// (review of October 24, finding 1).
    func testJISX0212InEUCJPIsRefusedSinceFoundationMisreadsIt() throws {
        let bytes = Data("Le caf".utf8) + Data([0x8F, 0xAB, 0xB1]) + Data(".".utf8)
        XCTAssertNil(TextFileDecoder.strictlyDecodedText(bytes, in: try encoding("euc-jp")))
        XCTAssertThrowsError(try decode(Array(bytes), chosen: "euc-jp"))
    }

    /// ISO-2022-JP's half-width katakana, after ESC ( I as Windows writes
    /// mail, are read (review of October 24, item 6): 0x31 there is "ｱ".
    func testISO2022JPHalfWidthKatakanaAreRead() throws {
        let katakana: [UInt8] = [0x41, 0x1B, 0x28, 0x49, 0x31, 0x32, 0x1B, 0x28, 0x42, 0x42]
        XCTAssertEqual(TextFileDecoder.strictlyDecodedText(Data(katakana), in: try encoding("iso-2022-jp")), "AｱｲB")
        // A byte half-width katakana does not have, and a file that ends among them, are refused.
        XCTAssertNil(TextFileDecoder.strictlyDecodedText(Data([0x1B, 0x28, 0x49, 0x60, 0x1B, 0x28, 0x42]), in: try encoding("iso-2022-jp")))
        XCTAssertFalse(TextEncodingByteGrammar.isWellFormedISO2022JP(Data([0x1B, 0x28, 0x49, 0x31]), requiringAShift: false))
    }

    /// Valid text in an encoding with two codes for one character is read,
    /// though Foundation writes it back with the other code: Windows' CP932
    /// writes the surname kanji 髙 and 﨑, and the small Roman numeral one,
    /// as IBM's extensions (0xFB 0xFC, 0xFA 0xB1, 0xFA 0x40), and Big5 has
    /// the bopomofo letter ㄆ at 0xA3 0x75. A rule asking the text to write
    /// back to the same bytes would refuse these.
    func testValidTextWithTwoCodesForOneCharacterIsRead() throws {
        let cases: [(identifier: String, bytes: [UInt8], text: String)] = [
            ("cp932", [0xFB, 0xFC], "髙"),
            ("cp932", [0xFA, 0xB1], "﨑"),
            ("cp932", [0xFA, 0x40], "ⅰ"),
            ("big5", [0xA3, 0x75], "ㄆ"),
        ]
        for (identifier, bytes, text) in cases {
            XCTAssertEqual(try decode(bytes, chosen: identifier).text, text, identifier)
        }
    }

    /// An identifier this TextMouth does not know is refused by name, never
    /// read by the fallback.
    func testAnUnknownChoiceIsRefusedByName() {
        XCTAssertThrowsError(try decode([0x41], chosen: "x-cp1999")) { error in
            XCTAssertEqual(error as? TextEncodingError, .unknownChosenEncoding(file: "Fixture.txt", identifier: "x-cp1999"))
        }
    }

    /// What a listener, or the log, hears of a refused choice.
    func testTheRefusalsSayWhatHappened() {
        XCTAssertEqual(
            TextEncodingError.invalidForChosenEncoding(file: "Ledger.txt", encoding: "Shift JIS (Japanese)").errorDescription,
            "The file “Ledger.txt” can't be read as Shift JIS (Japanese): it holds bytes that are not valid in that encoding."
        )
        XCTAssertEqual(
            TextEncodingError.unknownChosenEncoding(file: "Ledger.txt", identifier: "x-cp1999").errorDescription,
            "The file “Ledger.txt” is set to be read as “x-cp1999”, a text encoding this version of TextMouth can't read. "
                + "Choose another in Book Information."
        )
    }

    // MARK: - Every Encoding

    /// Every encoding of the catalog, and UTF-8, reads strictly the text it
    /// writes: each fixture paragraph in each encoding it is saved in.
    func testEveryEncodingReadsTheTextItWritesStrictly() throws {
        var checked = 0
        for paragraph in TextEncodingFixtures.paragraphs {
            for name in paragraph.encodings + [TextFileDecoder.utf8Identifier] {
                guard let encoding = TextFileDecoder.encoding(forLabel: name) else { continue }
                let file = try TextEncodingFixtures.file(paragraph.text, inEncodingNamed: name)
                XCTAssertEqual(
                    TextFileDecoder.strictlyDecodedText(file.bytes, in: encoding), file.text,
                    "\(paragraph.language) in \(name)"
                )
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 40, "the fixtures cover the catalog's encodings")
    }

    /// A GB 18030 character of four bytes ("¥", 0x81 0x30 0x84 0x36) is read
    /// as one character.
    func testAFourByteGB18030CharacterIsRead() throws {
        let gb18030 = try encoding("gb18030")
        let bytes = try XCTUnwrap("¥ and 中".data(using: gb18030, allowLossyConversion: false))
        XCTAssertTrue(bytes.starts(with: [0x81, 0x30, 0x84, 0x36]), "\(Array(bytes))")
        XCTAssertEqual(TextFileDecoder.strictlyDecodedText(bytes, in: gb18030), "¥ and 中")
    }

    /// ISO-2022-JP, chosen, reads a well formed file, and a file of plain
    /// ASCII, which needs no shift to be well formed; the guesser still asks
    /// for one, since plain ASCII reads alike in every encoding.
    func testISO2022JPChosenReadsWellFormedFilesWithOrWithoutAShift() throws {
        let jis = try encoding("iso-2022-jp")
        // "安" between ESC $ B and ESC ( B.
        let kanji: [UInt8] = [0x1B, 0x24, 0x42, 0x30, 0x42, 0x1B, 0x28, 0x42]
        XCTAssertEqual(TextFileDecoder.strictlyDecodedText(Data(kanji), in: jis), "安")
        XCTAssertEqual(TextFileDecoder.strictlyDecodedText(Data("Plain".utf8), in: jis), "Plain")

        XCTAssertTrue(TextEncodingByteGrammar.isWellFormedISO2022JP(Data(kanji), requiringAShift: true))
        XCTAssertFalse(TextEncodingByteGrammar.isWellFormedISO2022JP(Data("Plain".utf8), requiringAShift: true))
        XCTAssertTrue(TextEncodingByteGrammar.isWellFormedISO2022JP(Data("Plain".utf8), requiringAShift: false))
        // A file that ends inside JIS X 0208 is cut off.
        XCTAssertFalse(TextEncodingByteGrammar.isWellFormedISO2022JP(Data(kanji.dropLast(3)), requiringAShift: false))
    }

    /// Every multi-byte encoding of the catalog has a grammar, so none is
    /// read by Foundation's lenient reader alone; an encoding of one byte to
    /// a character needs none.
    func testEveryMultiByteEncodingOfTheCatalogHasAGrammar() {
        for entry in TextEncodingCatalog.entries {
            XCTAssertEqual(TextEncodingByteGrammar.of(entry.encoding) != nil, isMultiByte(entry), entry.identifier)
        }
        // The grammars name only identifiers the catalog has.
        let grammarIdentifiers = TextEncodingByteGrammar.grammarsByIdentifier.flatMap(\.identifiers)
        for identifier in grammarIdentifiers {
            XCTAssertNotNil(TextEncodingCatalog.entry(forIdentifier: identifier), identifier)
        }
    }

    /// Whether the catalog's `entry` makes characters of more than one byte,
    /// as Foundation reads it: some byte above ASCII reads as nothing alone,
    /// but as one character with a byte after it. (A byte an encoding of one
    /// byte to a character leaves undefined reads as nothing with any byte
    /// after it too.) ISO-2022-JP, whose characters are pairs of ASCII bytes
    /// after an escape sequence, is one as well.
    private func isMultiByte(_ entry: TextEncodingCatalog.Entry) -> Bool {
        if entry.isSevenBit { return true }
        return (0x80...0xFF).contains { lead in
            String(data: Data([UInt8(lead)]), encoding: entry.encoding) == nil
                && (0x40...0xFE).contains { trail in
                    String(data: Data([UInt8(lead), UInt8(trail)]), encoding: entry.encoding)?.unicodeScalars.count == 1
                }
        }
    }
}
