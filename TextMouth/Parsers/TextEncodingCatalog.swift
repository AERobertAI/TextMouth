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
        /// What a listener hears: the encoding's name, then the language or
        /// script it is for, such as "Windows-1251 (Cyrillic)".
        let name: String
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
        row("windows-1252", "Windows-1252 (Western European)"),
        row("macintosh", "Mac Roman (Western European)", tried: true),
        row("iso-8859-15", "ISO 8859-15 (Western European)", tried: true),
        // The DOS code pages of the United States and Western Europe, which
        // older text files from DOS and the Windows console still hold. Each
        // is taken only when Foundation's guess names it (not always tried),
        // and each is named apart, so the pop-up in Book Information offers
        // both.
        row("cp437", "CP437 (US DOS)"),
        row("cp850", "CP850 (Western European DOS)"),
        // Central European.
        row("windows-1250", "Windows-1250 (Central European)", tried: true),
        row("iso-8859-2", "ISO 8859-2 (Central European)", tried: true),
        row("x-mac-centraleurroman", "Mac Central European"),
        // Cyrillic.
        row("windows-1251", "Windows-1251 (Cyrillic)", tried: true),
        row("koi8-r", "KOI8-R (Russian)", tried: true),
        row("koi8-u", "KOI8-U (Ukrainian)", tried: true),
        row("cp866", "CP866 (Russian DOS)", tried: true),
        row("iso-8859-5", "ISO 8859-5 (Cyrillic)", tried: true),
        row("x-mac-cyrillic", "Mac Cyrillic", tried: true),
        // Greek, Turkish, Hebrew, Arabic, Baltic, and Thai. Hebrew is read
        // always, in Windows-1255 (ISO 8859-8 reads the same letters): its
        // letters are bytes that every Cyrillic encoding reads as clean
        // lowercase letters, so a short Hebrew text reads as well as
        // Windows-1251 as it does as Hebrew, and Foundation's guess names such
        // a text Windows-1251. The guesser must see both to see the tie.
        row("windows-1253", "Windows-1253 (Greek)"),
        row("iso-8859-7", "ISO 8859-7 (Greek)"),
        row("windows-1254", "Windows-1254 (Turkish)"),
        row("iso-8859-9", "ISO 8859-9 (Turkish)"),
        row("windows-1255", "Windows-1255 (Hebrew)", tried: true),
        row("iso-8859-8", "ISO 8859-8 (Hebrew)"),
        row("windows-1256", "Windows-1256 (Arabic)"),
        row("iso-8859-6", "ISO 8859-6 (Arabic)"),
        row("windows-1257", "Windows-1257 (Baltic)"),
        row("iso-8859-13", "ISO 8859-13 (Baltic)"),
        row("cp874", "Windows-874 (Thai)"),
        // Japanese, Chinese, and Korean. Windows' variants and the standards
        // they extend are named alike: they differ in a few symbols only.
        row("cp932", "Shift JIS (Japanese)"),
        row("shift_jis", "Shift JIS (Japanese)"),
        row("euc-jp", "EUC-JP (Japanese)"),
        row("iso-2022-jp", "ISO 2022-JP (Japanese)", sevenBit: true),
        row("gb18030", "GB 18030 (Simplified Chinese)"),
        row("gbk", "GBK (Simplified Chinese)"),
        row("cp936", "GBK (Simplified Chinese)"),
        row("gb2312", "GB 2312 (Simplified Chinese)"),
        row("big5", "Big5 (Traditional Chinese)"),
        row("cp950", "Big5 (Traditional Chinese)"),
        row("euc-kr", "EUC-KR (Korean)"),
        row("cp949", "EUC-KR (Korean)"),
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
    private static func row(_ identifier: String, _ name: String, tried: Bool = false, sevenBit: Bool = false) -> Entry? {
        guard let encoding = TextFileDecoder.encoding(forLabel: identifier) else { return nil }
        return Entry(identifier: identifier, encoding: encoding, name: name, isAlwaysTried: tried, isSevenBit: sevenBit)
    }
}
