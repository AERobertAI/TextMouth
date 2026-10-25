import Foundation

// MARK: - The Bytes of a Multi-Byte Encoding

/// Which byte sequences make the characters of a multi-byte encoding: the
/// bytes that stand alone, and the bytes that begin a character of two, three,
/// or four bytes, with the bytes that may follow them. A file is read in such
/// an encoding strictly (`TextFileDecoder.strictlyDecodedText(_:in:)`) only
/// when every byte belongs to one of its characters.
///
/// Foundation's readers of several of these encodings let malformed bytes
/// through instead of refusing them, as measured on macOS 26.3 (October 24,
/// 2026):
/// - EUC-JP and GB 2312 read a byte that cannot follow a lead byte as though
///   its top bit were set, so "A", 0xA1, "B" in EUC-JP reads as "A‖": the
///   letter B is taken into another character;
/// - Shift JIS reads 0x7F after a lead byte as 0x80;
/// - EUC-JP reads its single shift 0x8E before any byte, giving a full-width
///   character for "A", 0x8E, "B";
/// - ISO-2022-JP reads bytes above ASCII as Latin 1, and a cut-off escape
///   sequence as the escape and its letters;
/// - GB 18030 reads a lone 0x80 as the euro sign.
///
/// Checking the bytes against the grammar first refuses all of these. Which
/// characters an encoding defines is still Foundation's to say: a well formed
/// sequence it does not define is refused by Foundation's own reader. A test
/// pins that every multi-byte encoding of the catalog has a grammar here.
///
/// What no grammar can mend, since Foundation's reader decides it (review of
/// October 24, item 7): the euro sign in Big5 and CP950 (0xA3 0xE1) and in
/// EUC-KR and CP949 (0xA2 0xE6) is refused; Big5-HKSCS's characters (0x87
/// 0x40 and up) are refused, even through Core Foundation's own big5-hkscs;
/// CP950's 0xA2 0xCC reads as 十 followed by a private-use character
/// (U+F87F), which a braille display shows; and a GB 18030 file holding a
/// literal U+FFFD is refused by the replacement-character check
/// (`TextFileDecoder.strictlyDecodedText(_:in:)`).
enum TextEncodingByteGrammar: Sendable {
    /// Bytes that may stand at one position of a character.
    typealias Position = [ClosedRange<UInt8>]
    /// A character's bytes: what each of its positions may hold, in order.
    typealias Sequence = [Position]

    /// An encoding whose characters are the sequences listed. The sequences
    /// are tried in order at each character, and each must leave no doubt
    /// which one a character is: two sequences that begin alike differ in a
    /// later byte (GB 18030's two-byte and four-byte forms differ in their
    /// second byte).
    case sequences([Sequence])
    /// ISO-2022-JP, a 7-bit encoding that switches character sets with
    /// escape sequences (`isWellFormedISO2022JP(_:requiringAShift:)`).
    case iso2022JP

    // MARK: The Grammars

    /// ASCII, which every one of these encodings keeps as itself.
    private static let ascii: Sequence = [[0x00...0x7F]]

    /// Shift JIS and Windows' variant of it (CP932): ASCII, the half-width
    /// katakana 0xA1 to 0xDF alone, and pairs whose lead byte is 0x81 to 0x9F
    /// or 0xE0 to 0xFC and whose second byte is 0x40 to 0xFC but not 0x7F.
    static let shiftJIS = TextEncodingByteGrammar.sequences([
        [[0x00...0x7F, 0xA1...0xDF]],
        [[0x81...0x9F, 0xE0...0xFC], [0x40...0x7E, 0x80...0xFC]],
    ])

    /// EUC-JP: ASCII; pairs of 0xA1 to 0xFE (JIS X 0208); and the single
    /// shift 0x8E before a half-width katakana, 0xA1 to 0xDF. The single shift
    /// 0x8F before a pair (JIS X 0212) is refused, though EUC-JP has it:
    /// Foundation's reader takes the last of its three bytes for the start of
    /// another character, so "Le café." with é written so (0x8F 0xAB 0xB1)
    /// reads "Le café窺" (review of October 24, finding 1).
    static let eucJP = TextEncodingByteGrammar.sequences([
        ascii,
        [[0xA1...0xFE], [0xA1...0xFE]],
        [[0x8E...0x8E], [0xA1...0xDF]],
    ])

    /// The EUC encodings of one double-byte character set, GB 2312 (EUC-CN)
    /// and EUC-KR: ASCII, and pairs of 0xA1 to 0xFE.
    static let euc = TextEncodingByteGrammar.sequences([
        ascii,
        [[0xA1...0xFE], [0xA1...0xFE]],
    ])

    /// GBK and Windows' variant of it (CP936): ASCII, and pairs whose lead
    /// byte is 0x81 to 0xFE and whose second byte is 0x40 to 0xFE but not
    /// 0x7F.
    static let gbk = TextEncodingByteGrammar.sequences([
        ascii,
        [[0x81...0xFE], [0x40...0x7E, 0x80...0xFE]],
    ])

    /// GB 18030: GBK's sequences, and four-byte characters of a lead byte
    /// 0x81 to 0xFE, a digit, another 0x81 to 0xFE, and another digit.
    static let gb18030 = TextEncodingByteGrammar.sequences([
        ascii,
        [[0x81...0xFE], [0x40...0x7E, 0x80...0xFE]],
        [[0x81...0xFE], [0x30...0x39], [0x81...0xFE], [0x30...0x39]],
    ])

    /// Big5 and Windows' variant of it (CP950): ASCII, and pairs whose lead
    /// byte is 0x81 to 0xFE and whose second byte is 0x40 to 0x7E or 0xA1 to
    /// 0xFE.
    static let big5 = TextEncodingByteGrammar.sequences([
        ascii,
        [[0x81...0xFE], [0x40...0x7E, 0xA1...0xFE]],
    ])

    /// Windows' Korean encoding (CP949, Unified Hangul Code): ASCII, and
    /// pairs whose lead byte is 0x81 to 0xFE and whose second byte is a
    /// letter, 0x41 to 0x5A or 0x61 to 0x7A, or 0x81 to 0xFE.
    static let unifiedHangul = TextEncodingByteGrammar.sequences([
        ascii,
        [[0x81...0xFE], [0x41...0x5A, 0x61...0x7A, 0x81...0xFE]],
    ])

    /// The grammar of each multi-byte encoding of the catalog, by the
    /// identifiers the catalog records them under (`TextEncodingCatalog`).
    static let grammarsByIdentifier: [(identifiers: [String], grammar: TextEncodingByteGrammar)] = [
        (["cp932", "shift_jis"], shiftJIS),
        (["euc-jp"], eucJP),
        (["iso-2022-jp"], iso2022JP),
        (["gb2312", "euc-kr"], euc),
        (["gbk", "cp936"], gbk),
        (["gb18030"], gb18030),
        (["big5", "cp950"], big5),
        (["cp949"], unifiedHangul),
    ]

    /// The grammars by the encodings Foundation reads them with, for the
    /// identifiers this Mac's Core Foundation knows.
    private static let grammarsByEncoding: [String.Encoding: TextEncodingByteGrammar] = {
        var grammars: [String.Encoding: TextEncodingByteGrammar] = [:]
        for (identifiers, grammar) in grammarsByIdentifier {
            for identifier in identifiers {
                if let encoding = TextFileDecoder.encoding(forLabel: identifier) {
                    grammars[encoding] = grammar
                }
            }
        }
        return grammars
    }()

    /// The grammar of `encoding`, or nil for an encoding of one byte to a
    /// character (or a Unicode one), whose every byte Foundation's reader
    /// either reads as a character of its own or refuses.
    static func of(_ encoding: String.Encoding) -> TextEncodingByteGrammar? {
        grammarsByEncoding[encoding]
    }

    // MARK: Checking Bytes

    /// Whether every byte of `data` belongs to a character of this grammar,
    /// with no character cut off at the end.
    func admits(_ data: Data) -> Bool {
        switch self {
        case .sequences(let sequences):
            return Self.isMadeOf(sequences, data)
        case .iso2022JP:
            return Self.isWellFormedISO2022JP(data, requiringAShift: false)
        }
    }

    /// Whether `data` is a run of the characters `sequences` describe.
    private static func isMadeOf(_ sequences: [Sequence], _ data: Data) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var index = 0
            while index < bytes.count {
                // ASCII stands alone in every one of these encodings, and is
                // most of most files, so it is passed over first.
                if bytes[index] < 0x80 {
                    index += 1
                    continue
                }
                guard let length = lengthOfCharacter(at: index, in: bytes, sequences: sequences) else { return false }
                index += length
            }
            return true
        }
    }

    /// The length of the character of `sequences` that begins at `index` of
    /// `bytes`, or nil when none does: a malformed byte, or a character cut
    /// off by the end of the bytes.
    private static func lengthOfCharacter(
        at index: Int,
        in bytes: UnsafeRawBufferPointer,
        sequences: [Sequence]
    ) -> Int? {
        nextSequence: for sequence in sequences {
            guard index + sequence.count <= bytes.count else { continue }
            for (offset, position) in sequence.enumerated() {
                let byte = bytes[index + offset]
                guard position.contains(where: { $0.contains(byte) }) else { continue nextSequence }
            }
            return sequence.count
        }
        return nil
    }

    // MARK: ISO-2022-JP

    /// The character sets an ISO-2022-JP file switches between.
    private enum ISO2022JPSet {
        /// ASCII or JIS Roman (ESC ( B, ESC ( J): one byte a character.
        case roman
        /// JIS X 0201's half-width katakana (ESC ( I), as Windows writes them
        /// in mail: one byte a character, 0x21 to 0x5F.
        case katakana
        /// JIS X 0208 (ESC $ @, ESC $ B): pairs of bytes from 0x21 to 0x7E.
        case kanji
    }

    /// Whether `data` is well formed ISO-2022-JP, as RFC 1468 defines it,
    /// with the half-width katakana Windows writes in mail, which
    /// Foundation's reader reads (review of October 24, item 6): only the
    /// escape sequences of `ISO2022JPSet`, each character as its set has it
    /// (controls, line breaks among them, stand anywhere but inside JIS X
    /// 0208), no byte above ASCII, no shift-out or shift-in, and a return to
    /// ASCII or JIS Roman before the end. With `requiringAShift`, as the
    /// guesser asks it (`TextEncodingGuesser.guessSevenBit(_:)`), the file
    /// must also shift into JIS X 0208 at least once, or it is plain ASCII,
    /// which every encoding reads alike and no guess needs; a file chosen to
    /// be read in ISO-2022-JP need not.
    static func isWellFormedISO2022JP(_ data: Data, requiringAShift: Bool) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var set = ISO2022JPSet.roman
            var holdsFirstByteOfPair = false
            var shifts = 0
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                // ISO-2022-JP writes no byte above ASCII, and no shift-out or shift-in.
                guard byte < 0x80, byte != 0x0E, byte != 0x0F else { return false }
                if byte == 0x1B {
                    // An escape sequence is three bytes, and never inside a pair.
                    guard !holdsFirstByteOfPair, index + 2 < bytes.count else { return false }
                    switch (bytes[index + 1], bytes[index + 2]) {
                    case (0x28, 0x42), (0x28, 0x4A):
                        set = .roman
                    case (0x28, 0x49):
                        set = .katakana
                    case (0x24, 0x40), (0x24, 0x42):
                        set = .kanji
                        shifts += 1
                    default:
                        return false
                    }
                    index += 3
                    continue
                }
                switch set {
                case .kanji:
                    guard (0x21...0x7E).contains(byte) else { return false }
                    holdsFirstByteOfPair.toggle()
                case .katakana:
                    // Half-width katakana are 0x21 to 0x5F; the controls below pass.
                    guard byte <= 0x5F else { return false }
                case .roman:
                    break
                }
                index += 1
            }
            return set == .roman && !holdsFirstByteOfPair && (shifts > 0 || !requiringAShift)
        }
    }
}
