import Foundation

// MARK: - Text Encoding Catalog

/// The text encodings, beyond Unicode, that TextMouth can read a text file
/// in when nothing in the file names its encoding (FMT16): each with the
/// identifier a book records it under (`Book.textEncoding`) and the name a
/// listener hears in Book Information ("Windows-1251 (Cyrillic)").
///
/// The catalog is the one list `TextEncodingGuesser` draws on: it always
/// tries the entries marked `isAlwaysTried`, and takes any other entry only
/// when Foundation's own guess names it (an encoding Foundation names that
/// is not here is left out, because a reading TextMouth cannot name well is
/// not worth the risk of a wrong guess).
enum TextEncodingCatalog {

    /// One encoding of the catalog.
    struct Entry: Equatable, Sendable {
        /// The identifier a book records for the encoding: its IANA name in
        /// lowercase, as Core Foundation spells it ("windows-1251",
        /// "koi8-r", "macintosh", "cp932"). Looked up again on every later
        /// reading of the book, so it never changes.
        let identifier: String
        /// The encoding Foundation reads and writes it with.
        let encoding: String.Encoding
        /// What names it: entries that read alike share one label.
        let label: Label
        /// What a listener hears: the encoding's name, then the language or
        /// script it is for, such as "Windows-1251 (Cyrillic)".
        var name: String { label.name }
        /// Whether the guesser reads every file in this encoding to compare
        /// the readings. The rest are read only when Foundation's guess
        /// names them.
        let isAlwaysTried: Bool
        /// Whether the encoding writes only 7-bit bytes, switching character
        /// sets with escape sequences (ISO-2022-JP). A file in it is valid
        /// UTF-8 as well, so it cannot be told from UTF-8 by its bytes being
        /// invalid, and the decoder looks for it before it takes bytes for
        /// UTF-8 (`TextFileDecoder`), when the policy allows.
        let isSevenBit: Bool
    }

    /// The names of the encodings the catalog holds, one case for each name: Windows' variant of an
    /// encoding and the standard it extends are named alike ("Shift JIS (Japanese)" for CP932 and
    /// Shift_JIS), so they share a case. A case is a stable identity for a name, which
    /// `TextEncodingChoices` compares in place of the localized text.
    enum Label: Hashable, Sendable {
        case windows1252
        case macRoman
        case iso885915
        case cp437
        case cp850
        case windows1250
        case iso88592
        case macCentralEuropean
        case windows1251
        case koi8R
        case koi8U
        case cp866
        case iso88595
        case macCyrillic
        case windows1253
        case iso88597
        case windows1254
        case iso88599
        case windows1255
        case iso88598
        case windows1256
        case iso88596
        case windows1257
        case iso885913
        case windows874
        case shiftJIS
        case eucJP
        case iso2022JP
        case gb18030
        case gbk
        case gb2312
        case big5
        case eucKR

        /// What a listener hears: the encoding's name, then the language or script it is for, such as
        /// "Windows-1251 (Cyrillic)". Localized as a whole, so a language writes the script its own way.
        var name: String {
            switch self {
            case .windows1252:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.windows1252", "Windows-1252 (Western European)")
            case .macRoman:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.macRoman", "Mac Roman (Western European)")
            case .iso885915:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.iso885915", "ISO 8859-15 (Western European)")
            case .cp437:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.cp437", "CP437 (US DOS)")
            case .cp850:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.cp850", "CP850 (Western European DOS)")
            case .windows1250:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.windows1250", "Windows-1250 (Central European)")
            case .iso88592:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.iso88592", "ISO 8859-2 (Central European)")
            case .macCentralEuropean:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: an encoding of the classic Mac OS, named by its script. The word Mac stays as it is.
                return InterfaceText.line("label.name.macCentralEuropean", "Mac Central European")
            case .windows1251:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.windows1251", "Windows-1251 (Cyrillic)")
            case .koi8R:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.koi8R", "KOI8-R (Russian)")
            case .koi8U:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.koi8U", "KOI8-U (Ukrainian)")
            case .cp866:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.cp866", "CP866 (Russian DOS)")
            case .iso88595:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.iso88595", "ISO 8859-5 (Cyrillic)")
            case .macCyrillic:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: an encoding of the classic Mac OS, named by its script. The word Mac stays as it is.
                return InterfaceText.line("label.name.macCyrillic", "Mac Cyrillic")
            case .windows1253:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.windows1253", "Windows-1253 (Greek)")
            case .iso88597:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.iso88597", "ISO 8859-7 (Greek)")
            case .windows1254:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.windows1254", "Windows-1254 (Turkish)")
            case .iso88599:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.iso88599", "ISO 8859-9 (Turkish)")
            case .windows1255:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.windows1255", "Windows-1255 (Hebrew)")
            case .iso88598:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.iso88598", "ISO 8859-8 (Hebrew)")
            case .windows1256:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.windows1256", "Windows-1256 (Arabic)")
            case .iso88596:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.iso88596", "ISO 8859-6 (Arabic)")
            case .windows1257:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.windows1257", "Windows-1257 (Baltic)")
            case .iso885913:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.iso885913", "ISO 8859-13 (Baltic)")
            case .windows874:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.windows874", "Windows-874 (Thai)")
            case .shiftJIS:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.shiftJIS", "Shift JIS (Japanese)")
            case .eucJP:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.eucJP", "EUC-JP (Japanese)")
            case .iso2022JP:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.iso2022JP", "ISO 2022-JP (Japanese)")
            case .gb18030:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.gb18030", "GB 18030 (Simplified Chinese)")
            case .gbk:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.gbk", "GBK (Simplified Chinese)")
            case .gb2312:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.gb2312", "GB 2312 (Simplified Chinese)")
            case .big5:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.big5", "Big5 (Traditional Chinese)")
            case .eucKR:
                // Translators: The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.
                return InterfaceText.line("label.name.eucKR", "EUC-KR (Korean)")
            }
        }
    }

    /// The identifier of Windows-1252, the encoding every text file is read
    /// in when nothing says otherwise (`TextFileDecoder`'s fallback).
    static let windows1252Identifier = "windows-1252"

    // MARK: Entries

    /// The catalog. When two encodings read a file alike, the guesser names
    /// the one that comes first here (KOI8-R before KOI8-U, Windows-1250
    /// before ISO 8859-2 before Mac Central European, Mac Roman before Mac
    /// Cyrillic). An entry's identifier is Core Foundation's canonical IANA
    /// name for its encoding.
    static let entries: [Entry] = [
        // Western European. Windows-1252 is the default reading, here to be
        // named; ISO Latin 1 is read as it is, so it has no entry of its own.
        row("windows-1252", .windows1252),
        row("macintosh", .macRoman, tried: true),
        row("iso-8859-15", .iso885915, tried: true),
        // The DOS code pages of the United States and Western Europe, which
        // older text files from DOS and the Windows console still hold. Each
        // is taken only when Foundation's guess names it (not always tried),
        // and each is named apart, so the pop-up in Book Information offers
        // both.
        row("cp437", .cp437),
        row("cp850", .cp850),
        // Central European.
        row("windows-1250", .windows1250, tried: true),
        row("iso-8859-2", .iso88592, tried: true),
        row("x-mac-centraleurroman", .macCentralEuropean),
        // Cyrillic.
        row("windows-1251", .windows1251, tried: true),
        row("koi8-r", .koi8R, tried: true),
        row("koi8-u", .koi8U, tried: true),
        row("cp866", .cp866, tried: true),
        row("iso-8859-5", .iso88595, tried: true),
        row("x-mac-cyrillic", .macCyrillic, tried: true),
        // Greek, Turkish, Hebrew, Arabic, Baltic, and Thai. Hebrew is read
        // always, in Windows-1255 (ISO 8859-8 reads the same letters): its
        // letters are bytes that every Cyrillic encoding reads as clean
        // lowercase letters, so a short Hebrew text reads as well as
        // Windows-1251 as it does as Hebrew, and Foundation's guess names such
        // a text Windows-1251. The guesser must see both to see the tie.
        row("windows-1253", .windows1253),
        row("iso-8859-7", .iso88597),
        row("windows-1254", .windows1254),
        row("iso-8859-9", .iso88599),
        row("windows-1255", .windows1255, tried: true),
        row("iso-8859-8", .iso88598),
        row("windows-1256", .windows1256),
        row("iso-8859-6", .iso88596),
        row("windows-1257", .windows1257),
        row("iso-8859-13", .iso885913),
        row("cp874", .windows874),
        // Japanese, Chinese, and Korean. Windows' variants and the standards
        // they extend are named alike: they differ in a few symbols only.
        row("cp932", .shiftJIS),
        row("shift_jis", .shiftJIS),
        row("euc-jp", .eucJP),
        row("iso-2022-jp", .iso2022JP, sevenBit: true),
        row("gb18030", .gb18030),
        row("gbk", .gbk),
        row("cp936", .gbk),
        row("gb2312", .gb2312),
        row("big5", .big5),
        row("cp950", .big5),
        row("euc-kr", .eucKR),
        row("cp949", .eucKR),
    ].compactMap { $0 }

    /// The entry for `identifier`, in any letter case, or nil for an
    /// identifier the catalog does not know (one a later TextMouth recorded,
    /// or a damaged value).
    static func entry(forIdentifier identifier: String) -> Entry? {
        let key = identifier.lowercased()
        return entries.first { $0.identifier == key }
    }

    /// The entry that reads with `encoding`, or nil for an encoding the
    /// catalog does not hold. Each entry has an encoding of its own (a test
    /// pins it), though Windows' Shift JIS, GBK, Big5, and EUC-KR share a
    /// name with the standard they extend.
    static func entry(for encoding: String.Encoding) -> Entry? {
        entries.first { $0.encoding == encoding }
    }

    /// What a listener hears for the encoding recorded as `identifier`: the
    /// catalog's name for it, or the identifier itself for one it does not
    /// know, so that nothing recorded is ever left unnamed.
    static func name(forIdentifier identifier: String) -> String {
        entry(forIdentifier: identifier)?.name ?? identifier
    }

    // MARK: Building Entries

    /// An entry for the encoding Core Foundation knows by the IANA name
    /// `identifier`, or nil on a Mac whose Core Foundation does not know it,
    /// which leaves the entry out instead of failing the app.
    private static func row(_ identifier: String, _ label: Label, tried: Bool = false, sevenBit: Bool = false) -> Entry? {
        guard let encoding = TextFileDecoder.encoding(forLabel: identifier) else { return nil }
        return Entry(identifier: identifier, encoding: encoding, label: label, isAlwaysTried: tried, isSevenBit: sevenBit)
    }
}
