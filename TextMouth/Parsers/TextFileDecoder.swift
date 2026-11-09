import Foundation

// MARK: - Decoded Text

/// A text book file's bytes read as text, with the encoding they were read
/// in and what decided it.
struct DecodedText: Equatable, Sendable {
    /// What decided the encoding. `TextFileDecoder` looks for each in this
    /// order and takes the first it finds.
    enum Basis: Equatable, Sendable {
        /// The listener chose the encoding in Book Information, and every
        /// byte was read in it, whatever the bytes say of themselves
        /// (`EncodingPolicy.chosen(_:)`, encodingchoice).
        case chosen
        /// A byte-order mark at the start of the file named the encoding.
        case byteOrderMark
        /// No mark, but the bytes' own structure shows UTF-16 or UTF-32 text:
        /// the zero high bytes of UTF-16 in a Latin script, the repeated high
        /// byte of an alphabet's UTF-16, zero bytes among the high-valued
        /// bytes of other scripts' UTF-16, or the zero bytes of every UTF-32
        /// code unit (see `TextFileDecoder.unmarkedUnicode(in:)`).
        case unmarkedUnicode
        /// The bytes are valid UTF-8.
        case validUTF8
        /// An HTML file's own declaration named the encoding: a meta
        /// element's charset or the XML declaration's encoding, given here
        /// as the file spells it.
        case declaration(label: String)
        /// The book was imported with a guess, which it recorded
        /// (`Book.textEncoding`), and is read again in that encoding: the
        /// bytes still give no evidence of their own, and nothing is guessed
        /// a second time (`EncodingPolicy.recorded(_:)`).
        case recorded
        /// Nothing above applied, and `TextEncodingGuesser` judged the bytes
        /// to be in this encoding: a guess (FMT16), logged once as the book
        /// is imported, and recorded with it.
        case guess
        /// Nothing above applied, so each byte was read as its Windows-1252
        /// character. The bytes gave no evidence for this encoding, so it is
        /// the one basis the decoder logs on every read.
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

    /// The identifier to record with the book (`Book.textEncoding`) when the
    /// encoding was a guess, or nil when the bytes or the book's record
    /// settled it, in which case nothing needs recording.
    var guessedEncodingIdentifier: String? {
        guard basis == .guess else { return nil }
        return TextEncodingCatalog.entry(for: encoding)?.identifier
    }
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
    /// A file chosen to be read in an encoding (`EncodingPolicy.chosen(_:)`,
    /// encodingchoice) holds bytes that are not valid in it. `encoding` is
    /// the encoding's name as a listener hears it, "Shift JIS (Japanese)".
    case invalidForChosenEncoding(file: String, encoding: String)
    /// A file chosen to be read in an encoding this TextMouth does not know:
    /// one a later TextMouth recorded, or a damaged record. `identifier` is
    /// the encoding as the book recorded it.
    case unknownChosenEncoding(file: String, identifier: String)

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
        case let .invalidForChosenEncoding(file, encoding):
            return TextEncodingWording.notValid(in: encoding, subject: "The file “\(file)”")
        case let .unknownChosenEncoding(file, identifier):
            return TextEncodingWording.unknownChoice(identifier, subject: "The file “\(file)”")
        }
    }
}

// MARK: - Decoder

/// Reads the bytes of a plain-text (.txt), Markdown (.md), or HTML book as
/// text. Both reading paths take their source from `readText(at:format:)`:
/// the direct parsers (`BookParser`) and the Markdown cache
/// (`MarkdownCacheService`), so the two can never start from different text.
///
/// A book whose encoding the listener chose in Book Information
/// (`EncodingPolicy.chosen(_:)`, encodingchoice) is read in that encoding
/// alone, whatever its bytes say of themselves: every byte must be valid in
/// it (`strictlyDecodedText(_:in:)`), or the file is refused by name
/// (`TextEncodingError.invalidForChosenEncoding`), and nothing below is
/// tried. Otherwise the encoding comes from the strongest evidence the bytes
/// hold, tried in this order:
/// 1. A byte-order mark for UTF-8, UTF-16 (little- or big-endian), or UTF-32
///    (little- or big-endian) names the encoding. The bytes after a UTF-16
///    or UTF-32 mark must be valid in it, or `TextEncodingError` reports the
///    file as damaged. Bytes after a UTF-8 mark that are not valid UTF-8 are
///    read by the fallback (step 6), like any other broken UTF-8; no
///    declaration can overrule the mark.
/// 2. UTF-16 and UTF-32 without a mark are recognized by the structure of
///    their bytes (see `unmarkedUnicode(in:)`): the zero bytes of Latin
///    UTF-16 or of UTF-32, the shared high byte of an alphabet's UTF-16, and
///    the zeros of ASCII among other scripts' UTF-16. They must be looked
///    for before UTF-8, because UTF-16 holding only ASCII characters is also
///    valid UTF-8, read as a NUL after every letter, and so is a Cyrillic
///    UTF-16 text, read as control characters.
/// 3. Bytes that are valid UTF-8 are UTF-8, except a file in ISO-2022-JP,
///    which is valid UTF-8 too: the guessing policy looks for one (and a
///    book that recorded the encoding reads in it) before it takes bytes
///    for UTF-8 (`sevenBitText(_:policy:)`), and so does an HTML file that
///    declares ISO-2022-JP, whatever the policy says of bytes that name no
///    encoding (`declaredSevenBitText(_:)`).
/// 4. An HTML file whose bytes are not valid UTF-8 is read in the encoding
///    it declares in its first 1024 bytes, with a meta element or an XML
///    declaration (see `declaredEncodingLabel(in:)`). Valid UTF-8 is read as
///    UTF-8 even under a declaration that says otherwise: a file converted
///    to UTF-8 often keeps its old declaration, while text in another
///    encoding almost never forms valid UTF-8 by chance. (Text in a 7-bit
///    encoding such as ISO-2022-JP is always valid UTF-8, so its
///    declaration goes unread.) A declaration TextMouth cannot follow is
///    reported, never guessed past (`TextEncodingError`).
/// 5. What the book's reading policy says to do with bytes that name no
///    encoding (`EncodingPolicy`):
///    - the encoding the book recorded when it was imported with a guess
///      (`EncodingPolicy.recorded(_:)`), which a book read before guesses
///      were recorded does not have;
///    - a guess by `TextEncodingGuesser` (`EncodingPolicy.guess`), which
///      only the import of a new file makes and then records with the book;
///    - or nothing, which is what every read did before FMT16.
/// 6. Otherwise each byte is read as its Windows-1252 character. Every byte
///    has one (see `windows1252Text(_:)`), and Windows-1252 agrees with ISO
///    Latin 1 on every printable character Latin 1 has, so older texts in
///    either encoding read correctly. The fallback is logged, because it is
///    a guess (see `readText(at:format:policy:)`).
///
/// The policy is what keeps a book's text from changing under its reader: a
/// book imported before guesses were recorded has no record, and is read by
/// steps 1 to 4 and 6 exactly as it always was, however well the guesser
/// would do on it now.
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

    // MARK: Encoding Policy

    /// What a read does with bytes that name no encoding: the book's
    /// policy, which keeps its text from changing under its reader (FMT16).
    enum EncodingPolicy: Equatable, Sendable {
        /// Read them as Windows-1252, as every read did before guesses: the
        /// policy of a book that has no recorded encoding, and of every
        /// reader of a file that is no book (a playlist, a web archive).
        case fallback
        /// Guess their encoding (`TextEncodingGuesser`), and read them as
        /// Windows-1252 only when no guess can be trusted: the policy of the
        /// import of a new file, which records the guess with the book.
        case guess
        /// Read them in the encoding an earlier read recorded with the book
        /// (`Book.textEncoding`), by its identifier (`TextEncodingCatalog`).
        /// An identifier that names no catalogued encoding, or an encoding
        /// the bytes are not valid in, leaves them to the fallback.
        case recorded(String)
        /// Read every byte in the encoding the listener chose for the book in
        /// Book Information (encodingchoice), by its identifier: UTF-8
        /// (`utf8Identifier`) or one of the catalog's. Unlike every other
        /// policy, this one overrules what the bytes say of themselves (a
        /// byte-order mark, valid UTF-8, an HTML declaration), since the
        /// listener chose it because the file was read wrong; and it is
        /// strict: bytes that are not valid in the encoding, or an
        /// identifier this TextMouth does not know, are refused
        /// (`TextEncodingError`), never left to the fallback.
        case chosen(String)

        /// Whether this is the policy of a book that recorded its encoding.
        var isRecorded: Bool {
            if case .recorded = self { return true }
            return false
        }

        /// The policy for a book whose recorded encoding is `identifier`:
        /// that encoding, or the fallback for a book that has none.
        static func forBook(recording identifier: String?) -> EncodingPolicy {
            identifier.map(EncodingPolicy.recorded) ?? .fallback
        }
    }

    // MARK: Reading Files

    /// The tag that begins the debug log line recording a fallback.
    static let fallbackLogTag = "TEXT_ENCODING_FALLBACK"
    /// The tag that begins the debug log line recording a guess.
    static let guessLogTag = "TEXT_ENCODING_GUESS"

    /// The text of the plain-text, Markdown, or HTML book at `url`. When the
    /// bytes had to be read by the Windows-1252 fallback, one line records it
    /// in the console and the debug log:
    /// `TEXT_ENCODING_FALLBACK: <file>: decoded as Windows-1252`. When they
    /// were read in a guessed encoding, one line records that too:
    /// `TEXT_ENCODING_GUESS: <file>: read as windows-1251`.
    /// - Throws: the error reading the file, or `TextEncodingError`.
    static func readText(at url: URL, format: BookFormat, policy: EncodingPolicy = .fallback) throws -> String {
        try readDecodedText(at: url, format: format, policy: policy).text
    }

    /// The book file at `url` read as `readText(at:format:policy:)` reads
    /// it, with the encoding it was read in and what decided it, so that an
    /// import can record a guess with its book.
    /// - Throws: the error reading the file, or `TextEncodingError`.
    static func readDecodedText(at url: URL, format: BookFormat, policy: EncodingPolicy = .fallback) throws -> DecodedText {
        let fileName = url.lastPathComponent
        let decoded = try decode(Data(contentsOf: url), fileName: fileName, format: format, policy: policy)
        switch decoded.basis {
        case .fallback:
            logFallback(fileName: fileName, encoding: decoded.encoding)
        case .guess:
            logGuess(fileName: fileName, identifier: decoded.guessedEncodingIdentifier)
        default:
            break
        }
        return decoded
    }

    /// Record that `fileName` was read by the fallback, as one import event.
    /// A line break in the file name becomes a space, so the entry stays on
    /// the one line that readers of the log expect.
    private static func logFallback(fileName: String, encoding: String.Encoding) {
        DiagnosticLog.event(.import, "\(fallbackLogTag): \(fileName): decoded as \(name(of: encoding))")
    }

    /// Record that `fileName` was read in the guessed encoding `identifier`,
    /// as one import event.
    private static func logGuess(fileName: String, identifier: String?) {
        DiagnosticLog.event(.import, "\(guessLogTag): \(fileName): read as \(identifier ?? "an unnamed encoding")")
    }

    // MARK: Decoding

    /// Decode the bytes of a book file named `fileName` (named in any error)
    /// whose format is `format`, settling bytes that name no encoding as
    /// `policy` says. Only an HTML file's declarations are read.
    /// - Throws: `TextEncodingError` when the file names an encoding its
    ///   bytes cannot be read in.
    static func decode(
        _ data: Data, fileName: String, format: BookFormat, policy: EncodingPolicy = .fallback
    ) throws -> DecodedText {
        var decoded = try decodeBytes(data, fileName: fileName, readsDeclarations: format == .html, policy: policy)
        decoded.text = normalizingLineEndings(droppingLeadingByteOrderMarks(decoded.text))
        return decoded
    }

    /// Choose the encoding by the steps in the type's description and read
    /// `data` in it, before the text is finished.
    private static func decodeBytes(
        _ data: Data, fileName: String, readsDeclarations: Bool, policy: EncodingPolicy
    ) throws -> DecodedText {
        // 0. The listener's choice, which overrules everything the bytes say.
        if case let .chosen(identifier) = policy {
            return try chosenText(data, identifier: identifier, fileName: fileName)
        }

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

        // 2. UTF-16 or UTF-32 without a mark, recognized by the structure of its bytes.
        if let unmarked = unmarkedUnicode(in: data) {
            return DecodedText(text: unmarked.text, encoding: unmarked.encoding, basis: .unmarkedUnicode)
        }

        // 3. A file in a 7-bit encoding the policy names (ISO-2022-JP), which
        // is valid UTF-8 too and so is looked for before UTF-8 is.
        if let sevenBit = sevenBitText(data, policy: policy) {
            return sevenBit
        }

        // 3a. An HTML file that declares ISO-2022-JP, for the policies that
        // left the bytes to the fallback or to UTF-8 (not a recorded
        // encoding, which the book keeps).
        if readsDeclarations, !policy.isRecorded, let declared = declaredSevenBitText(data) {
            return declared
        }

        // 3b. Valid UTF-8.
        if let text = String(data: data, encoding: .utf8) {
            return DecodedText(text: text, encoding: .utf8, basis: .validUTF8)
        }

        // 4. The encoding an HTML file declares.
        if readsDeclarations, let label = declaredEncodingLabel(in: data),
           let declared = try declaredText(data, label: label, fileName: fileName) {
            return declared
        }

        // 5. The book's policy: the encoding it recorded, or a guess.
        if let settled = settledText(data, policy: policy) {
            return settled
        }

        // 6. The fallback, which reads every byte.
        return fallbackText(data)
    }

    /// `data` read in a 7-bit encoding (ISO-2022-JP) when `policy` names one:
    /// the guessing policy, when the file is well formed ISO-2022-JP
    /// (`TextEncodingGuesser.guessSevenBit(_:)`), and the recorded policy,
    /// when the book recorded such an encoding and the bytes still read in
    /// it. Nil for every other policy and file, which leaves the bytes to
    /// the steps after: a file in one of these encodings is valid UTF-8, and
    /// every book read before guesses were recorded reads it so.
    private static func sevenBitText(_ data: Data, policy: EncodingPolicy) -> DecodedText? {
        switch policy {
        case .fallback, .chosen:
            // A choice was read before any of the steps (`chosenText`).
            return nil
        case let .recorded(identifier):
            // The file must still be well formed in the encoding: Foundation's
            // reader would let a changed file through.
            guard TextEncodingCatalog.entry(forIdentifier: identifier)?.isSevenBit == true,
                  let guess = TextEncodingGuesser.guessSevenBit(data) else { return nil }
            return DecodedText(text: guess.text, encoding: guess.encoding, basis: .recorded)
        case .guess:
            guard let guess = TextEncodingGuesser.guessSevenBit(data) else { return nil }
            return DecodedText(text: guess.text, encoding: guess.encoding, basis: .guess)
        }
    }

    /// `data`, an HTML file, read in ISO-2022-JP when its own declaration
    /// names that encoding and the bytes are well formed in it with a shift
    /// into JIS X 0208, which a 7-bit text with no Japanese in it lacks (it
    /// reads the same as UTF-8 and ASCII, so it is left to them). ISO-2022-JP
    /// is valid UTF-8, so the declaration is never reached for it
    /// (step 4); the guessing policy finds such a file by its structure
    /// (`TextEncodingGuesser.guessSevenBit(_:)`), but a book without a
    /// recorded encoding was left reading the escape sequences as text.
    /// Nil for any other file, and for a declaration whose bytes are not
    /// well formed, which is left to UTF-8 as it always was.
    private static func declaredSevenBitText(_ data: Data) -> DecodedText? {
        guard data.contains(0x1B), let label = declaredEncodingLabel(in: data),
              encoding(forLabel: label) == .iso2022JP,
              let guess = TextEncodingGuesser.guessSevenBit(data) else { return nil }
        return DecodedText(text: guess.text, encoding: guess.encoding, basis: .declaration(label: label))
    }

    /// `data` read as `policy` says to read bytes that name no encoding, or
    /// nil when the policy leaves them to the fallback: it says to, the
    /// recorded encoding is one TextMouth does not know or the bytes are not
    /// valid in it (a changed file, or a record from a later TextMouth), or
    /// no guess can be trusted.
    private static func settledText(_ data: Data, policy: EncodingPolicy) -> DecodedText? {
        switch policy {
        case .fallback, .chosen:
            // A choice was read before any of the steps (`chosenText`).
            return nil
        case let .recorded(identifier):
            // A 7-bit encoding was tried before UTF-8 (`sevenBitText`); bytes
            // that got this far are not in it, and Foundation's reader would
            // let them through.
            guard let entry = TextEncodingCatalog.entry(forIdentifier: identifier), !entry.isSevenBit,
                  let text = decodedText(data, in: entry.encoding) else { return nil }
            return DecodedText(text: text, encoding: entry.encoding, basis: .recorded)
        case .guess:
            guard let guess = TextEncodingGuesser.guess(data) else { return nil }
            return DecodedText(text: guess.text, encoding: guess.encoding, basis: .guess)
        }
    }

    // MARK: The Listener's Choice

    /// The identifier a book records when the listener chooses UTF-8 for it
    /// in Book Information (encodingchoice): its IANA name in lowercase, as
    /// the catalog spells the others. UTF-8 is not in the catalog, which
    /// holds the encodings a guess can name; a guess never names UTF-8,
    /// which the decoder finds by its bytes.
    static let utf8Identifier = "utf-8"

    /// The encoding a book chosen to be read in `identifier` is read in,
    /// in any letter case: UTF-8 (`utf8Identifier`) or one of the catalog's;
    /// nil for one this TextMouth does not know. The one place UTF-8's
    /// identifier is told from the catalog's: everything that names or
    /// offers a choice goes through it.
    static func chosenEncoding(forIdentifier identifier: String) -> String.Encoding? {
        if identifier.lowercased() == utf8Identifier {
            return .utf8
        }
        return TextEncodingCatalog.entry(forIdentifier: identifier)?.encoding
    }

    /// What a listener hears for the encoding a book is chosen to be read
    /// in: "UTF-8", the catalog's name for one of its own ("Shift JIS
    /// (Japanese)"), or the identifier itself for one it does not know, so
    /// that nothing recorded is ever left unnamed.
    static func chosenEncodingName(forIdentifier identifier: String) -> String {
        chosenEncoding(forIdentifier: identifier).map(TextEncodingWording.name(of:)) ?? identifier
    }

    /// `data` read in the encoding the listener chose for the book,
    /// `identifier`, whatever the bytes say of themselves, with nothing
    /// dropped or replaced (`strictlyDecodedText(_:in:)`).
    /// - Throws: `TextEncodingError.unknownChosenEncoding` for an identifier
    ///   this TextMouth does not know, and
    ///   `TextEncodingError.invalidForChosenEncoding` when a byte is not
    ///   valid in the encoding.
    private static func chosenText(_ data: Data, identifier: String, fileName: String) throws -> DecodedText {
        guard let encoding = chosenEncoding(forIdentifier: identifier) else {
            throw TextEncodingError.unknownChosenEncoding(file: fileName, identifier: identifier)
        }
        guard let text = strictlyDecodedText(data, in: encoding) else {
            throw TextEncodingError.invalidForChosenEncoding(
                file: fileName, encoding: chosenEncodingName(forIdentifier: identifier)
            )
        }
        return DecodedText(text: text, encoding: encoding, basis: .chosen)
    }

    /// `data` read in `encoding` strictly: every byte belongs to a character
    /// the encoding defines, and none is dropped or replaced. Nil when one
    /// does not.
    ///
    /// - Windows-1252, and the encodings read as it (ISO Latin 1, ASCII),
    ///   give every byte a character (`windows1252Text(_:)`).
    /// - Foundation's UTF-8 reader refuses every malformed sequence: a
    ///   stray continuation, an overlong form, a surrogate, a character cut
    ///   off at the end.
    /// - A multi-byte encoding's bytes must first keep to its grammar
    ///   (`TextEncodingByteGrammar`), since Foundation's readers of several
    ///   let malformed bytes through, taking a following letter into another
    ///   character.
    /// - Any other encoding is read by Foundation, which refuses a byte the
    ///   encoding does not define rather than replace it; a replacement
    ///   character in the result, which none of these encodings defines a
    ///   byte as, is refused too.
    ///
    /// This is not the guesser's rule, which also asks the text to write
    /// back to the same bytes (`TextEncodingGuesser.guess(_:)`): that refuses
    /// valid text in encodings with two codes for one character, as Windows
    /// writes "髙" in CP932 (0xFB 0xFC, written back by Foundation as 0xEE
    /// 0xE0), which a listener choosing Shift JIS must be able to read.
    static func strictlyDecodedText(_ data: Data, in encoding: String.Encoding) -> String? {
        if windows1252Equivalents.contains(encoding) {
            return windows1252Text(data)
        }
        if encoding == .utf8 {
            return String(data: data, encoding: .utf8)
        }
        if let grammar = TextEncodingByteGrammar.of(encoding), !grammar.admits(data) {
            return nil
        }
        guard let text = String(data: data, encoding: encoding), !text.unicodeScalars.contains("\u{FFFD}") else {
            return nil
        }
        return text
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

    // MARK: Unmarked Unicode

    /// UTF-16 or UTF-32 text written without a byte-order mark, read: the
    /// text and its encoding, or nil when the bytes do not show either.
    ///
    /// Four rules look for it, each of which names the byte order from the
    /// structure of the bytes alone. They run in this order, and the first
    /// that names an encoding decides:
    /// 1. UTF-16 in a Latin script (`unmarkedUTF16Encoding(of:)`), the rule
    ///    that has always been here.
    /// 2. UTF-32 (`unmarkedUTF32Encoding(of:)`).
    /// 3. UTF-16 in an alphabet (`UTF16ByteStatistics.isAlphabetic(_:)`).
    /// 4. UTF-16 in any other script, such as Chinese, Japanese, or Korean
    ///    (`UTF16ByteStatistics.isAnchoredByZeros(_:)`).
    ///
    /// The text rules 2 to 4 give must also read as text
    /// (`isPlausibleText(_:)`): no control character, noncharacter, or
    /// private-use character, and no unpaired surrogate, which bytes of
    /// another kind, read as UTF-16, almost always hold. Rule 1's text is
    /// taken as it is, as it always was.
    ///
    /// Not every unmarked UTF-16 can be told. Chinese, Japanese, and Korean
    /// UTF-16 with no ASCII character in it, no line ending even, reads in
    /// the same bytes as text in Shift JIS, GBK, or EUC read two bytes at a
    /// time, and Indic scripts' high bytes are the tab, line feed, and
    /// carriage return of ordinary text. Both are left to the steps after
    /// this one, where a missed recognition costs less than a wrong one.
    static func unmarkedUnicode(in data: Data) -> (text: String, encoding: String.Encoding)? {
        // Rule 1.
        if let latin = unmarkedUTF16Encoding(of: data), let text = unicodeText(data, as: latin) {
            return (text, latin)
        }
        // Rules 2 to 4. A byte order that the structure names but whose text is not
        // plausible is refused, with no other rule asked.
        guard let encoding = unmarkedUTF32Encoding(of: data) ?? unmarkedStructuredUTF16Encoding(of: data),
              let text = unicodeText(data, as: encoding), isPlausibleText(text) else { return nil }
        return (text, encoding)
    }

    /// The byte order of UTF-32 text written without a mark, or nil when the
    /// bytes do not show one. The length must be a whole number of at least
    /// two code units, and every code unit must have its top byte zero and
    /// the byte below it no more than 0x10, since no code point is beyond
    /// U+10FFFF: in one byte order and not the other, and not all of them
    /// zero. Text in UTF-8, UTF-16, or a single- or double-byte encoding
    /// never holds a zero byte at every fourth position, and almost never a
    /// zero byte at all. (Whether the code points read as text is for
    /// `unmarkedUnicode(in:)` to ask.)
    static func unmarkedUTF32Encoding(of data: Data) -> String.Encoding? {
        guard data.count >= 8, data.count.isMultiple(of: 4) else { return nil }
        return data.withUnsafeBytes { bytes -> String.Encoding? in
            // Whether each byte order can hold every unit so far, and whether any unit is not zero.
            var littleEndianFits = true
            var bigEndianFits = true
            var anyNonZeroUnit = false
            for index in stride(from: 0, to: bytes.count, by: 4) {
                if bytes[index + 3] != 0 || bytes[index + 2] > 0x10 { littleEndianFits = false }
                if bytes[index] != 0 || bytes[index + 1] > 0x10 { bigEndianFits = false }
                // Neither byte order can hold the units: not UTF-32, and the usual case, at the first unit.
                if !littleEndianFits && !bigEndianFits { return nil }
                if bytes[index] != 0 || bytes[index + 1] != 0 || bytes[index + 2] != 0 || bytes[index + 3] != 0 {
                    anyNonZeroUnit = true
                }
            }
            // Both orders fit only when every unit is zero.
            guard anyNonZeroUnit, littleEndianFits != bigEndianFits else { return nil }
            return littleEndianFits ? .utf32LittleEndian : .utf32BigEndian
        }
    }

    /// The byte order of UTF-16 text that is not in a Latin script and has no
    /// mark, by rules 3 and 4 of `unmarkedUnicode(in:)`, or nil when neither
    /// byte order shows it, or both do.
    private static func unmarkedStructuredUTF16Encoding(of data: Data) -> String.Encoding? {
        guard let statistics = UTF16ByteStatistics(data) else { return nil }
        // An alphabet's text names its byte order by the one high byte its
        // letters share; text in another script by the zeros of its ASCII
        // characters.
        let orders: [(encoding: String.Encoding, units: UTF16ByteStatistics.Order)] = [
            (.utf16LittleEndian, statistics.littleEndian), (.utf16BigEndian, statistics.bigEndian),
        ]
        let showing = orders.filter {
            UTF16ByteStatistics.isAlphabetic($0.units) || UTF16ByteStatistics.isAnchoredByZeros($0.units)
        }
        return showing.count == 1 ? showing[0].encoding : nil
    }

    /// Whether `text`, read from bytes that were taken for Unicode text by
    /// their structure, reads as text: it is not empty, and every character
    /// is a printable one, a tab, a line ending, or a form feed. A control
    /// character (other than those), a noncharacter, a private-use
    /// character, and the replacement character are what bytes of some other
    /// kind read as UTF-16 or UTF-32 produce, and the first of them refuses
    /// the reading.
    private static func isPlausibleText(_ text: String) -> Bool {
        !text.unicodeScalars.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0C, 0x0D:
                return true
            case 0x00...0x1F, 0x7F...0x9F, 0xE000...0xF8FF, 0xFDD0...0xFDEF, 0xFFFD, 0xF0000...0x10FFFF:
                return false
            default:
                // U+FFFE and U+FFFF, and the last two code points of every plane.
                return scalar.value & 0xFFFE != 0xFFFE
            }
        }
    }

    /// Counts of the bytes of 16-bit code units, taken in each byte order,
    /// from which `unmarkedStructuredUTF16Encoding(of:)` judges UTF-16 that
    /// has no mark and is not in a Latin script. One pass over the bytes
    /// fills both orders.
    private struct UTF16ByteStatistics {
        /// What one byte order shows of the code units.
        struct Order {
            /// How many code units have each value as their high byte.
            var highByteCounts = [Int](repeating: 0, count: 256)
            /// How many code units have a zero low byte.
            var zeroLowBytes = 0
            /// How many code units have a nonzero high byte.
            var nonZeroHighBytes = 0
            /// How many of those have a low byte of 0x80 or more.
            var nonZeroHighBytesWithHighBitLow = 0

            /// Add the code unit whose bytes are `high` and `low`.
            mutating func add(high: UInt8, low: UInt8) {
                highByteCounts[Int(high)] += 1
                if low == 0 { zeroLowBytes += 1 }
                if high != 0 {
                    nonZeroHighBytes += 1
                    if low >= 0x80 { nonZeroHighBytesWithHighBitLow += 1 }
                }
            }
        }

        /// The code units read little-endian (high byte second).
        let littleEndian: Order
        /// The code units read big-endian (high byte first).
        let bigEndian: Order

        /// The fewest code units with a nonzero high byte that can show a
        /// rule: fewer is too little text to tell from chance.
        static let minimumNonZeroHighBytes = 8
        /// The high bytes of the alphabets whose letters share one: Greek
        /// (U+03xx), Cyrillic (U+04xx), Armenian and Hebrew (U+05xx), and
        /// Arabic (U+06xx). The tab, line feed, and carriage return are 0x09,
        /// 0x0A, and 0x0D, so the scripts at U+09xx to U+0Dxx are left out:
        /// a list of single characters, one to a line, would read as them.
        static let alphabetHighBytes: ClosedRange<Int> = 0x03...0x06

        /// The statistics of `data`, or nil when its length is odd or too
        /// short to hold `minimumNonZeroHighBytes` code units.
        init?(_ data: Data) {
            guard data.count.isMultiple(of: 2), data.count >= 2 * Self.minimumNonZeroHighBytes else { return nil }
            var little = Order()
            var big = Order()
            data.withUnsafeBytes { bytes in
                for index in stride(from: 0, to: bytes.count, by: 2) {
                    // The unit's two bytes, as a little-endian (low byte first)
                    // and a big-endian (high byte first) reading take them.
                    little.add(high: bytes[index + 1], low: bytes[index])
                    big.add(high: bytes[index], low: bytes[index + 1])
                }
            }
            littleEndian = little
            bigEndian = big
        }

        /// Whether the units show UTF-16 in an alphabet: at least
        /// `minimumNonZeroHighBytes` of them have a nonzero high byte, and
        /// at least 85% of those share one high byte of
        /// `alphabetHighBytes`. Ordinary text has no ETX, EOT, ENQ, or ACK
        /// in it, whichever way its bytes pair, and the share leaves room for
        /// the punctuation among the letters (a dash, a quotation mark).
        static func isAlphabetic(_ order: Order) -> Bool {
            guard order.nonZeroHighBytes >= minimumNonZeroHighBytes else { return false }
            let shared = alphabetHighBytes.map { order.highByteCounts[$0] }.max() ?? 0
            return shared * 100 >= order.nonZeroHighBytes * 85
        }

        /// Whether the units show UTF-16 in some other script by the zeros
        /// of its ASCII characters: at least two code units have a zero high
        /// byte (the line endings of a text, a space, a digit), at most one
        /// unit in four of those has a zero low byte (the characters 一, 가,
        /// and a blank braille cell do; read in the other byte order, the
        /// zeros of the ASCII characters are all low bytes), and at least 15% of the units with a nonzero high byte
        /// have a low byte of 0x80 or more, as Chinese, Japanese, and Korean
        /// characters do, and ASCII text, with or without the zeros a
        /// fixed-width export pads it with, never does. Text in UTF-8 or any
        /// 8-bit encoding holds no zero byte at all.
        static func isAnchoredByZeros(_ order: Order) -> Bool {
            order.nonZeroHighBytes >= minimumNonZeroHighBytes
                && order.highByteCounts[0] >= 2
                && order.zeroLowBytes * 4 <= order.highByteCounts[0]
                && order.nonZeroHighBytesWithHighBitLow * 100 >= order.nonZeroHighBytes * 15
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
        // Foundation refuses bytes that are not valid in the encoding rather
        // than replacing them, so a result holds every byte.
        guard let text = decodedText(data, in: encoding) else {
            throw TextEncodingError.invalidForDeclaredEncoding(file: fileName, label: label)
        }
        // Windows-1252 and its equivalents all report as Windows-1252, the
        // encoding the text was truly read in.
        let readEncoding = windows1252Equivalents.contains(encoding) ? String.Encoding.windowsCP1252 : encoding
        return DecodedText(text: text, encoding: readEncoding, basis: .declaration(label: label))
    }

    /// `data` read in `encoding` by the one rule every reader of a labelled
    /// encoding shares: ISO Latin 1, ASCII, and Windows-1252 are all read as
    /// Windows-1252, as browsers read them (see `windows1252Equivalents`), so
    /// the bytes 0x80 through 0x9F are curly quotation marks, dashes, and the
    /// euro sign, never invisible control characters. Any other encoding is
    /// read by Foundation. Internal because the web archive reader
    /// (`WebArchiveReader`) reads its page the same way.
    /// - Returns: nil when the bytes are not valid in `encoding`.
    static func decodedText(_ data: Data, in encoding: String.Encoding) -> String? {
        if windows1252Equivalents.contains(encoding) {
            return windows1252Text(data)
        }
        return String(data: data, encoding: encoding)
    }

    /// The encoding a declaration's label names, by the IANA names and
    /// aliases Core Foundation knows ("latin1", "cp1252", "Shift_JIS"), in
    /// any letter case. Nil for a label it does not know. Internal because
    /// the web archive reader (`WebArchiveReader`) names its page's
    /// encoding the same way.
    static func encoding(forLabel label: String) -> String.Encoding? {
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

    /// `text` without the U+FEFF characters at its start. Internal because
    /// the web archive reader (`WebArchiveReader`) finishes its text the
    /// same way.
    static func droppingLeadingByteOrderMarks(_ text: String) -> String {
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
