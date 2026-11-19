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
                return String(localized: "Windows-1252 (Western European)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .macRoman:
                return String(localized: "Mac Roman (Western European)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .iso885915:
                return String(localized: "ISO 8859-15 (Western European)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .cp437:
                return String(localized: "CP437 (US DOS)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .cp850:
                return String(localized: "CP850 (Western European DOS)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .windows1250:
                return String(localized: "Windows-1250 (Central European)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .iso88592:
                return String(localized: "ISO 8859-2 (Central European)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .macCentralEuropean:
                return String(localized: "Mac Central European",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: an encoding of the classic Mac OS, named by its script. The word Mac stays as it is.")
            case .windows1251:
                return String(localized: "Windows-1251 (Cyrillic)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .koi8R:
                return String(localized: "KOI8-R (Russian)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .koi8U:
                return String(localized: "KOI8-U (Ukrainian)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .cp866:
                return String(localized: "CP866 (Russian DOS)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .iso88595:
                return String(localized: "ISO 8859-5 (Cyrillic)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .macCyrillic:
                return String(localized: "Mac Cyrillic",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: an encoding of the classic Mac OS, named by its script. The word Mac stays as it is.")
            case .windows1253:
                return String(localized: "Windows-1253 (Greek)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .iso88597:
                return String(localized: "ISO 8859-7 (Greek)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .windows1254:
                return String(localized: "Windows-1254 (Turkish)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .iso88599:
                return String(localized: "ISO 8859-9 (Turkish)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .windows1255:
                return String(localized: "Windows-1255 (Hebrew)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .iso88598:
                return String(localized: "ISO 8859-8 (Hebrew)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .windows1256:
                return String(localized: "Windows-1256 (Arabic)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .iso88596:
                return String(localized: "ISO 8859-6 (Arabic)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .windows1257:
                return String(localized: "Windows-1257 (Baltic)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .iso885913:
                return String(localized: "ISO 8859-13 (Baltic)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .windows874:
                return String(localized: "Windows-874 (Thai)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .shiftJIS:
                return String(localized: "Shift JIS (Japanese)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .eucJP:
                return String(localized: "EUC-JP (Japanese)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .iso2022JP:
                return String(localized: "ISO 2022-JP (Japanese)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .gb18030:
                return String(localized: "GB 18030 (Simplified Chinese)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .gbk:
                return String(localized: "GBK (Simplified Chinese)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .gb2312:
                return String(localized: "GB 2312 (Simplified Chinese)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .big5:
                return String(localized: "Big5 (Traditional Chinese)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
            case .eucKR:
                return String(localized: "EUC-KR (Korean)",
                              comment: "The name of a text encoding in Book Information's Text Encoding pop-up, its row, and Speak Info: the encoding's standard name, which stays as it is, then the language or script it is for, in parentheses.")
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
