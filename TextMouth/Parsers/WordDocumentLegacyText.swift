import Foundation

// MARK: - The Characters of a Word 6 or Word 95 Document

/// How the characters of a Word 6 or Word 95 document are stored and read.
/// Word 97 keeps text as Windows-1252 bytes or UTF-16; the older Word keeps
/// it in the code page of the document's language, one byte for a character,
/// or (`fExtChar`, the files of the Far East editions, and others that were
/// saved with them) two: a 16-bit little-endian unit that is the byte of a
/// Latin character with a zero above it, or the pair of bytes of a double-byte
/// character with its lead byte above (a character of Shift JIS "8A C7" is
/// stored C7 8A).
///
/// The code page is not in the FIB's language alone (a Japanese or a Russian
/// document says English there). For a document of one-byte characters it is
/// chosen for each run of text (`WordLegacyCodePages`) from the run's own mark,
/// its font's character set, and the document's default; what this holds is
/// the document's own part: the language's code page (or Mac Roman for a
/// document marked as a Macintosh one), the fonts, and the table that decodes a
/// single byte. For a document of two-byte characters the code page is the
/// document's: the double-byte one the fonts' character sets name (a Far East
/// font), else the language's.
struct WordLegacyCharacters {

    // MARK: State

    /// Bytes for each character: 1, or 2 for the 16-bit units of `fExtChar`.
    let width: Int
    /// The code page's encoding.
    private let encoding: String.Encoding
    /// The code unit of each single byte.
    private let singleBytes: [UInt16]
    /// The document's fonts.
    let fonts: WordFontTable
    /// Whether the FIB marks the document as the Macintosh's (`chs` 256).
    let isMacintosh: Bool
    /// The language the FIB names (`lid`).
    let languageIdentifier: Int

    /// Characters stored `width` bytes each in `encoding`.
    init(width: Int, encoding: String.Encoding, fonts: WordFontTable = .none, isMacintosh: Bool = false, languageIdentifier: Int = 0) {
        self.width = width
        self.encoding = encoding
        singleBytes = Self.table(for: encoding)
        self.fonts = fonts
        self.isMacintosh = isMacintosh
        self.languageIdentifier = languageIdentifier
    }

    /// The code unit of each single byte in `encoding`.
    static func table(for encoding: String.Encoding) -> [UInt16] {
        (0..<256).map { byte in
            // Controls and ASCII are themselves in every code page this reads (a field
            // mark, a tab, a page break must stay what they are), except a line feed.
            // Word 97 drops it; textutil reads it as the end of a line, and a listener
            // must not hear the words on either side of it run together.
            if byte == 0x0A { return 0x0B }
            if byte < 0x80 { return UInt16(byte) }
            // A byte the code page does not define is the Windows-1252 character, as in
            // a Far East document that holds Western text; one that neither defines is itself.
            return unit(ofByte: UInt8(byte), in: encoding) ?? unit(ofByte: UInt8(byte), in: .windowsCP1252) ?? UInt16(byte)
        }
    }

    /// The code unit of each single byte of text in the font named Symbol: the Adobe Symbol encoding
    /// (`AdobeSymbolEncoding.wordScalar(forCode:)`) from 0x20 up, a space for a code with no character a voice can
    /// speak, and the control bytes as themselves (a line feed a line break, as in every table).
    static func symbolFontTable() -> [UInt16] {
        (0..<256).map { byte in
            if byte == 0x0A { return 0x0B }
            if byte < 0x20 { return UInt16(byte) }
            guard let scalar = AdobeSymbolEncoding.wordScalar(forCode: byte), scalar.value <= 0xFFFF else { return 0x20 }
            return UInt16(scalar.value)
        }
    }

    /// The code unit `encoding` gives the single byte `byte`, or nil if it is not a character of it.
    private static func unit(ofByte byte: UInt8, in encoding: String.Encoding) -> UInt16? {
        guard let text = String(data: Data([byte]), encoding: encoding), text.utf16.count == 1,
              let unit = text.utf16.first, unit != 0xFFFD else { return nil }
        return unit
    }

    // MARK: Decoding

    /// The code unit of the single byte `byte`.
    func unit(ofByte byte: UInt8) -> UInt16 { singleBytes[Int(byte)] }

    /// What a stored 16-bit unit reads as: one code unit, or two.
    struct Decoded {
        var first: UInt16
        var second: UInt16?
    }

    /// The characters of the 16-bit stored unit `stored`: a byte with a zero above it is that byte; a
    /// pair (the lead byte above) is a character of the code page; and a pair that is none is its two
    /// bytes, the high one first, as textutil reads it: a document of this age holds a stray single byte
    /// beside the pairs now and then (a paragraph mark among them, which must not be lost).
    /// `cache` keeps the pairs already decoded: a document has few different characters.
    func characters(ofStored stored: UInt16, cache: inout [UInt16: Decoded]) -> Decoded {
        let high = UInt8(stored >> 8)
        let low = UInt8(stored & 0xFF)
        if high == 0 { return Decoded(first: singleBytes[Int(low)], second: nil) }
        if let known = cache[stored] { return known }
        var decoded = Decoded(first: singleBytes[Int(high)], second: singleBytes[Int(low)])
        if let text = String(data: Data([high, low]), encoding: encoding), text.utf16.count == 1, let unit = text.utf16.first,
           unit != 0xFFFD {
            decoded = Decoded(first: unit, second: nil)
        }
        cache[stored] = decoded
        return decoded
    }

    // MARK: Choosing the Code Page

    /// The characters of the Word 6 or Word 95 document `fib` describes,
    /// whose WordDocument stream is `document`. The language's code page is the document's
    /// (Mac Roman for a Macintosh document) unless its characters are two bytes each, when a
    /// font of a Far East character set names the double-byte code page.
    static func characters(of fib: WordFileInformationBlock, in document: OLEBytes) -> WordLegacyCharacters {
        let width = fib.hasTwoByteCharacters ? 2 : 1
        var fonts = WordFontTable.none
        if let range = try? fib.range(of: .fontTable, in: document), let table = try? WordFontTable.legacy(range: range, in: document) {
            fonts = table
        }
        let isMacintosh = fib.characterSet == 256
        var identifier = codePage(ofLanguage: fib.languageIdentifier)
        if isMacintosh {
            identifier = "macintosh"
        } else if width == 2 {
            // A font of a Far East character set names a double-byte code page, which only a
            // document of two-byte characters (`fExtChar`) is written in: the Western
            // editions of Word 6 and Word 95 name such fonts too, beside their own.
            identifier = fonts.characterSets.lazy.compactMap { codePage(ofFontCharacterSet: $0) }.first ?? identifier
        }
        let encoding = encoding(named: identifier) ?? encoding(named: TextEncodingCatalog.windows1252Identifier) ?? .windowsCP1252
        return WordLegacyCharacters(
            width: width, encoding: encoding, fonts: fonts, isMacintosh: isMacintosh, languageIdentifier: fib.languageIdentifier
        )
    }

    /// The code pages whose characters can be two bytes.
    static let doubleByteCodePages: Set<String> = ["cp932", "cp936", "cp949", "cp950"]

    /// The encoding the catalog names `identifier`.
    static func encoding(named identifier: String) -> String.Encoding? {
        TextEncodingCatalog.entry(forIdentifier: identifier)?.encoding
    }

    /// The code page for a font's character set, or nil for ANSI (0), symbol
    /// (2), the default (1), and ones this does not know: those say nothing
    /// that the language does not.
    static func codePage(ofFontCharacterSet set: Int) -> String? {
        switch set {
        case 128: return "cp932"
        case 129, 130: return "cp949"
        case 134: return "cp936"
        case 136: return "cp950"
        case 161: return "windows-1253"
        case 162: return "windows-1254"
        case 177: return "windows-1255"
        case 178: return "windows-1256"
        case 186: return "windows-1257"
        case 204: return "windows-1251"
        case 222: return "cp874"
        case 238: return "windows-1250"
        default: return nil
        }
    }

    /// The code page for a Windows language identifier (`lid`): by its
    /// primary language, the low ten bits, and for Chinese by its region too.
    static func codePage(ofLanguage lid: Int) -> String {
        switch lid & 0x3FF {
        case 0x04: return [0x0804, 0x1004].contains(lid) ? "cp936" : "cp950"
        case 0x11: return "cp932"
        case 0x12: return "cp949"
        case 0x05, 0x0E, 0x15, 0x18, 0x1A, 0x1B, 0x1C, 0x24: return "windows-1250"
        case 0x02, 0x19, 0x22, 0x23, 0x2F: return "windows-1251"
        case 0x08: return "windows-1253"
        case 0x1F, 0x2C: return "windows-1254"
        case 0x0D: return "windows-1255"
        case 0x01, 0x20, 0x29: return "windows-1256"
        case 0x25, 0x26, 0x27: return "windows-1257"
        case 0x1E: return "cp874"
        default: return TextEncodingCatalog.windows1252Identifier
        }
    }
}
