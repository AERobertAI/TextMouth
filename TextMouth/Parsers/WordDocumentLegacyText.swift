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
/// The code page is not in the FIB's language alone (a Japanese document says
/// English there), so it comes, in turn, from the character set of the
/// fonts the document names (the font table has one for each font:
/// SHIFTJIS_CHARSET and the like), then from the language, then is
/// Windows-1252; a document marked as a Macintosh one is Mac Roman.
struct WordLegacyCharacters {

    // MARK: State

    /// Bytes for each character: 1, or 2 for the 16-bit units of `fExtChar`.
    let width: Int
    /// The code page's encoding.
    private let encoding: String.Encoding
    /// The code unit of each single byte; a byte below 0x80 is its own.
    private let singleBytes: [UInt16]

    /// Characters stored `width` bytes each in `encoding`.
    init(width: Int, encoding: String.Encoding) {
        self.width = width
        self.encoding = encoding
        singleBytes = (0..<256).map { byte in
            // Controls and ASCII are themselves in every code page this reads
            // (a field mark, a tab, a page break must stay what they are).
            if byte < 0x80 { return UInt16(byte) }
            guard let text = String(data: Data([UInt8(byte)]), encoding: encoding), let unit = text.utf16.first,
                  text.utf16.count == 1 else { return UInt16(byte) }
            return unit
        }
    }

    // MARK: Decoding

    /// The code unit of the single byte `byte`.
    func unit(ofByte byte: UInt8) -> UInt16 { singleBytes[Int(byte)] }

    /// The code unit of the 16-bit stored unit `stored`, or nil for a pair
    /// of bytes that is not a character of the code page (it is then left
    /// out). `cache` keeps the pairs already decoded: a document has few
    /// different characters.
    func unit(ofStored stored: UInt16, cache: inout [UInt16: UInt16?]) -> UInt16? {
        let high = UInt8(stored >> 8)
        if high == 0 { return singleBytes[Int(stored & 0xFF)] }
        if let known = cache[stored] { return known }
        // The lead byte is the high byte.
        var decoded: UInt16?
        if let text = String(data: Data([high, UInt8(stored & 0xFF)]), encoding: encoding), text.utf16.count == 1 {
            decoded = text.utf16.first
        }
        cache[stored] = .some(decoded)
        return decoded
    }

    // MARK: Choosing the Code Page

    /// The characters of the Word 6 or Word 95 document `fib` describes,
    /// whose WordDocument stream is `document`.
    static func characters(of fib: WordFileInformationBlock, in document: OLEBytes) -> WordLegacyCharacters {
        let width = fib.hasTwoByteCharacters ? 2 : 1
        let fontSets = (try? fontCharacterSets(of: fib, in: document)) ?? []
        // A document marked as a Macintosh one (chs 256) is in Mac Roman.
        if fib.characterSet == 256, let encoding = encoding(named: "macintosh") {
            return WordLegacyCharacters(width: width, encoding: encoding)
        }
        let identifier = fontSets.lazy.compactMap { codePage(ofFontCharacterSet: $0) }.first
            ?? codePage(ofLanguage: fib.languageIdentifier)
        let encoding = encoding(named: identifier) ?? encoding(named: TextEncodingCatalog.windows1252Identifier) ?? .windowsCP1252
        return WordLegacyCharacters(width: width, encoding: encoding)
    }

    /// The encoding the catalog names `identifier`.
    private static func encoding(named identifier: String) -> String.Encoding? {
        TextEncodingCatalog.entry(forIdentifier: identifier)?.encoding
    }

    /// The character sets (`chs`) of the fonts in the font table, in order:
    /// a 16-bit size, then each font as a size byte (of the rest of the
    /// font), a byte of flags, the 16-bit weight, the character set, a byte
    /// for the name's place, and the name. A table that does not fit gives
    /// the sets read before it.
    private static func fontCharacterSets(of fib: WordFileInformationBlock, in document: OLEBytes) throws -> [Int] {
        guard let range = try fib.range(of: .fontTable, in: document), range.count >= 2 else { return [] }
        var sets: [Int] = []
        var position = range.lowerBound + 2
        // Each font takes at least 6 bytes, which bounds the walk.
        while position + 6 <= range.upperBound, sets.count < 4096 {
            let size = try document.u8(position)
            guard size >= 5 else { break }
            sets.append(try document.u8(position + 4))
            position += size + 1
        }
        return sets
    }

    /// The code page for a font's character set, or nil for ANSI (0), symbol
    /// (2), the default (1), and ones this does not know: those say nothing
    /// that the language does not.
    private static func codePage(ofFontCharacterSet set: Int) -> String? {
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
    private static func codePage(ofLanguage lid: Int) -> String {
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
