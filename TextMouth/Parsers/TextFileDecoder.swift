import Foundation

// MARK: - Decoded Text

/// A text book file's bytes read as text, with the encoding they were read
/// in and what decided it.
struct DecodedText: Equatable, Sendable {
    /// What decided the encoding. `TextFileDecoder` looks for each in this
    /// order and takes the first it finds.
    enum Basis: Equatable, Sendable {
        /// A byte-order mark at the start of the file named the encoding.
        case byteOrderMark
        /// No mark, but the bytes show the zero high bytes of UTF-16 text
        /// in a Latin script (see `TextFileDecoder.unmarkedUTF16Encoding(of:)`).
        case unmarkedUTF16
        /// The bytes are valid UTF-8.
        case validUTF8
        /// An HTML file's own declaration named the encoding: a meta
        /// element's charset or the XML declaration's encoding, given here
        /// as the file spells it.
        case declaration(label: String)
        /// Nothing above applied, so each byte was read as its Windows-1252
        /// character. The bytes gave no evidence for this encoding, so it is
        /// the one basis the decoder logs.
        case fallback
    }

    /// The text, with no byte-order mark at its start and every line ending
    /// a line feed (see `TextFileDecoder.normalizingLineEndings(_:)`).
    var text: String
    /// The encoding the bytes were read in.
    var encoding: String.Encoding
    /// What decided `encoding`.
    var basis: Basis

    /// Whether the bytes were read by the Windows-1252 fallback because
    /// nothing in them said what their encoding was.
    var usedFallback: Bool { basis == .fallback }
}

// MARK: - Encoding Errors

/// A text book file that names its encoding, but whose bytes cannot be read
/// in it. The decoder never guesses past what a file says about itself, nor
/// drops or replaces bytes to get past it, so the reader is told which file
/// and which encoding instead.
enum TextEncodingError: LocalizedError, Equatable {
    /// An HTML file declares an encoding TextMouth does not know. `label` is
    /// the declaration's name for it, as the file spells it.
    case unsupportedDeclaredEncoding(file: String, label: String)
    /// An HTML file declares an encoding its bytes are not valid in.
    case invalidForDeclaredEncoding(file: String, label: String)
    /// A file begins with the byte-order mark of `encoding` ("UTF-16LE"),
    /// but the bytes after it are not valid in that encoding: they end
    /// partway through a character, or hold half of a surrogate pair or a
    /// code point beyond Unicode.
    case invalidForMarkedEncoding(file: String, encoding: String)

    /// What a reader hears, in the form `PackageDamage` gives damaged files:
    /// the file in curly quotation marks, what is wrong with it, and what to
    /// do next.
    var errorDescription: String? {
        switch self {
        case let .unsupportedDeclaredEncoding(file, label):
            return "The file “\(file)” declares the text encoding “\(label)”, which TextMouth cannot read. "
                + "Save it as UTF-8 text, then import it again."
        case let .invalidForDeclaredEncoding(file, label):
            return "The file “\(file)” declares the text encoding “\(label)”, "
                + "but it holds bytes that are not valid in that encoding. "
                + "Save it as UTF-8 text, then import it again."
        case let .invalidForMarkedEncoding(file, encoding):
            return "The file “\(file)” is damaged or incomplete: it begins with a \(encoding) byte-order mark, "
                + "but the rest of it is not valid \(encoding) text. "
                + "Get a fresh copy of the file, then import it again."
        }
    }
}

// MARK: - Decoder

/// Reads the bytes of a plain-text (.txt), Markdown (.md), or HTML book as
/// text. Both reading paths take their source from `readText(at:format:)`:
/// the direct parsers (`BookParser`) and the Markdown cache
/// (`MarkdownCacheService`), so the two can never start from different text.
///
/// The encoding comes from the strongest evidence the bytes hold, tried in
/// this order:
/// 1. A byte-order mark for UTF-8, UTF-16 (little- or big-endian), or UTF-32
///    (little- or big-endian) names the encoding. The bytes after a UTF-16
///    or UTF-32 mark must be valid in it, or `TextEncodingError` reports the
///    file as damaged. Bytes after a UTF-8 mark that are not valid UTF-8 are
///    read by the fallback (step 5), like any other broken UTF-8; no
///    declaration can overrule the mark.
/// 2. UTF-16 without a mark is recognized by its zero bytes (see
///    `unmarkedUTF16Encoding(of:)`). It must be looked for before UTF-8,
///    because UTF-16 holding only ASCII characters is also valid UTF-8, read
///    as a NUL after every letter.
/// 3. Bytes that are valid UTF-8 are UTF-8.
/// 4. An HTML file whose bytes are not valid UTF-8 is read in the encoding
///    it declares in its first 1024 bytes, with a meta element or an XML
///    declaration (see `declaredEncodingLabel(in:)`). Valid UTF-8 is read as
///    UTF-8 even under a declaration that says otherwise: a file converted
///    to UTF-8 often keeps its old declaration, while text in another
///    encoding almost never forms valid UTF-8 by chance. (Text in a 7-bit
///    encoding such as ISO-2022-JP is always valid UTF-8, so its
///    declaration goes unread.) A declaration TextMouth cannot follow is
///    reported, never guessed past (`TextEncodingError`).
/// 5. Otherwise each byte is read as its Windows-1252 character. Every byte
///    has one (see `windows1252Text(_:)`), and Windows-1252 agrees with ISO
///    Latin 1 on every printable character Latin 1 has, so older texts in
///    either encoding read correctly. The fallback is logged, because it is
///    a guess (see `readText(at:format:)`).
///
/// No byte is dropped or replaced to make the bytes fit an encoding: an
/// encoding either reads every byte or is not used. Only the finishing
/// described next changes the decoded text.
///
/// Whatever the encoding, the text is then finished the same way: any U+FEFF
/// at its start is removed, because a byte-order mark is a signature rather
/// than a word of the book (a second mark some tools write after the first
/// included), and every line ending becomes a line feed (see
/// `normalizingLineEndings(_:)`).
enum TextFileDecoder {

    // MARK: Reading Files

    /// The tag that begins the debug log line recording a fallback.
    static let fallbackLogTag = "TEXT_ENCODING_FALLBACK"

    /// The text of the plain-text, Markdown, or HTML book at `url`. When the
    /// bytes had to be read by the Windows-1252 fallback, one line records it
    /// in the console and the debug log:
    /// `TEXT_ENCODING_FALLBACK: <file>: decoded as Windows-1252`.
    /// - Throws: the error reading the file, or `TextEncodingError`.
    static func readText(at url: URL, format: BookFormat) throws -> String {
        let fileName = url.lastPathComponent
        let decoded = try decode(Data(contentsOf: url), fileName: fileName, format: format)
        if decoded.usedFallback {
            logFallback(fileName: fileName, encoding: decoded.encoding)
        }
        return decoded.text
    }

    /// Record that `fileName` was read by the fallback, as one line. A line
    /// break in the file name becomes a space, so the entry stays on the one
    /// line that readers of the log expect.
    private static func logFallback(fileName: String, encoding: String.Encoding) {
        let file = fileName.components(separatedBy: .newlines).joined(separator: " ")
        let line = "\(fallbackLogTag): \(file): decoded as \(name(of: encoding))"
        print(line)
        TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: line)
    }

    // MARK: Decoding

    /// Decode the bytes of a book file named `fileName` (named in any error)
    /// whose format is `format`. Only an HTML file's declarations are read.
    /// - Throws: `TextEncodingError` when the file names an encoding its
    ///   bytes cannot be read in.
    static func decode(_ data: Data, fileName: String, format: BookFormat) throws -> DecodedText {
        var decoded = try decodeBytes(data, fileName: fileName, readsDeclarations: format == .html)
        decoded.text = normalizingLineEndings(droppingLeadingByteOrderMarks(decoded.text))
        return decoded
    }

    /// Choose the encoding by the steps in the type's description and read
    /// `data` in it, before the text is finished.
    private static func decodeBytes(_ data: Data, fileName: String, readsDeclarations: Bool) throws -> DecodedText {
        // 1. A byte-order mark names the encoding.
        if let mark = byteOrderMarks.first(where: { data.starts(with: $0.bytes) }) {
            let content = data.dropFirst(mark.bytes.count)
            if mark.encoding == .utf8 {
                guard let text = String(data: content, encoding: .utf8) else {
                    return fallbackText(content)
                }
                return DecodedText(text: text, encoding: .utf8, basis: .byteOrderMark)
            }
            guard let text = unicodeText(content, as: mark.encoding) else {
                throw TextEncodingError.invalidForMarkedEncoding(file: fileName, encoding: name(of: mark.encoding))
            }
            return DecodedText(text: text, encoding: mark.encoding, basis: .byteOrderMark)
        }

        // 2. UTF-16 without a mark, recognized by its zero bytes.
        if let encoding = unmarkedUTF16Encoding(of: data), let text = unicodeText(data, as: encoding) {
            return DecodedText(text: text, encoding: encoding, basis: .unmarkedUTF16)
        }

        // 3. Valid UTF-8.
        if let text = String(data: data, encoding: .utf8) {
            return DecodedText(text: text, encoding: .utf8, basis: .validUTF8)
        }

        // 4. The encoding an HTML file declares.
        if readsDeclarations, let label = declaredEncodingLabel(in: data),
           let declared = try declaredText(data, label: label, fileName: fileName) {
            return declared
        }

        // 5. The fallback, which reads every byte.
        return fallbackText(data)
    }

    // MARK: Byte-Order Marks and Unicode

    /// The byte-order marks the decoder honors, with the encodings they name.
    /// UTF-32LE's mark begins with UTF-16LE's, so it is listed (and so tried)
    /// first.
    private static let byteOrderMarks: [(bytes: [UInt8], encoding: String.Encoding)] = [
        ([0xEF, 0xBB, 0xBF], .utf8),
        ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
        ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
        ([0xFF, 0xFE], .utf16LittleEndian),
        ([0xFE, 0xFF], .utf16BigEndian),
    ]

    /// `data` read in the UTF-16 or UTF-32 `encoding`, or nil when its bytes
    /// are not valid in it. Foundation silently drops the bytes of an
    /// incomplete code unit at the end, so a length that is not a whole
    /// number of code units is refused here first.
    private static func unicodeText(_ data: Data, as encoding: String.Encoding) -> String? {
        let codeUnitSize = (encoding == .utf32LittleEndian || encoding == .utf32BigEndian) ? 4 : 2
        guard data.count.isMultiple(of: codeUnitSize) else { return nil }
        return String(data: data, encoding: encoding)
    }

    /// The byte order of UTF-16 text written without a byte-order mark, or
    /// nil when the bytes do not show one.
    ///
    /// Text in a Latin script keeps most of its characters below U+0100, so
    /// most of its 16-bit code units have a zero high byte, while a zero low
    /// byte (U+0000, or a character such as U+0100 or U+4E00) is rare. The
    /// bytes are therefore taken to be UTF-16 in one byte order when their
    /// length is even, more than half the code units in that order have a
    /// zero high byte, and none has a zero low byte. Text in UTF-8 or a
    /// single-byte encoding holds a zero byte only by accident, never at
    /// every other position. Unmarked UTF-16 in another script has too few
    /// zero bytes to recognize and is decoded like any other bytes, which is
    /// why a byte-order mark is the dependable way to write UTF-16.
    static func unmarkedUTF16Encoding(of data: Data) -> String.Encoding? {
        guard data.count >= 2, data.count.isMultiple(of: 2) else { return nil }
        // Every file without a mark is scanned, so the raw bytes are read
        // directly rather than through Data's slower subscript.
        return data.withUnsafeBytes { bytes -> String.Encoding? in
            // How many code units have a zero first byte, and a zero second byte.
            var zeroFirstBytes = 0
            var zeroSecondBytes = 0
            for index in stride(from: 0, to: bytes.count, by: 2) {
                if bytes[index] == 0 { zeroFirstBytes += 1 }
                if bytes[index + 1] == 0 { zeroSecondBytes += 1 }
                // Zero bytes on both sides of the units rule out both orders.
                if zeroFirstBytes > 0 && zeroSecondBytes > 0 { return nil }
            }
            let codeUnits = bytes.count / 2
            // Little-endian code units keep their high byte second.
            if zeroFirstBytes == 0 && zeroSecondBytes * 2 > codeUnits {
                return .utf16LittleEndian
            }
            // Big-endian code units keep their high byte first.
            if zeroSecondBytes == 0 && zeroFirstBytes * 2 > codeUnits {
                return .utf16BigEndian
            }
            return nil
        }
    }

    // MARK: Declared Encodings

    /// How far into an HTML file a declaration is looked for: the first 1024
    /// bytes, as the HTML standard's encoding prescan examines.
    static let declarationScanLength = 1024

    /// The XML declaration's encoding, which only the start of a file can
    /// hold: `<?xml version="1.0" encoding="ISO-8859-1"?>`. Group 1 is the
    /// label.
    private static let xmlDeclarationPattern = #"^\s*<\?xml\s[^>]*?\bencoding\s*=\s*["']\s*([^\s"'?>]+)"#

    /// A meta element's charset: its `charset` attribute
    /// (`<meta charset="windows-1252">`), or the charset parameter of its
    /// `content` attribute (`<meta http-equiv="Content-Type"
    /// content="text/html; charset=iso-8859-1">`). Group 1 is the label.
    private static let metaCharsetPattern = #"<meta\s[^>]*?\bcharset\s*=\s*["']?\s*([^\s"';/>]+)"#

    /// A comment, including one the scanned bytes cut off before its end. A
    /// declaration commented out of the file does not count.
    private static let commentPattern = #"<!--[\s\S]*?(?:-->|$)"#

    /// The label of the encoding an HTML file declares in its first
    /// `declarationScanLength` bytes, as the file spells it ("ISO-8859-1"):
    /// the XML declaration's when the file begins with one, otherwise the
    /// first meta element's that names one. Nil when the file declares none.
    static func declaredEncodingLabel(in data: Data) -> String? {
        // Declarations are ASCII. ISO Latin 1 gives every byte a character,
        // so the scanned bytes always read, even when they end partway
        // through a character of the file's real encoding.
        guard let start = String(data: data.prefix(declarationScanLength), encoding: .isoLatin1) else {
            return nil
        }
        let markup = start.replacingOccurrences(of: commentPattern, with: " ", options: .regularExpression)
        return firstCapture(of: xmlDeclarationPattern, in: markup) ?? firstCapture(of: metaCharsetPattern, in: markup)
    }

    /// The text of group 1 in the first match of `pattern`, ignoring case.
    private static func firstCapture(of pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            assertionFailure("Invalid declaration pattern: \(pattern)")
            return nil
        }
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    /// Unicode's encodings. A declaration naming one leaves the bytes to the
    /// fallback: they have already failed UTF-8 (or the steps before it), and
    /// a declaration readable as ASCII cannot truly mean UTF-16 or UTF-32,
    /// which is why the HTML standard reads such a declaration as UTF-8.
    private static let unicodeEncodings: Set<String.Encoding> = [
        .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32, .utf32LittleEndian, .utf32BigEndian,
    ]

    /// Encodings whose declarations the HTML standard reads as Windows-1252,
    /// because files labeled ISO Latin 1 or ASCII are so often Windows-1252
    /// text: their curly quotation marks and dashes would otherwise read as
    /// invisible control characters. Windows-1252 has every printable
    /// character of both.
    private static let windows1252Equivalents: Set<String.Encoding> = [.windowsCP1252, .isoLatin1, .ascii]

    /// `data` read in the encoding an HTML file declares as `label`.
    /// - Returns: nil when the label names a Unicode encoding, leaving the
    ///   bytes to the fallback (see `unicodeEncodings`).
    /// - Throws: `TextEncodingError` when TextMouth does not know the
    ///   encoding, or the bytes are not valid in it.
    private static func declaredText(_ data: Data, label: String, fileName: String) throws -> DecodedText? {
        guard let encoding = encoding(forLabel: label) else {
            throw TextEncodingError.unsupportedDeclaredEncoding(file: fileName, label: label)
        }
        if unicodeEncodings.contains(encoding) {
            return nil
        }
        if windows1252Equivalents.contains(encoding) {
            return DecodedText(text: windows1252Text(data), encoding: .windowsCP1252, basis: .declaration(label: label))
        }
        // Foundation refuses bytes that are not valid in the encoding rather
        // than replacing them, so a result holds every byte.
        guard let text = String(data: data, encoding: encoding) else {
            throw TextEncodingError.invalidForDeclaredEncoding(file: fileName, label: label)
        }
        return DecodedText(text: text, encoding: encoding, basis: .declaration(label: label))
    }

    /// The encoding a declaration's label names, by the IANA names and
    /// aliases Core Foundation knows ("latin1", "cp1252", "Shift_JIS"), in
    /// any letter case. Nil for a label it does not know.
    private static func encoding(forLabel label: String) -> String.Encoding? {
        let encoding = CFStringConvertIANACharSetNameToEncoding(label as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    // MARK: Windows-1252

    /// The fallback's reading of `data`.
    private static func fallbackText(_ data: Data) -> DecodedText {
        DecodedText(text: windows1252Text(data), encoding: .windowsCP1252, basis: .fallback)
    }

    /// The characters of bytes 0x80 through 0x9F in Windows-1252, in byte
    /// order, as the WHATWG Encoding Standard's index gives them. The five
    /// bytes Windows leaves undefined (0x81, 0x8D, 0x8F, 0x90, and 0x9D) are
    /// the C1 control characters of the same value there, so every byte has
    /// a character; Foundation's own decoder refuses a whole file holding
    /// any of the five.
    private static let windows1252C1Range: [Unicode.Scalar] = [
        "\u{20AC}", "\u{0081}", "\u{201A}", "\u{0192}", "\u{201E}", "\u{2026}", "\u{2020}", "\u{2021}",
        "\u{02C6}", "\u{2030}", "\u{0160}", "\u{2039}", "\u{0152}", "\u{008D}", "\u{017D}", "\u{008F}",
        "\u{0090}", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{2022}", "\u{2013}", "\u{2014}",
        "\u{02DC}", "\u{2122}", "\u{0161}", "\u{203A}", "\u{0153}", "\u{009D}", "\u{017E}", "\u{0178}",
    ]

    /// `data` read as Windows-1252, one character for each byte. Bytes
    /// outside 0x80 through 0x9F are the ISO Latin 1 characters of the same
    /// value, which Windows-1252 shares.
    static func windows1252Text(_ data: Data) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in data {
            if (0x80...0x9F).contains(byte) {
                scalars.append(windows1252C1Range[Int(byte - 0x80)])
            } else {
                scalars.append(Unicode.Scalar(byte))
            }
        }
        return String(scalars)
    }

    // MARK: Finishing the Text

    /// `text` without the U+FEFF characters at its start.
    private static func droppingLeadingByteOrderMarks(_ text: String) -> String {
        guard text.unicodeScalars.first == "\u{FEFF}" else { return text }
        return String(text.unicodeScalars.drop(while: { $0 == "\u{FEFF}" }))
    }

    /// `text` with every line ending a line feed: a carriage return and line
    /// feed (CR LF, the Windows line ending) become one line feed, and a
    /// carriage return not followed by a line feed (a lone CR, the classic
    /// Mac OS line ending) becomes a line feed wherever it stands. A lone CR
    /// inside a line therefore ends that line, so the words after it begin a
    /// new one: the reading CommonMark, the HTML standard, and Unicode line
    /// breaking all give it. "\r\r\n" is two line endings, CR and then CR LF.
    /// The other characters some readers break lines at (VT, FF, NEL, LS,
    /// and PS) are left as they are.
    static func normalizingLineEndings(_ text: String) -> String {
        // Most files end their lines with LF alone and are returned as is.
        guard text.utf8.contains(0x0D) else { return text }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        // Whether the previous byte was a CR, already written as an LF, so
        // that an LF directly after it completes the same line ending.
        var followsCarriageReturn = false
        for byte in text.utf8 {
            if byte == 0x0D {
                bytes.append(0x0A)
                followsCarriageReturn = true
                continue
            }
            if !(byte == 0x0A && followsCarriageReturn) {
                bytes.append(byte)
            }
            followsCarriageReturn = false
        }
        // Only ASCII bytes changed, so the bytes are still valid UTF-8.
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Names

    /// An encoding's name in logs and messages: "UTF-8", "UTF-16LE",
    /// "UTF-16BE", "UTF-32LE", "UTF-32BE", or "Windows-1252", and any other
    /// encoding by its IANA name.
    static func name(of encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf16LittleEndian: return "UTF-16LE"
        case .utf16BigEndian: return "UTF-16BE"
        case .utf32LittleEndian: return "UTF-32LE"
        case .utf32BigEndian: return "UTF-32BE"
        case .windowsCP1252: return "Windows-1252"
        default:
            let ianaName = CFStringConvertEncodingToIANACharSetName(
                CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
            ) as String?
            return ianaName ?? String.localizedName(of: encoding)
        }
    }
}
