import XCTest
@testable import TextMouth

/// The decoder behind every plain-text, Markdown, and HTML book: which
/// encoding each kind of file is read in and what it reports, how the text
/// is finished, how a file that cannot be read is explained, and when a
/// guess is logged. Fixtures are written as bytes, so each encoding's
/// expectation can be checked by eye.
final class TextFileDecoderTests: XCTestCase {

    // MARK: - Fixtures

    /// "Aé“": an ASCII letter, a Latin 1 letter, and a quotation mark that
    /// only Windows-1252 among the single-byte encodings has.
    private static let sample = "Aé“"

    /// `sample` in each encoding a byte-order mark can name.
    private static let sampleUTF8: [UInt8] = [0x41, 0xC3, 0xA9, 0xE2, 0x80, 0x9C]
    private static let sampleUTF16LE: [UInt8] = [0x41, 0x00, 0xE9, 0x00, 0x1C, 0x20]
    private static let sampleUTF16BE: [UInt8] = [0x00, 0x41, 0x00, 0xE9, 0x20, 0x1C]
    private static let sampleUTF32LE: [UInt8] = [0x41, 0, 0, 0, 0xE9, 0, 0, 0, 0x1C, 0x20, 0, 0]
    private static let sampleUTF32BE: [UInt8] = [0, 0, 0, 0x41, 0, 0, 0, 0xE9, 0, 0, 0x20, 0x1C]

    /// "Café “quoted” – 1€" in Windows-1252: é is 0xE9, the curly quotation
    /// marks 0x93 and 0x94, the en dash 0x96, and the euro sign 0x80.
    private static let windows1252Bytes: [UInt8] = Array("Caf".utf8) + [0xE9, 0x20, 0x93]
        + Array("quoted".utf8) + [0x94, 0x20, 0x96, 0x20, 0x31, 0x80]
    private static let windows1252Text = "Café “quoted” – 1€"

    /// UTF-8 text holding one stray byte, 0xE9 ("é" in Windows-1252, which
    /// can never stand alone in UTF-8), and the fallback's reading of it:
    /// every byte one character, so each UTF-8 letter reads as two.
    private static let strayByteBytes: [UInt8] = Array("Naïve café, ".utf8) + [0xE9] + Array(" fin".utf8)
    private static let strayByteText = "NaÃ¯ve cafÃ©, é fin"

    /// Decode `bytes` as a file of `format` named "Fixture" with the
    /// format's first extension ("Fixture.html").
    private func decode(_ bytes: [UInt8], format: BookFormat = .txt) throws -> DecodedText {
        try TextFileDecoder.decode(Data(bytes), fileName: Self.fileName(for: format), format: format)
    }

    /// The name `decode(_:format:)` gives a file of `format`.
    private static func fileName(for format: BookFormat) -> String {
        "Fixture.\(format.fileExtensions[0])"
    }

    /// An HTML file with `head` in its head and `body` (bytes in whatever
    /// encoding the test needs) as its one paragraph.
    private static func html(head: String, body: [UInt8]) -> [UInt8] {
        Array("<html><head>\(head)<title>Fixture</title></head><body><p>".utf8)
            + body + Array("</p></body></html>".utf8)
    }

    // MARK: - Byte-Order Marks

    /// Each byte-order mark names its encoding, and the mark itself never
    /// reaches the text.
    func testEachByteOrderMarkNamesItsEncodingAndIsRemoved() throws {
        let marked: [(bytes: [UInt8], encoding: String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF] + Self.sampleUTF8, .utf8),
            ([0xFF, 0xFE] + Self.sampleUTF16LE, .utf16LittleEndian),
            ([0xFE, 0xFF] + Self.sampleUTF16BE, .utf16BigEndian),
            ([0xFF, 0xFE, 0x00, 0x00] + Self.sampleUTF32LE, .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF] + Self.sampleUTF32BE, .utf32BigEndian),
        ]
        for (bytes, encoding) in marked {
            XCTAssertEqual(
                try decode(bytes),
                DecodedText(text: Self.sample, encoding: encoding, basis: .byteOrderMark),
                TextFileDecoder.name(of: encoding)
            )
        }
    }

    /// A second byte-order mark some tools write after the first is removed
    /// too, so the text still begins with its first word; a U+FEFF inside
    /// the text is a character of it and stays.
    func testEveryLeadingByteOrderMarkIsRemovedAndInnerOnesStay() throws {
        XCTAssertEqual(try decode([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x41]).text, "A")
        XCTAssertEqual(try decode([0xFF, 0xFE, 0xFF, 0xFE, 0x41, 0x00]).text, "A")
        XCTAssertEqual(try decode([0xEF, 0xBB, 0xBF, 0x41, 0xEF, 0xBB, 0xBF, 0x42]).text, "A\u{FEFF}B")
    }

    /// A file holding only a byte-order mark, or nothing, is empty text.
    func testEmptyFilesDecodeToEmptyText() throws {
        XCTAssertEqual(try decode([]), DecodedText(text: "", encoding: .utf8, basis: .validUTF8))
        XCTAssertEqual(try decode([0xEF, 0xBB, 0xBF]), DecodedText(text: "", encoding: .utf8, basis: .byteOrderMark))
        XCTAssertEqual(
            try decode([0xFF, 0xFE]),
            DecodedText(text: "", encoding: .utf16LittleEndian, basis: .byteOrderMark)
        )
    }

    /// Bytes after a UTF-16 or UTF-32 mark that are not valid in its
    /// encoding are reported, never read by a guess: an odd byte at the end
    /// (which Foundation would silently drop), half of a surrogate pair,
    /// and a code point beyond Unicode.
    func testInvalidBytesAfterAUTF16OrUTF32MarkReportTheFileAsDamaged() {
        let damaged: [(bytes: [UInt8], encoding: String)] = [
            ([0xFF, 0xFE, 0x41, 0x00, 0x42], "UTF-16LE"),
            ([0xFE, 0xFF, 0x00, 0x41, 0xD8, 0x3D], "UTF-16BE"),
            ([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00], "UTF-32LE"),
            ([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x11, 0x00, 0x00], "UTF-32BE"),
        ]
        for (bytes, encoding) in damaged {
            XCTAssertThrowsError(try decode(bytes), encoding) { error in
                XCTAssertEqual(
                    error as? TextEncodingError,
                    .invalidForMarkedEncoding(file: "Fixture.txt", encoding: encoding)
                )
            }
        }
    }

    /// Bytes after a UTF-8 mark that are not valid UTF-8 are read by the
    /// fallback, like any other broken UTF-8, and the mark's own bytes are
    /// not read as "ï»¿".
    func testInvalidUTF8AfterAUTF8MarkIsReadByTheFallback() throws {
        XCTAssertEqual(
            try decode([0xEF, 0xBB, 0xBF, 0x41, 0xE9]),
            DecodedText(text: "Aé", encoding: .windowsCP1252, basis: .fallback)
        )
    }

    // MARK: - UTF-16 Without a Byte-Order Mark

    /// UTF-16 written without a mark is read as UTF-16, in its byte order.
    /// ASCII-only UTF-16 is also valid UTF-8, where it would read as a NUL
    /// after every letter, so the zero bytes are looked at first.
    func testUTF16WithoutAByteOrderMarkIsRecognizedByItsZeroBytes() throws {
        XCTAssertEqual(
            try decode(Self.sampleUTF16LE),
            DecodedText(text: Self.sample, encoding: .utf16LittleEndian, basis: .unmarkedUTF16)
        )
        XCTAssertEqual(
            try decode(Self.sampleUTF16BE),
            DecodedText(text: Self.sample, encoding: .utf16BigEndian, basis: .unmarkedUTF16)
        )
        let asciiOnly: [UInt8] = [0x48, 0x00, 0x69, 0x00, 0x21, 0x00]
        XCTAssertNotNil(String(data: Data(asciiOnly), encoding: .utf8))
        XCTAssertEqual(try decode(asciiOnly).text, "Hi!")
    }

    /// Zero bytes that do not show UTF-16 leave the bytes to UTF-8, which
    /// keeps a NUL as U+0000: half the code units or fewer with a zero high
    /// byte, a NUL code unit, zeros on both sides of the units, or a length
    /// that is not a whole number of code units.
    func testZeroBytesThatDoNotShowUTF16LeaveTheBytesToUTF8() throws {
        let notUTF16: [[UInt8]] = [
            [0x41, 0x00, 0x42, 0x43],
            [0x00, 0x00, 0x41, 0x00],
            [0x41, 0x00, 0x00, 0x42],
            [0x41, 0x00, 0x42, 0x00, 0x43],
        ]
        for bytes in notUTF16 {
            XCTAssertNil(TextFileDecoder.unmarkedUTF16Encoding(of: Data(bytes)), "\(bytes)")
            XCTAssertEqual(
                try decode(bytes),
                DecodedText(text: String(decoding: bytes, as: UTF8.self), encoding: .utf8, basis: .validUTF8)
            )
        }
    }

    // MARK: - UTF-8

    /// Valid UTF-8 is UTF-8, every character kept, a NUL included.
    func testValidUTF8IsReadAsUTF8() throws {
        XCTAssertEqual(try decode(Self.sampleUTF8), DecodedText(text: Self.sample, encoding: .utf8, basis: .validUTF8))
        XCTAssertEqual(try decode([0x41, 0x00, 0x42]).text, "A\u{0}B")
    }

    // MARK: - The Windows-1252 Fallback

    /// Windows-1252 text is read by the fallback, curly quotation marks,
    /// dash, and euro sign included.
    func testWindows1252TextIsReadByTheFallback() throws {
        let decoded = try decode(Self.windows1252Bytes)
        XCTAssertEqual(decoded, DecodedText(text: Self.windows1252Text, encoding: .windowsCP1252, basis: .fallback))
        XCTAssertTrue(decoded.usedFallback)
    }

    /// ISO Latin 1 text reads correctly through the Windows-1252 fallback,
    /// which shares every Latin 1 character from 0xA0 up.
    func testLatin1TextIsReadByTheFallback() throws {
        let latin1: [UInt8] = [0xA9, 0x20, 0xF1, 0x20, 0xDF, 0x20, 0xFF, 0x20, 0xAB, 0x42, 0xBB, 0x20, 0xA3, 0x35]
        XCTAssertEqual(
            try decode(latin1),
            DecodedText(text: "© ñ ß ÿ «B» £5", encoding: .windowsCP1252, basis: .fallback)
        )
    }

    /// A stray byte in otherwise UTF-8 text sends the whole file to the
    /// fallback, which reads every byte as one character: nothing is
    /// dropped or replaced, though the UTF-8 letters read as two characters
    /// each.
    func testInvalidByteInUTF8TextKeepsEveryByte() throws {
        let decoded = try decode(Self.strayByteBytes)
        XCTAssertEqual(decoded, DecodedText(text: Self.strayByteText, encoding: .windowsCP1252, basis: .fallback))
        XCTAssertEqual(decoded.text.unicodeScalars.count, Self.strayByteBytes.count)
    }

    /// Every byte has a Windows-1252 character: Foundation's for the bytes
    /// Windows defines, and the C1 control of the same value for the five it
    /// leaves undefined, where Foundation refuses the whole file.
    func testWindows1252GivesEveryByteACharacter() {
        let undefined: Set<UInt8> = [0x81, 0x8D, 0x8F, 0x90, 0x9D]
        for value in 0...255 {
            let byte = UInt8(value)
            let text = TextFileDecoder.windows1252Text(Data([byte]))
            if undefined.contains(byte) {
                XCTAssertNil(String(data: Data([byte]), encoding: .windowsCP1252))
                XCTAssertEqual(text.unicodeScalars.map(\.value), [UInt32(byte)], "byte \(byte)")
            } else {
                XCTAssertEqual(text, String(data: Data([byte]), encoding: .windowsCP1252), "byte \(byte)")
            }
        }
        XCTAssertEqual(
            try decode([0xFF, 0x81, 0x8D, 0x8F, 0x90, 0x9D]).text,
            "ÿ\u{81}\u{8D}\u{8F}\u{90}\u{9D}"
        )
    }

    // MARK: - Declared Encodings

    /// An HTML file whose bytes are not UTF-8 is read in the encoding its
    /// meta element declares, which is reported as the basis, not the
    /// fallback.
    func testHTMLMetaCharsetIsReadWhenTheBytesAreNotUTF8() throws {
        let decoded = try decode(
            Self.html(head: "<meta charset=\"windows-1252\">", body: Self.windows1252Bytes), format: .html
        )
        XCTAssertTrue(decoded.text.contains("<p>\(Self.windows1252Text)</p>"), decoded.text)
        XCTAssertEqual(decoded.encoding, .windowsCP1252)
        XCTAssertEqual(decoded.basis, .declaration(label: "windows-1252"))
        XCTAssertFalse(decoded.usedFallback)
    }

    /// A Content-Type meta element and an XML declaration are read too.
    /// ISO Latin 1 is read as Windows-1252, as the HTML standard reads it,
    /// so the curly quotation marks Windows writes in such files read as
    /// quotation marks rather than invisible control characters.
    func testContentTypeAndXMLDeclarationsAreRead() throws {
        let body: [UInt8] = [0x93] + Array("Hi".utf8) + [0x94]
        let contentType = try decode(Self.html(
            head: "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=iso-8859-1\">", body: body
        ), format: .html)
        let xml = try decode(
            Array("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n".utf8) + Self.html(head: "", body: body),
            format: .html
        )
        for (decoded, label) in [(contentType, "iso-8859-1"), (xml, "ISO-8859-1")] {
            XCTAssertTrue(decoded.text.contains("<p>“Hi”</p>"), decoded.text)
            XCTAssertEqual(decoded.encoding, .windowsCP1252)
            XCTAssertEqual(decoded.basis, .declaration(label: label))
        }
    }

    /// Declarations are found in the spellings HTML and XML allow: any
    /// letter case, single, double, or no quotation marks, attributes in any
    /// order. The XML declaration speaks first; a commented-out declaration
    /// and one past the first 1024 bytes do not count.
    func testDeclarationsAreFoundInEverySpelling() {
        let labels: [(markup: String, label: String?)] = [
            ("<meta charset=\"windows-1252\">", "windows-1252"),
            ("<META CHARSET='Windows-1252'/>", "Windows-1252"),
            ("<meta charset=koi8-r>", "koi8-r"),
            ("<meta content=\"text/html;charset=iso-8859-2\" http-equiv=\"content-type\">", "iso-8859-2"),
            ("<meta http-equiv='Content-Type' content='text/html; charset=\"latin1\"'>", "latin1"),
            ("<?xml version='1.0' encoding='windows-1250'?><meta charset=\"koi8-r\">", "windows-1250"),
            ("<!-- <meta charset=\"x-klingon\"> --><meta charset=\"cp1252\">", "cp1252"),
            ("<meta name=\"description\" content=\"A guide\"><p>charset=utf-8</p>", nil),
            ("<!-- <meta charset=\"cp1252\">", nil),
            (String(repeating: " ", count: TextFileDecoder.declarationScanLength) + "<meta charset=\"cp1252\">", nil),
            ("<html><head><title>No declaration</title></head></html>", nil),
        ]
        for (markup, label) in labels {
            XCTAssertEqual(TextFileDecoder.declaredEncodingLabel(in: Data(markup.utf8)), label, markup)
        }
    }

    /// An encoding other than Windows-1252 is read as declared.
    func testOtherDeclaredEncodingsAreReadAsDeclared() throws {
        // "あ" in Shift_JIS is 0x82 0xA0, which can never be UTF-8.
        let decoded = try decode(Self.html(head: "<meta charset=\"Shift_JIS\">", body: [0x82, 0xA0]), format: .html)
        XCTAssertTrue(decoded.text.contains("<p>あ</p>"), decoded.text)
        XCTAssertEqual(TextFileDecoder.name(of: decoded.encoding), "shift_jis")
        XCTAssertEqual(decoded.basis, .declaration(label: "Shift_JIS"))
    }

    /// A declared encoding TextMouth does not know, or one the bytes are not
    /// valid in, is reported with the file and the declaration's label. The
    /// file says what it is, so it is never guessed past.
    func testDeclaredEncodingsThatCannotBeReadAreReported() {
        let unknown = Self.html(head: "<meta charset=\"x-klingon\">", body: [0xE9])
        XCTAssertThrowsError(try decode(unknown, format: .html)) { error in
            XCTAssertEqual(
                error as? TextEncodingError,
                .unsupportedDeclaredEncoding(file: "Fixture.html", label: "x-klingon")
            )
        }
        // 0xFF begins no character in Shift_JIS, nor in UTF-8.
        let invalid = Self.html(head: "<meta charset=\"shift_jis\">", body: [0xFF])
        XCTAssertThrowsError(try decode(invalid, format: .html)) { error in
            XCTAssertEqual(
                error as? TextEncodingError,
                .invalidForDeclaredEncoding(file: "Fixture.html", label: "shift_jis")
            )
        }
    }

    /// A declaration naming a Unicode encoding cannot explain bytes that
    /// already failed UTF-8 (and a declaration readable as ASCII cannot
    /// truly mean UTF-16), so the fallback reads them.
    func testDeclaredUnicodeEncodingsLeaveBrokenBytesToTheFallback() throws {
        for label in ["utf-8", "UTF-16", "utf-16le", "utf-32"] {
            let decoded = try decode(
                Self.html(head: "<meta charset=\"\(label)\">", body: Self.windows1252Bytes), format: .html
            )
            XCTAssertEqual(decoded.basis, .fallback, label)
            XCTAssertTrue(decoded.text.contains(Self.windows1252Text), label)
        }
    }

    /// Valid UTF-8 is read as UTF-8 even when the file still declares the
    /// encoding it was converted from.
    func testValidUTF8IsReadAsUTF8UnderAStaleDeclaration() throws {
        let decoded = try decode(
            Self.html(head: "<meta charset=\"windows-1252\">", body: Self.sampleUTF8), format: .html
        )
        XCTAssertTrue(decoded.text.contains("<p>\(Self.sample)</p>"), decoded.text)
        XCTAssertEqual(decoded.basis, .validUTF8)
    }

    /// Only an HTML book's declarations are read: in a plain-text or
    /// Markdown book the same characters are words of the text.
    func testOnlyHTMLDeclarationsAreRead() throws {
        let bytes = Self.html(head: "<meta charset=\"x-klingon\">", body: Self.windows1252Bytes)
        for format in [BookFormat.txt, .markdown] {
            let decoded = try decode(bytes, format: format)
            XCTAssertEqual(decoded.basis, .fallback, format.rawValue)
        }
    }

    /// A byte-order mark names the encoding whatever the file declares, as
    /// in the HTML standard: the declaration is not even read.
    func testByteOrderMarkOverrulesADeclaration() throws {
        let source = "<meta charset=\"x-klingon\"><p>\(Self.sample)</p>"
        let utf16Body = try XCTUnwrap(source.data(using: .utf16LittleEndian))
        let utf16 = [0xFF, 0xFE] + Array(utf16Body)
        XCTAssertEqual(
            try decode(utf16, format: .html),
            DecodedText(text: source, encoding: .utf16LittleEndian, basis: .byteOrderMark)
        )
        let brokenUTF8 = [0xEF, 0xBB, 0xBF] + Self.html(head: "<meta charset=\"x-klingon\">", body: [0xE9])
        XCTAssertEqual(try decode(brokenUTF8, format: .html).basis, .fallback)
    }

    // MARK: - Line Endings

    /// CR LF and a lone CR each become one LF, wherever they stand: a lone
    /// CR inside a line ends it, LF CR is two line endings, and so is
    /// CR CR LF. Text without a CR is returned unchanged.
    func testLineEndingsBecomeLineFeeds() {
        let cases: [(text: String, normalized: String)] = [
            ("One\r\nTwo", "One\nTwo"),
            ("First half\rsecond half", "First half\nsecond half"),
            ("Mac\rlines\r", "Mac\nlines\n"),
            ("a\n\rb", "a\n\nb"),
            ("a\r\r\nb", "a\n\nb"),
            ("\r\n\r\n", "\n\n"),
            ("é\r\n🙂\re\u{301}", "é\n🙂\ne\u{301}"),
            ("No carriage returns\nhere", "No carriage returns\nhere"),
            ("", ""),
        ]
        for (text, normalized) in cases {
            XCTAssertEqual(TextFileDecoder.normalizingLineEndings(text), normalized, text.debugDescription)
        }
    }

    /// The characters some readers break lines at but no file ends its lines
    /// with (VT, FF, NEL, LS, and PS) are left to those readers.
    func testOtherLineSeparatorsAreLeftAsTheyAre() {
        let text = "a\u{0B}b\u{0C}c\u{85}d\u{2028}e\u{2029}f"
        XCTAssertEqual(TextFileDecoder.normalizingLineEndings(text), text)
    }

    /// Decoded text has LF line endings in every encoding and whatever
    /// decided it.
    func testDecodedTextHasLineFeedEndingsInEveryEncoding() throws {
        let source = "One\r\nTwo\rThree\n"
        let utf16LE = try XCTUnwrap(source.data(using: .utf16LittleEndian))
        let utf16BE = try XCTUnwrap(source.data(using: .utf16BigEndian))
        let encodings: [(bytes: [UInt8], basis: DecodedText.Basis)] = [
            (Array(source.utf8), .validUTF8),
            ([0xFF, 0xFE] + Array(utf16LE), .byteOrderMark),
            (Array(utf16BE), .unmarkedUTF16),
            (Array(source.utf8) + [0xE9], .fallback),
        ]
        for (bytes, basis) in encodings {
            let decoded = try decode(bytes)
            XCTAssertEqual(decoded.basis, basis)
            XCTAssertTrue(decoded.text.hasPrefix("One\nTwo\nThree\n"), decoded.text.debugDescription)
        }
    }

    // MARK: - Error Descriptions

    /// Each message names the file and the encoding, says what is wrong,
    /// and says what to do, in the form damaged files are reported in.
    func testEncodingErrorDescriptionsNameTheFileAndTheEncoding() {
        XCTAssertEqual(
            TextEncodingError.unsupportedDeclaredEncoding(file: "Tides.html", label: "x-klingon").localizedDescription,
            "The file “Tides.html” declares the text encoding “x-klingon”, which TextMouth cannot read. "
                + "Save it as UTF-8 text, then import it again."
        )
        XCTAssertEqual(
            TextEncodingError.invalidForDeclaredEncoding(file: "Tides.html", label: "Shift_JIS").localizedDescription,
            "The file “Tides.html” declares the text encoding “Shift_JIS”, "
                + "but it holds bytes that are not valid in that encoding. "
                + "Save it as UTF-8 text, then import it again."
        )
        XCTAssertEqual(
            TextEncodingError.invalidForMarkedEncoding(file: "Tides.txt", encoding: "UTF-16LE").localizedDescription,
            "The file “Tides.txt” is damaged or incomplete: it begins with a UTF-16LE byte-order mark, "
                + "but the rest of it is not valid UTF-16LE text. "
                + "Get a fresh copy of the file, then import it again."
        )
    }

    /// Logs and messages name encodings by their standard names.
    func testEncodingNames() {
        let names: [(encoding: String.Encoding, name: String)] = [
            (.utf8, "UTF-8"), (.utf16LittleEndian, "UTF-16LE"), (.utf16BigEndian, "UTF-16BE"),
            (.utf32LittleEndian, "UTF-32LE"), (.utf32BigEndian, "UTF-32BE"), (.windowsCP1252, "Windows-1252"),
            (.isoLatin2, "iso-8859-2"),
        ]
        for (encoding, name) in names {
            XCTAssertEqual(TextFileDecoder.name(of: encoding), name)
        }
    }

    // MARK: - Logging the Fallback

    /// Write `bytes` to a new file named `fileName` in a directory removed
    /// when the test ends.
    private func temporaryFile(named fileName: String, holding bytes: [UInt8]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(fileName)
        try Data(bytes).write(to: file)
        return file
    }

    /// Reading a file by the fallback writes exactly one line naming the
    /// file and the encoding to the debug log, every time it is read.
    func testFallbackIsLoggedOnceForEachRead() throws {
        let name = "Fallback \(UUID().uuidString).txt"
        let file = try temporaryFile(named: name, holding: Self.windows1252Bytes)

        XCTAssertEqual(try TextFileDecoder.readText(at: file, format: .txt), Self.windows1252Text)
        let lines = debugLogLines(containing: "\(TextFileDecoder.fallbackLogTag): \(name):")
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.hasSuffix("TEXT_ENCODING_FALLBACK: \(name): decoded as Windows-1252") == true, "\(lines)")

        _ = try TextFileDecoder.readText(at: file, format: .txt)
        XCTAssertEqual(debugLogLines(containing: "\(TextFileDecoder.fallbackLogTag): \(name):").count, 2)
    }

    /// A stray byte in otherwise UTF-8 text is a fallback like any other:
    /// reading the file keeps every byte and logs the one line.
    func testStrayByteInUTF8FileIsKeptAndLogged() throws {
        let name = "Stray Byte \(UUID().uuidString).txt"
        let file = try temporaryFile(named: name, holding: Self.strayByteBytes)

        XCTAssertEqual(try TextFileDecoder.readText(at: file, format: .txt), Self.strayByteText)
        XCTAssertEqual(debugLogLines(containing: "TEXT_ENCODING_FALLBACK: \(name): decoded as Windows-1252").count, 1)
    }

    /// An encoding the bytes give evidence for is no guess, and is not
    /// logged: a byte-order mark, unmarked UTF-16, valid UTF-8, or an HTML
    /// declaration.
    func testEncodingsReadByEvidenceAreNotLogged() throws {
        let files: [(format: BookFormat, bytes: [UInt8])] = [
            (.txt, [0xFF, 0xFE] + Self.sampleUTF16LE),
            (.txt, Self.sampleUTF16BE),
            (.txt, Self.sampleUTF8),
            (.html, Self.html(head: "<meta charset=\"windows-1252\">", body: Self.windows1252Bytes)),
        ]
        for file in files {
            let name = "Evidence \(UUID().uuidString).\(file.format.fileExtensions[0])"
            _ = try TextFileDecoder.readText(at: temporaryFile(named: name, holding: file.bytes), format: file.format)
            XCTAssertEqual(debugLogLines(containing: name), [], name)
        }
    }

    /// A line break in a file's name becomes a space in its log entry, so
    /// the entry stays on one line.
    func testFallbackLogEntryStaysOnOneLine() throws {
        let id = UUID().uuidString
        let file = try temporaryFile(named: "Two\nLines \(id).txt", holding: Self.windows1252Bytes)
        _ = try TextFileDecoder.readText(at: file, format: .txt)
        XCTAssertEqual(debugLogLines(containing: "TEXT_ENCODING_FALLBACK: Two Lines \(id).txt: decoded as Windows-1252").count, 1)
    }
}
