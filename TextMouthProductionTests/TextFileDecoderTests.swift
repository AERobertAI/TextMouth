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
            DecodedText(text: Self.sample, encoding: .utf16LittleEndian, basis: .unmarkedUnicode)
        )
        XCTAssertEqual(
            try decode(Self.sampleUTF16BE),
            DecodedText(text: Self.sample, encoding: .utf16BigEndian, basis: .unmarkedUnicode)
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

    // MARK: - Unmarked UTF-16 in Other Scripts, and Unmarked UTF-32

    /// The four forms of Unicode text a file can hold with no byte-order mark
    /// that the decoder tells by the bytes alone, with the bytes of a text in
    /// each, written out here so no Foundation behavior decides the fixture.
    private enum UnmarkedForm: CaseIterable {
        case utf16LittleEndian, utf16BigEndian, utf32LittleEndian, utf32BigEndian

        /// The encoding the decoder is expected to report for it.
        var encoding: String.Encoding {
            switch self {
            case .utf16LittleEndian: return .utf16LittleEndian
            case .utf16BigEndian: return .utf16BigEndian
            case .utf32LittleEndian: return .utf32LittleEndian
            case .utf32BigEndian: return .utf32BigEndian
            }
        }

        /// `text` in this form, with no byte-order mark.
        func bytes(of text: String) -> [UInt8] {
            var result: [UInt8] = []
            switch self {
            case .utf16LittleEndian, .utf16BigEndian:
                for unit in text.utf16 {
                    let low = UInt8(unit & 0xFF)
                    let high = UInt8(unit >> 8)
                    result += self == .utf16LittleEndian ? [low, high] : [high, low]
                }
            case .utf32LittleEndian, .utf32BigEndian:
                for scalar in text.unicodeScalars {
                    let value: UInt32 = scalar.value
                    let little: [UInt8] = [
                        UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                        UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
                    ]
                    result += self == .utf32LittleEndian ? little : Array(little.reversed())
                }
            }
            return result
        }
    }

    /// Texts in the scripts a rule of `TextFileDecoder.unmarkedUnicode(in:)`
    /// is written for: each has more than a few words, a line ending, and
    /// the ASCII punctuation or digits real text has.
    private static let unmarkedSamples: [(script: String, text: String)] = [
        ("Russian", "Привет, мир! Это проверка текста в кодировке UTF-16 без метки порядка байтов.\nВторая строка — с тире и «кавычками».\n"),
        ("Greek", "Καλημέρα κόσμε. Αυτό είναι ένα δοκιμαστικό κείμενο χωρίς σήμανση σειράς byte.\nΔεύτερη γραμμή.\n"),
        ("Hebrew", "שלום עולם. זהו טקסט לבדיקה ללא סימן סדר בתים.\nשורה שנייה.\n"),
        ("Arabic", "مرحبا بالعالم. هذا نص تجريبي بدون علامة ترتيب البايتات.\nالسطر الثاني.\n"),
        ("Japanese", "吾輩は猫である。名前はまだ無い。\nどこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。\n2026年11月9日\n"),
        ("Chinese", "我们在2026年11月9日测试这段没有字节顺序标记的文字。\n第二行也是中文，包含标点符号。\n"),
        ("Korean", "안녕하세요. 이것은 바이트 순서 표시가 없는 UTF-16 텍스트입니다.\n두 번째 줄입니다.\n"),
        ("Russian with an emoji", "Привет 😀 мир, это строка с эмодзи и кириллицей.\n"),
        ("Latin", "Café au lait for the señor — naïve, “quoted” text.\n"),
        ("ASCII", "Hello world, plain ASCII in Unicode without a mark.\n"),
    ]

    /// Unmarked UTF-16 in an alphabet or in Chinese, Japanese, or Korean, and
    /// unmarked UTF-32, are read as Unicode in their byte order, the text
    /// whole and the encoding named. Every script is tried in all four forms,
    /// and every miss is reported at once.
    func testUnmarkedUnicodeInEveryScriptIsRecognizedByItsBytes() throws {
        var failures: [String] = []
        for (script, text) in Self.unmarkedSamples {
            for form in UnmarkedForm.allCases {
                let decoded = try decode(form.bytes(of: text))
                let expected = DecodedText(text: text, encoding: form.encoding, basis: .unmarkedUnicode)
                if decoded != expected {
                    failures.append(
                        "\(script) as \(form): read as \(TextFileDecoder.name(of: decoded.encoding)), \(decoded.basis), "
                            + "text \(decoded.text.prefix(24).debugDescription)…"
                    )
                }
            }
        }
        XCTAssertEqual(failures, [], "unmarked Unicode that was not recognized")
    }

    /// The least UTF-32 there is, two characters, is read; so is a single
    /// line of Cyrillic UTF-16 of the fewest letters the rule asks for.
    func testTheShortestUnmarkedTextsThatAreRecognized() throws {
        XCTAssertEqual(try decode(UnmarkedForm.utf32LittleEndian.bytes(of: "Hi")).text, "Hi")
        XCTAssertEqual(try decode(UnmarkedForm.utf32BigEndian.bytes(of: "Hi")).encoding, .utf32BigEndian)
        let eightLetters = "приветик"
        XCTAssertEqual(eightLetters.count, 8)
        XCTAssertEqual(try decode(UnmarkedForm.utf16LittleEndian.bytes(of: eightLetters)).text, eightLetters)
    }

    /// Bytes that are not Unicode text are not read as it, however much they
    /// look like it to a rule: each is left to the steps after, which read
    /// them as they always did. Every case says why it is not unmarked
    /// Unicode, and the cases that fail are all reported.
    func testBytesThatAreNotUnmarkedUnicodeAreNotReadAsIt() {
        let russian = "Привет, мир! Это проверка текста.\n"
        let russianLE = UnmarkedForm.utf16LittleEndian.bytes(of: russian)
        /// `text` with `scalar` in place of its fifth character, as UTF-16LE.
        func replacingAFifthCharacter(with scalar: UInt16) -> [UInt8] {
            var units = Array(russian.utf16)
            units[4] = scalar
            return units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        }
        // Fixed-width records: letters with a NUL at every eighth byte, all at odd positions.
        var paddedExport: [UInt8] = []
        for position in 0..<512 {
            let letter: Int = 0x41 + position % 26
            paddedExport.append(position % 8 == 7 ? 0 : UInt8(letter))
        }
        // Single characters, one to a line and then one to a word.
        var digitsPerLine: [UInt8] = []
        var digitsPerWord: [UInt8] = []
        for number in 1...40 {
            let digit = UInt8(0x30 + number % 10)
            digitsPerLine += [digit, 0x0A]
            digitsPerWord += [digit, 0x20]
        }
        let cases: [(why: String, bytes: [UInt8])] = [
            ("an odd number of bytes", Array(russianLE.dropLast())),
            ("a control character among the letters", replacingAFifthCharacter(with: 0x0001)),
            ("a private-use character among the letters", replacingAFifthCharacter(with: 0xE000)),
            ("half of a surrogate pair among the letters", replacingAFifthCharacter(with: 0xD800)),
            ("a noncharacter among the letters", replacingAFifthCharacter(with: 0xFFFF)),
            ("too few Cyrillic letters", UnmarkedForm.utf16LittleEndian.bytes(of: "Привет")),
            ("a NUL-padded export", paddedExport),
            ("a column of digits, one to a line", digitsPerLine),
            ("single characters and spaces", digitsPerWord),
            ("Russian in UTF-8", Array(russian.utf8)),
            ("sixty-four zero bytes", [UInt8](repeating: 0, count: 64)),
            ("UTF-32 with a control character", UnmarkedForm.utf32LittleEndian.bytes(of: "Привет\u{1}мир, мир")),
            ("UTF-32 beyond Unicode", [0x41, 0, 0, 0, 0x42, 0, 0x11, 0, 0x43, 0, 0, 0, 0x44, 0, 0, 0] as [UInt8]),
            ("UTF-32 of a single zero unit pair", [0, 0, 0, 0, 0, 0, 0, 0]),
        ]
        var failures: [String] = []
        for (why, bytes) in cases {
            if let read = TextFileDecoder.unmarkedUnicode(in: Data(bytes)) {
                failures.append("\(why): read as \(TextFileDecoder.name(of: read.encoding)), \(read.text.prefix(24).debugDescription)")
            }
        }
        XCTAssertEqual(failures, [], "bytes taken for unmarked Unicode that are not")
    }

    /// Text in 8-bit and double-byte encodings is not taken for unmarked
    /// Unicode: the same sentences as the recognized cases above, in every
    /// encoding they are written in that Foundation has, as the whole file
    /// and from each of many starts, with ends of 16, 17, 40, and 101 bytes
    /// after the start, since a window of a file is the likeliest thing to be
    /// misread.
    func testTextInOtherEncodingsIsNeverTakenForUnmarkedUnicode() {
        // The IANA names Core Foundation knows; one it lacks is left out.
        let encodings: [(script: String, names: [String])] = [
            ("Russian", ["utf-8", "windows-1251", "koi8-r", "ibm866"]),
            ("Greek", ["utf-8", "windows-1253", "iso-8859-7"]),
            ("Hebrew", ["utf-8", "windows-1255"]),
            ("Arabic", ["utf-8", "windows-1256"]),
            ("Japanese", ["utf-8", "shift_jis", "euc-jp", "iso-2022-jp", "windows-31j"]),
            ("Chinese", ["utf-8", "gbk", "gb18030", "big5"]),
            ("Korean", ["utf-8", "euc-kr"]),
            ("Latin", ["utf-8", "windows-1252", "macintosh", "iso-8859-1"]),
        ]
        var failures: [String] = []
        var windows = 0
        for (script, names) in encodings {
            guard let text = Self.unmarkedSamples.first(where: { $0.script == script })?.text else {
                XCTFail("no sample text for \(script)")
                continue
            }
            for name in names {
                guard let encoding = TextEncodingFixtures.encoding(named: name),
                      let data = String(repeating: TextEncodingFixtures.writable(text, in: encoding), count: 6)
                        .data(using: encoding) else { continue }
                for start in 0..<max(0, data.count - 16) {
                    // Short windows from every start; the rest of the file from every seventh.
                    var lengths: [Int] = [16, 17, 40, 101]
                    if start % 7 == 0 { lengths.append(data.count - start) }
                    for length in lengths where length >= 16 && start + length <= data.count {
                        windows += 1
                        if let read = TextFileDecoder.unmarkedUnicode(in: Data(data[start..<start + length])) {
                            failures.append("\(script) in \(name), bytes \(start)..<\(start + length): "
                                + "read as \(TextFileDecoder.name(of: read.encoding)) \(read.text.prefix(16).debugDescription)")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(windows, 5_000, "the sweep covered too little to prove anything")
        XCTAssertEqual(Array(failures.prefix(20)), [], "\(failures.count) of \(windows) windows were taken for unmarked Unicode")
    }

    /// TestData's text samples (plain text, Markdown, HTML, XML, and the
    /// subtitle, playlist, and braille formats) are never taken for unmarked
    /// Unicode, whole, nor in any of many windows of them: every prefix and
    /// suffix of a small file, and 400 windows of a large one such as
    /// pride.txt, from a fixed seed. Files with a NUL byte are not 8-bit
    /// text and are left out; the count of those swept is asserted so that
    /// a moved folder cannot empty the sweep.
    func testTheTextSamplesInTestDataAreNeverTakenForUnmarkedUnicode() throws {
        let testData = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestData", isDirectory: true)
        let textExtensions: Set<String> = [
            "txt", "md", "markdown", "html", "htm", "xhtml", "xml", "csv", "tsv", "srt", "vtt", "lrc", "m3u", "m3u8", "cue",
            "json", "xspf", "pls", "ttml", "opml", "ssml", "fb2", "dtbook", "brf", "brl", "pef", "eml", "mbox", "edl",
            "smil", "opf", "ncx",
        ]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: testData, includingPropertiesForKeys: [.isRegularFileKey]),
            "TestData cannot be listed at \(testData.path)"
        )
        var generator: UInt64 = 0x9E37_79B9_7F4A_7C15
        /// The next number of a fixed sequence, so a failure can be repeated.
        func next(below limit: Int) -> Int {
            generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(generator >> 33) % limit
        }
        var failures: [String] = []
        var files = 0
        var windows = 0
        for case let url as URL in enumerator where textExtensions.contains(url.pathExtension.lowercased()) {
            let data = try Data(contentsOf: url)
            guard !data.contains(0) else { continue }
            files += 1
            let name = url.lastPathComponent
            var ranges: [Range<Int>] = [0..<data.count]
            if data.count <= 2_048 {
                // Every prefix and every suffix of a small file.
                for end in 16..<max(16, data.count) { ranges.append(0..<end) }
                for start in 1..<max(1, data.count - 16) { ranges.append(start..<data.count) }
            } else {
                for _ in 0..<400 {
                    let length: Int = min(16 + next(below: 4_081), data.count - 1)
                    let start: Int = next(below: data.count - length)
                    ranges.append(start..<(start + length))
                }
            }
            for range in ranges where range.count >= 16 {
                windows += 1
                if let read = TextFileDecoder.unmarkedUnicode(in: Data(data[range])) {
                    failures.append("\(name) bytes \(range): read as \(TextFileDecoder.name(of: read.encoding)) \(read.text.prefix(16).debugDescription)")
                }
            }
            // The decoder as a whole, with the file as it is.
            if let decoded = try? TextFileDecoder.decode(data, fileName: name, format: .txt), decoded.basis == .unmarkedUnicode {
                failures.append("\(name) decoded as unmarked Unicode")
            }
        }
        XCTAssertGreaterThan(files, 20, "TestData holds too few text samples to prove anything (\(files))")
        XCTAssertEqual(Array(failures.prefix(20)), [], "\(failures.count) of \(windows) windows of \(files) files were taken for unmarked Unicode")
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
            (Array(utf16BE), .unmarkedUnicode),
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

    // MARK: - Guessing and Recording an Encoding (FMT16)

    /// The Russian sentence the encoding policy tests write in KOI8-R and
    /// Windows-1251.
    private static let russian = "Съешь же ещё этих мягких французских булок, да выпей чаю.\nПаром отходит в семь.\n"

    /// `text` as the bytes of a file in the encoding named `name`.
    private func bytes(of text: String, in name: String) throws -> [UInt8] {
        let encoding = try XCTUnwrap(TextEncodingFixtures.encoding(named: name), name)
        return Array(try XCTUnwrap(text.data(using: encoding, allowLossyConversion: false), name))
    }

    /// Decode `bytes` as a plain-text file under `policy`.
    private func decode(_ bytes: [UInt8], policy: TextFileDecoder.EncodingPolicy) throws -> DecodedText {
        try TextFileDecoder.decode(Data(bytes), fileName: "Fixture.txt", format: .txt, policy: policy)
    }

    /// Under the guessing policy, bytes that name no encoding are read in the
    /// encoding the guesser finds, which is the basis and is recorded.
    func testTheGuessingPolicyReadsBytesThatNameNoEncodingInTheGuessedOne() throws {
        let koi8 = try bytes(of: Self.russian, in: "koi8-r")
        let decoded = try decode(koi8, policy: .guess)
        XCTAssertEqual(decoded.text, Self.russian)
        XCTAssertEqual(decoded.basis, .guess)
        XCTAssertEqual(TextFileDecoder.name(of: decoded.encoding), "koi8-r")
        XCTAssertEqual(decoded.guessedEncodingIdentifier, "koi8-r")
        XCTAssertFalse(decoded.usedFallback)
    }

    /// The default policy reads the same bytes as it always did, as
    /// Windows-1252, and has nothing to record; so does a record that names
    /// no encoding of the catalog.
    func testThePolicyOfNoGuessReadsAsItAlwaysDid() throws {
        let koi8 = try bytes(of: Self.russian, in: "koi8-r")
        for policy in [TextFileDecoder.EncodingPolicy.fallback, .recorded("not-an-encoding")] {
            let decoded = try decode(koi8, policy: policy)
            XCTAssertEqual(decoded.basis, .fallback)
            XCTAssertEqual(decoded.encoding, .windowsCP1252)
            XCTAssertEqual(decoded.text, TextFileDecoder.windows1252Text(Data(koi8)))
            XCTAssertNil(decoded.guessedEncodingIdentifier)
        }
        // A call that names no policy has the same one.
        let plain = try TextFileDecoder.decode(Data(koi8), fileName: "Fixture.txt", format: .txt)
        XCTAssertEqual(plain.basis, .fallback)
    }

    /// Evidence in the bytes comes before a guess: a byte-order mark, valid
    /// UTF-8, unmarked UTF-16, and an HTML declaration are read as before.
    func testEvidenceInTheBytesComesBeforeAGuess() throws {
        XCTAssertEqual(try decode(Self.sampleUTF8, policy: .guess).basis, .validUTF8)
        XCTAssertEqual(try decode([0xFF, 0xFE] + Self.sampleUTF16LE, policy: .guess).basis, .byteOrderMark)
        XCTAssertEqual(try decode(Self.sampleUTF16BE, policy: .guess).basis, .unmarkedUnicode)
        let declared = try TextFileDecoder.decode(
            Data(Self.html(head: "<meta charset=\"windows-1252\">", body: Self.windows1252Bytes)),
            fileName: "Fixture.html", format: .html, policy: .guess
        )
        XCTAssertEqual(declared.basis, .declaration(label: "windows-1252"))
    }

    /// The 13 short files in TestData/format-samples/txt-encodings, decoded
    /// under the guessing policy as an import decodes them: UTF-8 and UTF-16
    /// by their evidence, the two Windows-1252 reads by the fallback, and
    /// the other nine as the text each holds, by a guess.
    func testEverySampleFileReadsRightUnderTheGuessingPolicy() throws {
        for sample in TextEncodingFixtures.sampleFiles {
            let bytes = try Data(contentsOf: formatSampleURL("txt-encodings/\(sample.name).txt"))
            let decoded = try TextFileDecoder.decode(bytes, fileName: "\(sample.name).txt", format: .txt, policy: .guess)
            XCTAssertEqual(decoded.text, sample.text, sample.name)
            XCTAssertEqual(decoded.basis, sample.basis, sample.name)
        }
    }

    /// Bytes Windows-1252 reads correctly are not guessed away from it, even
    /// under the guessing policy: they are read by the fallback.
    func testTheGuessingPolicyLeavesWindows1252TextToTheFallback() throws {
        let decoded = try decode(Self.windows1252Bytes, policy: .guess)
        XCTAssertEqual(decoded, DecodedText(text: Self.windows1252Text, encoding: .windowsCP1252, basis: .fallback))
    }

    /// A book that recorded its encoding is read in it, whatever a guess
    /// would say, and the same bytes read differently in another encoding.
    func testTheRecordedPolicyReadsInTheRecordedEncoding() throws {
        let koi8 = try bytes(of: Self.russian, in: "koi8-r")
        let asKOI8 = try decode(koi8, policy: .recorded("koi8-r"))
        XCTAssertEqual(asKOI8.text, Self.russian)
        XCTAssertEqual(asKOI8.basis, .recorded)
        XCTAssertNil(asKOI8.guessedEncodingIdentifier)

        // The record decides, not the bytes: a book recorded as Windows-1251 reads them that way.
        let asWindows1251 = try decode(koi8, policy: .recorded("windows-1251"))
        XCTAssertEqual(asWindows1251.basis, .recorded)
        XCTAssertEqual(asWindows1251.encoding, .windowsCP1251)
        XCTAssertEqual(asWindows1251.text, String(data: Data(koi8), encoding: .windowsCP1251))
        XCTAssertNotEqual(asWindows1251.text, Self.russian)

        // An identifier in any letter case is found, and Windows-1252 recorded reads as the fallback does.
        XCTAssertEqual(try decode(koi8, policy: .recorded("KOI8-R")).text, Self.russian)
        XCTAssertEqual(try decode(koi8, policy: .recorded("windows-1252")).text, TextFileDecoder.windows1252Text(Data(koi8)))
    }

    /// A record the bytes cannot be read in, or one TextMouth does not know,
    /// leaves the bytes to the fallback: a rebuild never fails where it did
    /// not, and never reads half a file in an encoding that does not fit.
    func testARecordTheBytesCannotBeReadInLeavesThemToTheFallback() throws {
        // 0x98 is undefined in Windows-1251.
        let undefined: [UInt8] = [0x41, 0x98, 0x42]
        XCTAssertNil(String(data: Data(undefined), encoding: .windowsCP1251))
        XCTAssertEqual(try decode(undefined, policy: .recorded("windows-1251")).basis, .fallback)
        XCTAssertEqual(try decode(undefined, policy: .recorded("x-klingon")).basis, .fallback)
        XCTAssertEqual(try decode(undefined, policy: .recorded("")).basis, .fallback)
    }

    /// A file in ISO-2022-JP is valid UTF-8, and so is read as ASCII with its
    /// escape sequences by every read that does not look for it, as it always
    /// was; the guessing policy, and the policy of a book that recorded the
    /// encoding, look for it before taking bytes for UTF-8, and read it as
    /// Japanese.
    func testAnISO2022JPFileIsFoundBeforeUTF8ByTheGuessingAndRecordedPolicies() throws {
        let japanese = "いろはにほへと ちりぬるを。\nフェリーは七時に出ます。\n"
        let bytes = Array(try XCTUnwrap(japanese.data(using: .iso2022JP)))
        XCTAssertNotNil(String(data: Data(bytes), encoding: .utf8))

        let guessed = try decode(bytes, policy: .guess)
        XCTAssertEqual(guessed.text, japanese)
        XCTAssertEqual(guessed.basis, .guess)
        XCTAssertEqual(guessed.guessedEncodingIdentifier, "iso-2022-jp")

        let recorded = try decode(bytes, policy: .recorded("iso-2022-jp"))
        XCTAssertEqual(recorded.text, japanese)
        XCTAssertEqual(recorded.basis, .recorded)

        // Every other read takes it for UTF-8 as it always did.
        let plain = try decode(bytes, policy: .fallback)
        XCTAssertEqual(plain.basis, .validUTF8)
        XCTAssertTrue(plain.text.contains("\u{1B}"))
        // So does a read under another encoding's record.
        XCTAssertEqual(try decode(bytes, policy: .recorded("windows-1251")).basis, .validUTF8)

        // A changed file that is no longer well formed ISO-2022-JP is left to the steps after,
        // not read by Foundation's lenient reader.
        XCTAssertEqual(try decode(bytes + [0xE9], policy: .recorded("iso-2022-jp")).basis, .fallback)
    }

    /// An HTML file that declares ISO-2022-JP is valid UTF-8, so its
    /// declaration was never reached: it read as ASCII with escape sequences
    /// in it, under every policy but the guessing one. It is now read in
    /// ISO-2022-JP by its declaration under the fallback, the policy of a
    /// book that recorded no encoding; a book that recorded one keeps it, and
    /// the guessing policy still finds it by its structure first.
    func testAnHTMLFileThatDeclaresISO2022JPIsReadInIt() throws {
        let japanese = "いろはにほへと ちりぬるを。\nフェリーは七時に出ます。\n"
        let body = Array(try XCTUnwrap(japanese.data(using: .iso2022JP)))
        for head in [
            "<meta charset=\"iso-2022-jp\">",
            "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=ISO-2022-JP\">",
        ] {
            let file = Data(Self.html(head: head, body: body))
            XCTAssertNotNil(String(data: file, encoding: .utf8), "\(head): the fixture is not valid UTF-8")

            // The policy of a book that recorded no encoding, which is the default.
            let decoded = try TextFileDecoder.decode(file, fileName: "Fixture.html", format: .html, policy: .fallback)
            XCTAssertTrue(decoded.text.contains(japanese), "\(head): \(decoded.text.debugDescription)")
            XCTAssertFalse(decoded.text.contains("\u{1B}"), "\(head): an escape sequence was read as text")
            XCTAssertEqual(decoded.encoding, .iso2022JP, head)
            XCTAssertEqual(decoded.basis, .declaration(label: head.contains("charset=ISO-2022-JP") ? "ISO-2022-JP" : "iso-2022-jp"), head)
            // The guessing policy finds it by its structure, as it did.
            let guessed = try TextFileDecoder.decode(file, fileName: "Fixture.html", format: .html, policy: .guess)
            XCTAssertEqual(guessed.basis, .guess, head)
            XCTAssertTrue(guessed.text.contains(japanese), head)
            // A book that recorded another encoding keeps it.
            let recorded = try TextFileDecoder.decode(
                file, fileName: "Fixture.html", format: .html, policy: .recorded("windows-1251")
            )
            XCTAssertEqual(recorded.basis, .validUTF8, "\(head): a recorded encoding was overruled")
        }
    }

    /// The declaration reads only what it can: a page with no escape in it
    /// is plain ASCII, whatever it declares; one whose ISO-2022-JP is
    /// truncated is left to UTF-8 as it was; a plain-text file has no
    /// declaration to read; and an HTML file that declares nothing is as before.
    func testADeclarationOfISO2022JPChangesNothingItCannotRead() throws {
        let japanese = "いろはにほへと\n"
        let body = Array(try XCTUnwrap(japanese.data(using: .iso2022JP)))
        let declared = "<meta charset=\"iso-2022-jp\">"

        let ascii = try TextFileDecoder.decode(
            Data(Self.html(head: declared, body: Array("plain words".utf8))),
            fileName: "Fixture.html", format: .html
        )
        XCTAssertEqual(ascii.basis, .validUTF8, "a page with no escape in it")

        // Cut off in the middle of the shift into JIS X 0208 (ESC $ B).
        let truncated = try TextFileDecoder.decode(
            Data(Self.html(head: declared, body: [0x1B, 0x24])), fileName: "Fixture.html", format: .html
        )
        XCTAssertEqual(truncated.basis, .validUTF8, "a truncated escape sequence")

        let plainText = try TextFileDecoder.decode(Data(body), fileName: "Fixture.txt", format: .txt)
        XCTAssertEqual(plainText.basis, .validUTF8, "a plain-text file has no declaration")

        let undeclared = try TextFileDecoder.decode(
            Data(Self.html(head: "", body: body)), fileName: "Fixture.html", format: .html
        )
        XCTAssertEqual(undeclared.basis, .validUTF8, "an HTML file that declares no encoding")
    }

    /// A book's policy is the encoding it recorded, or the fallback for a
    /// book that recorded none.
    func testABooksPolicyIsItsRecordedEncodingOrTheFallback() {
        XCTAssertEqual(TextFileDecoder.EncodingPolicy.forBook(recording: nil), .fallback)
        XCTAssertEqual(TextFileDecoder.EncodingPolicy.forBook(recording: "koi8-r"), .recorded("koi8-r"))
    }

    /// A guessed reading is finished like any other: line feeds for every
    /// line ending, and no byte-order mark.
    func testAGuessedReadingHasLineFeedEndings() throws {
        let crlf = try bytes(of: Self.russian.replacingOccurrences(of: "\n", with: "\r\n"), in: "windows-1251")
        let decoded = try decode(crlf, policy: .guess)
        XCTAssertEqual(decoded.basis, .guess)
        XCTAssertEqual(decoded.text, Self.russian)
    }

    // MARK: Logging a Guess

    /// Reading a file under the guessing policy writes exactly one line
    /// naming the file and the guessed encoding; a read under a book's record
    /// writes none, and is no fallback either.
    func testAGuessIsLoggedOnceAndARecordedReadNotAtAll() throws {
        let name = "Guess \(UUID().uuidString).txt"
        let file = try temporaryFile(named: name, holding: try bytes(of: Self.russian, in: "koi8-r"))

        let decoded = try TextFileDecoder.readDecodedText(at: file, format: .txt, policy: .guess)
        XCTAssertEqual(decoded.basis, .guess)
        let lines = debugLogLines(containing: "\(TextFileDecoder.guessLogTag): \(name):")
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.hasSuffix("TEXT_ENCODING_GUESS: \(name): read as koi8-r") == true, "\(lines)")

        _ = try TextFileDecoder.readText(at: file, format: .txt, policy: .recorded("koi8-r"))
        XCTAssertEqual(debugLogLines(containing: "\(TextFileDecoder.guessLogTag): \(name):").count, 1)
        XCTAssertEqual(debugLogLines(containing: "\(TextFileDecoder.fallbackLogTag): \(name):").count, 0)
    }
}
