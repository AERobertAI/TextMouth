import XCTest
@testable import TextMouth

/// Plain-text, Markdown, and HTML books read the same whatever encoding and
/// line endings their files are written with, along both reading paths: the
/// direct parsers (`BookParser`) and the Markdown cache an import writes.
/// Each fixture is written as bytes in every encoding the decoder reads and
/// with every common line ending, imported through the production path, and
/// read both ways.
final class TextEncodingFidelityTests: XCTestCase {

    // MARK: - Reading Both Ways

    /// The direct and cached readings of `bytes` imported as a book file
    /// named `fileName`: the parsers' reading of the package's copy of the
    /// file, and the reading of the content.md the import wrote.
    private func readings(
        of bytes: [UInt8],
        named fileName: String,
        format: BookFormat
    ) throws -> (direct: DocumentContent, cached: DocumentContent) {
        let book = try importBookFile(Data(bytes), named: fileName)
        XCTAssertEqual(book.cacheFormatVersion, MarkdownCacheService.currentCacheVersion, fileName)
        let direct = try BookParser.parse(url: URL(fileURLWithPath: book.filePath), format: format)
        let cached = try MarkdownCacheService.loadFromCache(for: book)
        return (direct, cached)
    }

    /// Assert that neither a byte-order mark nor a carriage return reached
    /// `chapter`'s text or any of its heading labels.
    private func assertNoMarkOrCarriageReturn(
        in chapter: Chapter?,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let chapter else { return }
        for text in [chapter.text] + chapter.headings.map(\.text) {
            XCTAssertFalse(text.unicodeScalars.contains("\u{FEFF}"), "byte-order mark; \(context)", file: file, line: line)
            XCTAssertFalse(text.unicodeScalars.contains("\r"), "carriage return; \(context)", file: file, line: line)
        }
    }

    // MARK: - Fixtures

    /// The fixtures' encodings write exactly the bytes their names promise:
    /// the mark, if any, and then the text, with no mark Foundation adds.
    func testFixtureEncodingsWriteExactlyTheirMarks() {
        let expected: [EncodedBookFixture.Encoding: [UInt8]] = [
            .utf8: [0x41],
            .utf8WithMark: [0xEF, 0xBB, 0xBF, 0x41],
            .utf16LEWithMark: [0xFF, 0xFE, 0x41, 0x00],
            .utf16BEWithMark: [0xFE, 0xFF, 0x00, 0x41],
            .utf32LEWithMark: [0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00],
            .utf32BEWithMark: [0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41],
            .utf16LE: [0x41, 0x00],
            .utf16BE: [0x00, 0x41],
            .windows1252: [0x41],
        ]
        for encoding in EncodedBookFixture.Encoding.allCases {
            XCTAssertEqual(encoding.bytes(of: "A"), expected[encoding], encoding.rawValue)
        }
        XCTAssertEqual(
            EncodedBookFixture.LineEnding.mixed.text(of: ["a", "b", "c", "d"]),
            "a\r\nb\nc\rd\r\n"
        )
    }

    // MARK: - Plain Text

    /// The acceptance case: one plain-text book, with an all-caps, an ATX,
    /// and a setext heading, written in every encoding and with LF, CR LF,
    /// CR, and mixed line endings, reads as one text with one heading list
    /// (level, label, and offset) on both paths. Lines wrapped by CR LF or
    /// CR join their paragraph, each setext underline is consumed below its
    /// heading, no byte-order mark reaches the text or a heading, and the
    /// decoder reports the encoding the bytes are written in.
    func testPlainTextReadsTheSameInEveryEncodingAndWithEveryLineEnding() throws {
        let reading = EncodedBookFixture.plainTextReading
        let headings = EncodedBookFixture.plainTextHeadings
        let offsets = headings.map { (reading as NSString).range(of: $0.text).location }
        for encoding in EncodedBookFixture.Encoding.allCases {
            for ending in EncodedBookFixture.LineEnding.allCases {
                let context = "\(encoding.rawValue), \(ending.rawValue) line endings"
                let source = ending.text(of: EncodedBookFixture.plainTextLines)
                let bytes = try XCTUnwrap(encoding.bytes(of: source), context)
                let (direct, cached) = try readings(of: bytes, named: "Canal Register.txt", format: .txt)

                let chapter = assertSamePlainTextReading(cached: cached, direct: direct, context: context)
                XCTAssertEqual(chapter?.text, reading, context)
                XCTAssertEqual(chapter?.headings.map(\.level), headings.map(\.level), context)
                XCTAssertEqual(chapter?.headings.map(\.text), headings.map(\.text), context)
                XCTAssertEqual(chapter?.headings.map(\.characterOffset), offsets, context)
                assertNoMarkOrCarriageReturn(in: chapter, context: context)

                let decoded = try TextFileDecoder.decode(Data(bytes), fileName: "Canal Register.txt", format: .txt)
                XCTAssertEqual(decoded.encoding, encoding.stringEncoding, context)
                XCTAssertEqual(decoded.basis, encoding.basis, context)
            }
        }
    }

    /// The shared plain-text fixture, which mixes every heading style,
    /// Markdown and HTML lookalikes, emoji, combining marks, and LF, CR LF,
    /// and CR line endings, reads as its documented reading on both paths in
    /// every Unicode encoding, marked or not.
    func testCombinedPlainTextFixtureReadsTheSameInEveryUnicodeEncoding() throws {
        for encoding in EncodedBookFixture.Encoding.allCases where encoding != .windows1252 {
            let bytes = try XCTUnwrap(encoding.bytes(of: PlainTextFixture.combined), encoding.rawValue)
            let (direct, cached) = try readings(of: bytes, named: "Combined Fixture.txt", format: .txt)
            let chapter = assertSamePlainTextReading(cached: cached, direct: direct, context: encoding.rawValue)
            XCTAssertEqual(chapter?.text, PlainTextFixture.combinedReading, encoding.rawValue)
            XCTAssertEqual(chapter?.headings.map(\.text), PlainTextFixture.combinedHeadings.map(\.text), encoding.rawValue)
            XCTAssertEqual(chapter?.headings.map(\.level), PlainTextFixture.combinedHeadings.map(\.level), encoding.rawValue)
        }
    }

    /// A real Project Gutenberg text, saved as UTF-8 with a byte-order mark
    /// and CR LF line endings, reads in paragraphs on both paths: the lines
    /// of its opening sentence join, where each used to be a paragraph of
    /// its own, and its chapter headings are still found.
    func testGutenbergTextWithByteOrderMarkAndCRLFReadsInParagraphs() throws {
        let source = try Data(contentsOf: requireFile("pride.txt"))
        XCTAssertTrue(source.starts(with: [0xEF, 0xBB, 0xBF]))
        XCTAssertTrue(source.contains(0x0D))

        let (direct, cached) = try readings(of: Array(source), named: "pride.txt", format: .txt)
        let chapter = try XCTUnwrap(assertSamePlainTextReading(cached: cached, direct: direct, context: "pride.txt"))
        XCTAssertTrue(chapter.text.contains(
            "\n\nIt is a truth universally acknowledged, that a single man in possession"
                + " of a good fortune must be in want of a wife.\n\n"
        ))
        XCTAssertTrue(chapter.headings.contains { $0.level == 2 && $0.text == "CHAPTER II." })
        assertNoMarkOrCarriageReturn(in: chapter, context: "pride.txt")
    }

    // MARK: - Markdown

    /// A Markdown book reads the same in every encoding and with every line
    /// ending, on both paths: a soft line break is still a space, and the
    /// lines of a fenced code block keep their line feeds.
    func testMarkdownReadsTheSameInEveryEncodingAndWithEveryLineEnding() throws {
        var reference: Chapter?
        for encoding in EncodedBookFixture.Encoding.allCases {
            for ending in EncodedBookFixture.LineEnding.allCases {
                let context = "\(encoding.rawValue), \(ending.rawValue) line endings"
                let bytes = try XCTUnwrap(encoding.bytes(of: ending.text(of: EncodedBookFixture.markdownLines)), context)
                let (direct, cached) = try readings(of: bytes, named: "Canal Register.md", format: .markdown)
                let chapter = try XCTUnwrap(assertSamePlainTextReading(cached: cached, direct: direct, context: context))
                assertNoMarkOrCarriageReturn(in: chapter, context: context)
                // The first variant's reading is the one every other must equal.
                if let reference {
                    XCTAssertEqual(chapter.text, reference.text, context)
                    XCTAssertEqual(chapter.headings, reference.headings, context)
                } else {
                    reference = chapter
                }
            }
        }
        let first = try XCTUnwrap(reference)
        XCTAssertTrue(first.text.contains("keep a ledger of every boat that passes."), first.text)
        XCTAssertTrue(first.text.contains("Upper lock\nLower lock"), first.text)
        XCTAssertEqual(first.headings.map(\.text), ["The Canal Register", "Locks and “Weirs”"])
        XCTAssertEqual(first.headings.map(\.level), [1, 2])
    }

    // MARK: - HTML

    /// An HTML book reads the same in every encoding, however it declares
    /// it, and with every line ending, on both paths (see
    /// `assertSameHTMLReading`): the same words, the same headings at the
    /// same words, and preformatted lines still separated by line feeds.
    /// Every variant's direct reading, and every variant's cached reading,
    /// is exactly the same text, and the decoder reports each encoding and
    /// what decided it.
    func testHTMLReadsTheSameInEveryEncodingAndWithEveryLineEnding() throws {
        var reference: (direct: Chapter, cached: Chapter)?
        for variant in EncodedBookFixture.htmlVariants {
            for ending in EncodedBookFixture.LineEnding.allCases {
                let context = "\(variant.name), \(ending.rawValue) line endings"
                let source = ending.text(of: EncodedBookFixture.htmlLines(prefix: variant.prefix, head: variant.head))
                let bytes = try XCTUnwrap(variant.encoding.bytes(of: source), context)
                let (direct, cached) = try readings(of: bytes, named: "Canal Register.html", format: .html)
                XCTAssertEqual(direct.chapters.count, 1, context)
                XCTAssertEqual(cached.chapters.count, 1, context)
                let directChapter = try XCTUnwrap(direct.chapters.first, context)
                let cachedChapter = try XCTUnwrap(cached.chapters.first, context)

                assertSameHTMLReading(cached: cachedChapter, direct: directChapter, context: context)
                XCTAssertEqual(normalizedHTMLReading(directChapter.text), EncodedBookFixture.htmlWords, context)
                XCTAssertEqual(directChapter.headings.map(\.text), EncodedBookFixture.htmlHeadings.map(\.text), context)
                XCTAssertEqual(directChapter.headings.map(\.level), EncodedBookFixture.htmlHeadings.map(\.level), context)
                XCTAssertTrue(directChapter.text.contains("Upper lock\nLower lock"), context)
                XCTAssertTrue(cachedChapter.text.contains("Upper lock\nLower lock"), context)
                assertNoMarkOrCarriageReturn(in: directChapter, context: context)
                assertNoMarkOrCarriageReturn(in: cachedChapter, context: context)

                let decoded = try TextFileDecoder.decode(Data(bytes), fileName: "Canal Register.html", format: .html)
                XCTAssertEqual(decoded.encoding, variant.decodedEncoding, context)
                XCTAssertEqual(decoded.basis, variant.basis, context)

                // The first variant's readings are the ones every other must equal.
                if let reference {
                    XCTAssertEqual(directChapter.text, reference.direct.text, context)
                    XCTAssertEqual(directChapter.headings, reference.direct.headings, context)
                    XCTAssertEqual(cachedChapter.text, reference.cached.text, context)
                    XCTAssertEqual(cachedChapter.headings, reference.cached.headings, context)
                } else {
                    reference = (directChapter, cachedChapter)
                }
            }
        }
    }

    // MARK: - Import Feedback

    /// A book read by the fallback is logged once each time its bytes are
    /// decoded: once when its import writes the cache, then once for each
    /// later reading of the source, by either path.
    func testFallbackIsLoggedOnceWhenImportedAndOnceForEachLaterRead() throws {
        let name = "Fallback Register \(UUID().uuidString).txt"
        let entry = "\(TextFileDecoder.fallbackLogTag): \(name): decoded as Windows-1252"
        let source = EncodedBookFixture.LineEnding.crlf.text(of: EncodedBookFixture.plainTextLines)
        let bytes = try XCTUnwrap(EncodedBookFixture.Encoding.windows1252.bytes(of: source))

        let book = try importBookFile(Data(bytes), named: name)
        XCTAssertEqual(debugLogLines(containing: entry).count, 1)
        _ = try BookParser.parse(url: URL(fileURLWithPath: book.filePath), format: .txt)
        XCTAssertEqual(debugLogLines(containing: entry).count, 2)
        _ = try MarkdownCacheService.generateReportedCacheContent(for: book)
        XCTAssertEqual(debugLogLines(containing: entry).count, 3)
    }

    /// A file that declares an encoding TextMouth cannot read is reported
    /// with the same message by both reading paths, and by the analysis a
    /// reader runs to open a book with no cache, which shows that message in
    /// place of the book.
    func testUnreadableEncodingIsReportedByBothPathsAndWhenOpened() throws {
        let book = try importBookFile(Data("<p>Placeholder</p>".utf8), named: "Klingon Tides.html")
        let bytes = Array("<html><head><meta charset=\"x-klingon\"></head><body><p>Caf".utf8)
            + [0xE9] + Array("</p></body></html>".utf8)
        try Data(bytes).write(to: URL(fileURLWithPath: book.filePath))
        let expected = TextEncodingError.unsupportedDeclaredEncoding(file: "Klingon Tides.html", label: "x-klingon")

        XCTAssertThrowsError(try BookParser.parse(url: URL(fileURLWithPath: book.filePath), format: .html)) { error in
            XCTAssertEqual(error as? TextEncodingError, expected)
            XCTAssertEqual(error.localizedDescription, expected.errorDescription)
        }
        XCTAssertThrowsError(try MarkdownCacheService.generateReportedCacheContent(for: book)) { error in
            XCTAssertEqual(error as? TextEncodingError, expected)
        }
        MarkdownCacheService.deleteCache(for: book)
        XCTAssertThrowsError(try BookContentAnalysisService.load(book: book)) { error in
            XCTAssertEqual(error.localizedDescription, expected.errorDescription)
        }
    }
}

// MARK: - Importing Fixture Files

extension XCTestCase {
    /// Import `data` as a book file named `fileName` through the production
    /// path, which copies it into a new package, writes content.md, and
    /// stamps the cache version. The source file and the package are removed
    /// when the test ends.
    func importBookFile(_ data: Data, named fileName: String) throws -> Book {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(fileName)
        try data.write(to: file)
        let book = try FileImportService.importFile(from: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        return book
    }
}

// MARK: - Encoded Books

/// Books written as bytes in every encoding the decoder reads by evidence,
/// and with every common line ending.
enum EncodedBookFixture {

    /// A way of writing text as bytes, with what the decoder must report for
    /// a plain-text file written this way.
    enum Encoding: String, CaseIterable {
        case utf8 = "UTF-8"
        case utf8WithMark = "UTF-8 with a byte-order mark"
        case utf16LEWithMark = "UTF-16LE with a byte-order mark"
        case utf16BEWithMark = "UTF-16BE with a byte-order mark"
        case utf32LEWithMark = "UTF-32LE with a byte-order mark"
        case utf32BEWithMark = "UTF-32BE with a byte-order mark"
        case utf16LE = "UTF-16LE without a byte-order mark"
        case utf16BE = "UTF-16BE without a byte-order mark"
        case windows1252 = "Windows-1252"

        /// `text` written this way: the byte-order mark, if any, then the
        /// text. Nil when the encoding cannot hold every character.
        func bytes(of text: String) -> [UInt8]? {
            guard let body = text.data(using: stringEncoding) else { return nil }
            return byteOrderMark + Array(body)
        }

        /// The encoding the text is written in.
        var stringEncoding: String.Encoding {
            switch self {
            case .utf8, .utf8WithMark: return .utf8
            case .utf16LEWithMark, .utf16LE: return .utf16LittleEndian
            case .utf16BEWithMark, .utf16BE: return .utf16BigEndian
            case .utf32LEWithMark: return .utf32LittleEndian
            case .utf32BEWithMark: return .utf32BigEndian
            case .windows1252: return .windowsCP1252
            }
        }

        /// The byte-order mark written before the text.
        var byteOrderMark: [UInt8] {
            switch self {
            case .utf8WithMark: return [0xEF, 0xBB, 0xBF]
            case .utf16LEWithMark: return [0xFF, 0xFE]
            case .utf16BEWithMark: return [0xFE, 0xFF]
            case .utf32LEWithMark: return [0xFF, 0xFE, 0x00, 0x00]
            case .utf32BEWithMark: return [0x00, 0x00, 0xFE, 0xFF]
            case .utf8, .utf16LE, .utf16BE, .windows1252: return []
            }
        }

        /// What the decoder must report decided the encoding of a plain-text
        /// file written this way.
        var basis: DecodedText.Basis {
            switch self {
            case .utf8: return .validUTF8
            case .utf8WithMark, .utf16LEWithMark, .utf16BEWithMark, .utf32LEWithMark, .utf32BEWithMark:
                return .byteOrderMark
            case .utf16LE, .utf16BE: return .unmarkedUnicode
            case .windows1252: return .fallback
            }
        }
    }

    /// The line endings files are written with.
    enum LineEnding: String, CaseIterable {
        case lf = "LF"
        case crlf = "CR LF"
        case cr = "CR"
        case mixed = "mixed"

        /// `lines` written as a file's text, each line ended this way. A
        /// mixed file cycles through CR LF, LF, and CR, so a line ended by a
        /// lone CR is always followed by one ended by CR LF: an empty line
        /// ended by LF there would make the two endings one CR LF, which any
        /// reader would read as a single line ending.
        func text(of lines: [String]) -> String {
            lines.enumerated().map { index, line in line + ending(ofLine: index) }.joined()
        }

        /// The ending of the line at `index`.
        private func ending(ofLine index: Int) -> String {
            switch self {
            case .lf: return "\n"
            case .crlf: return "\r\n"
            case .cr: return "\r"
            case .mixed: return ["\r\n", "\n", "\r"][index % 3]
            }
        }
    }

    // MARK: Plain Text

    /// A plain-text book with an all-caps, an ATX, and a setext heading,
    /// paragraphs wrapped across lines, and characters outside ASCII that
    /// Windows-1252 has too: an accented letter, curly quotation marks, and
    /// a dash.
    static let plainTextLines = [
        "THE CANAL REGISTER",
        "Café owners along the towpath keep a ledger",
        "of every boat that passes.",
        "",
        "# Locks and “Weirs”",
        "The upper lock opens at dawn — never earlier.",
        "",
        "Tolls Paid",
        "==========",
        "A narrowboat pays one shilling;",
        "a wide beam pays two.",
    ]

    /// The reading both paths must give `plainTextLines`, whatever their
    /// encoding and line endings.
    static let plainTextReading = [
        "THE CANAL REGISTER",
        "Café owners along the towpath keep a ledger of every boat that passes.",
        "Locks and “Weirs”",
        "The upper lock opens at dawn — never earlier.",
        "Tolls Paid",
        "A narrowboat pays one shilling; a wide beam pays two.",
    ].joined(separator: "\n\n")

    /// The headings of `plainTextLines`: all-caps, ATX, and setext.
    static let plainTextHeadings: [(level: Int, text: String)] = [
        (2, "THE CANAL REGISTER"),
        (1, "Locks and “Weirs”"),
        (1, "Tolls Paid"),
    ]

    // MARK: Markdown

    /// A Markdown book with two headings, a paragraph wrapped across lines,
    /// a fenced code block, emphasis, and characters outside ASCII that
    /// Windows-1252 has too.
    static let markdownLines = [
        "# The Canal Register",
        "",
        "Café owners along the towpath keep a ledger",
        "of every boat that passes.",
        "",
        "## Locks and “Weirs”",
        "",
        "```",
        "Upper lock",
        "Lower lock",
        "```",
        "",
        "The upper lock opens at dawn — *never* earlier.",
    ]

    // MARK: HTML

    /// An HTML book whose file begins with `prefix` and whose head holds
    /// `head`, the two places an encoding is declared: two headings, a
    /// paragraph wrapped across lines, preformatted lines, and characters
    /// outside ASCII that Windows-1252 has too.
    static func htmlLines(prefix: String, head: String) -> [String] {
        [
            prefix + "<html><head>" + head + "<title>Canal Register</title></head>",
            "<body>",
            "<h1>The Canal Register</h1>",
            "<p>Café owners along the towpath keep a ledger",
            "of every boat that passes.</p>",
            "<h2>Locks and “Weirs”</h2>",
            "<pre>Upper lock",
            "Lower lock</pre>",
            "<p>The upper lock opens at dawn — never earlier.</p>",
            "</body></html>",
        ]
    }

    /// The words of the HTML book, as `normalizedHTMLReading` gives them.
    static let htmlWords = "The Canal Register Café owners along the towpath keep a ledger of every boat that passes."
        + " Locks and “Weirs” Upper lock Lower lock The upper lock opens at dawn — never earlier."

    /// The headings of the HTML book.
    static let htmlHeadings: [(level: Int, text: String)] = [
        (1, "The Canal Register"),
        (2, "Locks and “Weirs”"),
    ]

    /// One way an HTML file can be written and declare its encoding, with
    /// what the decoder must report for it.
    struct HTMLVariant {
        /// Names the variant in failure messages.
        var name: String
        /// Text before the html element, where an XML declaration goes.
        var prefix = ""
        /// Text at the start of the head, where a meta element goes.
        var head = ""
        /// How the file is written.
        var encoding: Encoding
        /// The encoding the decoder must report.
        var decodedEncoding: String.Encoding
        /// What the decoder must report decided it.
        var basis: DecodedText.Basis
    }

    /// Every way the HTML book is written: UTF-8 under a stale declaration
    /// of the encoding it was converted from, each Unicode encoding marked,
    /// UTF-16 unmarked, and Windows-1252 declared by a meta charset, by a
    /// Content-Type meta element naming ISO-8859-1, by an XML declaration
    /// naming ISO-8859-1, and not declared at all.
    static let htmlVariants: [HTMLVariant] = [
        HTMLVariant(
            name: "UTF-8 under a stale Windows-1252 declaration", head: "<meta charset=\"windows-1252\">",
            encoding: .utf8, decodedEncoding: .utf8, basis: .validUTF8
        ),
        HTMLVariant(
            name: "UTF-8 with a byte-order mark",
            encoding: .utf8WithMark, decodedEncoding: .utf8, basis: .byteOrderMark
        ),
        HTMLVariant(
            name: "UTF-16LE with a byte-order mark",
            encoding: .utf16LEWithMark, decodedEncoding: .utf16LittleEndian, basis: .byteOrderMark
        ),
        HTMLVariant(
            name: "UTF-16BE with a byte-order mark",
            encoding: .utf16BEWithMark, decodedEncoding: .utf16BigEndian, basis: .byteOrderMark
        ),
        HTMLVariant(
            name: "UTF-16LE without a byte-order mark",
            encoding: .utf16LE, decodedEncoding: .utf16LittleEndian, basis: .unmarkedUnicode
        ),
        HTMLVariant(
            name: "Windows-1252 declared by a meta charset", head: "<meta charset=\"windows-1252\">",
            encoding: .windows1252, decodedEncoding: .windowsCP1252, basis: .declaration(label: "windows-1252")
        ),
        HTMLVariant(
            name: "ISO-8859-1 declared by a Content-Type meta element",
            head: "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=iso-8859-1\">",
            encoding: .windows1252, decodedEncoding: .windowsCP1252, basis: .declaration(label: "iso-8859-1")
        ),
        HTMLVariant(
            name: "ISO-8859-1 declared by an XML declaration", prefix: "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>",
            encoding: .windows1252, decodedEncoding: .windowsCP1252, basis: .declaration(label: "ISO-8859-1")
        ),
        HTMLVariant(
            name: "Windows-1252 without a declaration",
            encoding: .windows1252, decodedEncoding: .windowsCP1252, basis: .fallback
        ),
    ]
}
